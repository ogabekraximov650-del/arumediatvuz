// lib/services/app_build.dart — ILOVA HAQIDA.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi:
//   * "ikkita build qil: bittasida admin paneliga tegishli kodlar
//      bo'lmasin, ikkinchisida esa men uchun admin paneli bor";
//   * "admin panelga versiya raqam yozadigan bo'lim qo'sh ...
//      Worker shu va shundan katta versiyalarda ishlaydi";
//   * "APP_KEY nimaga kerak? ... busiz ishlaydigan qilish kerak,
//      ya'ni worker ilovaning haqiqiyligini tekshirishi kerak".
//
// ── NEGA KALIT OLIB TASHLANDI ───────────────────────────────
//
// Foydalanuvchi haq edi. APK'ga qo'yilgan sir — shunchaki APK
// ichidagi matn: uni ochib o'qish mumkin va u hech narsani
// ISBOTLAMAYDI. Ustiga uni GitHub Secrets'ga qo'yish va har
// almashtirganda APK qayta yig'ish kerak edi — ortiqcha ish.
//
// O'rniga ILOVANING IMZOSI ishlatiladi (`AppSignature`). Uni
// ilova o'zi tanlamaydi — TIZIM beradi. Kimdir ilovani
// o'zgartirib qayta yig'sa, uni o'z kaliti bilan imzolashga
// majbur va imzo hash'i boshqacha chiqadi.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// ── ADMIN PANELI BOR BUILDMI ────────────────────────────────
///
/// `const` bo'lgani MUHIM: Dart kompilyatori `if (kAdminBuild)`
/// shartini build paytida hal qiladi va `false` bo'lsa ichidagi
/// kodni butunlay tashlab yuboradi. Oddiy `bool` bilan kod APK
/// ichida QOLIB KETARDI.
///
/// Odatiy `false` — tasodifan `--dart-define` berilmasa, admin
/// paneli BO'LMAGAN (xavfsizroq) build chiqadi.
const bool kAdminBuild = bool.fromEnvironment('ADMIN_BUILD');

/// ── ILOVA VERSIYASI ─────────────────────────────────────────
///
/// `0.0.9+230` ko'rinishida. Har so'rovda serverga yuboriladi va
/// server uni eng past ruxsat etilgan versiya bilan solishtiradi.
///
/// Bo'sh bo'lsa — ishlab chiqish rejimi.
const String kAppVersion = String.fromEnvironment('APP_VERSION');

/// ── ILOVANING IMZOSI ────────────────────────────────────────
///
/// APK imzo sertifikatining SHA-256 hash'i (base64). Tizimdan
/// olinadi (`MainActivity.kt` -> `aru/signature`).
///
/// Ilova ochilishida BIR MARTA o'qiladi va xotirada qoladi: har
/// so'rovda platformaga murojaat qilish qimmat bo'lardi.
///
/// ⚠️ ROSTINI AYTISH KERAK: hash'ning o'zini APK'dan o'qib,
/// so'rovni qo'lda yasash mumkin. Ya'ni bu:
///   * O'ZGARTIRILGAN ILOVANI to'xtatadi — asosiy maqsad shu;
///   * brauzer, bot va oddiy skriptlarni to'xtatadi;
///   * maqsadli hujumchini to'xtatmaydi.
/// Mutlaq yechim (Play Integrity) Play Store'ni talab qiladi,
/// bu ilova esa APK bo'lib tarqatiladi.
class AppSignature {
  const AppSignature._();

  static const _ch = MethodChannel('aru/signature');

  static String _value = '';

  /// Hash (bo'sh — hali o'qilmagan yoki olinmadi).
  static String get value => _value;

  /// Ilova ochilishida bir marta chaqiriladi.
  static Future<void> load() async {
    if (_value.isNotEmpty) return;
    try {
      _value = await _ch.invokeMethod<String>('sha256') ?? '';
    } catch (e) {
      // iOS yoki eski qurilma — hash bo'sh qoladi. Server bunday
      // holatda tekshiruvni o'chirib qo'ygan bo'lsa ilova
      // baribir ishlaydi.
      if (kDebugMode) debugPrint('AppSignature: $e');
    }
  }
}

/// ── BOSH SAHIFADAGI STATISTIKA KO'RINSINMI ──────────────────
///
/// Foydalanuvchi talabi: build qilinganda bosh sahifa tepasidagi
/// statistika banneri KO'RINMASIN.
///
/// `const` bo'lgani MUHIM: `if (kHomeStats)` sharti build paytida
/// hal qilinadi va `false` bo'lsa banner kodi APK ichiga
/// umuman tushmaydi (tree-shaking).
///
/// Odatiy `false`. Kerak bo'lsa:
///   flutter build apk --dart-define=HOME_STATS=true
const bool kHomeStats = bool.fromEnvironment('HOME_STATS');
