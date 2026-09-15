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
//     O'ZINING keshini ishlatadi: 3000 tagacha fayl, 180 kun.
//
// Rasm kichik (poster ~40-120 KB), ya'ni 3000 ta fayl ham eng
// yomon holatda ~200-300 MB emas, amalda ancha kam: katalogda
// shuncha anime yo'q. Chegara "hech qachon yetib bo'lmaydigan"
// qilib qo'yildi — maqsad aynan shu.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class AppImageCache {
  const AppImageCache._();

  /// Papka nomi. `StorageJanitor` shu nomni TEGMASDAN qoldiradi.
  static const String key = 'aru_images';

  static final CacheManager manager = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 180),
      maxNrOfCacheObjects: 3000,
    ),
  );
}

/// `CachedNetworkImageProvider` ning shu kesh bilan ishlaydigan
/// ko'rinishi. `Image(image: ...)` va `ResizeImage(...)` ichida
/// ishlatiladi.
CachedNetworkImageProvider appImageProvider(String url) =>
    CachedNetworkImageProvider(url, cacheManager: AppImageCache.manager);
