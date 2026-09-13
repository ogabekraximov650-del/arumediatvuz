// lib/services/account_data.dart — HISOB ALMASHGANDA.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB (foydalanuvchi)
// ═══════════════════════════════════════════════════════════════
//
// "Chiqish yoki hisobni o'chirishda endi hech narsa tozalanmasin.
//  Shunchaki boshqa accountga o'tganda ilova ichida accountid_1
//  deb oxiriga user id qo'yib papka ochilgan bo'lishi kerak, yangi
//  accountga o'tsa accountid_5 qilib yangi papka ochilishi kerak —
//  yani account ma'lumotlari chalkashib ketmasligi uchun.
//  Lekin rasm va video fayllar bitta joydan olinishi kerak ikkala
//  accountda ham."
//
// Shu sabab BU YERDA HECH NARSA O'CHIRILMAYDI. Qilinadigan ish
// atigi ikkita:
//
//   1. Rust yadrosiga "endi shu hisobning papkasi" deb aytish
//      (`RustCore.setAccount`);
//   2. xotiradagi ro'yxatlarni bo'shatib, YANGI papkadan qaytadan
//      o'qish — aks holda ekranda oldingi hisobning tarixi bir
//      zumga ko'rinib qolardi.
//
// Eski hisobga qaytilsa, uning papkasi joyida turadi va hammasi
// (tomosha tarixi, qayerda to'xtagani, sevimlilar, trafik hisobi)
// o'sha holicha ochiladi.
//
// ── NIMA UMUMIY BO'LIB QOLADI ─────────────────────────────────
//
//   * yuklab olingan VIDEOLAR — `video_byte_cache` (Rust yadrosi);
//   * POSTERLAR — vaqtinchalik papkadagi `libCachedImageData`;
//   * anime ro'yxati — `anime_cache.rustbin`.
//
// Ya'ni bitta telefondagi ikki hisob bir xil faylni ikki marta
// yuklab olmaydi.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'rust_bridge.dart';
import 'season_info.dart';
import 'stats_service.dart';
import 'sync_queue.dart';
import 'traffic_service.dart';
import 'watch_history.dart';
import 'watch_progress.dart';

class AccountData {
  const AccountData._();

  /// Hisob almashdi (kirildi, chiqildi yoki boshqasiga o'tildi).
  ///
  /// `userId` 0 bo'lsa — mehmon (`accountid_0`).
  static Future<void> switchTo(int userId) async {
    // ── 1. ESKI PAPKA YOPILADI ────────────────────────────────
    // Yozilmagan o'zgarishlar AYNAN eski hisobning papkasiga
    // tushishi kerak, shu sabab papka almashtirilishidan OLDIN.
    try {
      WatchProgress.instance.flush();
    } catch (_) {}
    try {
      await TrafficService.instance.detach();
    } catch (_) {}
    // Yuborilmagan yozuvlar ham ESKI papkada qolishi kerak.
    try {
      SyncQueue.instance.detach();
    } catch (_) {}

    // ── 2. PAPKA ALMASHADI ────────────────────────────────────
    RustCore.instance.setAccount(userId);
    RustCore.instance.setUserId(userId);

    // Xotiradagi ro'yxatlar — endi yangi hisobniki (hech narsa
    // O'CHIRILMAYDI, faqat bo'shatiladi).
    try {
      WatchHistory.instance.clear();
    } catch (_) {}
    try {
      FavoritesService.instance.clear();
    } catch (_) {}
    try {
      MyStatsService.instance.clear();
    } catch (_) {}
    try {
      WatchProgress.instance.reload();
    } catch (_) {}
    // Sozlamalar ham hisobga tegishli (`list_settings.rustbin`).
    try {
      AppSettings.instance.reload();
    } catch (_) {}

    // ── 3. YANGI PAPKADAGI NUSXALAR DARHOL KO'RINSIN ──────────
    try {
      WatchHistory.instance.loadFromDisk();
    } catch (_) {}
    try {
      FavoritesService.instance.loadFromDisk();
    } catch (_) {}
    try {
      MyStatsService.instance.loadFromDisk();
    } catch (_) {}
    try {
      await TrafficService.instance.attach();
    } catch (_) {}
    try {
      SyncQueue.instance.attach();
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════
  //  HISOB O'CHIRILGANDA — TELEFON HAM TOZALANADI
  // ═══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "hisobni o'chirganda foydalanuvchiga
  // tegishli ma'lumotlar tozalab tashlanishi kerak va tozalanish
  // jarayoni progress chizig'i bilan ko'rsatilsin".
  //
  // MUHIM FARQ: bu faqat HISOBNI O'CHIRISHDA bo'ladi. Oddiy
  // chiqishda (`logout`) telefonda hech narsa o'chmaydi —
  // o'sha hisobga qaytilsa hammasi joyida turadi (yuqoridagi
  // izohga qarang).
  //
  // `onStep` — chiqish oynasidagi progress chizig'i uchun.
  static Future<void> wipeDevice({
    void Function(String step, double progress)? onStep,
  }) async {
    // 1) Yuborilmagan yozuvlar — serverda baribir o'chiriladi.
    onStep?.call('Navbat tozalanmoqda', 0.10);
    try {
      SyncQueue.instance.wipe();
    } catch (_) {}

    // 2) Hisob papkasi: tomosha tarixi, sevimlilar, kadrlar,
    //    trafik hisobi, sozlamalar.
    onStep?.call('Tomosha tarixi va sozlamalar', 0.35);
    final dir = RustCore.instance.dataDirPath;
    final root = RustCore.instance.rootDirPath;
    if (dir != null && dir != root) {
      _wipeDir(Directory(dir));
    } else if (dir != null) {
      // Papka ochilmagan holat (eski qurilma): faqat shu hisobga
      // tegishli fayllar o'chiriladi, umumiy kesh qolaveradi.
      _wipeDir(Directory(dir), onlyPrefixed: true);
    }

    // 3) Yuklab olingan videolar.
    onStep?.call('Yuklab olingan videolar', 0.65);
    try {
      RustCore.instance.videoCacheWipe();
    } catch (_) {}

    // 4) Posterlar keshi.
    onStep?.call('Rasmlar keshi', 0.85);
    try {
      final tmp = await getTemporaryDirectory();
      for (final e in tmp.listSync()) {
        final name = e.uri.pathSegments
            .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (!name.startsWith('libCachedImageData')) continue;
        try {
          if (e is File) {
            e.deleteSync();
          } else if (e is Directory) {
            e.deleteSync(recursive: true);
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Rasm keshi tozalanmadi: \$e');
    }

    onStep?.call('Tayyor', 1.0);
  }

  /// Papkadagi fayllarni o'chiradi.
  ///
  /// `onlyPrefixed` — faqat hisobga tegishli fayllar (`list_`,
  /// `thumb_`), ya'ni umumiy anime keshiga tegilmaydi.
  static void _wipeDir(Directory dir, {bool onlyPrefixed = false}) {
    try {
      if (!dir.existsSync()) return;
      for (final e in dir.listSync(recursive: false)) {
        final name = e.uri.pathSegments
            .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (onlyPrefixed &&
            !name.startsWith('list_') &&
            !name.startsWith('thumb_')) {
          continue;
        }
        try {
          if (e is File) {
            e.deleteSync();
          } else if (e is Directory) {
            e.deleteSync(recursive: true);
          }
        } catch (_) {
          // Band fayl — qolganini o'chiraveramiz.
        }
      }
    } catch (e) {
      debugPrint('Hisob papkasi tozalanmadi: \$e');
    }
  }
}
