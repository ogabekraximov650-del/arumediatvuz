// lib/services/gif_service.dart — IZOHLARGA GIF.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "izohga GIF yuborish tizimini ulab bera olasanmi,
// huddi Instagramdagidek" va keyin "boshlanishiga test qilib
// ko'rish uchun 3 ta apidan ham barcha kategoriyalar va
// reaksiyalarni ula va GIF yuborishda qaysi apidan foydalanishni
// tanlaydigan qilib yasab ber — o'zim uchchalasini ham test qilib
// ko'raman va qaysi biri to'g'ri kelsa faqat shuni qilaman".
//
// ── UCHALASI SINAB KO'RILDI ─────────────────────────────────
//
// Quyidagi ma'lumot taxmin emas: har bir manzilga haqiqiy so'rov
// yuborilib tekshirilgan.
//
//   NEKOS.BEST   63 ta reaksiya, GIF. `amount` bor — bitta
//                so'rovda bir nechta GIF keladi, ya'ni tanlash
//                oynasi bitta so'rov bilan to'ladi. O'lchamlari
//                ham keladi (joy oldindan ajratiladi, ro'yxat
//                sakramaydi) va anime nomi ham.
//                RASMIY QOIDASI: to'liq SFW — personajlar hatto
//                cho'milish kostyumi yoki ichki kiyimda ham
//                uchramaydi. Yosh chegarasi bor ilova uchun
//                aynan shu kerak.
//                MUHIM: `User-Agent` sarlavhasi SHART, usiz
//                server so'rovni bloklaydi (sinab topilgan).
//
//   OTAKUGIFS    70 ta reaksiya, GIF. `webp` formati ham bor —
//                u GIF'dan bir necha barobar yengil, ya'ni
//                trafikni tejaydi. Kamchiligi: `amount`
//                ishlamaydi, har GIF uchun alohida so'rov
//                kerak (oyna sekinroq to'ladi).
//
//   NEKOSAPI     GIF EMAS — bu rasm bazasi (webp, harakatsiz).
//                Teglari reaksiya emas, tavsif: `catgirl`,
//                `school_uniform`, `sword`...
//                Ro'yxatdagi teglar sinab ko'rilgan — javob
//                bermaganlari olib tashlangan.
//
//                REYTING TANLANADI (foydalanuvchi talabi:
//                "GIF yuborishda yosh chegarasi bo'lmasin,
//                barchasiga ruxsat ber — sinchiklab tekshirib
//                ko'raman"). Odatiy qiymat baribir `safe`:
//                oyna ochilganda eng toza tarkib chiqadi,
//                qolganini sinovchi O'ZI tanlaydi.
//
//                ⚠️ Ilovada YOSH CHEGARASI bor. Sinov
//                tugagach reytingni `safe` ga qaytarish yoki
//                tanlash qatorini butunlay olib tashlash
//                kerak — aks holda izohlarga nomaqbul rasm
//                tushishi mumkin.
//
// ── XAVFSIZLIK SERVERDA ─────────────────────────────────────
//
// Tanlangan manzil serverga yuboriladi va u yerda TEKSHIRILADI:
// faqat shu uchta xizmatning manzili qabul qilinadi
// (`clean_gif_url`). Ya'ni o'zgartirilgan ilova bilan begona
// (masalan nomaqbul) rasmni izohga qo'yib bo'lmaydi.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Qaysi xizmatdan GIF olinadi.
enum GifSource {
  nekosBest('nekos.best', 'GIF · 63 reaksiya'),
  otakuGifs('otakugifs', 'GIF · 70 reaksiya'),
  nekosApi('nekosapi', 'Rasm · teglar');

  /// Tanlash tugmasidagi yozuv.
  final String label;

  /// Tugma ostidagi kichik izoh.
  final String hint;

  const GifSource(this.label, this.hint);
}

/// Bitta topilgan GIF (yoki rasm).
@immutable
class GifItem {
  final String url;

  /// Qaysi animedan (faqat nekos.best beradi, bo'lsa).
  final String animeName;

  /// Oldindan ma'lum nisbat (eni/bo'yi). 0 — noma'lum.
  ///
  /// Bu bo'lsa ro'yxat rasm yuklanishini kutmasdan joy ajratadi
  /// va yuklanganda sakramaydi.
  final double ratio;

  const GifItem({
    required this.url,
    this.animeName = '',
    this.ratio = 0,
  });
}

