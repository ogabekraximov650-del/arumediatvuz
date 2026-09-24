// lib/services/rust_bridge.dart
//
// Flutter (Dart) ↔ Rust (librust_core.so) ko'prigi.
// Barcha "mexanizm" — kesh, qidiruv, filtrlash, validatsiya — shu orqali
// Rust tomonida bajariladi. Dart bu yerda faqat chaqiruvchi (caller).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
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

// Hisobdan chiqilganda butun keshni o'chirish (argumentsiz).
typedef _VideoWipeC = Int32 Function();
typedef _VideoWipeDart = int Function();

// ── TANBAL (LAZY) OYNA KESHLASH ─────────────────────────────────
//
// Katta fayl (masalan 1.5 GB) 480 MiB'lik "oynalarga" bo'linadi va
// KESHGA FAQAT KERAK BO'LGANI olinadi:
//   * video ochilganda — faqat #0 oyna (0-480 MiB);
//   * foydalanuvchi ko'rib yoki sek qilib #1 oynaga yaqinlashsa —
//     o'shanda #1 oyna (480-960 MiB) keshlanadi;
//   * foydalanuvchi videoning oxiriga umuman bormasa, oxirgi oyna
//     manbadan HECH QACHON o'qilmaydi.
//
// Shu bilan xarajat faqat HAQIQATAN ko'rilgan qism uchun to'lanadi.
typedef _VideoWindowC = Int32 Function(Pointer<Utf8>, Uint64);
typedef _VideoWindowDart = int Function(Pointer<Utf8>, int);

typedef _VideoTotalC = Uint64 Function(Pointer<Utf8>);
typedef _VideoTotalDart = int Function(Pointer<Utf8>);

typedef _VideoWindowSizeC = Uint64 Function();
typedef _VideoWindowSizeDart = int Function();

// Kirgan hisob raqamini yadroga bildirish (faqat jurnal uchun —
// trafikni ilovaning o'zi sanaydi, `traffic_service.dart`).
typedef _SetUserIdC = Void Function(Int64);
typedef _SetUserIdDart = void Function(int);

typedef _CryptoGenKeyC = Pointer<Utf8> Function();
typedef _CryptoGenKeyDart = Pointer<Utf8> Function();
typedef _CryptoSetKeyC = Int32 Function(Pointer<Utf8>);
typedef _CryptoSetKeyDart = int Function(Pointer<Utf8>);

typedef _SecureSaveC = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SecureSaveDart = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SecureLoadC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _SecureLoadDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _SecureClearC = Int32 Function(Pointer<Utf8>);
typedef _SecureClearDart = int Function(Pointer<Utf8>);

// Ikkilik ma'lumotni muhrlash/ochish (`rust_seal_bytes` va h.k.).
typedef _BytesC = Pointer<Uint8> Function(
    Pointer<Utf8>, Pointer<Uint8>, Size, Pointer<Size>);
typedef _BytesDart = Pointer<Uint8> Function(
    Pointer<Utf8>, Pointer<Uint8>, int, Pointer<Size>);
typedef _FreeBytesC = Void Function(Pointer<Uint8>, Size);
typedef _FreeBytesDart = void Function(Pointer<Uint8>, int);

// So'rov imzosi (`app_sign` — rust/src/lib.rs izohiga qarang).
typedef _AppSignC = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AppSignDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// Ilova versiyasini yadroga bildirish — yadro O'Z so'rovlariga
// (video, rasm) `X-App-Version` ni qo'yishi uchun.
typedef _SetAppVersionC = Void Function(Pointer<Utf8>);
typedef _SetAppVersionDart = void Function(Pointer<Utf8>);

