// lib/services/screen_guard.dart — SKRINSHOT VA EKRAN YOZUVINI TAQIQLASH.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "ilovada video pleyerda va shaxsiy chatda
// screenshot olish va ekranni yozib olish taqiqlansin".
//
// ── QANDAY ISHLAYDI ─────────────────────────────────────────
//
// Android oynasiga `FLAG_SECURE` qo'yiladi (`MainActivity.kt`).
// U bir vaqtda uchta ishni qiladi:
//   * skrinshot olinmaydi — tizim "ruxsat yo'q" deydi;
//   * ekran yozuvida va uzatishda oyna QORA ko'rinadi;
//   * oxirgi ilovalar ro'yxatida tarkib yashiriladi.
//
// ── NEGA SANOQ (counter) ────────────────────────────────────
//
// Bayroq BUTUN oynaga tegishli, ekran esa bir nechtasi ustma-ust
// ochilishi mumkin (pleyer ustidan yozishma ochilsa). Agar har
// ekran yopilganda bayroq shunchaki o'chirilsa, tagdagi ekran
// himoyasiz qolardi. Shu sabab bu yerda ochiq "himoyalangan
// ekranlar" SONI sanaladi: son noldan oshsa bayroq yoqiladi,
// nolga tushsa o'chiriladi.
//
// ── IOS ─────────────────────────────────────────────────────
//
// iOS'da skrinshotni butunlay to'sish yo'li YO'Q (tizim bunday
// imkon bermaydi). Bu yerdagi kanal iOS'da shunchaki javob
// bermaydi va ilova xatosiz ishlayveradi.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_build.dart';

class ScreenGuard {
  const ScreenGuard._();

  static const _ch = MethodChannel('aru/secure');

  /// Hozir nechta himoyalangan ekran ochiq.
  static int _depth = 0;

  /// Bayroq hozir yoqilganmi (keraksiz kanal chaqiruvlarini
  /// oldini oladi).
  static bool _on = false;

  /// Himoyani yoqadi (ekran `initState` da chaqiradi).
  /// Admin buildda screenshot va ekran yozuviga ruxsat beriladi.
  static void enable() {
    if (kAdminBuild) return;
    _depth++;
    _apply();
  }

  /// Himoyani o'chiradi (ekran `dispose` da chaqiradi).
  static void disable() {
    if (kAdminBuild) return;
    if (_depth > 0) _depth--;
    _apply();
  }

  static void _apply() {
    final want = _depth > 0;
    if (want == _on) return;
    _on = want;
    // Javob KUTILMAYDI: bayroq qo'yilishi UI oqimida bajariladi
    // va ekranni ushlab turishning ma'nosi yo'q. Xato bo'lsa
    // (masalan iOS) — jim o'tiladi.
    _ch.invokeMethod<bool>(want ? 'on' : 'off').catchError((Object e) {
      if (kDebugMode) {
        // Faqat ishlab chiqish paytida ko'rinadi.
        debugPrint('ScreenGuard: $e');
      }
      return false;
    });
  }
}

/// Ekranga himoyani ULAYDIGAN aralashma (mixin).
///
/// `State` klassiga qo'shilsa yetarli — ekran ochilganda himoya
/// yoqiladi, yopilganda o'chiriladi. Har ekranda `initState` va
/// `dispose` ni qo'lda yozish shart emas va shu bilan "bittasida
/// o'chirishni unutib qo'yish" xatosi ham yo'qoladi.
mixin ScreenGuarded<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    ScreenGuard.enable();
  }

  @override
  void dispose() {
    ScreenGuard.disable();
    super.dispose();
  }
}