class GifService {
  const GifService._();

  /// So'rovlarga qo'yiladigan sarlavha.
  ///
  /// nekos.best `User-Agent` bo'lmasa so'rovni BLOKLAYDI — bu
  /// sinab topilgan, taxmin emas.
  static const _headers = {'User-Agent': 'AniRaxUz/1.0'};

  static const _timeout = Duration(seconds: 20);

  // ── KATEGORIYALAR ──────────────────────────────────────────
  //
  // Ro'yxatlar ilovada TURADI, serverdan so'ralmaydi: ular deyarli
  // o'zgarmaydi va oyna ochilganda qo'shimcha so'rov kutishning
  // ma'nosi yo'q. Uchalasi ham haqiqiy javobdan olingan.

  /// nekos.best — 63 ta reaksiya (`/api/v2/endpoints` javobidan).
  static const nekosBestCategories = <String>[
    'hug', 'kiss', 'pat', 'cuddle', 'handhold', 'peck', 'blowkiss',
    'happy', 'smile', 'laugh', 'blush', 'smug', 'wink', 'teehee',
    'cry', 'pout', 'bored', 'confused', 'shocked', 'think', 'nod',
    'nope', 'shrug', 'facepalm', 'stare', 'lurk', 'yawn', 'sleep',
    'dance', 'clap', 'highfive', 'handshake', 'salute', 'thumbsup',
    'wave', 'poke', 'tickle', 'bite', 'bonk', 'punch', 'kick',
    'slap', 'shoot', 'yeet', 'tableflip', 'baka', 'angry', 'bleh',
    'nom', 'feed', 'sip', 'run', 'spin', 'wag', 'carry', 'kabedon',
    'lappillow', 'neko', 'kitsune', 'waifu', 'husbando', 'nya',
    'shake',
  ];

  /// otakugifs — 70 ta reaksiya (`/gif/allreactions` javobidan).
  static const otakuGifsCategories = <String>[
    'hug', 'kiss', 'airkiss', 'cuddle', 'nuzzle', 'handhold', 'love',
    'happy', 'smile', 'laugh', 'blush', 'smug', 'wink', 'shy',
    'cry', 'sad', 'pout', 'mad', 'angrystare', 'nervous', 'scared',
    'confused', 'huh', 'shrug', 'facepalm', 'stare', 'peek',
    'sigh', 'tired', 'yawn', 'sleep', 'drool', 'sweat', 'nosebleed',
    'dance', 'celebrate', 'yay', 'clap', 'slowclap', 'cheers',
    'thumbsup', 'brofist', 'wave', 'poke', 'pat', 'tickle', 'pinch',
    'bite', 'lick', 'punch', 'slap', 'smack', 'bleh', 'nom',
    'sip', 'run', 'roll', 'sing', 'headbang', 'evillaugh', 'cool',
    'nyah', 'sneeze', 'sorry', 'stop', 'surprised', 'woah', 'yes',
    'no', 'shout',
  ];

  /// nekosapi — teglar. HAR BIRI SINAB KO'RILGAN: javob
  /// bermaganlari (`neko`, `smile`, `blush`, `long_hair`...)
  /// ro'yxatdan olib tashlangan.
  ///
  /// Bo'sh satr — "Barchasi" (tegsiz tasodifiy rasm).
  static const nekosApiTags = <String>[
    '', 'catgirl', 'kemonomimi', 'girl', 'boy', 'school_uniform',
    'dress', 'maid', 'glasses', 'sword', 'guitar', 'flowers',
    'night', 'beach', 'rain',
  ];

  /// Tanlangan xizmatning kategoriyalari.
  static List<String> categoriesOf(GifSource src) => switch (src) {
        GifSource.nekosBest => nekosBestCategories,
        GifSource.otakuGifs => otakuGifsCategories,
        GifSource.nekosApi => nekosApiTags,
      };

  /// Kategoriya nomini ekranda ko'rsatish uchun.
  static String labelOf(String category) =>
      category.isEmpty ? 'Barchasi' : category;

  // ── OLIB KELISH ────────────────────────────────────────────

