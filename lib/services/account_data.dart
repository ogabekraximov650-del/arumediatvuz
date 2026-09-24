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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'billing_service.dart';
import 'admin_badges.dart';
import 'support_service.dart';
import 'rust_bridge.dart';
import 'season_info.dart';
import 'stats_service.dart';
import 'image_cache.dart';
import 'sync_queue.dart';
import 'traffic_service.dart';
import 'watch_history.dart';
import 'watch_progress.dart';

class AccountData {
  const AccountData._();

  /// Hisob almashdi (kirildi, chiqildi yoki boshqasiga o'tildi).
  ///
  /// `userId` 0 bo'lsa — mehmon (`accountid_0`).
  static Future<void> switchTo(int userId, {int telegramId = 0}) async {
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
    guardOwner(userId, telegramId);

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
    // Balans va obuna ham hisobga tegishli.
    try {
      BillingService.instance.clear();
    } catch (_) {}
    // O'qilmagan xabarlar nuqtasi ham hisobga tegishli.
    try {
      UnreadBadge.instance.clear();
    } catch (_) {}
    // Admin panelidagi yangilik nuqtalari ham.
    try {
      AdminBadges.instance.clear();
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
    // Obuna muddati — tarmoqsiz ham ma'lum bo'lishi kerak
    // (`billing_service.dart` -> `restore` izohiga qarang).
    try {
      BillingService.instance.restore();
    } catch (_) {}
    try {
      await TrafficService.instance.attach();
    } catch (_) {}
    try {
      SyncQueue.instance.attach();
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════
  //  PAPKA BOSHQA ODAMGA O'TIB KETMASLIGI
  // ═══════════════════════════════════════════════════════════
  //
  // TOPILGAN XAVF: ilovadagi raqam (`users_db.id`) QAYTA
  // ISHLATILADI. Server yangi hisobga "band bo'lmagan eng kichik
  // raqam" ni beradi (`next_user_slot`) — ya'ni 1-raqamli hisob
  // o'chirilsa, keyingi ro'yxatdan o'tgan odam ham 1 ni oladi.
  //
  // Papka nomi esa aynan shu raqamdan yasaladi (`accountid_1`).
  // Demak eski egasining telefonida qolgan papka YANGI odamga
  // ochilib qolishi mumkin edi: tomosha tarixi, sevimlilar,
  // trafik hisobi — hammasi begona odamga ko'rinardi.
  //
  // Himoya oddiy: papkaga egasining TELEGRAM raqami yozib
  // qo'yiladi (u hech qachon qayta ishlatilmaydi). Kirganda raqam
  // mos kelmasa papka tozalanadi.
  static const String _ownerFile = 'owner.json';
  static const String _ownerLabel = 'account-owner';

  static void guardOwner(int userId, int telegramId) {
    if (userId <= 0 || telegramId <= 0) return;
    final dir = RustCore.instance.dataDirPath;
    final root = RustCore.instance.rootDirPath;
    // Papka ochilmagan (eski qurilma) — umumiy kesh, tegilmaydi.
    if (dir == null || dir == root) return;
    try {
      // Egasi fayli SHIFRLANGAN (foydalanuvchi talabi: "diskda
      // saqlanadigan hamma narsa shifrlansin"). Eski ilova uni ochiq
      // JSON bilan yozgan — o'shani ham o'qiymiz, keyin shifrlangan
      // holda qayta yoziladi.
      final path = '$dir/$_ownerFile';
      final f = File(path);
      var text = RustCore.instance.secureLoad(path, _ownerLabel);
      if (text.isEmpty && f.existsSync()) {
        try {
          text = f.readAsStringSync();
        } catch (_) {}
      }
      if (text.isNotEmpty) {
        final prev = ((jsonDecode(text) as Map)['tg'] as num?)?.toInt() ?? 0;
        if (prev != 0 && prev != telegramId) {
          // Papka BOSHQA odamniki — tozalanadi.
          _wipeDir(Directory(dir));
        }
      }
      final owner = jsonEncode({'tg': telegramId});
      if (!RustCore.instance.secureSave(path, _ownerLabel, owner)) {
        // Kalit yo'q (Keystore xatosi — ilova bu holatda shifrlashsiz
        // ishlaydi). Himoya o'chib qolmasin: ochiq holda yoziladi.
        f.writeAsStringSync(owner);
      }
    } catch (e) {
      debugPrint('Papka egasi tekshirilmadi: $e');
    }
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
    //
    // Ikki joyga qaraladi: yangi papka qo'llab-quvvatlash
    // papkasida (`image_cache.dart`), eski o'rnatishlarda esa
    // vaqtinchalik papkada qolgan bo'lishi mumkin.
    onStep?.call('Rasmlar keshi', 0.85);
    for (final root in [
      await getApplicationSupportDirectory(),
      await getTemporaryDirectory(),
    ]) {
      _wipeImageCache(root);
    }

    onStep?.call('Tayyor', 1.0);
  }

  /// Papkadagi posterlar keshini o'chiradi.
  static void _wipeImageCache(Directory root) {
    try {
      if (!root.existsSync()) return;
      for (final e in root.listSync()) {
        final name = e.uri.pathSegments
            .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (!name.startsWith('libCachedImageData') &&
            !name.startsWith(AppImageCache.key)) {
          continue;
        }
        try {
          if (e is File) {
            e.deleteSync();
          } else if (e is Directory) {
            e.deleteSync(recursive: true);
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Rasm keshi tozalanmadi: $e');
    }
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
      debugPrint('Hisob papkasi tozalanmadi: $e');
    }
  }
}
