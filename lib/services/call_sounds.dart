// lib/services/call_sounds.dart — QO'NG'IROQ VA BILDIRISHNOMA OVOZLARI.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "qo'ng'iroq qilganda va kelganda odamning asabiga
// va jig'iga tegmaydigan, xalaqit bermaydigan ovoz qo'yish kerak".
//
// Shu sabab ovozlar noldan yasalgan (`ci/gen_sounds.py`): sof
// sinus to'lqin + ikkita yumshoq harmonika, har bir notaning boshi
// silliqlangan (klik eshitilmaydi), kelayotgan qo'ng'iroq esa past
// ovozda boshlanib asta kuchayadi.
//
// Yon foyda: tayyor ohangni internetdan olishda mualliflik huquqi
// masalasi chiqadi — bu yerda esa hammasi loyihaning o'ziniki.
//
// ── PLEYER OVOZINI PASAYTIRISH ────────────────────────────────
//
// TALAB (foydalanuvchi): "agar pleyerda o'tirgan bo'lsa 5 soniyaga
// video ovozi pasayib bildirishnoma ovozi eshitilishi kerak".
//
// Buni bu fayl O'ZI qilmaydi — u pleyerni bilmaydi va bilmasligi
// ham kerak. Uning o'rniga `onDuck` chaqiriladi: pleyer ekrani
// unga o'z ishini bog'lab qo'yadi. Shu bilan ikkovi bir-biridan
// mustaqil qoladi.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Qaysi ovoz.
enum AppSound {
  /// Qo'ng'iroq kelmoqda (takrorlanadi).
  incoming,

  /// Siz qo'ng'iroq qilyapsiz, kutish (takrorlanadi).
  outgoing,

  /// Yangi xabar yoki ovozli xabar.
  message,

  /// Suhbat ulandi.
  connected,

  /// Suhbat tugadi.
  ended,
}

extension _Asset on AppSound {
  String get path => switch (this) {
        AppSound.incoming => 'assets/sounds/incoming_call.wav',
        AppSound.outgoing => 'assets/sounds/outgoing_call.wav',
        AppSound.message => 'assets/sounds/message.wav',
        AppSound.connected => 'assets/sounds/call_connected.wav',
        AppSound.ended => 'assets/sounds/call_ended.wav',
      };

  /// Takrorlanadimi — qo'ng'iroq ohanglari takrorlanadi, qolgani
  /// bir marta chalinadi.
  bool get loops => this == AppSound.incoming || this == AppSound.outgoing;

  /// Balandligi (0..1). Bildirishnoma qo'ng'iroqdan pastroq —
  /// u shunchaki eslatma, chaqiriq emas.
  double get volume => switch (this) {
        AppSound.incoming => 1.0,
        AppSound.outgoing => 0.7,
        AppSound.message => 0.6,
        AppSound.connected => 0.5,
        AppSound.ended => 0.5,
      };
}

class CallSounds {
  CallSounds._();
  static final CallSounds instance = CallSounds._();

  /// ── NEGA IKKI PLEYER ──────────────────────────────────────
  ///
  /// Qo'ng'iroq ohangi uzoq chalinadi, bildirishnoma esa uning
  /// USTIGA tushishi mumkin (qo'ng'iroq kelayotganda xabar ham
  /// kelishi mumkin). Bitta pleyer bilan ikkinchisi birinchisini
  /// uzib qo'yardi.
  AudioPlayer? _ring;
  AudioPlayer? _blip;

  /// Pleyer ovozini vaqtincha pasaytirish uchun ulanish nuqtasi.
  ///
  /// Video ekrani ochilganda o'zini shu yerga yozadi, yopilganda
  /// `null` qilib qo'yadi.
  ///
  /// `on` — `true` bo'lsa pasaytir, `false` bo'lsa qaytar.
  void Function(bool on)? onDuck;

  Timer? _unduck;

  /// Ovozni chaladi.
  ///
  /// `duck` — chalish paytida video ovozini pasaytirsinmi.
  Future<void> play(AppSound s, {bool duck = false}) async {
    try {
      if (duck) _duck();
      if (s.loops) {
        await stopRing();
        final p = AudioPlayer();
        _ring = p;
        await p.setAsset(s.path);
        await p.setLoopMode(LoopMode.one);
        await p.setVolume(s.volume);
        await p.play();
      } else {
        // Oldingi qisqa ovoz hali tugamagan bo'lsa — to'xtatamiz.
        await _blip?.stop();
        await _blip?.dispose();
        final p = AudioPlayer();
        _blip = p;
        await p.setAsset(s.path);
        await p.setVolume(s.volume);
        await p.play();
      }
    } catch (e) {
      // Ovoz chalinmasligi ILOVANI TO'XTATMASLIGI kerak: qo'ng'iroq
      // ovozsiz ham ishlayveradi, ekranda ko'rinib turadi.
      debugPrint('CallSounds: $e');
    }
  }

  /// Takrorlanayotgan ohangni to'xtatadi.
  Future<void> stopRing() async {
    final p = _ring;
    _ring = null;
    if (p == null) return;
    try {
      await p.stop();
      await p.dispose();
    } catch (_) {}
  }

  /// Video ovozini 5 soniyaga pasaytiradi.
  ///
  /// NEGA 5 SONIYA: bildirishnoma banneri ham shuncha turadi
  /// (foydalanuvchi talabi), ya'ni ovoz va ko'rinish bir vaqtda
  /// paydo bo'lib, bir vaqtda ketadi.
  void _duck() {
    final f = onDuck;
    if (f == null) return;
    f(true);
    _unduck?.cancel();
    _unduck = Timer(const Duration(seconds: 5), () => f(false));
  }

  Future<void> dispose() async {
    _unduck?.cancel();
    await stopRing();
    try {
      await _blip?.dispose();
    } catch (_) {}
    _blip = null;
  }
}
