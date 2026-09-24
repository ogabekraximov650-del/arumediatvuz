// lib/services/image_cache.dart — POSTERLAR DISKDA QOLSIN.
//
// ═══════════════════════════════════════════════════════════════
//  TOPILGAN XATO (foydalanuvchi: "anime posteri diskda saqlanishi
//  kerak edi, lekin har safar ilovaga kirganda qayta yuklanyapti")
// ═══════════════════════════════════════════════════════════════
//
// Ikkita sabab bor edi va ikkovi ham tuzatildi:
//
//  1. SERVER javobida `Cache-Control: max-age=86400` turardi —
//     ya'ni bir kun. Ertasiga fayl "eskirgan" deb bilinardi va
//     qaytadan yuklab olinardi. Endi worker rasmni o'zgarmas
//     (`immutable`) deb e'lon qiladi: B2'dagi fayl nomi hech
//     qachon qayta ishlatilmaydi, shu sabab bu xavfsiz
//     (`worker/src/lib.rs` -> `CLIENT_CACHE`).
//
//  2. ILOVADA `cached_network_image` ning ODATIY keshi ishlardi:
//     unda eng ko'pi 200 ta fayl turadi. Posterlar, avatarlar,
//     izohlardagi rasmlar va tarixdagi kadrlar birgalikda bu
//     chegaradan tez oshib ketardi — eng eski poster o'chib,
//     keyingi ochilishda qaytadan yuklanardi. Shu sabab ilova
//     O'ZINING keshini ishlatadi va uning chegarasi amalda
//     yetib bo'lmaydigan qilib qo'yilgan (pastdagi izohga
//     qarang).

// ═══════════════════════════════════════════════════════════════
//  RASMLAR DISKDA SHIFRLANGAN (2026-09)
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "diskda saqlanadigan HAMMA narsa
// shifrlansin, faqat video emas".
//
// `flutter_cache_manager` rasmlarni OCHIQ fayl sifatida, URL'lar
// ro'yxatini esa ochiq sqlite bazasida saqlardi. Endi:
//
//   * har bir rasm fayli AES-256-GCM bilan muhrlanadi
//     (`_SealedFile` — yozishda muhrlaydi, o'qishda ochadi; kalit
//     fayl nomidan hosil qilinadi, `RustCore.sealBytes`);
//   * URL'lar ro'yxati ham muhrlangan faylda (`_SealingLocalFs`,
//     `JsonCacheInfoRepository` shu orqali o'qiydi/yozadi).
//
// Hamma ekranlar avvalgidek `AppImageCache.manager` dan
// foydalanadi — ularning birortasi o'zgarmadi.
//
// Kalit tayyor bo'lmasa (Keystore xatosi) rasm DISKKA YOZILMAYDI
// (ochiq holda ham) — faqat xotirada ko'rsatiladi; mavjud fayllar
// esa o'chirilmaydi (`RustCore.cryptoReady`).
//
// Eski (ochiq) kesh: `aru_images/` dagi fayllar va
// `databases/aru_images.db` bir marta o'chiriladi
// (`AppImageCache.dropLegacy`).

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as pf;
import 'package:file/local.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'rust_bridge.dart';

/// Muhrlash yorlig'i — har bir fayl o'z kalitini oladi.
///
/// `.tmp` qo'shimchasi olib tashlanadi: kesh ba'zi fayllarni (URL
/// ro'yxati) avval `<nom>.tmp` ga yozib, keyin `<nom>` ga qayta
/// nomlaydi — yorliq bir xil bo'lmasa fayl keyin ochilmasdi.
String _labelOf(String basename) => basename.endsWith('.tmp')
    ? 'img:${basename.substring(0, basename.length - 4)}'
    : 'img:$basename';

/// Muhrlovchi fayl tizimi: undan olingan HAR QANDAY fayl
/// (`file(...)`) muhrlangan bo'ladi. Kesh qo'shni fayllarni
/// (`<ro'yxat>.tmp`) aynan `file.fileSystem.file(...)` orqali
/// yaratadi — shu sabab ular ham shifrlanadi.
class _SealingLocalFs extends pf.ForwardingFileSystem {
  _SealingLocalFs() : super(const LocalFileSystem());

  static final _SealingLocalFs instance = _SealingLocalFs();

  @override
  pf.File file(dynamic path) =>
      _SealedFile(this, io.File(path is String ? path : '$path'));
}

