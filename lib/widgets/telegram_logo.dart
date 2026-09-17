import 'package:flutter/material.dart';

import 'glass.dart';

/// TELEGRAM LOGOTIPI — sof kod bilan chiziladi.
///
/// NEGA rasm fayl emas: ilovada hech qanday `assets/` papkasi yo'q
/// va uni qo'shish `pubspec.yaml` + APK hajmi degani. Logotip esa
/// oddiy vektor shakl — uni `CustomPainter` bilan chizsak, har
/// qanday o'lchamda mutlaqo aniq (piksel bulg'anmaydi) chiqadi va
/// ilovaga bitta ham qo'shimcha bayt qo'shilmaydi.
///
/// Shakl — Telegram'ning rasmiy "qog'oz samolyot" konturi
/// (512x512 koordinata tizimida). `getBounds()` orqali avtomatik
/// markazlanadi, shu sabab hech qanday sehrli surish soni yo'q.
class TelegramGlyph extends StatelessWidget {
  final double size;
  final Color color;

  const TelegramGlyph({super.key, required this.size, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _PlanePainter(color)),
    );
  }
}

/// Ko'k doira ichidagi to'liq Telegram logotipi.
class TelegramLogo extends StatelessWidget {
  final double size;

  const TelegramLogo({super.key, this.size = 96});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.telegramLight, AppColors.telegram],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.telegram.withValues(alpha: 0.35),
            blurRadius: size * 0.28,
            spreadRadius: size * 0.02,
          ),
        ],
      ),
      child: Center(
        // Samolyot doiraning ~52% i — rasmiy nisbatga eng yaqini.
        // Ozgina o'ngga surilgan: shaklning og'irlik markazi chapda,
        // shunchaki markazga qo'yilsa ko'zga qiyshiq ko'rinadi.
        child: Padding(
          padding: EdgeInsets.only(left: size * 0.03, bottom: size * 0.02),
          child: TelegramGlyph(size: size * 0.52),
        ),
      ),
    );
  }
}

class _PlanePainter extends CustomPainter {
  final Color color;
  const _PlanePainter(this.color);

  static Path _plane() {
    return Path()
      ..moveTo(446.7, 98.6)
      ..lineTo(379.1, 417.4)
      ..cubicTo(374.0, 439.9, 360.7, 445.5, 341.8, 434.9)
      ..lineTo(238.8, 359.0)
      ..lineTo(189.1, 406.8)
      ..cubicTo(183.6, 412.3, 179.0, 416.9, 168.4, 416.9)
      ..lineTo(175.8, 312.0)
      ..lineTo(366.7, 139.5)
      ..cubicTo(375.0, 132.1, 364.9, 128.0, 353.8, 135.4)
      ..lineTo(117.8, 284.0)
      ..lineTo(16.2, 252.2)
      ..cubicTo(-5.9, 245.3, -6.3, 230.1, 20.8, 219.5)
      ..lineTo(418.2, 66.4)
      ..cubicTo(436.6, 59.5, 452.7, 70.5, 446.7, 98.6)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final path = _plane();
    final b = path.getBounds();
    if (b.width <= 0 || b.height <= 0) return;

    final scale = (size.width / b.width) < (size.height / b.height)
        ? size.width / b.width
        : size.height / b.height;

    // Shaklni markazlaymiz. Matrix4 o'rniga to'g'ridan-to'g'ri
    // kanva amallari: ular Flutter versiyalari orasida o'zgarmagan
    // va qo'shimcha obyekt yaratmaydi.
    canvas.save();
    canvas.translate(
      (size.width - b.width * scale) / 2 - b.left * scale,
      (size.height - b.height * scale) / 2 - b.top * scale,
    );
    canvas.scale(scale);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlanePainter old) => old.color != color;
}
