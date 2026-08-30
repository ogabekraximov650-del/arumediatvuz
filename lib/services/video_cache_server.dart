import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show RootIsolateToken, BackgroundIsolateBinaryMessenger;
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
//
// MUHIM ARXITEKTURA QARORI (muzlab qolish diagnostikasi natijasi): server
// ASOSIY (UI) isolate'da EMAS, ALOHIDA fon Isolate'da ishlaydi. Sabab: agar
// server asosiy isolate'da bo'lsa va o'sha ish oqimi biror sababdan (masalan
// video pleyerning ichki native ishga tushirish jarayoni) band bo'lib
// qolsa — server so'rovga javob berolmaydi, video pleyer esa aynan shu
// javobni kutib turadi. Bu o'z-o'ziga qulflanish (deadlock) hosil qiladi:
// hech qanday Dart Timer/timeout ham ishlamaydi, chunki ular ham xuddi
// o'sha band bo'lgan ish oqimida rejalashtiriladi. Diagnostikada aynan shu
// holat kuzatilgan edi: "meta.json diskdan o'qildi" logidan keyin HATTO
// 5 soniyalik timeout'lar ham ishlamay, jarayon butunlay to'xtab qolgan.
// Serverni mustaqil Isolate'ga chiqarish bu klassdagi muammoni tag-tugidan
// yo'q qiladi — endi u asosiy ish oqimi nima bilan band bo'lishidan qat'i
// nazar har doim so'rovlarga javob bera oladi.
class VideoCacheServer {
  VideoCacheServer._();
  static final VideoCacheServer instance = VideoCacheServer._();

  Isolate? _isolate;
  int? _port;
  String? _cacheRootPath;
  Future<int>? _starting;

  // ── Diagnostika jurnali ──────────────────────────────────────────
  // Mahalliy server nima uchun ishlamayotganini QURILMANING O'ZIDA,
  // ekranda ko'rish uchun (adb/logcat kerak bo'lmasdan). video_player_
  // screen.dart shu ro'yxatni tinglab, so'nggi qatorlarni ekranda kichik
  // panel sifatida ko'rsatadi.
  static final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  // video_player_screen.dart kabi tashqi fayllar ham shu umumiy
  // (xronologik) jurnalga yozishi uchun ochiq wrapper.
  static void log(String msg) => _log(msg);

  static void _log(String msg, {bool alreadyPersisted = false}) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    final line = '[$ts] $msg';
    final list = List<String>.from(logs.value)..add(line);
    if (list.length > 200) list.removeRange(0, list.length - 200);
    logs.value = list;

