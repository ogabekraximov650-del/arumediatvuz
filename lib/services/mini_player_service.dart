// services/mini_player_service.dart
//
// ═══════════════════════════════════════════════════════════════
//  ILOVA ICHIDAGI SUZUVCHI PLEYER
// ═══════════════════════════════════════════════════════════════
//
// Bu — tizim PiP'i EMAS (u `pip_service.dart` da). Bu ilovaning
// O'Z kichik oynasi: pleyer yopilganda video ilova ichida, hamma
// sahifalar ustida kichik oynada davom etadi va foydalanuvchi uni
// hohlagan joyga surib qo'yadi.
//
// ── NEGA KONTROLLER BU YERDA EMAS ─────────────────────────────
//
// `VideoPlayerController` ni shu servisda saqlab, pleyer bilan
// BO'LISHISH mumkindek tuyuladi — lekin yo'q: kontroller native
// surface'ga bog'langan va u qaysi widget daraxtida bo'lsa,
// o'shanda yashaydi. Pleyer yopilganda uning surface'i ham
// yo'qoladi.
//
// Shu sabab bu yerda FAQAT ma'lumot turadi (qaysi video, qaysi
// soniyada), kichik oyna esa o'ziga YANGI kontroller ochadi va
// aynan o'sha soniyadan davom ettiradi. Foydalanuvchi uchun bu
// uzluksiz ko'rinadi.

import 'package:flutter/foundation.dart';

@immutable
class MiniPlayerData {
  /// Pleyerni qayta ochish uchun kerak (bo'lim/fasl qatori).
  final Map<String, dynamic> season;

  /// Qismning O'ZGARMAS IDsi (`epizod_db.epizod_id`).
  ///
  /// DIQQAT: bu `epizod_number` EMAS. Kattalashtirilganda pleyer
  /// aynan shu ID bo'yicha qismni topadi — raqam o'zgarsa ham
  /// to'g'ri qism ochiladi. 0 — noma'lum (pleyer o'zi tanlaydi).
  final int epizodId;

  /// Video manzili (qaysi sifat tanlangan bo'lsa — o'sha).
  final String url;

  /// Qaysi soniyada to'xtagani.
  final Duration position;

  /// Kichik oyna ostidagi yozuv.
  final String title;

  const MiniPlayerData({
    required this.season,
    required this.epizodId,
    required this.url,
    required this.position,
    required this.title,
  });

  MiniPlayerData copyWith({Duration? position}) => MiniPlayerData(
        season: season,
        epizodId: epizodId,
        url: url,
        position: position ?? this.position,
        title: title,
      );
}

class MiniPlayerService extends ChangeNotifier {
  MiniPlayerService._();
  static final instance = MiniPlayerService._();

  MiniPlayerData? _data;

  MiniPlayerData? get data => _data;

  /// Kichik oyna ochiqmi.
  ///
  /// `_data != null` bilan bir xil — alohida bayroq saqlansa
  /// ikkovi bir-biriga zid bo'lib qolishi mumkin edi.
  bool get active => _data != null;

  void activate(MiniPlayerData data) {
    _data = data;
    notifyListeners();
  }

  void deactivate() {
    if (_data == null) return;
    _data = null;
    notifyListeners();
  }

  /// Ijro davom etgani sayin soniyani yangilab turadi.
  ///
  /// ATAYLAB `notifyListeners` CHAQIRMAYDI: u sekundiga bir necha
  /// marta keladi va butun ilovani qayta chizishga majbur qilardi.
  /// Bu qiymat faqat oyna kattalashtirilganda o'qiladi.
  void updatePosition(Duration pos) {
    final d = _data;
    if (d == null) return;
    _data = d.copyWith(position: pos);
  }
}
