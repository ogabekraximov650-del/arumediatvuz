// services/floating_player_service.dart
//
// ═══════════════════════════════════════════════════════════════
//  ILOVALAR USTIDA SUZUVCHI PLEYER (to'liq boshqariladigan)
// ═══════════════════════════════════════════════════════════════
//
// Ilovada suzuvchi pleyerning UCH turi bor — chalkashmaslik uchun:
//
//   1. `mini_player_service.dart` — ILOVA ICHIDA. Flutter bilan
//      chizilgan kichik oyna, hamma bo'limlar ustida turadi.
//
//   2. `pip_service.dart` — tizim PiP'i. Ilovalar ustida, lekin
//      oynani ANDROID boshqaradi: tugmalar yo'q, surib bo'lmaydi.
//
//   3. SHU FAYL — ilovalar ustida, oynani BIZ boshqaramiz:
//      tugmalari bor, suriladi, o'lchami o'zgaradi. Video native
//      ExoPlayer bilan chiziladi (`FloatingPlayerService.kt`).
//
// Uchinchisi eng qulay, lekin "ilovalar ustida ko'rsatish"
// ruxsatini talab qiladi. Uni oddiy dialog bilan so'rab
// bo'lmaydi — foydalanuvchi Sozlamalarda qo'lda yoqadi.
//
// Android'dan boshqa platformada kanal javob bermaydi, shu sabab
// har bir chaqiruv himoyalangan va xavfsiz qiymat qaytaradi.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FloatingPlayerService {
  FloatingPlayerService._();
  static final instance = FloatingPlayerService._();

  static const _ch = MethodChannel('aru/float');

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// "Ilovalar ustida ko'rsatish" ruxsati berilganmi.
  ///
  /// Foydalanuvchi uni Sozlamalardan istalgan payt o'chirib
  /// qo'yishi mumkin — shu sabab javob KESHLANMAYDI, har safar
  /// qaytadan so'raladi.
  Future<bool> hasPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('canDraw') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Sozlamalardagi ruxsat sahifasini ochadi.
  ///
  /// Qaytgan qiymat — sahifa OCHILDIMI, degani. Ruxsat
  /// berilganini bilish uchun foydalanuvchi qaytgach
  /// [hasPermission] qayta chaqiriladi.
  Future<bool> openPermissionSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Suzuvchi oynani ochadi va ilovani orqaga oladi.
  ///
  /// [positionMs] — video qaysi soniyadan davom etsin.
  /// `false` — ruxsat yo'q yoki tizim rad etdi.
  Future<bool> start({
    required String url,
    required Duration position,
    String title = '',
  }) async {
    if (!_isAndroid || url.isEmpty) return false;
    try {
      return await _ch.invokeMethod<bool>('start', {
            'url': url,
            'positionMs': position.inMilliseconds,
            'title': title,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Oynani yopadi (agar ochiq bo'lsa).
  Future<void> stop() async {
    if (!_isAndroid) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  /// Oyna hozir ochiqmi.
  Future<bool> isRunning() async {
    if (!_isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Oyna yopilgandagi oxirgi ijro nuqtasi.
  ///
  /// `null` — yozilgan nuqta yo'q. O'qilgach native tomonda
  /// tozalanadi, ya'ni bir qiymat IKKI MARTA qaytmaydi: aks holda
  /// keyingi ochilishda pleyer eski joyga sakrab ketardi.
  Future<Duration?> takeLastPosition() async {
    if (!_isAndroid) return null;
    try {
      final ms = await _ch.invokeMethod<int>('takeLastPosition') ?? -1;
      if (ms < 0) return null;
      return Duration(milliseconds: ms);
    } catch (_) {
      return null;
    }
  }
}
