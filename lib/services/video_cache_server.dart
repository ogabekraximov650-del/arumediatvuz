import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

// ── Videoni doimiy, bayt-darajasida diskka keshlaydigan mahalliy proksi ──
//
// Video pleyer (video_player/fvp) to'g'ridan-to'g'ri masofaviy URL'ga emas,
// shu klass ochadigan mahalliy (127.0.0.1) HTTP serverga ulanadi. Server
// har bir video uchun kelayotgan Range so'rovlarini tahlil qilib:
//   - diskda ALLAQACHON mavjud bo'lgan bo'laklarni to'g'ridan-to'g'ri
//     fayldan o'qib qaytaradi (worker'ga so'rov YUBORMAYDI),
//   - diskda YO'Q bo'lgan bo'laklarnigina worker'dan yuklab, diskka
//     yozib qo'yadi va shundan keyingina klientga uzatadi.
//
// Har bir video FIKSIRLANGAN 1 MiB (1 048 576 bayt) chegaralarga
// tekislangan "chunk" fayllarga bo'lib saqlanadi (chunk_0000000.bin,
// chunk_0000001.bin, ...). Bu ataylab shunday tanlangan: kelajakda har
// bir bo'lak bitta umumiy kalit bilan AES orqali mustaqil shifrlanishi
// rejalashtirilgan (Android'da kalit Android Keystore'da saqlanadi) —
// hozirgi bo'lak-asosidagi tuzilma o'sha bosqichga tayyor holda qoladi,
// faqat bo'lak yozish/o'qish joyiga shifrlash/deshifrlash qo'shiladi.
//
// Fayllar path_provider'ning "Application Support" papkasida saqlanadi —
// bu ilovaning shaxsiy, faqat o'zi (va qurilmada root) kira oladigan
// ichki xotirasi (Android: /data/user/0/<paket>/..., tashqi/almashinuv
// xotirasi EMAS) — xuddi Telegram media keshini saqlagani kabi.
class VideoCacheServer {
  VideoCacheServer._();
  static final VideoCacheServer instance = VideoCacheServer._();

  // Kelajakdagi AES-per-chunk shifrlash rejasi bilan mos: 1 MiB.
  static const int chunkSize = 1024 * 1024;

  HttpServer? _server;
  Directory? _cacheRoot;
  Future<void>? _starting;

