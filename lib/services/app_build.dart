// lib/services/app_build.dart — ILOVA HAQIDA (build vaqtida beriladi).
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi:
//   * "ikkita build qil: bittasida admin paneliga tegishli kodlar
//      bo'lmasin, ikkinchisida esa men uchun admin paneli bor";
//   * "admin panelga versiya raqam yozadigan bo'lim qo'sh ...
//      Worker shu va shundan katta versiyalarda ishlaydi, agar
//      versiya past bo'lsa ishlamaydi";
//   * "Workerni faqat ilovaga javob beradigan qil, tashqi
//      so'rovlar rad etilsin".
//
// Uchalasi ham SHU YERDAGI uchta qiymatga tayanadi. Ular kodda
// yozilmaydi — build paytida `--dart-define` bilan beriladi
// (`.github/workflows/build-flutter-apk.yml`).

/// ── ADMIN PANELI BOR BUILDMI ────────────────────────────────
///
/// `const` bo'lgani MUHIM: Dart kompilyatori `if (kAdminBuild)`
/// shartini build paytida hal qiladi va `false` bo'lsa ichidagi
/// kodni butunlay tashlab yuboradi. Oddiy `bool` bilan kod APK
/// ichida QOLIB KETARDI.
///
/// Odatiy `false` — ya'ni tasodifan `--dart-define` berilmasa,
/// admin paneli BO'LMAGAN (xavfsizroq) build chiqadi.
const bool kAdminBuild = bool.fromEnvironment('ADMIN_BUILD');

/// ── ILOVA VERSIYASI ─────────────────────────────────────────
///
/// `0.0.9+230` ko'rinishida. Har so'rovda serverga yuboriladi va
/// server uni eng past ruxsat etilgan versiya bilan solishtiradi
/// (`app_min_version`).
///
/// Bo'sh bo'lsa — ishlab chiqish rejimi: server bunday so'rovni
/// tekshirmaydi.
const String kAppVersion = String.fromEnvironment('APP_VERSION');

/// ── ULANISH KALITI ──────────────────────────────────────────
///
/// Har so'rovga qo'shiladi (`X-App-Key`). Server kalitsiz yoki
/// noto'g'ri kalitli so'rovni rad etadi — ya'ni brauzerdan yoki
/// skriptdan API'ga kirib bo'lmaydi.
///
/// ⚠️ MUHIM VA ROSTINI AYTISH KERAK: kalit APK ICHIDA turadi.
/// Uni telefonga o'rnatgan va APK'ni ochib ko'ra oladigan odam
/// kalitni topishi MUMKIN. Ya'ni bu:
///   * tasodifiy so'rovlarni, qidiruv botlarini va oddiy
///     skriptlarni TO'XTATADI;
///   * maqsadli hujumchini to'xtatmaydi.
/// Haqiqiy himoya — serverdagi sessiya tekshiruvi va so'rov
/// chegaralari, ular o'z joyida qoladi.
const String kAppKey = String.fromEnvironment('APP_KEY');
