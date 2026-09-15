// lib/services/app_settings.dart — FOYDALANUVCHI SOZLAMALARI.
//
// ═══════════════════════════════════════════════════════════════
//  NIMA UCHUN
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): pleyerning o'ng yuqorisidagi uch nuqta
// ostida "introni avtomatik o'tkazish" degan yoqib-o'chiradigan
// tugma bo'lsin — yoqilgan bo'lsa intro o'zi o'tkazib yuboriladi,
// o'chiq bo'lsa foydalanuvchi qo'lda bosadi.
//
// Sozlama ilova yopilganda YO'QOLMASLIGI kerak, shu sabab u
// diskka yoziladi.
//
// ── QAYERGA YOZILADI ─────────────────────────────────────────
//
// Rust yadrosining ro'yxat keshiga (`list_settings.rustbin`) —
// hamma boshqa mahalliy yozuvlar kabi SHIFRLANGAN holda va
// HISOB PAPKASIDA (`accountid_<id>`). Ya'ni bitta telefonda ikki
// kishi kirsa, har birining o'z sozlamasi bo'ladi.
//
// Alohida paket (`shared_preferences`) ATAYLAB qo'shilmadi:
// bittagina bayroq uchun yangi bog'liqlik va yangi shifrlanmagan
// fayl — ortiqcha.
//
// ── YANGI SOZLAMA QO'SHISH ───────────────────────────────────
//
// Maydonni qo'shing, `_read` va `_write` ga bitta qatordan
// yozing. Yozuv BITTA qator (`Map`) bo'lib qoladi, ya'ni
// sozlamalar soni ortsa ham fayl bitta.

import 'package:flutter/foundation.dart';

import 'rust_bridge.dart';

class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  /// Diskdagi yozuv kaliti (`list_settings.rustbin`).
  static const String _key = 'settings';

  /// Intro vaqti kelganda video O'ZI o'tkazib yuborilsinmi.
  ///
  /// `false` — tugma chiqadi va foydalanuvchi qo'lda bosadi
  /// (boshlang'ich holat: hech narsa so'ramasdan videoni
  /// sakratib yuborish kutilmagan bo'lardi).
  bool autoSkipIntro = false;

  /// Qism tugaganda KEYINGISI o'zi ochilsinmi.
  ///
  /// TALAB (foydalanuvchi): "pleyerdagi 3ta nuqtaga `avto qism
  /// o'tkazish` nomli tugma qo'sh — tugmani bosganda video
  /// tugashi bilan avtomatik ravishda keyingi qismga o'tadi".
  ///
  /// `false` — boshlang'ich holat: so'ralmasdan keyingi qismni
  /// ochib yuborish kutilmagan bo'lardi.
  bool autoNextEpisode = false;

  bool _loaded = false;

  /// Diskdan o'qiydi. Bir necha marta chaqirilsa ham bir marta
  /// ishlaydi (pleyer har ochilganda chaqiraveradi).
  void load() {
    if (_loaded) return;
    _loaded = true;
    _read();
  }

  /// Hisob almashganda qayta o'qiladi — sozlama ham hisobga
  /// tegishli.
  void reload() {
    _loaded = true;
    _read();
    notifyListeners();
  }

  void setAutoSkipIntro(bool on) {
    if (autoSkipIntro == on) return;
    autoSkipIntro = on;
    _write();
    notifyListeners();
  }

  void setAutoNextEpisode(bool on) {
    if (autoNextEpisode == on) return;
    autoNextEpisode = on;
    _write();
    notifyListeners();
  }

  void _read() {
    try {
      final rows = RustCore.instance.getCachedList(_key);
      if (rows == null || rows.isEmpty) return;
      autoSkipIntro = rows.first['auto_skip_intro'] == true;
      autoNextEpisode = rows.first['auto_next_episode'] == true;
    } catch (_) {
      // O'qib bo'lmadi — boshlang'ich qiymatlar qoladi.
    }
  }

  void _write() {
    try {
      RustCore.instance.saveListCache(_key, [
        {
          'auto_skip_intro': autoSkipIntro,
          'auto_next_episode': autoNextEpisode,
        },
      ]);
    } catch (_) {
      // Diskka yozib bo'lmadi — sozlama shu seansda baribir
      // ishlaydi.
    }
  }
}