/// Baytlarni muhrlab, faylga ATOM tarzda yozadi (avval `.tmp`).
/// Kalit tayyor bo'lmasa — hech narsa yozilmaydi.
Future<void> _writeSealed(io.File target, String label, Uint8List plain) async {
  final sealed = RustCore.instance.sealBytes(label, plain);
  if (sealed == null) return;
  final tmp = io.File('${target.path}.tmp');
  await tmp.writeAsBytes(sealed, flush: true);
  await tmp.rename(target.path);
}

/// Muhrlangan faylni ochadi. Ochilmasa: kalit bor bo'lsa fayl
/// buzilgan/eski — o'chiriladi (keyingi so'rovda qayta yuklanadi).
Future<Uint8List> _readSealed(io.File source, String label) async {
  final raw = await source.readAsBytes();
  final plain = RustCore.instance.openBytes(label, raw);
  if (plain != null) return plain;
  if (RustCore.instance.cryptoReady) {
    try {
      await source.delete();
    } catch (_) {}
  }
  throw io.FileSystemException('Rasm fayli ochilmadi', source.path);
}

/// ── RASMLAR QAYERDA YOTADI ──────────────────────────────────
///
/// TALAB (foydalanuvchi): "ilovada foydalanuvchi ko'rgan barcha
/// suratlar butun umrga cheksiz diskda saqlansin; faqat ilova
/// o'chirilganda yoki telefon sozlamalaridan tozalanmaguncha
/// o'chmasin".
///
/// Papka `getApplicationSupportDirectory()` da (Android'da `files/`):
/// tizim unga tegmaydi, u faqat ilova o'chirilganda yoki
/// "Xotirani tozalash" da yo'qoladi. (`cacheDir` ni esa tizim
/// xohlagan payti tozalardi.)
class _SealedFileSystem implements FileSystem {
  _SealedFileSystem(this._dirName) : _dir = _open(_dirName);
  final String _dirName;
  final Future<pf.Directory> _dir;

  static Future<pf.Directory> _open(String dirName) async {
    final base = await getApplicationSupportDirectory();
    const fs = LocalFileSystem();
    final dir = fs.directory(p.join(base.path, AppImageCache.key, dirName));
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<pf.File> createFile(String name) async {
    var dir = await _dir;
    if (!await dir.exists()) dir = await _open(_dirName);
    return _SealingLocalFs.instance.file(p.join(dir.path, name));
  }
}

/// Diskda muhrlangan, tashqariga OCHIQ ko'rinadigan fayl.
///
/// Kesh bilan ishlaydigan kod faqat quyidagilarni chaqiradi
/// (paket manbasi tekshirilgan): `openWrite` (yuklab olish),
/// `writeAsBytes` (`putFile`), `readAsBytes` (rasmni chizish),
/// `exists`/`delete`. Qolgani o'zgarishsiz asl faylga uzatiladi.
class _SealedFile extends pf.ForwardingFileSystemEntity<pf.File, io.File>
    with pf.ForwardingFile {
  _SealedFile(this.fileSystem, this.delegate);

  @override
  final pf.FileSystem fileSystem;

  @override
  final io.File delegate;

  String get _label => _labelOf(basename);

  @override
  String get dirname => fileSystem.path.dirname(path);

  @override
  String get basename => fileSystem.path.basename(path);

  @override
  pf.Directory wrapDirectory(io.Directory delegate) =>
      fileSystem.directory(delegate.path);

  @override
  pf.File wrapFile(io.File delegate) => _SealedFile(fileSystem, delegate);

  @override
  pf.Link wrapLink(io.Link delegate) => fileSystem.link(delegate.path);

  @override
  Future<Uint8List> readAsBytes() => _readSealed(delegate, _label);

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      encoding.decode(await readAsBytes());

  @override
  Future<pf.File> writeAsString(
    String contents, {
    io.FileMode mode = io.FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) =>
      writeAsBytes(encoding.encode(contents));

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    final all = await readAsBytes();
    final from = (start ?? 0).clamp(0, all.length);
    final to = (end ?? all.length).clamp(from, all.length);
    yield Uint8List.sublistView(all, from, to);
  }

  @override
  Future<pf.File> writeAsBytes(
    List<int> bytes, {
    io.FileMode mode = io.FileMode.write,
    bool flush = false,
  }) async {
    await _writeSealed(delegate, _label, Uint8List.fromList(bytes));
    return this;
  }

  @override
  io.IOSink openWrite({
    io.FileMode mode = io.FileMode.write,
    Encoding encoding = utf8,
  }) =>
      _SealingSink(delegate, _label, encoding);
}

/// Baytlarni xotirada yig'adi va `close()` da muhrlab yozadi.
///
/// Rasm fayllari kichik (odatda 50-500 KB), ya'ni butunlay
/// xotirada yig'ish muammo emas. Kesh ma'lumotni `stream.pipe(sink)`
/// orqali yozadi — ya'ni `addStream` + `close`.
class _SealingSink implements io.IOSink {
  _SealingSink(this._target, this._label, this.encoding);

