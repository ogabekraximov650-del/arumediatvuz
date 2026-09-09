import 'package:flutter/material.dart';

/// ARU logotipi — oq harflar, shaffof fon.
///
/// NEGA ASSET (rasm fayl): Telegram belgisidan farqli o'laroq
/// (`telegram_logo.dart` — u `CustomPainter` bilan chiziladi) ARU
/// harflarining konturi murakkab: A ning o'ng oyog'i R ning
/// tayanchiga, R ning qorni esa U ning tayanchiga tegib turadi.
/// Uni qo'lda qayta chizish manba (`branding/aru-geometry.js`)
/// bilan ikki xil bo'lib ketish xavfini tug'diradi — shu sabab
/// ilova aynan brend fayllaridan chiqarilgan rasmni ishlatadi.
///
/// Manba zanjiri:
///   branding/aru-foreground.svg -> branding/aru-mark.png
///   -> assets/aru-mark.png
///
/// Rasm oq bo'lgani uchun u FAQAT to'q fonda ishlatiladi (ilovaning
/// hamma joyi to'q). Kerak bo'lsa `color` bilan bo'yash mumkin.
class AruLogo extends StatelessWidget {
  /// Logotip balandligi. Kengligi nisbatga qarab o'zi hisoblanadi
  /// (asl rasm 1027x606, ya'ni eni balandligidan ~1.69 barobar).
  final double height;

  /// Boshqa rangga bo'yash kerak bo'lsa.
  final Color? color;

  const AruLogo({super.key, this.height = 28, this.color});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/aru-mark.png',
      height: height,
      // Rasm o'lchamini balandlikka moslab beramiz — kattaroq
      // rasmni ekranga siqishda Flutter uni oldindan kichraytiradi
      // va xotira behuda sarflanmaydi.
      cacheHeight: (height * MediaQuery.of(context).devicePixelRatio).round(),
      color: color,
      filterQuality: FilterQuality.medium,
      fit: BoxFit.contain,
    );
  }
}
