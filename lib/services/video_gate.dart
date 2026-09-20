// lib/services/video_gate.dart — VIDEO IJRO ETILAYOTGANDAMI?
//
// ═══════════════════════════════════════════════════════════════
//  NEGA BU FAYL BOR
// ═══════════════════════════════════════════════════════════════
//
// TOPILGAN XATO (foydalanuvchi): "chatdagi thumbnail tizimi
// ishlamadi, uyam yetmagandek endi video qotib sekin ishlayapti".
//
// Yozishmadagi kadrlarni yasash tarmoqqa chiqadi. O'sha paytda
// foydalanuvchi video ochsa, ikkalasi BITTA tor kanalni bo'lishib
// oladi va ijroga qoladigan tezlik yetmay qoladi — video qotadi.
//
// Ilova uchun muhimlik tartibi aniq: VIDEO KO'RISH — asosiy
// vazifa, kadr esa qulaylik. Shu sabab pleyer ochiq turganda
// kadr yasash BUTUNLAY to'xtaydi.
//
// ── NEGA SANAGICH (oddiy `bool` EMAS) ───────────────────────
//
// Ekranlar bir-birining ustiga ochiladi: pleyer ustidan yana
// bir media oynasi ochilishi mumkin. Oddiy `bool` bilan
// ustidagisi yopilganda bayroq o'chib ketardi-yu, pastdagi
// pleyer hamon ishlab turardi. Sanagich bunday xatoga yo'l
// qo'ymaydi: nol bo'lgandagina "hech narsa ijro etilmayapti".

import 'package:flutter/foundation.dart';

class VideoGate {
  const VideoGate._();

  static int _open = 0;

  /// Hozir biror video ekrani ochiqmi.
  static bool get busy => _open > 0;

  /// Pleyer ekrani ochildi (`initState`).
  static void enter() => _open++;

  /// Pleyer ekrani yopildi (`dispose`).
  ///
  /// Manfiyga tushmaydi: `dispose` ikki marta chaqirilsa ham
  /// hisob buzilmaydi.
  static void leave() {
    if (_open > 0) _open--;
    if (kDebugMode && _open == 0) {
      debugPrint('VideoGate: hamma pleyer yopildi');
    }
  }
}
