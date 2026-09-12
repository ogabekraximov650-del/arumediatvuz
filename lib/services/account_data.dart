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

import 'app_settings.dart';
import 'rust_bridge.dart';
import 'season_info.dart';
import 'stats_service.dart';
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
  }
}
