// lib/widgets/poster_image.dart — TARMOQDAN KELADIGAN KICHIK RASM.
//
// Bo'lim posteri, avatar va shunga o'xshash joylar uchun bitta
// qator: manzil bo'sh bo'lsa ham, kelmasa ham ekranda bo'sh joy
// emas, quyuq to'rtburchak turadi.
//
// Kesh — ilovaning O'Z keshi (`image_cache.dart`), ya'ni rasm
// diskda uzoq qoladi va har ochilishda qayta yuklanmaydi.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/image_cache.dart';
import 'glass.dart';

/// Rasm XOTIRAGA shu kenglikdan kattaroq qilib ochilmaydi.
///
/// ═══════════════════════════════════════════════════════════
///  TOPILGAN MUAMMO: RO'YXAT NEGA QOTARDI
/// ═══════════════════════════════════════════════════════════
///
/// TALAB (foydalanuvchi): "uini tez va qotmasdan ishlaydigan qil".
///
/// Sabab ranglarda emas, RASMLARDA edi. Ilgari bu yerda hech
/// qanday o'lcham berilmasdi, ya'ni poster serverdagi TO'LIQ
/// o'lchamida ochilardi. Masalan 1000x1500 poster xotirada
/// 1000 x 1500 x 4 bayt = ~6 MB joy egallaydi.
///
/// To'rda bir vaqtda 8-10 ta poster ko'rinadi, surilganda esa
/// o'nlab. Ya'ni ilova o'nlab megabaytlik rasmlarni ochib,
/// ularni GPU ga yuklab, keyin ekranga 180 piksel kenglikda
/// SIQIB chizardi. Har bir yangi poster — bitta "yo'qolgan"
/// kadr; foydalanuvchi buni "sekin va qotib qoladi" deb ko'radi.
///
/// Endi rasm AYNAN ko'rinadigan o'lchamda ochiladi: 180 px lik
/// katakcha uchun ~500 px (piksel zichligi hisobga olinadi), ya'ni
/// xotira ~20 barobar kamayadi va dekodlash shuncha tezlashadi.
/// Ko'rinishida hech qanday farq yo'q — piksel zichligi baribir
/// ekrannikidan kam emas.
///
/// Yuqori chegara: juda keng joylarda ham 1440 px dan oshmaydi.
const int _kMaxDecodeWidth = 1440;

/// Rasm chiqishidagi silliq o'tish.
///
/// Paketning boshlang'ich qiymati — YARIM SONIYA. Ro'yxat
/// surilganda har bir poster shuncha vaqt "ochilib" kelardi va
/// ilova sekin ko'rinardi. 120 ms — ko'z uchun hali ham silliq,
/// lekin deyarli darhol.
const Duration _kFade = Duration(milliseconds: 120);

class PosterImage extends StatelessWidget {
  final String url;
  final BoxFit fit;

  const PosterImage({super.key, required this.url, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) return Container(color: AppColors.cardAlt);
    // Katakcha kengligi LayoutBuilder orqali olinadi: PosterImage
    // ro'yxatda ham, to'rda ham, avatar sifatida ham ishlatiladi —
    // o'lchamni har bir chaqiruvda qo'lda yozib chiqish esa bir
    // kun albatta unutilardi.
    return LayoutBuilder(
      builder: (context, box) {
        int? decodeWidth;
        if (box.hasBoundedWidth && box.maxWidth > 0) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final want = (box.maxWidth * dpr).round();
          decodeWidth = want > _kMaxDecodeWidth ? _kMaxDecodeWidth : want;
        }
        return CachedNetworkImage(
          cacheManager: AppImageCache.manager,
          imageUrl: url,
          fit: fit,
          memCacheWidth: decodeWidth,
          fadeInDuration: _kFade,
          fadeOutDuration: _kFade,
          placeholder: (_, __) => Container(color: AppColors.cardAlt),
          errorWidget: (_, __, ___) => Container(
            color: AppColors.cardAlt,
            child: const Center(
              child: Icon(Icons.image_not_supported_outlined,
                  size: 18, color: Colors.white24),
            ),
          ),
        );
      },
    );
  }
}
