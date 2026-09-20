// lib/services/chat_send_thumb.dart — VIDEONING KADRINI YUBORUVCHI YASAYDI.
//
// ═══════════════════════════════════════════════════════════════
//  SAVOL VA JAVOB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "nimaga bizning ilovada huddi Telegramdagidek
// videoning birinchi kadri thumbnail qilib ko'rsatilmayapti?"
//
// Javob: chunki avval TESKARI yo'ldan borilgan edi — kadr
// KO'RUVCHI telefonda, UZOQDAGI fayldan, tarmoq orqali
// ajratilardi. Har bir ko'ruvchi, har safar. Sekin tarmoqda u
// ulgurmasdi, ijroga ham xalaqit berardi.
//
// ═══════════════════════════════════════════════════════════════
//  TELEGRAM QANDAY QILADI (VA ENDI BIZ HAM)
// ═══════════════════════════════════════════════════════════════
//
// Kadrni QABUL QILUVCHI emas, YUBORUVCHI yasaydi:
//
//   1. Video tanlandi — fayl YUBORUVCHINING telefonida turibdi.
//      Undan kadr ajratish MAHALLIY ish: tarmoq kerak emas,
//      bir necha yuz millisekund oladi.
//   2. Kichik JPEG (~10-30 KB) video bilan BIRGA yuklanadi.
//   3. Xabarda uning nomi ketadi (`media_thumb`).
//   4. Qabul qiluvchi TAYYOR rasmni ko'rsatadi — hech narsa
//      hisoblamaydi, hech qayerdan video yuklamaydi.
//
// ── NEGA BU YAXSHIROQ ───────────────────────────────────────
//
//   * ko'ruvchida NOL qo'shimcha ish — ijroga xalaqit bermaydi;
//   * kadr BIR MARTA yasaladi, har ko'rgan odam uchun emas;
//   * ~15 KB rasm yuklanadi, yuzlab kilobayt MP4 emas — sekin
//     tarmoqda ham darhol chiqadi;
//   * Rust yadrosi, sun'iy mini-MP4, kadr xotirasi — hech biri
//     kerak emas.
//
// ── CHEKLOVI ────────────────────────────────────────────────
//
// Faqat YANGI yuborilgan videolarda ishlaydi: eski xabarlarda
// kadr fayli yo'q va ular avvalgidek qora puffak bo'lib qoladi.
// Ularni to'ldirish yana o'sha eski, qiyin yo'lni talab qilardi.

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ChatSendThumb {
  const ChatSendThumb._();

  /// Kadr ajratuvchi bilan aloqa kanali (`MainActivity.kt`).
  static const MethodChannel _channel = MethodChannel('aru/thumb');

  /// Kadr qaysi lahzadan olinadi.
  ///
  /// TALAB (foydalanuvchi): "1-chi soniyada qora rang bo'lishi
  /// mumkin, shuning uchun 2-chi sonidagi kadr thumbnail qilib
  /// qo'yilgani yaxshi".
  ///
  /// Video 2 soniyadan qisqa bo'lsa tizim so'ralgan lahzani
  /// faylning oxiriga qisqartiradi (`MainActivity.grabFrame`).
  static const int atMs = 2000;

  /// MAHALLIY videodan kadr oladi va JPEG qaytaradi.
  ///
  /// Hech qachon xato tashlamaydi: kadr chiqmasa `null` va video
  /// shunchaki kadrsiz yuboriladi — yuborish HECH QACHON
  /// to'xtamaydi. Kadr — qulaylik, xabarning o'zi emas.
  ///
  /// Muddat qisqa (8 soniya): bu MAHALLIY ish, tarmoq kutilmaydi.
  /// Cho'zilsa — demak fayl g'alati, kutib o'tirishning ma'nosi
  /// yo'q.
  static Future<Uint8List?> fromFile(String path) async {
    if (path.isEmpty) return null;
    try {
      final data = await _channel.invokeMethod<Uint8List>('grab', {
        'url': path,
        'atMs': atMs,
        // Puffak eni ~220 px — 640 px yetarlidan ortiq, lekin
        // zichligi yuqori ekranlarda rasm mayin ko'rinadi.
        'maxWidth': 640,
        'quality': 72,
      }).timeout(const Duration(seconds: 8));
      if (data == null || data.isEmpty) return null;
      return data;
    } catch (e) {
      if (kDebugMode) debugPrint('ChatSendThumb: kadr olinmadi — $e');
      return null;
    }
  }
}