    // Kesh-isolate o'z log qatorlarini o'zi diskka yozadi (pastga q.);
    // faqat ASOSIY isolate'dan chiqqan loglarni (masalan proxyUri yoki
    // ctrl.initialize xatolari) shu yerda alohida yozamiz — shunda ikkala
    // isolate'ning loglari BITTA umumiy fayl ichida xronologik aralashadi.
    if (!alreadyPersisted) {
      final root = instance._cacheRootPath;
      if (root != null) {
        try {
          File('$root/debug_log.txt')
              .writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
        } catch (_) {}
      }
    }
  }

  // Berilgan asl (masofaviy) URL o'rniga video_player'ga beriladigan
  // mahalliy proksi URL'ini qaytaradi. Serverni kerak bo'lsa ishga
  // tushiradi (lazy — ilova ochilganda emas, birinchi video o'ynatilganda).
  //
  // MUHIM: 5 soniyalik timeout bilan himoyalangan. Ba'zi qurilmalarda
  // (masalan MIUI'ning agressiv tarmoq cheklovlari) mahalliy HTTP
  // server ochish muammoli bo'lishi mumkin — bunday holatda bu funksiya
  // cheksiz kutib qolmasdan xato tashlaydi, chaqiruvchi (video_player_
  // screen.dart) esa buni ushlab, ASL (kesh'siz) URL bilan to'g'ridan-
  // to'g'ri o'ynatishga qaytadi. Shu bilan kesh ishlamasa ham video
  // pleyer HECH QACHON abadiy "yuklanmoqda" holatida qotib qolmaydi.
  Future<Uri> proxyUri(String originalUrl) async {
    _log('proxyUri chaqirildi: ${_shortUrl(originalUrl)}');
    final port = await _ensureStarted().timeout(const Duration(seconds: 5));
    return Uri.parse(
        'http://127.0.0.1:$port/v?u=${Uri.encodeQueryComponent(originalUrl)}');
  }

  Future<int> _ensureStarted() {
    if (_port != null) return Future.value(_port);
    if (_starting != null) return _starting!;
    final completer = Completer<int>();
    _starting = completer.future;
    _spawnIsolate(completer);
    return completer.future;
  }

  Future<void> _spawnIsolate(Completer<int> completer) async {
    _log('Kesh-server uchun ALOHIDA isolate ishga tushirilmoqda...');
    final mainReceivePort = ReceivePort();
    RootIsolateToken? token;
    try {
      token = RootIsolateToken.instance;
      if (token == null) {
        throw StateError('RootIsolateToken olinmadi');
      }
      _isolate = await Isolate.spawn(
        _serverIsolateMain,
        _IsolateInit(mainReceivePort.sendPort, token),
        debugName: 'video_cache_server',
      );
    } catch (e) {
      _log('XATO: kesh-server isolate ishga tushmadi — $e');
      if (!completer.isCompleted) completer.completeError(e);
      _starting = null;
      return;
    }

    mainReceivePort.listen((dynamic message) {
      if (message is! List || message.isEmpty) return;
      final kind = message[0];
      if (kind == 'started') {
        _port = message[1] as int;
        _cacheRootPath = message[2] as String;
        _log('Kesh-server isolate ishga tushdi: 127.0.0.1:$_port');
        if (!completer.isCompleted) completer.complete(_port);
        _starting = null;
      } else if (kind == 'log') {
        // Isolate o'zi diskka allaqachon yozgan — bu yerda faqat
        // ekrandagi (UI) ro'yxatga qo'shamiz, qayta diskka yozmaymiz.
        _log(message[1] as String, alreadyPersisted: true);
      } else if (kind == 'error') {
        final err = message[1];
        _log('XATO (kesh-server isolate): $err');
        if (!completer.isCompleted) {
          completer.completeError(StateError(err.toString()));
          _starting = null;
        }
      }
    });
  }

  static String _shortUrl(String url) =>
      url.length > 70 ? '...${url.substring(url.length - 70)}' : url;
}

// Isolate.spawn'ga argument sifatida uzatiladigan yengil, sendable paket.
class _IsolateInit {
  final SendPort mainSendPort;
  final RootIsolateToken rootIsolateToken;
  _IsolateInit(this.mainSendPort, this.rootIsolateToken);
}

// ── Fon isolate'ning kirish nuqtasi ─────────────────────────────────────
// Bu funksiya butunlay MUSTAQIL Dart isolate'ida ishlaydi — asosiy (UI)
// isolate bilan XOTIRA ULASHMAYDI, faqat SendPort orqali xabar almashadi.
// Shu sabab asosiy isolate qanchalik band bo'lmasin (video pleyerning
// ichki ishga tushirish jarayoni, og'ir widget qayta chizish va h.k.), bu
// yerdagi HTTP server har doim mustaqil ravishda so'rovlarga javob bera
// oladi.
void _serverIsolateMain(_IsolateInit init) async {
  final mainSendPort = init.mainSendPort;
  void isoLog(String msg) {
    mainSendPort.send(['log', msg]);
  }

  try {
    // MUHIM: fon isolate'da path_provider kabi platform-kanal (MethodChannel)
    // paketlaridan foydalanish uchun bu chaqiruv SHART — aks holda ular
    // yoki xato tashlaydi, yoki (yomonrog'i) abadiy osilib qoladi.
    BackgroundIsolateBinaryMessenger.ensureInitialized(init.rootIsolateToken);

    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/video_byte_cache');
    await root.create(recursive: true);
    isoLog('Kesh papkasi: ${root.path}');

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    isoLog('Server (fon isolate) ishga tushdi: 127.0.0.1:${server.port}');
    mainSendPort.send(['started', server.port, root.path]);

    final engine = _CacheEngine(root, (msg) {
      final now = DateTime.now();
      final ts =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
      final line = '[$ts] $msg';
      // Fon isolate'ning o'zi TO'G'RIDAN-TO'G'RI diskka yozadi — bu asosiy
      // isolate qanchalik band/muzlagan bo'lmasin, HAQIQIY vaqt jurnalini
      // kafolatlaydi (UI paneliga bog'liq emas).
      try {
        File('${root.path}/debug_log.txt')
            .writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      } catch (_) {}
      mainSendPort.send(['log', msg]);
    });
    server.listen(engine.handleRequest);
  } catch (e, st) {
    mainSendPort.send(['error', '$e | ${st.toString().split('\n').take(2).join(' ')}']);
  }
}

