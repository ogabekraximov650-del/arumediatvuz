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
typedef _SearchFilterDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

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

  bool _loaded = false;
  String? _cacheFilePath;

  /// Ilova ishga tushganda bir marta chaqiriladi (main() ichida).
  Future<void> init() async {
    if (_loaded) return;

    _lib = Platform.isAndroid
        ? DynamicLibrary.open('librust_core.so')
        : DynamicLibrary.process();

    _cacheGet = _lib.lookupFunction<_CacheGetC, _CacheGetDart>('rust_cache_get');
    _cacheIsFresh =
        _lib.lookupFunction<_CacheIsFreshC, _CacheIsFreshDart>('rust_cache_is_fresh');
    _cacheSave = _lib.lookupFunction<_CacheSaveC, _CacheSaveDart>('rust_cache_save');
    _cacheClear = _lib.lookupFunction<_CacheClearC, _CacheClearDart>('rust_cache_clear');
    _searchFilter =
        _lib.lookupFunction<_SearchFilterC, _SearchFilterDart>('rust_search_filter');
    _filterGenre =
        _lib.lookupFunction<_FilterGenreC, _FilterGenreDart>('rust_filter_by_genre');
    _validate = _lib.lookupFunction<_ValidateC, _ValidateDart>('rust_validate_anime_form');
    _freeString = _lib.lookupFunction<_FreeStringC, _FreeStringDart>('rust_free_string');
    _version = _lib.lookupFunction<_VersionC, _VersionDart>('rust_core_version');

    final dir = await getApplicationDocumentsDirectory();
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
}
