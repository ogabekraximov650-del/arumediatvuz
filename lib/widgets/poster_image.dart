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

class PosterImage extends StatelessWidget {
  final String url;
  final BoxFit fit;

  const PosterImage({super.key, required this.url, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) return Container(color: AppColors.cardAlt);
    return CachedNetworkImage(
      cacheManager: AppImageCache.manager,
      imageUrl: url,
      fit: fit,
      placeholder: (_, __) => Container(color: AppColors.cardAlt),
      errorWidget: (_, __, ___) => Container(
        color: AppColors.cardAlt,
        child: const Center(
          child: Icon(Icons.image_not_supported_outlined,
              size: 18, color: Colors.white24),
        ),
      ),
    );
  }
}