// ── Haqiqiy kesh-server mantiqi — fon isolate ichida ishlaydi ──────────
// Avval VideoCacheServer'ning o'zida edi; endi mustaqil, statik bo'lmagan
// holatga ega klass sifatida ajratildi — shunda uni to'g'ridan-to'g'ri
// Isolate ichida (asosiy isolate'ning hech qanday statik holatiga
// tegmasdan) ishlatish mumkin.
class _CacheEngine {
  _CacheEngine(this._cacheRoot, this._log);

  final Directory _cacheRoot;
  final void Function(String) _log;

  static const int chunkSize = 1024 * 1024;

  // MUHIM (real qurilmada aniqlangan tuzatish): worker'ga qilinadigan
  // BARCHA so'rovlar (bo'lak yuklash, meta-probe) SHU BITTA doimiy
  // HttpClient orqali amalga oshiriladi va u HECH QACHON yopilmaydi.
  // Avval har bir bo'lak uchun ALOHIDA "HttpClient()" yaratilib, ishdan
  // so'ng "close(force: true)" bilan majburan yopilar edi — bu esa har
  // bir bo'lak uchun QAYTA-QAYTA yangi TCP+TLS handshake talab qilardi.
  // Tez sinov muhitida bu sezilarsiz (~0.6s) edi, lekin haqiqiy mobil
  // tarmoqda handshake o'zi soniyalab vaqt olib, ketma-ket bir nechta
  // bo'lakni 15 soniyalik ctrl.initialize() oynasi ichida yuklab
  // ulgurmaslikka (va shu bilan "faqat qayta bosganda bittadan bo'lak
  // yuklanish" holatiga) sabab bo'lgan. Bitta HttpClient'ni qayta
  // ishlatish (Dart standart holatda ulanishlarni keep-alive bilan
  // saqlaydi) bu handshake xarajatini deyarli yo'q qiladi.
  final HttpClient _sharedClient = HttpClient()
    ..idleTimeout = const Duration(seconds: 60)
    ..maxConnectionsPerHost = 6;

  final Map<String, Future<Uint8List>> _inFlightChunks = {};
  final Map<String, Future<_CacheMeta>> _inFlightMeta = {};
  int _activeRequests = 0;

  // MUHIM (qurilmada aniqlangan xato): foydalanuvchi epizod tugmasini
  // qayta bossa, ESKI (tashlab ketilgan) so'rov uchun _serve va uning
  // _prefetchAhead zanjiri hech qachon bekor qilinmasdi — ular orqa
  // fonda cheksiz davom etib, hech kim kutmaydigan bo'laklarni
  // tarmoqdan yuklashda davom etar edi. Bir necha marta qayta bosilsa,
  // bir nechta bunday "o'lik" jarayon PARALLEL yig'ilib, tarmoq/xotira
  // ziddiyatiga (va oxir-oqibat ilova OOM bilan o'chib qolishiga) sabab
  // bo'lardi — aynan shu narsa "har safar tugma bosilganda MB ketishi"
  // va "ilova qotib, o'chib qolishi" holatlarining sababi edi.
  //
  // Har bir video (kalit) uchun "avlod" raqami saqlanadi: har safar
  // o'sha videoga YANGI so'rov kelganda bu raqam oshiriladi. Eski
  // so'rovning _serve tsikli va undan tug'ilgan _prefetchAhead
  // zanjirlari o'z avlod raqamini eskirganini sezishi bilanoq DARHOL
  // to'xtaydi — allaqachon boshlangan (in-flight) bitta bo'lak yuklashi
  // baribir yakunlanadi (bekor qilinmaydi, chunki keshga foydali), lekin
  // undan KEYINGI hech qanday yangi yuklash boshlanmaydi.
  final Map<String, int> _activeGeneration = {};

