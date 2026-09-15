// lib/services/storage_janitor.dart — ILOVA HAJMI O'SIB KETMASIN.
//
// ═══════════════════════════════════════════════════════════════
//  TOPILGAN XATO (foydalanuvchi: "ilova hajmi juda tez ko'tarilib
//  ketyapti, xuddi keraksiz fayllarni yuklab olayotgandek")
// ═══════════════════════════════════════════════════════════════
//
// Sabab yuklab olingan videolar EMAS edi — fayl TANLASH edi.
//
// `image_picker` galereyadan tanlangan faylni ILOVANING O'Z
// vaqtinchalik papkasiga (`getTemporaryDirectory`, Android'da
// `cacheDir`) NUSXALAYDI va o'sha nusxani beradi. Ya'ni admin
// panelidan 300 MB lik qism yuklansa, telefonda YANA 300 MB
// paydo bo'ladi — va u hech qachon o'chmasdi. Uch sifat (480p,
// 720p, 1080p) bilan bitta qism ~1 GB joy egallardi.
//
// Xuddi shu narsa rasm tanlashda ham bo'ladi (anime posteri,
// bo'lim posteri, profil rasmi) — faqat kichikroq hajmda.
//
// ── YECHIM: IKKI QATLAM ───────────────────────────────────────
//
//   1. `dropPicked` — yuklash tugashi bilan (muvaffaqiyatli
//      bo'ldimi yoki xatomi) nusxa DARHOL o'chiriladi;
//   2. `sweep` — ilova ochilganda eski qoldiqlar tozalanadi
//      (tizim ilovani yuklash o'rtasida yopib qo'ygan bo'lsa).
//
// Ikkinchi qatlam kerak, chunki birinchisiga har doim ham
// yetib borilmaydi: yuklash paytida ilova o'ldirilishi mumkin.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class StorageJanitor {
  const StorageJanitor._();

  /// Shu muddatdan eski qoldiqlar o'chiriladi. Yangilariga
  /// tegilmaydi: aynan shu daqiqada tanlangan fayl yuklanayotgan
  /// bo'lishi mumkin.
  static const Duration _staleAfter = Duration(minutes: 30);

  /// Vaqtinchalik papkada TEGILMAYDIGAN nomlar.
  ///
  /// `libCachedImageData` — posterlar keshi (`cached_network_image`).
  /// U o'zini o'zi cheklaydi va uni o'chirish har safar posterlarni
  /// qaytadan yuklab olishga majbur qilardi — ya'ni trafik sarfi.
  ///
  /// `aru_images` — ilovaning O'Z posterlar keshi
  /// (`image_cache.dart`). U `libCachedImageData` ning o'rnini
  /// egalladi: odatiy keshda eng ko'pi 200 ta fayl turardi va
  /// poster undan tez chiqib ketib, qayta yuklanardi.
  static const Set<String> _keep = {
    'aru_images',
    'aru_images.db',
    'libCachedImageData',
    'libCachedImageData.db',
  };

  /// Tanlangan faylning ilova ichidagi NUSXASINI o'chiradi.
  ///
  /// Faqat ilovaning o'z vaqtinchalik papkasidagi fayl o'chiriladi
  /// — foydalanuvchining galereyasidagi ASL faylga hech qachon
  /// tegilmaydi.
  static Future<void> dropPicked(String path) async {
    if (path.isEmpty) return;
    try {
      final tmp = (await getTemporaryDirectory()).path;
      if (!path.startsWith(tmp)) return;
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      debugPrint('Tanlangan fayl nusxasi o\'chirilmadi: $e');
    }
  }

  /// Ilova ochilganda: eski qoldiqlarni tozalaydi.
  ///
  /// Kutilmaydi — `main()` da fon'ga qo'yiladi.
  static Future<void> sweep() async {
    try {
      final dir = await getTemporaryDirectory();
      if (!dir.existsSync()) return;
      final now = DateTime.now();
      var freed = 0;
      for (final e in dir.listSync()) {
        final name = e.uri.pathSegments.isEmpty
            ? ''
            : e.uri.pathSegments
                .lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (_keep.contains(name)) continue;
        try {
          final stat = e.statSync();
          if (now.difference(stat.modified) < _staleAfter) continue;
          if (e is File) {
            freed += stat.size;
            e.deleteSync();
          } else if (e is Directory) {
            e.deleteSync(recursive: true);
          }
        } catch (_) {
          // Band fayl — keyingi safar.
        }
      }
      if (freed > 0) {
        debugPrint('Vaqtinchalik fayllar tozalandi: $freed bayt');
      }
    } catch (e) {
      debugPrint('Vaqtinchalik papka tozalanmadi: $e');
    }
  }
}
