// lib/services/rust_bridge.dart
//
// Flutter (Dart) ↔ Rust (librust_core.so) ko'prigi.
// Barcha "mexanizm" — kesh, qidiruv, filtrlash, validatsiya — shu orqali
// Rust tomonida bajariladi. Dart bu yerda faqat chaqiruvchi (caller).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

// ── FFI signature'lari ──────────────────────────────────────────

typedef _CacheGetC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _CacheGetDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _CacheIsFreshC = Int32 Function(Pointer<Utf8>);
typedef _CacheIsFreshDart = int Function(Pointer<Utf8>);

typedef _CacheSaveC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _CacheSaveDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _CacheClearC = Int32 Function(Pointer<Utf8>);
typedef _CacheClearDart = int Function(Pointer<Utf8>);

typedef _SearchFilterC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _SearchFilterDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>);

typedef _FilterGenreC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FilterGenreDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _ValidateC = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _ValidateDart = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _FreeStringC = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

typedef _VersionC = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

// ── Video-kesh serveri (lib/services/video_cache_server.dart shu orqali
//    Rust'dagi native (mustaqil OS ish oqimidagi) HTTP proksiga ulanadi) ──

typedef _VideoCacheStartC = Int32 Function(Pointer<Utf8>);
typedef _VideoCacheStartDart = int Function(Pointer<Utf8>);

typedef _VideoCacheNetBytesC = Uint64 Function();
typedef _VideoCacheNetBytesDart = int Function();

// ── Video yuklab olish (progress / boshqaruv) ───────────────────
//
// `rust_video_cache_stats` BITTA chaqiruvda bir nechta URL uchun holat
// qaytaradi — shu sabab ekranda 3-4 ta sifat ochilganda ham FFI
// chaqiruvlari soni bitta bo'lib qoladi.
typedef _VideoStatsC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _VideoStatsDart = Pointer<Utf8> Function(Pointer<Utf8>);

// Pleyer HOZIR qayerni ko'rsatayotgani (millisekundda). Rust yadrosi
// oldindan yuklash oynasini aynan shu nuqtadan hisoblaydi.
typedef _VideoSetPosC = Int32 Function(Pointer<Utf8>, Uint64);
typedef _VideoSetPosDart = int Function(Pointer<Utf8>, int);

typedef _VideoUrlActionC = Int32 Function(Pointer<Utf8>);
typedef _VideoUrlActionDart = int Function(Pointer<Utf8>);

typedef _CryptoGenKeyC = Pointer<Utf8> Function();
typedef _CryptoGenKeyDart = Pointer<Utf8> Function();
typedef _CryptoSetKeyC = Int32 Function(Pointer<Utf8>);
typedef _CryptoSetKeyDart = int Function(Pointer<Utf8>);

class RustCore {
  RustCore._();
  static final RustCore instance = RustCore._();

  late final DynamicLibrary _lib;
  late final _CacheGetDart _cacheGet;
  late final _CacheIsFreshDart _cacheIsFresh;
  late final _CacheSaveDart _cacheSave;
  late final _CacheClearDart _cacheClear;
  late final _SearchFilterDart _searchFilter;
  late final _FilterGenreDart _filterGenre;
  late final _ValidateDart _validate;
  late final _FreeStringDart _freeString;
  late final _VersionDart _version;
  late final _VideoCacheStartDart _videoCacheStart;
  late final _VideoCacheNetBytesDart _videoCacheNetBytes;
  late final _VideoCacheNetBytesDart _videoCacheServedBytes;
  late final _VideoStatsDart _videoStats;
  late final _VideoSetPosDart _videoSetPos;
  late final _VideoUrlActionDart _videoDownload;
  late final _VideoUrlActionDart _videoPause;
  late final _VideoUrlActionDart _videoDelete;
  late final _VideoUrlActionDart _videoPrepare;
  late final _VideoUrlActionDart _videoPrepareStatus;
  late final _VideoUrlActionDart _videoComplete;
  late final _VideoUrlActionDart _videoPrepareReset;
  late final _CryptoGenKeyDart _cryptoGenKey;
  late final _CryptoSetKeyDart _cryptoSetKey;

