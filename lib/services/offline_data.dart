// lib/services/offline_data.dart — OFLAYN MA'LUMOTLARNI TOZALASH.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB (foydalanuvchi)
// ═══════════════════════════════════════════════════════════════
//
// "Foydalanuvchi accountini o'chirsa yoki chiqib ketsa, ilova shu
//  zahoti oflayn rejimda ishlatish uchun yuklab olingan
//  ma'lumotlarni tozalab tashlasin. Boshqa account bilan qayta
//  kirganda esa o'sha accountga tegishli ma'lumotlar kerak vaqtda
//  keragicha yuklab olinsin."
//
// Shu sabab chiqishda DISKDA hech narsa qolmaydi:
//
//   * yuklab olingan videolar va yuklash navbati (Rust yadrosi);
//   * ro'yxat keshlari — animelar, bo'limlar, qismlar, sevimlilar,
//     statistika, trafik hisobi (`list_*.rustbin`);
//   * tomosha tarixidagi kadr rasmlari (`thumb_*.rustbin`);
//   * rasmlar keshi (posterlar).
//
// Xotiradagi xizmatlar ham bo'shatiladi — ekranda oldingi
// hisobning ma'lumoti bir zumga ham ko'rinib qolmasin.
//
// ── NEGA HAMMASI, TANLAB EMAS ─────────────────────────────────
//
// Kesh fayllarida "kimniki" degan belgi yo'q va bo'lishi ham
// shart emas: ro'yxat keshlari qaytadan bir necha kilobaytda
// yuklanadi, videolar esa foydalanuvchi qaysi qismni xohlasa
// o'shani qaytadan yuklab oladi. Tanlab tozalash murakkab va
// xatoga moyil bo'lardi, natijada esa boshqa odamning yuklab
// olgan videosi telefonda qolib ketishi mumkin edi.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'rust_bridge.dart';
import 'season_info.dart';
import 'stats_service.dart';
import 'traffic_service.dart';
import 'watch_history.dart';

class OfflineData {
  const OfflineData._();

  /// Hamma narsani o'chiradi. Xato bo'lsa ham to'xtamaydi —
  /// har bir bosqich mustaqil.
  static Future<void> wipe() async {
    // 1) Xotiradagi ro'yxatlar (ekran darhol bo'shasin).
    try {
      WatchHistory.instance.clear();
    } catch (_) {}
    try {
      FavoritesService.instance.clear();
    } catch (_) {}
    try {
      MyStatsService.instance.clear();
    } catch (_) {}

    // 2) Yuklab olingan videolar va yuklash navbati.
    try {
      RustCore.instance.videoCacheWipe();
    } catch (_) {}

    // 3) Diskdagi kesh fayllari.
    await _removeCacheFiles();

    // 4) Posterlar keshi (xotira + disk).
    try {
      imageCache.clear();
      imageCache.clearLiveImages();
    } catch (_) {}
    await _removeImageCache();

    // 5) Trafik hisobi shu paytdan qaytadan boshlanadi.
    try {
      await TrafficService.instance.reset();
    } catch (_) {}
  }

  /// `list_*.rustbin` va `thumb_*.rustbin` fayllari.
  ///
  /// Umumiy statistika keshi (`list_app_stats.rustbin`) ham
  /// o'chadi — u shaxsiy emas, lekin qaytadan olish bir so'rov,
  /// alohida istisno qilishning ma'nosi yo'q.
  static Future<void> _removeCacheFiles() async {
    final dir = RustCore.instance.dataDirPath;
    if (dir == null) return;
    try {
      final entries = Directory(dir).listSync();
      for (final e in entries) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (name.startsWith('list_') || name.startsWith('thumb_')) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('Kesh fayllari o\'chirilmadi: $e');
    }
  }

  /// `cached_network_image` posterlarni vaqtinchalik papkadagi
  /// `libCachedImageData` ichida saqlaydi. Papkaning o'zi
  /// o'chiriladi — paket keyingi safar uni qaytadan yasaydi.
  static Future<void> _removeImageCache() async {
    try {
      final tmp = await getTemporaryDirectory();
      for (final name in const ['libCachedImageData', 'libCachedImageData.db']) {
        final entity = Directory('${tmp.path}/$name');
        if (entity.existsSync()) {
          entity.deleteSync(recursive: true);
          continue;
        }
        final file = File('${tmp.path}/$name');
        if (file.existsSync()) file.deleteSync();
      }
    } catch (e) {
      debugPrint('Rasm keshi o\'chirilmadi: $e');
    }
  }
}