  /// nekosapi reytinglari.
  ///
  /// TALAB (foydalanuvchi): "GIF yuborishda yosh chegarasi
  /// bo'lmasin, barchasiga ruxsat ber — sinchiklab tekshirib
  /// ko'raman. Agar umuman to'g'ri kelmasa o'zimiz yasaymiz".
  ///
  /// Shu sabab filtr QOTIB QOLGAN emas, tanlanadi. Birinchisi
  /// (`safe`) odatiy bo'lib qoladi: oyna ochilganda eng toza
  /// tarkib chiqadi.
  static const nekosApiRatings = <String>[
    'safe', 'suggestive', 'borderline', 'explicit',
  ];

  /// Tanlangan xizmatdan `count` ta GIF (yoki rasm) oladi.
  ///
  /// `rating` faqat nekosapi uchun ma'noli.
  ///
  /// Xato bo'lsa BO'SH ro'yxat qaytadi — oyna "topilmadi" deb
  /// yozadi va ilova yiqilmaydi.
  static Future<List<GifItem>> fetch(
    GifSource src,
    String category, {
    int count = 12,
    String rating = 'safe',
  }) async {
    try {
      return switch (src) {
        GifSource.nekosBest => await _nekosBest(category, count),
        GifSource.otakuGifs => await _otakuGifs(category, count),
        GifSource.nekosApi => await _nekosApi(category, count, rating),
      };
    } catch (_) {
      return const [];
    }
  }

  /// nekos.best — BITTA so'rovda `count` ta GIF.
  static Future<List<GifItem>> _nekosBest(String cat, int count) async {
    final r = await http
        .get(
          Uri.parse('https://nekos.best/api/v2/$cat?amount=$count'),
          headers: _headers,
        )
        .timeout(_timeout);
    if (r.statusCode != 200) return const [];
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final rows = ((j['results'] as List?) ?? []).cast<Map<String, dynamic>>();
    return rows
        .map((e) {
          final d = (e['dimensions'] as Map?)?.cast<String, dynamic>();
          final w = ((d?['width'] as num?) ?? 0).toDouble();
          final h = ((d?['height'] as num?) ?? 0).toDouble();
          return GifItem(
            url: '${e['url'] ?? ''}',
            animeName: '${e['anime_name'] ?? ''}',
            ratio: (w > 0 && h > 0) ? w / h : 0,
          );
        })
        .where((e) => e.url.isNotEmpty)
        .toList();
  }

  /// otakugifs — har GIF uchun ALOHIDA so'rov.
  ///
  /// `amount` parametri qabul qilinmaydi (sinab ko'rilgan), shu
  /// sabab so'rovlar BARAVARIGA yuboriladi — birin-ketin
  /// yuborilsa oyna bir necha soniya to'lardi.
  ///
  /// Format `webp`: GIF'dan bir necha barobar yengil, ya'ni
  /// trafik tejaladi (ilovada trafik hisobi bor).
  static Future<List<GifItem>> _otakuGifs(String cat, int count) async {
    final calls = List.generate(count, (_) async {
      final r = await http
          .get(
            Uri.parse(
                'https://api.otakugifs.xyz/gif?reaction=$cat&format=webp'),
            headers: _headers,
          )
          .timeout(_timeout);
      if (r.statusCode != 200) return '';
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return '${j['url'] ?? ''}';
    });
    final urls = await Future.wait(calls);
    // Tasodifiy tanlangani uchun bir xil GIF ikki marta kelishi
    // mumkin — takrorlari olib tashlanadi.
    final seen = <String>{};
    return urls
        .where((u) => u.isNotEmpty && seen.add(u))
        .map((u) => GifItem(url: u))
        .toList();
  }

  /// nekosapi — teg bo'yicha rasm (GIF emas).
  ///
  /// Reyting TANLANADI (foydalanuvchi talabi — yuqoridagi
  /// izohga qarang). Bo'sh berilsa server o'zi hal qiladi.
  static Future<List<GifItem>> _nekosApi(
      String tag, int count, String rating) async {
    final q = StringBuffer('limit=$count');
    if (rating.isNotEmpty) q.write('&rating=$rating');
    if (tag.isNotEmpty) q.write('&tags=$tag');
    final r = await http
        .get(
          Uri.parse('https://api.nekosapi.com/v4/images/random?$q'),
          headers: _headers,
        )
        .timeout(_timeout);
    if (r.statusCode != 200) return const [];
    final rows = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    return rows
        .map((e) => GifItem(url: '${e['url'] ?? ''}'))
        .where((e) => e.url.isNotEmpty)
        .toList();
  }
}