  final io.File _target;
  final String _label;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  @override
  Encoding encoding;

  @override
  void add(List<int> data) => _buf.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (!_done.isCompleted) _done.completeError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach(_buf.add);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (_closed) return _done.future;
    _closed = true;
    try {
      await _writeSealed(_target, _label, _buf.takeBytes());
      if (!_done.isCompleted) _done.complete();
    } catch (e, st) {
      if (!_done.isCompleted) _done.completeError(e, st);
    }
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;

  @override
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
}

class AppImageCache {
  const AppImageCache._();

  /// Papka nomi (`files/aru_images`). `StorageJanitor`,
  /// `StorageUsage` va hisobni o'chirish shu nomga qaraydi.
  static const String key = 'aru_images';

  /// Muhrlangan rasmlar papkasi (`aru_images/v2`).
  static const String _sealedDir = 'v2';

  /// ── NEGA BU RAQAMLAR ─────────────────────────────────────
  ///
  /// `stalePeriod` — fayl shu muddat ISHLATILMASA o'chiriladi.
  /// 100 yil qo'yildi: amalda "hech qachon".
  ///
  /// `maxNrOfCacheObjects` — odatda 200 edi va poster undan tez
  /// chiqib ketardi. Bu yerdagi son ham amalda yetib
  /// bo'lmaydigan qilib qo'yilgan.
  static final CacheManager manager = CacheManager(
    Config(
      '${key}_v2',
      stalePeriod: const Duration(days: 365 * 100),
      maxNrOfCacheObjects: 1000000,
      fileSystem: _SealedFileSystem(_sealedDir),
      // URL'lar ro'yxati ham muhrlangan fayl (`_SealedFile`): kesh
      // uni `readAsString`/`writeAsString` (qo'shni `.tmp` orqali)
      // bilan o'qib-yozadi.
      repo: JsonCacheInfoRepository.withFile(_indexFile()),
    ),
  );

  /// URL'lar ro'yxati fayli: `aru_images/v2.index`.
  ///
  /// `JsonCacheInfoRepository.withFile` faylni SINXRON talab
  /// qiladi, papka esa asinxron aniqlanadi — shu sabab yo'l
  /// `init()` da oldindan olinadi (ilova ochilishida, `runApp`
  /// dan oldin).
  static pf.File _indexFile() => _SealingLocalFs.instance
      .file(p.join(_supportPath!, key, '$_sealedDir.index'));

  static String? _supportPath;

  /// Ilova ochilishida BIR MARTA (`main`, `manager` ishlatilishidan
  /// oldin).
  static Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    _supportPath = base.path;
    await io.Directory(p.join(base.path, key)).create(recursive: true);
    unawaited(dropLegacy(base));
  }

  /// Eski OCHIQ keshni o'chiradi: `aru_images/` ning to'g'ridan-to'g'ri
  /// ichidagi fayllar (yangi `v2/` papka va `v2.index` dan tashqari)
  /// va sqlite bazasi (`databases/aru_images.db*`).
  @visibleForTesting
  static Future<void> dropLegacy(io.Directory base) async {
    try {
      final dir = io.Directory(p.join(base.path, key));
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          final name = p.basename(e.path);
          if (name == _sealedDir || name.startsWith('$_sealedDir.index')) {
            continue;
          }
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
      // Android: `files/` ning yonidagi `databases/`.
      final dbDir = io.Directory(p.join(base.parent.path, 'databases'));
      if (await dbDir.exists()) {
        await for (final e in dbDir.list()) {
          if (p.basename(e.path).startsWith('$key.db')) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('Eski rasm keshi o\'chirilmadi: $e');
    }
  }
}

/// `CachedNetworkImageProvider` ning shu kesh bilan ishlaydigan
/// ko'rinishi. `Image(image: ...)` va `ResizeImage(...)` ichida
/// ishlatiladi.
CachedNetworkImageProvider appImageProvider(String url) =>
    CachedNetworkImageProvider(url, cacheManager: AppImageCache.manager);