  final Map<String, Future<Uint8List>> _inFlightChunks = {};
  final Map<String, Future<_CacheMeta>> _inFlightMeta = {};

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    if (_starting != null) return _starting;
    final completer = Completer<void>();
    _starting = completer.future;
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory('${support.path}/video_byte_cache');
      await root.create(recursive: true);
      _cacheRoot = root;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handleRequest);
      _server = server;
    } finally {
      completer.complete();
      _starting = null;
    }
  }

  // Berilgan asl (masofaviy) URL o'rniga video_player'ga beriladigan
  // mahalliy proksi URL'ini qaytaradi. Serverni kerak bo'lsa ishga
  // tushiradi (lazy — ilova ochilganda emas, birinchi video o'ynatilganda).
  Future<Uri> proxyUri(String originalUrl) async {
    await _ensureStarted();
    return Uri.parse(
        'http://127.0.0.1:${_server!.port}/v?u=${Uri.encodeQueryComponent(originalUrl)}');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final originalUrl = request.uri.queryParameters['u'];
      if (originalUrl == null || originalUrl.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      await _serve(request, originalUrl);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(HttpRequest request, String originalUrl) async {
    final key = _hashUrl(originalUrl);
    final dir = Directory('${_cacheRoot!.path}/$key');
    await dir.create(recursive: true);

    final meta = await _ensureMeta(dir, originalUrl);
    final total = meta.totalSize;

    if (total <= 0) {
      // Hajmi aniqlanmadi (masalan manba Range'ni qo'llab-quvvatlamaydi
      // yoki jonli oqim) — keshlamasdan to'g'ridan-to'g'ri o'tkazamiz.
      await _passthrough(request, originalUrl);
      return;
    }

    int start = 0;
    int end = total - 1;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final isRange = rangeHeader != null && rangeHeader.startsWith('bytes=');
    if (isRange) {
      final spec = rangeHeader.substring(6).split('-');
      if (spec[0].isEmpty && spec.length > 1 && spec[1].isNotEmpty) {
        // "bytes=-N" — faylning OXIRIDAN N bayt (masalan FFmpeg/mdk-sdk
        // moov atomini o'qish uchun MP4 oxirini shunday so'rashi mumkin).
        final suffixLen = int.tryParse(spec[1]) ?? 0;
        start = total - suffixLen;
        if (start < 0) start = 0;
        end = total - 1;
      } else {
        if (spec[0].isNotEmpty) start = int.tryParse(spec[0]) ?? 0;
        if (spec.length > 1 && spec[1].isNotEmpty) {
          end = int.tryParse(spec[1]) ?? (total - 1);
        }
      }
      if (end > total - 1) end = total - 1;
      if (start < 0 || start > end) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await request.response.close();
        return;
      }
    }

    request.response.statusCode =
        isRange ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, meta.contentType)
      ..contentLength = end - start + 1;
    if (isRange) {
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    }

    try {
      var cursor = start;
      while (cursor <= end) {
        final chunkIndex = cursor ~/ chunkSize;
        final chunkStart = chunkIndex * chunkSize;
        final chunkEndMax = chunkStart + chunkSize - 1;
        final chunkEnd = chunkEndMax < total - 1 ? chunkEndMax : total - 1;
        final expectedLen = chunkEnd - chunkStart + 1;

        final chunkBytes = await _readOrFetchChunk(
            key, dir, originalUrl, chunkIndex, chunkStart, chunkEnd, expectedLen);

        final sliceStart = cursor - chunkStart;
        final sliceEndExclusive =
            (end < chunkEnd ? end : chunkEnd) - chunkStart + 1;
        request.response.add(chunkBytes.sublist(sliceStart, sliceEndExclusive));
        await request.response.flush();
        cursor = chunkStart + sliceEndExclusive;
      }
    } catch (_) {
      // Klient uzildi (masalan foydalanuvchi yangi joyga sek qildi va
      // pleyer eski so'rovni bekor qildi) — jim tugatamiz, xato emas.
    }
    try {
      await request.response.close();
    } catch (_) {}
  }

  Future<Uint8List> _readOrFetchChunk(String key, Directory dir, String url,
      int index, int start, int end, int expectedLen) async {
    final finalFile = File('${dir.path}/${_chunkName(index)}');
    if (await finalFile.exists()) {
      final onDisk = await finalFile.readAsBytes();
      if (onDisk.length == expectedLen) return onDisk;
    }

    final flightKey = '$key#$index';
    final inFlight = _inFlightChunks[flightKey];
    if (inFlight != null) return inFlight;

    final future = _fetchAndStoreChunk(dir, url, index, start, end)
        .whenComplete(() => _inFlightChunks.remove(flightKey));
    _inFlightChunks[flightKey] = future;
    return future;
  }

  Future<Uint8List> _fetchAndStoreChunk(
      Directory dir, String url, int index, int start, int end) async {
    // Boshqa parallel so'rov ushbu bo'lakni bizdan oldin allaqachon
    // yuklab ulgurgan bo'lishi mumkin — tarmoqqa chiqishdan oldin
    // yana bir bor tekshiramiz.
    final finalFile = File('${dir.path}/${_chunkName(index)}');
    final expectedLen = end - start + 1;
    if (await finalFile.exists()) {
      final onDisk = await finalFile.readAsBytes();
      if (onDisk.length == expectedLen) return onDisk;
    }

    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != HttpStatus.partialContent &&
          res.statusCode != HttpStatus.ok) {
        throw HttpException('Yuklab olishda xato: ${res.statusCode}');
      }

      // MUHIM: server Range so'rovini e'tiborsiz qoldirib TO'LIQ faylni
      // (0-baytdan boshlab) 200 status bilan yuborayotgan bo'lishi mumkin.
      // Bunday holatda bizga kerakli [start,end] qismi javob TANASINING
      // BOSHIDA emas, "start" bayt ichkariroqda joylashgan bo'ladi — shu
      // sabab avval "start" ta baytni tashlab yuboramiz (skip), keyin
      // kerakli "expectedLen" baytni yig'amiz. ENG MUHIMI: kerakli
      // baytlar to'planishi bilanoq pastda "break" bilan o'qishni
      // TO'XTATAMIZ — aks holda (ayniqsa faylning keyingi bo'laklari
      // uchun) qolgan BUTUN faylni oxirigacha behuda yuklab olar edik,
      // bu esa aynan pleyer umuman ochilmay, tarmoq esa sekin-sekin
      // ishlab turishining sababi edi.
      final ignoresRange = res.statusCode == HttpStatus.ok;
      final skipBytes = ignoresRange ? start : 0;

      final builder = BytesBuilder(copy: false);
      var skipped = 0;
      var collected = 0;
      await for (final part in res) {
        var piece = part;
        if (skipped < skipBytes) {
          final toSkip = skipBytes - skipped;
          if (piece.length <= toSkip) {
            skipped += piece.length;
            continue;
          }
          piece = piece.sublist(toSkip);
          skipped = skipBytes;
        }
        final remaining = expectedLen - collected;
        if (piece.length > remaining) {
          piece = piece.sublist(0, remaining);
        }
        builder.add(piece);
        collected += piece.length;
        if (collected >= expectedLen) break;
      }
      final bytes = builder.takeBytes();

      // Ulanish o'rtada uzilib, KUTILGANDAN QISQAROQ bayt kelishi mumkin
      // (masalan tarmoq muammosi) — bunday chala natijani DISKKA
      // YOZMAYMIZ, aks holda kesh "to'liq" deb noto'g'ri belgilanib
      // qolar edi. Klientga qisman natija baribir qaytariladi (yuqorida
      // chaqiruvchi uni "uzildi" deb talqin qilib jim tugatadi), keyingi
      // so'rov esa qaytadan tarmoqdan to'liq yuklab oladi.
      if (bytes.length == expectedLen) {
        // Diskka faqat TO'LIQ bo'lak yuklab bo'lingandan keyin,
        // vaqtinchalik nomdan YAKUNIY nomga ATOM ravishda ko'chirib
        // yoziladi — shu bilan yuklash so'rov bekor qilinsa ham (masalan
        // sek), keshda hech qachon yarim/buzuq bo'lak qolmaydi.
        final tmpFile = File('${dir.path}/${_chunkName(index)}.${DateTime.now().microsecondsSinceEpoch}.tmp');
        await tmpFile.writeAsBytes(bytes, flush: true);
        try {
          await tmpFile.rename(finalFile.path);
        } catch (_) {
          // Parallel so'rov bizdan oldin yozib ulgurgan bo'lishi mumkin —
          // vaqtinchalik faylni tozalaymiz, xato emas.
          try {
            await tmpFile.delete();
          } catch (_) {}
        }
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<_CacheMeta> _ensureMeta(Directory dir, String url) {
    final flightKey = dir.path;
    final existing = _inFlightMeta[flightKey];
    if (existing != null) return existing;
    final future = _loadOrProbeMeta(dir, url)
        .whenComplete(() => _inFlightMeta.remove(flightKey));
    _inFlightMeta[flightKey] = future;
    return future;
  }

  Future<_CacheMeta> _loadOrProbeMeta(Directory dir, String url) async {
    final metaFile = File('${dir.path}/meta.json');
    if (await metaFile.exists()) {
      try {
        final map = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        final size = map['totalSize'] as int?;
        final ct = map['contentType'] as String?;
        if (size != null && size > 0) {
          return _CacheMeta(size, ct ?? 'video/mp4');
        }
      } catch (_) {}
    }

    final client = HttpClient();
    try {
      int size = -1;
      String contentType = 'video/mp4';

      // HEAD so'rovida javob TANASI umuman bo'lmaydi — shu sabab bu yerda
      // hech narsani "drain" qilish shart emas.
      try {
        final headReq = await client
            .headUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        final headRes = await headReq.close().timeout(const Duration(seconds: 10));
        if (headRes.contentLength > 0) size = headRes.contentLength;
        final ct = headRes.headers.value(HttpHeaders.contentTypeHeader);
        if (ct != null && ct.isNotEmpty) contentType = ct;
      } catch (_) {}

      if (size <= 0) {
        // MUHIM: agar server HEAD'ni qo'llab-quvvatlamasa, zaxira sifatida
        // "bytes=0-0" bilan GET yuboramiz — LEKIN javob tanasini HECH
        // QACHON o'qib (drain qilib) chiqmaymiz! Agar server Range'ni
        // e'tiborsiz qoldirib TO'LIQ videoni 200 status bilan yubora
        // boshlagan bo'lsa, uni oxirigacha o'qish shunchaki hajmini
        // bilish uchun BUTUN VIDEONI behuda yuklab olishga (va shu
        // paytda pleyerning umuman ochilmasligiga) sabab bo'lardi.
        // Sarlavhalarni o'qib bo'lgach, ulanish pastdagi finally blokida
        // client.close(force: true) orqali MAJBURAN yopib tashlanadi —
        // tana hech qachon yuklanmaydi.
        final req = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final res = await req.close().timeout(const Duration(seconds: 10));
        final contentRange = res.headers.value(HttpHeaders.contentRangeHeader);
        if (contentRange != null && contentRange.contains('/')) {
          // Server Range'ga hurmat qilib, chindan ham 206 (qisman) javob
          // qaytargan — "Content-Range: bytes 0-0/<umumiy hajm>".
          size = int.tryParse(contentRange.split('/').last) ?? -1;
        } else if (res.statusCode == HttpStatus.ok && res.contentLength > 0) {
          // Server Range'ni e'tiborsiz qoldirib, TO'LIQ tanani 200 status
          // bilan yubormoqchi — bu holatda Content-Length aynan UMUMIY
          // hajmning o'zi (tanani o'qimasdan ham buni bilib olamiz).
          size = res.contentLength;
        }
        final ct = res.headers.value(HttpHeaders.contentTypeHeader);
        if (ct != null && ct.isNotEmpty) contentType = ct;
      }

      final meta = _CacheMeta(size, contentType);
      if (size > 0) {
        await metaFile.writeAsString(
            jsonEncode({'totalSize': size, 'contentType': contentType}));
      }
      return meta;
    } finally {
      client.close(force: true);
    }
  }

  // Hajmi noma'lum/keshlanmaydigan manbalar uchun zaxira yo'l: so'rovni
  // xech qanday keshlashsiz to'g'ridan-to'g'ri manbaga uzatadi.
  Future<void> _passthrough(HttpRequest request, String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null) req.headers.set(HttpHeaders.rangeHeader, rangeHeader);
      final res = await req.close();
      request.response.statusCode = res.statusCode;
      res.headers.forEach((name, values) {
        for (final v in values) {
          request.response.headers.add(name, v);
        }
      });
      await request.response.addStream(res);
    } catch (_) {
    } finally {
      client.close(force: true);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  String _chunkName(int index) => 'chunk_${index.toString().padLeft(7, '0')}.bin';

  // Barqaror, fayl nomi sifatida xavfsiz kesh kaliti — tashqi kripto
  // paketiga muhtoj bo'lmaslik uchun oddiy FNV-1a (64-bit) xeshi.
  String _hashUrl(String url) {
    const prime = 0x100000001b3;
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(url)) {
      hash = (hash ^ byte) & 0xFFFFFFFFFFFFFFFF;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

class _CacheMeta {
  final int totalSize;
  final String contentType;
  _CacheMeta(this.totalSize, this.contentType);
}
