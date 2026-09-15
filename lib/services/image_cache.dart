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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' hide FileSystem;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// ── RASMLAR QAYERDA YOTADI ──────────────────────────────────
///
/// TALAB (foydalanuvchi): "ilovada foydalanuvchi ko'rgan barcha
/// suratlar butun umrga cheksiz diskda saqlansin; faqat ilova
/// o'chirilganda yoki telefon sozlamalaridan tozalanmaguncha
/// o'chmasin".
///
/// `flutter_cache_manager` ODATDA `getTemporaryDirectory()` ga
/// yozadi — Android'da bu `cacheDir`. Nomidan ko'rinib turibdi:
/// TIZIM u yerdagi fayllarni xohlagan payti, xotira
/// kamayganda O'ZI o'chirib yuboradi. Ya'ni "butun umrga"
/// degani u yerda bajarilmasdi.
///
/// Shu sabab papka `getApplicationSupportDirectory()` ga
/// ko'chirildi. Android'da bu `files/` ichida: tizim unga
/// tegmaydi, u faqat
///   * ilova o'chirilganda, yoki
///   * odam Sozlamalar > Ilova > Xotirani tozalash desa
/// yo'qoladi — aynan foydalanuvchi so'ragan xatti-harakat.
class _PermanentFileSystem implements FileSystem {
  _PermanentFileSystem(this._key) : _dir = _open(_key);

  final String _key;
  final Future<Directory> _dir;

  static Future<Directory> _open(String key) async {
    final base = await getApplicationSupportDirectory();
    const fs = LocalFileSystem();
    final dir = fs.directory(p.join(base.path, key));
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<File> createFile(String name) async {
    var dir = await _dir;
    if (!await dir.exists()) dir = await _open(_key);
    return dir.childFile(name);
  }
}

class AppImageCache {
  const AppImageCache._();

  /// Papka nomi. `StorageJanitor` shu nomni TEGMASDAN qoldiradi
  /// (papka endi vaqtinchalik emas, lekin eski o'rnatishlarda
  /// qoldiq bo'lishi mumkin).
  static const String key = 'aru_images';

  /// ── NEGA BU RAQAMLAR ─────────────────────────────────────
  ///
  /// `stalePeriod` — fayl shu muddat ISHLATILMASA o'chiriladi.
  /// 100 yil qo'yildi: amalda "hech qachon".
  ///
  /// `maxNrOfCacheObjects` — odatda 200 edi va poster undan tez
  /// chiqib ketardi. Bu yerdagi son ham amalda yetib
  /// bo'lmaydigan qilib qo'yilgan.
  ///
  /// Ya'ni rasmni faqat foydalanuvchining o'zi (yoki ilovaning
  /// o'chirilishi) yo'qotadi.
  static final CacheManager manager = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 365 * 100),
      maxNrOfCacheObjects: 1000000,
      fileSystem: _PermanentFileSystem(key),
    ),
  );
}

/// `CachedNetworkImageProvider` ning shu kesh bilan ishlaydigan
/// ko'rinishi. `Image(image: ...)` va `ResizeImage(...)` ichida
/// ishlatiladi.
CachedNetworkImageProvider appImageProvider(String url) =>
    CachedNetworkImageProvider(url, cacheManager: AppImageCache.manager);