// Pleyer manzili uchun muddatli token (`app_play_token`).
typedef _PlayTokenC = Pointer<Utf8> Function(Pointer<Utf8>, Uint64);
typedef _PlayTokenDart = Pointer<Utf8> Function(Pointer<Utf8>, int);

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
  late final _VideoWipeDart _videoWipe;
  late final _VideoUrlActionDart _videoPrepare;
  late final _VideoUrlActionDart _videoPrepareStatus;
  late final _VideoUrlActionDart _videoComplete;
  late final _VideoUrlActionDart _videoPrepareReset;
  late final _VideoWindowDart _videoWarmWindow;
  late final _VideoWindowDart _videoWindowStatus;
  late final _VideoWindowDart _videoWindowSeen;
  late final _VideoTotalDart _videoTotal;
  late final _VideoWindowSizeDart _videoWindowSize;
  late final _SetUserIdDart _setUserId;
  late final _CryptoGenKeyDart _cryptoGenKey;
  late final _CryptoSetKeyDart _cryptoSetKey;
  late final _SecureSaveDart _secureSave;
  late final _BytesDart _sealBytes;
  late final _BytesDart _openBytes;
  late final _FreeBytesDart _freeBytes;
  late final _SecureLoadDart _secureLoad;
  late final _SecureClearDart _secureClear;
  late final _AppSignDart _appSign;
  late final _SetAppVersionDart _setAppVersion;
  late final _PlayTokenDart _playToken;

  bool _loaded = false;
  String? _cacheFilePath;

  /// Joriy hisobning papkasi — `<hujjatlar>/accountid_<id>`.
  /// Kirilmagan bo'lsa `accountid_0` (mehmon).
  String? _accountDirPath;
  int _accountId = -1;
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
    _appSign = _lib.lookupFunction<_AppSignC, _AppSignDart>('app_sign');
    _setAppVersion = _lib
        .lookupFunction<_SetAppVersionC, _SetAppVersionDart>(
            'rust_set_app_version');
    _playToken =
        _lib.lookupFunction<_PlayTokenC, _PlayTokenDart>('app_play_token');
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
    _videoWipe = _lib.lookupFunction<_VideoWipeC, _VideoWipeDart>(
        'rust_video_cache_wipe');
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
    _videoWarmWindow = _lib.lookupFunction<_VideoWindowC, _VideoWindowDart>(
        'rust_video_cache_warm_window');
    _videoWindowStatus = _lib.lookupFunction<_VideoWindowC, _VideoWindowDart>(
        'rust_video_cache_window_status');
    _videoWindowSeen = _lib.lookupFunction<_VideoWindowC, _VideoWindowDart>(
        'rust_video_cache_window_seen');
    _videoTotal = _lib.lookupFunction<_VideoTotalC, _VideoTotalDart>(
        'rust_video_cache_total');
    _videoWindowSize =
        _lib.lookupFunction<_VideoWindowSizeC, _VideoWindowSizeDart>(
            'rust_video_cache_window_size');
    _setUserId =
        _lib.lookupFunction<_SetUserIdC, _SetUserIdDart>('rust_set_user_id');
    _cryptoGenKey = _lib.lookupFunction<_CryptoGenKeyC, _CryptoGenKeyDart>(
        'rust_crypto_generate_key');
    _cryptoSetKey = _lib.lookupFunction<_CryptoSetKeyC, _CryptoSetKeyDart>(
        'rust_crypto_set_key');
    _secureSave = _lib.lookupFunction<_SecureSaveC, _SecureSaveDart>(
        'rust_secure_save');
    _secureLoad = _lib.lookupFunction<_SecureLoadC, _SecureLoadDart>(
        'rust_secure_load');
    _secureClear = _lib.lookupFunction<_SecureClearC, _SecureClearDart>(
        'rust_secure_clear');
    _sealBytes = _lib.lookupFunction<_BytesC, _BytesDart>('rust_seal_bytes');
    _openBytes = _lib.lookupFunction<_BytesC, _BytesDart>('rust_open_bytes');
    _freeBytes =
        _lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('rust_free_bytes');

    final dir = await getApplicationDocumentsDirectory();
    _cacheDirPath = dir.path;
    // Anime ro'yxati — UMUMIY kontent, hisobga bog'liq emas.
    _cacheFilePath = '${dir.path}/anime_cache.rustbin';
    // Hisob ma'lum bo'lguncha mehmon papkasi ishlatiladi.
    setAccount(0);

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
    final dir = _accountDirPath ?? _cacheDirPath;
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

  bool _cryptoReady = false;

  /// Asosiy kalit o'rnatilganmi (shifrlash ishlayaptimi).
  ///
  /// `false` bo'lsa shifrlangan faylni ochib bo'lmasligi "fayl
  /// buzilgan" degani EMAS — kalit hali yo'q. Rasm keshi shunga
  /// qarab faylni o'chirmaydi.
  bool get cryptoReady => _cryptoReady;

  /// Asosiy kalitni Rust yadrosiga uzatadi. Shundan keyin barcha
  /// yozishlar shifrlangan holatda boradi.
  bool setMasterKey(String hexKey) {
    if (!_loaded || hexKey.isEmpty) return false;
    final ptr = hexKey.toNativeUtf8();
    try {
      final ok = _cryptoSetKey(ptr) == 1;
      if (ok) _cryptoReady = true;
      return ok;
    } catch (_) {
      return false;
    } finally {
      malloc.free(ptr);
    }
  }

  // ── MAXFIY KICHIK FAYL (AES-256-GCM) ───────────────────────
  //
  // Kichik, lekin maxfiy matnni diskda MUHRLANGAN holda saqlash
  // uchun. Hozir bitta joyda ishlatiladi: Telegram orqali kirishda
  // olingan bir martalik token (`auth_service.dart`).
  //
  // Kalit har bir `label` uchun asosiy kalitdan alohida hosil
  // qilinadi, ya'ni bitta faylning kaliti boshqasini ochmaydi.
  // Shifrlash o'chiq bo'lsa (asosiy kalit hali o'rnatilmagan)
  // saqlash ATAYLAB muvaffaqiyatsiz bo'ladi — token hech qachon
  // ochiq matnda diskka tushmaydi.

  /// Matnni shifrlab faylga yozadi. `true` — muvaffaqiyat.
  bool secureSave(String path, String label, String text) {
    if (!_loaded) return false;
    final p = path.toNativeUtf8();
    final l = label.toNativeUtf8();
    final t = text.toNativeUtf8();
    try {
      return _secureSave(p, l, t) == 1;
    } catch (_) {
      return false;
    } finally {
      malloc.free(p);
      malloc.free(l);
      malloc.free(t);
    }
  }

  /// Shifrlangan fayldan matnni o'qiydi. Fayl yo'q, buzilgan yoki
  /// boshqa kalit bilan yozilgan bo'lsa — bo'sh satr.
  /// Ilova versiyasini yadroga bildiradi.
  ///
  /// Yadro video va rasm so'rovlarini O'ZI yuboradi, ya'ni
  /// `X-App-Version` ni ham o'zi qo'yishi kerak. Aks holda admin
  /// oynasidan "eng past versiya" tekshiruvi yoqilgan zahoti
  /// video ishlamay qolardi.
  void setAppVersion(String version) {
    if (!_loaded || version.isEmpty) return;
    final v = version.toNativeUtf8();
    try {
      _setAppVersion(v);
    } catch (_) {
      // Eski yadro — bu funksiya yo'q. Video baribir ishlaydi.
    } finally {
      malloc.free(v);
    }
  }

  /// PLEYER MANZILI UCHUN MUDDATLI TOKEN.
  ///
  /// `/api/play/...` ni ExoPlayer ochadi va unga sarlavha qo'shib
  /// bo'lmaydi. Shu sabab ruxsat manzilning o'ziga qo'yiladi:
  /// `?t=<muddat>.<hex>`.
  ///
  /// Oddiy imzo bu yerda yaramaydi — u 2 daqiqada o'ladi, ijro esa
  /// soatlab davom etadi.
  String playToken(String path, {int ttlSeconds = 6 * 60 * 60}) {
    if (!_loaded) return '';
    final p = path.toNativeUtf8();
    try {
      return _readAndFree(_playToken(p, ttlSeconds)) ?? '';
    } catch (_) {
      return '';
    } finally {
      malloc.free(p);
    }
  }

  /// SO'ROV IMZOSI — `v2.<vaqt>.<hex>`.
  ///
  /// Sir Rust yadrosining ichida (`app_sign`), Dart tomonida
  /// UMUMAN YO'Q — shu sabab uni APK ichidagi Dart tasviridan
  /// topib bo'lmaydi.
  ///
  /// Bo'sh qaytsa (yadro yuklanmagan yoki sir berilmagan) ilova
  /// sarlavhani qo'ymaydi va server tekshiruvni o'chirgan bo'lsa
  /// baribir ishlayveradi.
  String appSign(int unixSeconds, String method, String path) {
    if (!_loaded) return '';
    final t = '$unixSeconds'.toNativeUtf8();
    final m = method.toNativeUtf8();
    final p = path.toNativeUtf8();
    try {
      return _readAndFree(_appSign(t, m, p)) ?? '';
    } catch (_) {
      return '';
    } finally {
      malloc.free(t);
      malloc.free(m);
      malloc.free(p);
    }
  }

  String secureLoad(String path, String label) {
    if (!_loaded) return '';
    final p = path.toNativeUtf8();
    final l = label.toNativeUtf8();
    try {
      return _readAndFree(_secureLoad(p, l)) ?? '';
    } catch (_) {
      return '';
    } finally {
      malloc.free(p);
      malloc.free(l);
    }
  }

  // ── IKKILIK MA'LUMOT (rasmlar) ────────────────────────────────
  //
  // TALAB (foydalanuvchi): "diskda saqlanadigan HAMMA narsa
  // shifrlansin". Rasm keshi (`image_cache.dart`) shular orqali
  // yozadi va o'qiydi — AES-256-GCM, har bir `label` o'z kaliti.

  /// Baytlarni muhrlaydi. Shifrlash tayyor bo'lmasa — `null`
  /// (chaqiruvchi faylni OCHIQ holda yozmasligi kerak).
  Uint8List? sealBytes(String label, Uint8List data) =>
      _bytesCall(_sealBytes, label, data);

  /// Muhrlangan baytlarni ochadi. Buzilgan yoki begona ma'lumot
  /// bo'lsa — `null`.
  Uint8List? openBytes(String label, Uint8List data) =>
      _bytesCall(_openBytes, label, data);

  Uint8List? _bytesCall(_BytesDart fn, String label, Uint8List data) {
    if (!_loaded) return null;
    final l = label.toNativeUtf8();
    final input = malloc<Uint8>(data.isEmpty ? 1 : data.length);
    final outLen = malloc<Size>();
    try {
      input.asTypedList(data.length).setAll(0, data);
      final out = fn(l, input, data.length, outLen);
      if (out == nullptr) return null;
      final n = outLen.value;
      try {
        return Uint8List.fromList(out.asTypedList(n));
      } finally {
        _freeBytes(out, n);
      }
    } catch (_) {
      return null;
    } finally {
      malloc.free(l);
      malloc.free(input);
      malloc.free(outLen);
    }
  }

  /// Faylni o'chiradi (yo'q bo'lsa ham `true`).
  bool secureClear(String path) {
    if (!_loaded) return false;
    final p = path.toNativeUtf8();
    try {
      return _secureClear(p) == 1;
    } catch (_) {
      return false;
    } finally {
      malloc.free(p);
    }
  }

  /// JORIY HISOBNING papkasi (`accountid_<id>`). Tarix kadrlari va
  /// ro'yxat keshlari shu yerda. `init()` chaqirilmagan bo'lsa
  /// `null`.
  String? get dataDirPath => _accountDirPath ?? _cacheDirPath;

  /// ILDIZ hujjatlar papkasi — hamma hisoblarning papkalari
  /// (`accountid_*`) va umumiy fayllar (`anime_cache.rustbin`)
  /// shu ichida yotadi.
  ///
  /// `dataDirPath` dan farqi: u FAQAT joriy hisobning papkasini
  /// beradi. Xotira hisobi esa ilovaning HAMMASINI sanashi kerak
  /// (`storage_usage.dart`).
  String? get rootDirPath => _cacheDirPath;

  // ═══════════════════════════════════════════════════════════
  //  HAR BIR HISOBGA — O'Z PAPKASI
  // ═══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "boshqa accountga o'tganda ilova ichida
  // accountid_1 deb oxiriga user id qo'yib papka ochilgan bo'lishi
  // kerak... yani account ma'lumotlari chalkashib ketmasligi uchun".
  //
  // Shu sabab hisobga TEGISHLI hamma narsa (tomosha tarixi, qayerda
  // to'xtagani, sevimlilar, shaxsiy statistika, trafik hisobi,
  // tarix kadrlari) `<hujjatlar>/accountid_<id>` ichida yotadi.
  // Hisob almashsa — papka almashadi, ya'ni hech narsa o'chirilmaydi
  // va eski hisobga qaytilganda hammasi joyida turadi.
  //
  // ── RASM VA VIDEO IKKALA HISOBDA HAM BITTA JOYDAN ─────────
  //
  // Bu papkaga video ham, poster ham TUSHMAYDI:
  //
  //   * videolar — `<qo'llab-quvvatlash>/video_byte_cache` (Rust
  //     yadrosi, hisobdan qat'i nazar bitta);
  //   * posterlar — vaqtinchalik papkadagi `libCachedImageData`;
  //   * anime ro'yxati — `anime_cache.rustbin` (umumiy kontent).
  //
  // Ya'ni bitta telefonda ikki hisob bir xil faylni ikki marta
  // yuklab olmaydi.
  void setAccount(int userId) {
    final root = _cacheDirPath;
    if (root == null) return;
    final id = userId > 0 ? userId : 0;
    if (_accountId == id && _accountDirPath != null) return;
    final path = '$root/accountid_$id';
    try {
      final dir = Directory(path);
      final existed = dir.existsSync();
      if (!existed) dir.createSync(recursive: true);
      _accountDirPath = path;
      _accountId = id;
      if (!existed && id > 0) _adoptLegacyFiles(root, path);
    } catch (e) {
      // Papka ochilmadi — eski joyda (ildizda) ishlayveramiz.
      debugPrint('Hisob papkasi ochilmadi: $e');
      _accountDirPath = root;
      _accountId = id;
    }
  }

  /// Joriy hisob raqami (mehmon bo'lsa 0).
  int get accountId => _accountId < 0 ? 0 : _accountId;

  /// ── ESKI VERSIYADAN KO'CHIRISH ────────────────────────────
  ///
  /// Yangilanishdan oldin fayllar to'g'ridan-to'g'ri hujjatlar
  /// papkasida yotardi. Ular O'SHA PAYTDA kirgan hisobniki, shu
  /// sabab hisob birinchi marta o'z papkasini olganda ular
  /// ko'chiriladi — tomosha tarixi va "qayerda to'xtagani"
  /// yo'qolmasin.
  void _adoptLegacyFiles(String root, String target) {
    try {
      for (final e in Directory(root).listSync()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.startsWith('list_') && !name.startsWith('thumb_')) continue;
        try {
          e.renameSync('$target/$name');
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Eski fayllar ko\'chirilmadi: $e');
    }
  }

  /// Yuklab olingan BARCHA videolarni va yuklash navbatini
  /// o'chiradi.
  ///
  /// HOZIRCHA HECH QAYERDAN CHAQIRILMAYDI: hisobdan chiqilganda
  /// endi hech narsa tozalanmaydi (foydalanuvchi talabi). Yadroda
  /// qoldirildi — kelajakda "keshni tozalash" tugmasi uchun.
  int videoCacheWipe() {
    if (!_loaded) return 0;
    try {
      return _videoWipe();
    } catch (_) {
      return 0;
    }
  }

  /// Kirgan hisob raqamini yadroga bildiradi (chiqilganda 0).
  ///
  /// Trafikni endi ilovaning O'ZI sanaydi
  /// (`traffic_service.dart`), shu sabab yadro so'rovlarga hech
  /// qanday qo'shimcha sarlavha qo'ymaydi — raqam faqat
  /// jurnalda ko'rinadi.
  void setUserId(int id) {
    if (!_loaded) return;
    try {
      _setUserId(id);
    } catch (_) {
      // Eski kutubxona (yangilanmagan .so) — trafik shunchaki
      // shaxsiy hisobga yozilmaydi, boshqa hech narsa buzilmaydi.
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

  /// Tayyorlash holati:
  ///   0 — hali ketyapti (kutish kerak);
  ///   1 — TAYYOR: oyna(lar) Cloudflare keshida, pleyerni ochsa
  ///       bo'ladi va ijro paytida B2'ga umuman chiqilmaydi;
  ///   2 — MUVAFFAQIYATSIZ: isitib bo'lmadi. Bu holatda pleyerni
  ///       ochish behuda — `/api/play/...` 503 qaytaradi va
  ///       "Videoni yuklab bo'lmadi" chiqadi.
  ///
  /// AVVAL bu yerda faqat "tayyor/tayyor emas" bor edi va
  /// muvaffaqiyatsizlik ham "tayyor" deb ko'rsatilardi — onlayn
  /// videoning ochilmasligiga aynan shu olib kelgan edi.
  int videoPrepareStatus(String url) {
    if (!_loaded || url.isEmpty) return 1;
    final ptr = url.toNativeUtf8();
    try {
      return _videoPrepareStatus(ptr);
    } catch (_) {
      return 1;
    } finally {
      malloc.free(ptr);
    }
  }

  /// Tayyorlash muvaffaqiyatli tugadimi. `true` — pleyerni ochish
  /// mumkin.
  bool videoPrepareReady(String url) => videoPrepareStatus(url) == 1;

  /// ── ISITISHNI BOSHIDAN QAYTA BOSHLASH ───────────────────────
  ///
  /// Cloudflare keshi katta yozuvlarni (480 MiB'lik oyna) xotira
  /// siqilganda o'chirib yuborishi mumkin — o'shanda `/api/play/...`
  /// 503 qaytaradi va video ochilmaydi. Shu chaqiruvdan keyin
  /// keyingi `videoPrepare` oynani HAQIQATDAN qayta isitadi.
  void videoPrepareReset(String url) =>
      _videoUrlAction(_videoPrepareReset, url);

  // ── TANBAL (LAZY) OYNA KESHLASH ────────────────────────────
  //
  // Ish tartibi pleyerda (video_player_screen.dart) shunday:
  //   1. Video ochilganda `videoPrepare` faqat #0 oynani keshlaydi
  //      — foydalanuvchi shu bittasini kutadi, boshqa hech narsa
  //      manbadan o'qilmaydi.
  //   2. Ijro davomida pleyer oyna chegarasiga yaqinlashganda ilova
  //      `videoWarmWindow(url, keyingi)` ni chaqiradi — keyingi oyna
  //      FON'DA tayyorlanadi va foydalanuvchi hech narsa sezmaydi.
  //   3. Foydalanuvchi hali keshlanmagan joyga SEK qilsa, ilova
  //      avval `videoWarmWindow` chaqirib, `videoWindowStatus`
  //      "tayyor" bo'lishini kutadi va faqat KEYIN sek qiladi.
  //      Shu sabab pleyer hech qachon "keshda yo'q" xatosini
  //      ko'rmaydi — ya'ni bufer ham tozalanmaydi.

  /// Berilgan oynani keshga olishni boshlaydi (fon'da). Bir necha
  /// marta chaqirilsa ham manbaga BITTA so'rov ketadi.
  void videoWarmWindow(String url, int windowIndex) {
    if (!_loaded || url.isEmpty || windowIndex < 0) return;
    final ptr = url.toNativeUtf8();
    try {
      _videoWarmWindow(ptr, windowIndex);
    } catch (_) {
    } finally {
      malloc.free(ptr);
    }
  }

  /// Oyna holati:
  ///   0 — keshlanyapti (kutish kerak);
  ///   1 — TAYYOR (o'sha joyni ijro qilsa bo'ladi);
  ///   2 — muvaffaqiyatsiz (qayta urinsa bo'ladi);
  ///   3 — hali umuman boshlanmagan.
  int videoWindowStatus(String url, int windowIndex) {
    if (!_loaded || url.isEmpty || windowIndex < 0) return 3;
    final ptr = url.toNativeUtf8();
    try {
      return _videoWindowStatus(ptr, windowIndex);
    } catch (_) {
      return 3;
    } finally {
      malloc.free(ptr);
    }
  }

  /// ── BU BO'LAK AVVAL KESHDA KO'RILGANMI ────────────────────
  ///
  /// `true` bo'lsa ilova pleyerni ochishdan oldin isitishni
  /// KUTMAYDI — video darhol ochiladi, isitish esa fon'da ketadi.
  ///
  /// NEGA KERAK: o'lchandi, "bo'sh" isitish so'rovi (kesh
  /// allaqachon tayyor bo'lgan holat) data-markazdan 0.26-0.63
  /// soniya, telefonda mobil tarmoqda esa 1-3 soniya oladi.
  /// `/api/play` ning o'zi atigi 0.3 soniyada javob beradi. Ya'ni
  /// "video keshda bo'lsa ham sekin ochilyapti" muammosining
  /// katta qismi aynan shu keraksiz kutish edi.
  ///
  /// Kesh kutilmaganda o'chirilgan bo'lsa pleyer xatoga chiqadi va
  /// odatdagi tiklanish yo'li oynani isitib, o'sha joydan qayta
  /// ochadi.
  bool videoWindowSeen(String url, int windowIndex) {
    if (!_loaded || url.isEmpty || windowIndex < 0) return false;
    final ptr = url.toNativeUtf8();
    try {
      return _videoWindowSeen(ptr, windowIndex) == 1;
    } catch (_) {
      return false;
    } finally {
      malloc.free(ptr);
    }
  }

  /// Faylning umumiy hajmi (bayt). 0 — hali noma'lum.
  int videoTotalBytes(String url) {
    if (!_loaded || url.isEmpty) return 0;
    final ptr = url.toNativeUtf8();
    try {
      return _videoTotal(ptr);
    } catch (_) {
      return 0;
    } finally {
      malloc.free(ptr);
    }
  }

  /// Bitta oynadagi baytlar soni. Qiymat Rust yadrosidan olinadi —
  /// ilovada qo'lda takrorlanmaydi, ya'ni ikki tomon hech qachon
  /// bir-biriga zid bo'lib qolmaydi.
  int get videoWindowSize {
    if (!_loaded) return 480 * 1024 * 1024;
    try {
      final v = _videoWindowSize();
      return v > 0 ? v : 480 * 1024 * 1024;
    } catch (_) {
      return 480 * 1024 * 1024;
    }
  }

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