  bool _loaded = false;
  String? _cacheFilePath;
  String? _cacheDirPath;
  int? _videoCachePort;

  /// Ilova ishga tushganda bir marta chaqiriladi (main() ichida).
  Future<void> init() async {
    if (_loaded) return;

    _lib = Platform.isAndroid
        ? DynamicLibrary.open('librust_core.so')
        : DynamicLibrary.process();

    _cacheGet =
        _lib.lookupFunction<_CacheGetC, _CacheGetDart>('rust_cache_get');
    _cacheIsFresh = _lib.lookupFunction<_CacheIsFreshC, _CacheIsFreshDart>(
        'rust_cache_is_fresh');
    _cacheSave =
        _lib.lookupFunction<_CacheSaveC, _CacheSaveDart>('rust_cache_save');
    _cacheClear =
        _lib.lookupFunction<_CacheClearC, _CacheClearDart>('rust_cache_clear');
    _searchFilter = _lib.lookupFunction<_SearchFilterC, _SearchFilterDart>(
        'rust_search_filter');
    _filterGenre = _lib.lookupFunction<_FilterGenreC, _FilterGenreDart>(
        'rust_filter_by_genre');
    _validate = _lib
        .lookupFunction<_ValidateC, _ValidateDart>('rust_validate_anime_form');
    _freeString =
        _lib.lookupFunction<_FreeStringC, _FreeStringDart>('rust_free_string');
    _version =
        _lib.lookupFunction<_VersionC, _VersionDart>('rust_core_version');
    _videoCacheStart =
        _lib.lookupFunction<_VideoCacheStartC, _VideoCacheStartDart>(
            'rust_video_cache_start');
    _videoCacheNetBytes =
        _lib.lookupFunction<_VideoCacheNetBytesC, _VideoCacheNetBytesDart>(
            'rust_video_cache_net_bytes');
    _videoCacheServedBytes =
        _lib.lookupFunction<_VideoCacheNetBytesC, _VideoCacheNetBytesDart>(
            'rust_video_cache_served_bytes');
    _videoStats = _lib.lookupFunction<_VideoStatsC, _VideoStatsDart>(
        'rust_video_cache_stats');
    _videoSetPos = _lib.lookupFunction<_VideoSetPosC, _VideoSetPosDart>(
        'rust_video_cache_set_position');
    _videoDownload =
        _lib.lookupFunction<_VideoUrlActionC, _VideoUrlActionDart>(
            'rust_video_cache_download');
    _videoPause = _lib.lookupFunction<_VideoUrlActionC, _VideoUrlActionDart>(
        'rust_video_cache_pause');
    _videoDelete = _lib.lookupFunction<_VideoUrlActionC, _VideoUrlActionDart>(
        'rust_video_cache_delete');
    _videoPrepare = _lib.lookupFunction<_VideoUrlActionC, _VideoUrlActionDart>(
        'rust_video_cache_prepare');
    _videoComplete = _lib.lookupFunction<_VideoUrlActionC, _VideoUrlActionDart>(
        'rust_video_cache_complete');
    _videoPrepareStatus =
        _lib.lookupFunction<_VideoUrlActionC, _VideoUrlActionDart>(
            'rust_video_cache_prepare_status');
    _videoPrepareReset =
        _lib.lookupFunction<_VideoUrlActionC, _VideoUrlActionDart>(
            'rust_video_cache_prepare_reset');
    _cryptoGenKey = _lib.lookupFunction<_CryptoGenKeyC, _CryptoGenKeyDart>(
        'rust_crypto_generate_key');
    _cryptoSetKey = _lib.lookupFunction<_CryptoSetKeyC, _CryptoSetKeyDart>(
        'rust_crypto_set_key');

    final dir = await getApplicationDocumentsDirectory();
    _cacheDirPath = dir.path;
    _cacheFilePath = '${dir.path}/anime_cache.rustbin';

    _loaded = true;
  }