  Future<void> handleRequest(HttpRequest request) async {
    final rangeHdr = request.headers.value(HttpHeaders.rangeHeader) ?? '(hammasi)';
    _activeRequests++;
    final myReqId = _activeRequests;
    try {
      final originalUrl = request.uri.queryParameters['u'];
      if (originalUrl == null || originalUrl.isEmpty) {
        _log('So\'rov: u parametri yo\'q — 400');
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      _log('So\'rov keldi (#$myReqId, faol jami=$_activeRequests): Range=$rangeHdr');
      await _serve(request, originalUrl);
      _log('So\'rov (#$myReqId) _serve dan qaytdi');
    } catch (e, st) {
      _log('XATO (_handleRequest #$myReqId): $e');
      _log('  stack: ${st.toString().split('\n').take(3).join(' | ')}');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    } finally {
      _activeRequests--;
    }
  }

  Future<void> _serve(HttpRequest request, String originalUrl) async {
    _log('_serve boshlandi');
    final key = _hashUrl(originalUrl);
    // Shu videoga qilingan har qanday OLDINGI (hali tugamagan) so'rovni
    // "eskirgan" deb belgilaydi — ular o'z navbatidagi tekshiruvda buni
    // sezib, o'z-o'zini to'xtatadi (pastga qarang).
    final myGeneration = (_activeGeneration[key] ?? 0) + 1;
    _activeGeneration[key] = myGeneration;
    final dir = Directory('${_cacheRoot.path}/$key');
    _log('Papka yaratilmoqda: ${dir.path}');
    await dir.create(recursive: true).timeout(const Duration(seconds: 5),
        onTimeout: () {
      _log('XATO: papka yaratish 5s ichida tugamadi!');
      return dir;
    });
    _log('Papka tayyor, _ensureMeta chaqirilyapti...');

    final meta = await _ensureMeta(dir, originalUrl).timeout(
        const Duration(seconds: 8), onTimeout: () {
      _log('XATO: _ensureMeta 8s ichida await dan qaytmadi!');
      throw TimeoutException('_ensureMeta await timeout');
    });
    _log('_ensureMeta dan qaytdi');
    final total = meta.totalSize;
    _log('Meta: hajm=$total, tur=${meta.contentType}');

    if (total <= 0) {
      // Hajmi aniqlanmadi (masalan manba Range'ni qo'llab-quvvatlamaydi
      // yoki jonli oqim) — keshlamasdan to'g'ridan-to'g'ri o'tkazamiz.
      _log('Hajm aniqlanmadi (total<=0) — to\'g\'ridan-to\'g\'ri o\'tkazish');
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

    var cancelled = false;
    try {
      var cursor = start;
      while (cursor <= end) {
        if (_activeGeneration[key] != myGeneration) {
          // Shu videoga YANGI so'rov kelib ulgurgan — bu (eski) so'rov
          // endi hech kimga kerak emas, tsiklni darhol to'xtatamiz (lekin
          // pastdagi response.close() baribir bajarilishi uchun "return"
          // emas, "break" ishlatiladi).
          _log('_serve bekor qilindi (yangi so\'rov boshlangan, avlod eskirdi)');
          cancelled = true;
          break;
        }
        final chunkIndex = cursor ~/ chunkSize;
        final chunkStart = chunkIndex * chunkSize;
        final chunkEndMax = chunkStart + chunkSize - 1;
        final chunkEnd = chunkEndMax < total - 1 ? chunkEndMax : total - 1;
        final expectedLen = chunkEnd - chunkStart + 1;

        final chunkBytes = await _readOrFetchChunk(
            key, dir, originalUrl, chunkIndex, chunkStart, chunkEnd, expectedLen);
        _log('Bo\'lak #$chunkIndex tayyor (${chunkBytes.length} bayt)');
        if (_activeGeneration[key] == myGeneration) {
          _prefetchAhead(key, dir, originalUrl, chunkIndex + 1, total, myGeneration);
        }

        final sliceStart = cursor - chunkStart;
        final sliceEndExclusive =
            (end < chunkEnd ? end : chunkEnd) - chunkStart + 1;
        request.response.add(chunkBytes.sublist(sliceStart, sliceEndExclusive));
        await request.response.flush();
        cursor = chunkStart + sliceEndExclusive;
      }
      if (!cancelled) {
        _log('So\'rov muvaffaqiyatli yakunlandi ($start-$end)');
      }
    } catch (e) {
      // Klient uzilgan bo'lishi mumkin (masalan foydalanuvchi yangi
      // joyga sek qildi va pleyer eski so'rovni bekor qildi) — bu holat
      // klientga xato sifatida qaytarilmaydi, lekin diagnostika uchun
      // baribir jurnalga yoziladi.
      _log('So\'rov uzildi/xato ($start-$end): $e');
    }
    try {
      await request.response.close();
    } catch (_) {}
  }

  Future<Uint8List> _readOrFetchChunk(String key, Directory dir, String url,
      int index, int start, int end, int expectedLen) async {
    _log('Bo\'lak #$index diskda bor-yo\'qligi tekshirilmoqda...');
    final finalFile = File('${dir.path}/${_chunkName(index)}');
    final exists = await finalFile.exists().timeout(
        const Duration(seconds: 5), onTimeout: () {
      _log('XATO: bo\'lak #$index exists() 5s ichida tugamadi!');
      return false;
    });
    if (exists) {
      final onDisk =
          await finalFile.readAsBytes().timeout(const Duration(seconds: 5));
      if (onDisk.length == expectedLen) {
        _log('Bo\'lak #$index diskdan o\'qildi (${onDisk.length} bayt)');
        return onDisk;
      }
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

    _log('Bo\'lak #$index worker\'dan yuklanmoqda ($start-$end)...');
    try {
      final req = await _sharedClient
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      final res = await req.close().timeout(const Duration(seconds: 10));
      _log('Bo\'lak #$index javob: status=${res.statusCode}');
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
      _log('Bo\'lak #$index yig\'ildi: ${bytes.length}/$expectedLen bayt');

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
    } catch (e) {
      _log('XATO: bo\'lak #$index yuklanmadi — $e');
      rethrow;
    }
    // MUHIM: bu yerda client.close() ATAYLAB chaqirilmaydi — _sharedClient
    // butun server umri davomida ochiq qoladi, shunda keyingi bo'lak
    // so'rovlari mavjud (keep-alive) ulanishni qayta ishlatadi.
  }

  // Joriy bo'lak muvaffaqiyatli olingandan keyin, undan KEYINGI (hali
  // diskda yo'q va hali yuklanmayotgan) bir nechta bo'lakni FON'DA,
  // hech kimni kutmasdan oldindan yuklab qo'yadi. Shu bilan pleyer
  // ularga yetib kelguncha ular allaqachon diskda tayyor turadi — endi
  // har bir bo'lak uchun alohida "qayta bos" kerak bo'lmaydi.
  void _prefetchAhead(String key, Directory dir, String url, int fromIndex,
      int total, int myGeneration) {
    const lookahead = 2;
    for (var i = fromIndex; i < fromIndex + lookahead; i++) {
      // MUHIM: shu videoga YANGI so'rov kelib ulgurgan bo'lsa (avlod
      // eskirgan), bu yerdan buyon HECH QANDAY yangi fon'dagi yuklash
      // BOSHLANMAYDI — orqa fonda cheksiz to'planib ketmasligi uchun.
      if (_activeGeneration[key] != myGeneration) return;
      final chunkStart = i * chunkSize;
      if (chunkStart >= total) break;
      final chunkEndMax = chunkStart + chunkSize - 1;
      final chunkEnd = chunkEndMax < total - 1 ? chunkEndMax : total - 1;
      final expectedLen = chunkEnd - chunkStart + 1;
      final flightKey = '$key#$i';
      if (_inFlightChunks.containsKey(flightKey)) continue;
      final finalFile = File('${dir.path}/${_chunkName(i)}');
      finalFile.exists().then((exists) async {
        if (_activeGeneration[key] != myGeneration) return;
        if (exists) {
          final onDisk = await finalFile.readAsBytes();
          if (onDisk.length == expectedLen) return;
        }
        if (_activeGeneration[key] != myGeneration) return;
        if (_inFlightChunks.containsKey(flightKey)) return;
        _log('Bo\'lak #$i oldindan (fon\'da) yuklab qo\'yilyapti...');
        final future = _fetchAndStoreChunk(dir, url, i, chunkStart, chunkEnd)
            .whenComplete(() => _inFlightChunks.remove(flightKey));
        _inFlightChunks[flightKey] = future;
        try {
          await future;
        } catch (_) {
          // Fon'dagi oldindan-yuklash xatosi jim yutiladi — kerak
          // bo'lganda asosiy so'rov o'zi qayta urinib ko'radi.
        }
      });
    }
  }

  Future<_CacheMeta> _ensureMeta(Directory dir, String url) {
    final flightKey = dir.path;
    final existing = _inFlightMeta[flightKey];
    if (existing != null) {
      _log('_ensureMeta: mavjud (in-flight) future kutilyapti...');
      return existing;
    }
    _log('_ensureMeta: yangi _loadOrProbeMeta boshlanmoqda...');
    final future = _loadOrProbeMeta(dir, url).whenComplete(() {
      _inFlightMeta.remove(flightKey);
      _log('_ensureMeta: future YAKUNLANDI (whenComplete ishladi)');
    });
    _inFlightMeta[flightKey] = future;
    return future;
  }

  Future<_CacheMeta> _loadOrProbeMeta(Directory dir, String url) async {
    final metaFile = File('${dir.path}/meta.json');
    _log('meta.json bor-yo\'qligi tekshirilmoqda...');
    final metaExists = await metaFile.exists().timeout(
        const Duration(seconds: 5), onTimeout: () {
      _log('XATO: meta.json exists() 5s ichida tugamadi!');
      return false;
    });
    _log('meta.json mavjud: $metaExists');
    if (metaExists) {
      try {
        final map = jsonDecode(await metaFile.readAsString().timeout(
                const Duration(seconds: 5))) as Map<String, dynamic>;
        final size = map['totalSize'] as int?;
        final ct = map['contentType'] as String?;
        if (size != null && size > 0) {
          _log('meta.json diskdan o\'qildi: hajm=$size');
          return _CacheMeta(size, ct ?? 'video/mp4');
        }
      } catch (e) {
        _log('meta.json o\'qishda xato (e\'tiborsiz qoldiriladi): $e');
      }
    }

    // MUHIM: bu yerda ATAYLAB _sharedClient EMAS, ALOHIDA, bir martalik
    // HttpClient ishlatiladi — sabab pastdagi "bytes=0-0" so'rovi javob
    // tanasini o'qimasdan (drain qilmasdan) finally blokida MAJBURAN
    // yopib tashlanadi (agar manba Range'ni e'tiborsiz qoldirib butun
    // faylni yubora boshlasa, ulanishni to'xtatishning yagona yo'li).
    // Bu ulanishni _sharedClient orqali qilsak, forced-close BARCHA
    // boshqa parallel bo'lak yuklashlarini ham to'xtatib qo'yar edi.
    // Meta faqat video boshida (bir marta, keyin meta.json'dan) so'ralgani
    // uchun bu yerdagi qo'shimcha TLS handshake xarajati arzimas.
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
        _log('HEAD javobi: status=${headRes.statusCode}, hajm=$size');
      } catch (e) {
        _log('HEAD ishlamadi: $e — zaxira GET urinib ko\'riladi');
      }

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
        _log('GET bytes=0-0 javobi: status=${res.statusCode}, hajm=$size');
      }

      final meta = _CacheMeta(size, contentType);
      if (size > 0) {
        _log('meta.json yozilmoqda...');
        try {
          await metaFile
              .writeAsString(
                  jsonEncode({'totalSize': size, 'contentType': contentType}))
              .timeout(const Duration(seconds: 5));
          _log('meta.json yozildi');
        } catch (e) {
          // Diskka yozish muvaffaqiyatsiz/tomonidan kechiktirilgan bo'lsa
          // ham, hajm allaqachon bilinganidan keyin video ijrosini
          // to'xtatib qo'ymaslik uchun bu xato jim yutiladi — kesh
          // shunchaki keyingi safar qayta yozishga urinadi.
          _log('XATO: meta.json yozib bo\'lmadi — $e');
        }
      } else {
        _log('XATO: video hajmini aniqlab bo\'lmadi (HEAD ham, GET ham)');
      }
      return meta;
    } catch (e) {
      _log('XATO: meta probe umuman ishlamadi — $e');
      rethrow;
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