  String? _readAndFree(Pointer<Utf8> ptr) {
    if (ptr.address == 0) return null;
    final result = ptr.toDartString();
    _freeString(ptr);
    return result;
  }

  // ── Kesh ─────────────────────────────────────────────────────

  /// Keshdan animelarni oladi. MUDDATIDAN QAT'IY NAZAR — offline holatda
  /// ham har doim mavjud ma'lumotni qaytaradi. Fayl umuman yo'q bo'lsagina
  /// null qaytaradi.
  List<Map<String, dynamic>>? getCachedAnimes() {
    if (!_loaded || _cacheFilePath == null) return null;
    final pathPtr = _cacheFilePath!.toNativeUtf8();
    try {
      final resultPtr = _cacheGet(pathPtr);
      final json = _readAndFree(resultPtr);
      if (json == null) return null;
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// Kesh "yangi"mi (5 daqiqadan yosh) — faqat ONLINE holatda fon-yangilash
  /// kerakmi-yo'qmi hal qilish uchun ishlatiladi. Offline'da e'tiborga
  /// olinmasligi kerak (kesh baribir ko'rsatiladi).
  bool isCacheFresh() {
    if (!_loaded || _cacheFilePath == null) return false;
    final pathPtr = _cacheFilePath!.toNativeUtf8();
    try {
      return _cacheIsFresh(pathPtr) == 1;
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// Animelarni keshga saqlaydi.
  bool saveAnimesCache(List<Map<String, dynamic>> animes) {
    if (!_loaded || _cacheFilePath == null) return false;
    final pathPtr = _cacheFilePath!.toNativeUtf8();
    final jsonPtr = jsonEncode(animes).toNativeUtf8();
    try {
      return _cacheSave(pathPtr, jsonPtr) == 1;
    } finally {
      malloc.free(pathPtr);
      malloc.free(jsonPtr);
    }
  }

  /// Keshni tozalaydi (pull-to-refresh uchun).
  void clearCache() {
    if (!_loaded || _cacheFilePath == null) return;
    final pathPtr = _cacheFilePath!.toNativeUtf8();
    try {
      _cacheClear(pathPtr);
    } finally {
      malloc.free(pathPtr);
    }
  }

  // ── Umumiy (kalit bo'yicha) ro'yxat keshi ────────────────────
  //
  // Epizodlar/bo'limlar ro'yxati kabi har qanday JSON ro'yxatni diskka
  // saqlaydi va OFFLINE holatda ham qaytaradi (muddatidan qat'i nazar).
  // Shu bilan internet bo'lmaganda ham epizod tugmalari ko'rinib
  // turadi — allaqachon keshlangan videolarni oflayn ko'rish mumkin.

  String? _pathForKey(String key) {
    final dir = _cacheDirPath;
    if (dir == null) return null;
    // Kalitni fayl nomi uchun xavfsiz holatga keltiramiz.
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '$dir/list_$safe.rustbin';
  }

  List<Map<String, dynamic>>? getCachedList(String key) {
    if (!_loaded) return null;
    final path = _pathForKey(key);
    if (path == null) return null;
    final pathPtr = path.toNativeUtf8();
    try {
      final json = _readAndFree(_cacheGet(pathPtr));
      if (json == null) return null;
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    } finally {
      malloc.free(pathPtr);
    }
  }

  bool saveListCache(String key, List<Map<String, dynamic>> data) {
    if (!_loaded) return false;
    final path = _pathForKey(key);
    if (path == null) return false;
    final pathPtr = path.toNativeUtf8();
    final jsonPtr = jsonEncode(data).toNativeUtf8();
    try {
      return _cacheSave(pathPtr, jsonPtr) == 1;
    } catch (_) {
      return false;
    } finally {
      malloc.free(pathPtr);
      malloc.free(jsonPtr);
    }
  }

  // ── Qidiruv / filtrlash ──────────────────────────────────────

  List<Map<String, dynamic>> searchFilter(
      List<Map<String, dynamic>> list, String query) {
    if (!_loaded) return [];
    final listPtr = jsonEncode(list).toNativeUtf8();
    final queryPtr = query.toNativeUtf8();
    try {
      final resultPtr = _searchFilter(listPtr, queryPtr);
      final json = _readAndFree(resultPtr);
      if (json == null) return [];
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    } finally {
      malloc.free(listPtr);
      malloc.free(queryPtr);
    }
  }

  List<Map<String, dynamic>> filterByGenre(
      List<Map<String, dynamic>> list, String genre) {
    if (!_loaded) return [];
    final listPtr = jsonEncode(list).toNativeUtf8();
    final genrePtr = genre.toNativeUtf8();
    try {
      final resultPtr = _filterGenre(listPtr, genrePtr);
      final json = _readAndFree(resultPtr);
      if (json == null) return [];
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    } finally {
      malloc.free(listPtr);
      malloc.free(genrePtr);
    }
  }

  // ── Validatsiya (hozircha ilova ichida ishlatilmaydi — barcha
  //    maydonlar ixtiyoriy qilib qo'yildi, lekin funksiya kerak
  //    bo'lganda ishlatish uchun saqlab qolindi) ──────────────────

  bool validateAnimeForm({
    required String name,
    required String davlat,
    required String studiya,
    required String janri,
    required String tavsif,
  }) {
    if (!_loaded) return false;
    final ptrs = [name, davlat, studiya, janri, tavsif]
        .map((s) => s.toNativeUtf8())
        .toList();
    try {
      return _validate(ptrs[0], ptrs[1], ptrs[2], ptrs[3], ptrs[4]) == 1;
    } finally {
      for (final p in ptrs) {
        malloc.free(p);
      }
    }
  }

  String get version {
    if (!_loaded) return 'yuklanmagan';
    final ptr = _version();
    return _readAndFree(ptr) ?? 'noma\'lum';
  }

  bool get isLoaded => _loaded;

  // ── Video-kesh serveri ───────────────────────────────────────

  /// Rust'dagi mahalliy (127.0.0.1) video-kesh HTTP serverini ishga
  /// tushiradi (agar allaqachon ishga tushmagan bo'lsa) va bog'langan
  /// portni qaytaradi. Server to'liq mustaqil native OS ish oqimida
  /// (std::thread) ishlaydi — Dart/Flutter isolate holatidan qat'i
  /// nazar har doim so'rovlarga javob bera oladi.
  Future<int> startVideoCache() async {
    if (_videoCachePort != null) return _videoCachePort!;
    if (!_loaded) {
      throw StateError('RustCore hali init() qilinmagan');
    }
    final support = await getApplicationSupportDirectory();
    final pathPtr = support.path.toNativeUtf8();
    try {
      final port = _videoCacheStart(pathPtr);
      if (port <= 0) {
        throw StateError('Rust video-kesh serveri ishga tushmadi (kod=$port)');
      }
      _videoCachePort = port;
      return port;
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// Ilova ishga tushgandan beri TARMOQDAN olingan umumiy bayt hajmi
  /// (keshdan o'qilganlar kirmaydi). Bu son o'smay tursa — video uchun
  /// tarmoqqa umuman chiqilmayapti.
  int get videoCacheNetBytes {
    if (!_loaded) return 0;
    try {
      return _videoCacheNetBytes();
    } catch (_) {
      return 0;
    }
  }

  /// Video TO'LIQ yuklab olingan bo'lsa, uning diskdagi YAGONA fayl
  /// yo'lini qaytaradi (aks holda bo'sh satr).
  ///
  /// Bu yo'l olinsa, pleyer videoni HTTP'siz — to'g'ridan-to'g'ri
  /// fayldan o'ynatadi: hech qanday TCP ulanish, timeout yoki qayta
  /// ulanish yo'q, sek esa oddiy fayl ichida siljish.
  ///
  // ── Shifrlash ────────────────────────────────────────────────
  //
  // Asosiy kalit ilova ishga tushganda BIR MARTA o'rnatiladi. U
  // o'rnatilmaguncha Rust yadrosi hamma narsani AVVALGIDEK ochiq
  // saqlaydi — ya'ni kalit yo'qolsa ham ilova ishlashdan to'xtamaydi,
  // shunchaki himoyasiz rejimga tushadi.

  /// Yangi tasodifiy asosiy kalit (64 ta hex belgi).
  String generateMasterKey() {
    if (!_loaded) return '';
    try {
      return _readAndFree(_cryptoGenKey()) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Asosiy kalitni Rust yadrosiga uzatadi. Shundan keyin barcha
  /// yozishlar shifrlangan holatda boradi.
  bool setMasterKey(String hexKey) {
    if (!_loaded || hexKey.isEmpty) return false;
    final ptr = hexKey.toNativeUtf8();
    try {
      return _cryptoSetKey(ptr) == 1;
    } catch (_) {
      return false;
    } finally {
      malloc.free(ptr);
    }
  }

  /// Pleyerga MAHALLIY (127.0.0.1) ulanish orqali uzatilgan umumiy
  /// bayt hajmi. Telefon status-satridagi "KB/s" hisoblagichi ko'p
  /// qurilmalarda loopback'ni ham qo'shib hisoblaydi — shu sabab
  /// keshdan o'ynatilayotgan video ham u yerda "trafik" bo'lib
  /// ko'rinadi. Bu son o'sib, videoCacheNetBytes o'smay tursa —
  /// internetga UMUMAN chiqilmayapti.
  int get videoCacheServedBytes {
    if (!_loaded) return 0;
    try {
      return _videoCacheServedBytes();
    } catch (_) {
      return 0;
    }
  }

  // ── Video yuklab olish: holat va boshqaruv ───────────────────
  //
  // Bu chaqiruvlarning HECH BIRI tarmoqqa chiqmaydi va HECH BIRI
  // kutmaydi (bloklamaydi): `videoStats` faqat xotiradagi hisobni
  // o'qiydi, `videoDownload`/`videoDelete` esa ishni Rust tomonidagi
  // fon ish oqimiga topshirib darhol qaytadi. Shu sabab ularni UI
  // oqimidan soniyasiga bir necha marta chaqirish xavfsiz.

  /// Berilgan URL'lar uchun: {url: {total, downloaded, downloading}}.
  Map<String, Map<String, dynamic>> videoStats(List<String> urls) {
    if (!_loaded || urls.isEmpty) return const {};
    final ptr = jsonEncode(urls).toNativeUtf8();
    try {
      final json = _readAndFree(_videoStats(ptr));
      if (json == null || json.isEmpty) return const {};
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()));
    } catch (_) {
      return const {};
    } finally {
      malloc.free(ptr);
    }
  }

  /// ── ESKIRGAN: HOZIR HECH KIM CHAQIRMAYDI ──────────────────
  ///
  /// Pleyer endi mahalliy serverga "hozir shu joydaman" deb xabar
  /// bermaydi: worker'dan ijro etilganda yadro umuman ishtirok
  /// etmaydi, mahalliy ijroda esa fayl allaqachon to'liq diskda
  /// bo'ladi. Chaqiruv Rust tomonida ham hech qayerda o'qilmaydi —
  /// mos keluvchanlik uchun saqlanyapti.
  ///
  /// Pleyer HOZIR qayerni ko'rsatayotganini Rust yadrosiga bildiradi.
  ///
  /// Oldindan yuklash oynasi aynan shu nuqtadan hisoblanadi. Ilgari
  /// yadro faqat O'ZI uzatgan oxirgi bo'lakni bilardi — u esa BUFER
  /// UCHI, ya'ni ijro nuqtasidan bir necha bo'lak oldinda. Natijada
  /// oyna pleyerning o'z buferi USTIGA qo'shilib, ikki barobar
  /// kengayib ketardi.
  ///
  /// Juda arzon: Rust tomonida ikkita atomik yozuv, hech qanday
  /// qulf yoki disk yo'q.
  void videoSetPosition(String url, int positionMs) {
    if (!_loaded || url.isEmpty) return;
    final ptr = url.toNativeUtf8();
    try {
      _videoSetPos(ptr, positionMs < 0 ? 0 : positionMs);
    } catch (_) {
    } finally {
      malloc.free(ptr);
    }
  }

  /// Videoni to'liq yuklab olishni boshlaydi (faqat YETISHMAYOTGAN
  /// bo'laklar olinadi — ya'ni to'xtatilgan joydan davom etadi).
  void videoDownload(String url) => _videoUrlAction(_videoDownload, url);

  /// Yuklab olishni to'xtatadi. Olingan bo'laklar joyida qoladi.
  void videoPause(String url) => _videoUrlAction(_videoPause, url);

  /// Shu sifatdagi videoning keshini butunlay o'chiradi.
  void videoDelete(String url) => _videoUrlAction(_videoDelete, url);

  /// ── VIDEONI IJROGA TAYYORLASH ───────────────────────────────
  ///
  /// Worker'ga "oynani keshga ko'chir" degan BITTA so'rov yuboradi
  /// va DARHOL qaytadi (ish fon oqimida ketadi). Shu isitish
  /// tugagach video B2'ga umuman chiqmasdan, Cloudflare
  /// chekkasidan o'ynatiladi.
  ///
  /// Fayl allaqachon to'liq telefonda bo'lsa — hech narsa
  /// qilinmaydi va holat darhol "tayyor" bo'ladi.
  void videoPrepare(String url) => _videoUrlAction(_videoPrepare, url);

  /// ── SHU VIDEO TELEFONDA TO'LIQ BORMI ────────────────────────
  ///
  /// Pleyer manba tanlashda AYNAN shu javobga tayanadi:
  ///   * `true`  — fayl to'liq diskda: video MAHALLIY server orqali
  ///     ko'rsatiladi, internetga umuman chiqilmaydi;
  ///   * `false` — fayl to'liq emas: video to'g'ridan-to'g'ri
  ///     worker'dan oqim bilan ko'rsatiladi (internet kerak).
  ///
  /// MUHIM: bu chaqiruv `videoStats` dan farqli o'laroq DISKKA
  /// chiqadi (bir marta skanerlaydi), shu sabab u FAQAT video
  /// ochilayotganda chaqiriladi — ro'yxat chizilayotganda emas.
  bool videoIsComplete(String url) {
    if (!_loaded || url.isEmpty) return false;
    final ptr = url.toNativeUtf8();
    try {
      return _videoComplete(ptr) == 1;
    } catch (_) {
      return false;
    } finally {
      malloc.free(ptr);
    }
  }

  /// Tayyorlash tugadimi. `true` — pleyerni ochish mumkin.
  bool videoPrepareReady(String url) {
    if (!_loaded || url.isEmpty) return true;
    final ptr = url.toNativeUtf8();
    try {
      return _videoPrepareStatus(ptr) == 1;
    } catch (_) {
      return true;
    } finally {
      malloc.free(ptr);
    }
  }

  /// ── ISITISHNI BOSHIDAN QAYTA BOSHLASH ───────────────────────
  ///
  /// Cloudflare keshi katta yozuvlarni (480 MiB'lik oyna) xotira
  /// siqilganda o'chirib yuborishi mumkin — o'shanda `/api/play/...`
  /// 503 qaytaradi va video ochilmaydi. Shu chaqiruvdan keyin
  /// keyingi `videoPrepare` oynani HAQIQATDAN qayta isitadi.
  void videoPrepareReset(String url) =>
      _videoUrlAction(_videoPrepareReset, url);

  void _videoUrlAction(_VideoUrlActionDart fn, String url) {
    if (!_loaded || url.isEmpty) return;
    final ptr = url.toNativeUtf8();
    try {
      fn(ptr);
    } catch (_) {
    } finally {
      malloc.free(ptr);
    }
  }
}
