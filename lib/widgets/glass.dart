// widgets/glass.dart
// Blur yo'q — faqat tekis rang + juda xira ramka.
// GPU yuki 0 ga yaqin — istalgan telefondan 60fps+.

import 'package:flutter/material.dart';

// ══════════════════════════════════════════════════════════════
//  ILOVA PALITRASI — BITTA JOYDA
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "ilova uisiga tegmaysan, faqat rangini
// va chizilish uslubini shu rasmdagidek qilasan".
//
// Rasmlardagi uslub piksel bo'yicha o'lchab olindi:
//
//   fon      #0A0A0C — NEYTRAL qora (ko'kimtir emas);
//   karta    #151517 — fondan sal ochroq, ramkasiz;
//   urg'u    apelsin — butun ilovada BITTA urg'u rangi;
//   ikonka   apelsin tusli qora kvadratcha, ichida apelsin belgi.
//
// ── QOIDA: RANG SHU YERDAN OLINADI ────────────────────────────
//
// Ekranlarda `Color(0x...)` yozilmaydi. Sabab oddiy: ilgari 75 ta
// qo'lda yozilgan rang bor edi va palitra almashtirilganda
// ularning yarmi eski ko'kimtir-pushti holida qolib ketardi.
// Yangi rang kerak bo'lsa — SHU YERGA qo'shiladi.
//
// ── NEGA URG'U BITTA ──────────────────────────────────────────
//
// Ilgari uchta urg'u bor edi (pushti, binafsha, moviy) va ular
// ekrandan ekranga almashardi. Rasmdagi ilovada esa bitta apelsin
// — shu sabab `accent2` endi apelsinning OCHROQ tusi (gradient
// juftligi), `accent3` esa oltin (reyting yulduzi, yosh belgisi).
class AppColors {
  // ── Yuzalar ────────────────────────────────────────────────
  /// Ekran foni.
  static const bg = Color(0xFF0A0A0C);

  /// Fondan sal ajralib turadigan yuza (panel, pastki qatlam).
  static const surface = Color(0xFF101012);

  /// Asosiy karta va ro'yxat qatori.
  static const card = Color(0xFF151517);

  /// Karta ICHIDAGI qism — yana bir pog'ona.
  static const cardAlt = Color(0xFF1B1B1E);

  // ── Urg'u ──────────────────────────────────────────────────
  /// Asosiy urg'u — apelsin. Faol tugma, faol menyu, belgilar.
  static const accent = Color(0xFFC2410C);

  /// Gradient juftligi — o'sha apelsinning ochroq tusi.
  static const accent2 = Color(0xFFE2620F);

  /// Oltin — reyting yulduzi, yosh belgisi, ogohlantirish.
  static const accent3 = Color(0xFFFFC93C);

  /// Ikonka kvadratchasining foni — apelsin tusli qora.
  static const accentTint = Color(0xFF281914);

  /// Urg'u ustidagi matn/belgi rangi.
  static const onAccent = Color(0xFFFFFFFF);

  // ── Ramka ──────────────────────────────────────────────────
  //
  // Rasmdagi kartalarda ramka KO'RINMAYDI, lekin butunlay olib
  // tashlansa qorada qora chegara yo'qoladi — shu sabab juda
  // xira oq qoldirildi.
  static const border = Color(0x0FFFFFFF);
  static const borderBright = Color(0x1AFFFFFF);

  // ── Matn ───────────────────────────────────────────────────
  /// Asosiy matn.
  static const text = Color(0xFFF2F2F3);

  /// Ikkilamchi matn (izoh, sana, bo'lim sarlavhasi).
  static const textDim = Color(0xFF9A9AA0);

  /// Eng xira matn (o'chirilgan holat).
  static const textFaint = Color(0xFF6B6B70);

  // ── Holat ranglari ─────────────────────────────────────────
  //
  // Bular URG'U EMAS — HOLAT bildiradi va rasmda ham o'z rangida
  // turadi (yashil "CHIQDI", oltin "15+"). Shu sabab apelsinga
  // qo'shilmaydi.
  /// Muvaffaqiyat, "chiqdi", faol seans.
  static const success = Color(0xFF4ADE80);

  /// Ogohlantirish, oltin belgilar.
  static const gold = Color(0xFFFFC93C);

  /// Xato, o'chirish, "18+".
  static const danger = Color(0xFFE5484D);

  /// Telegram — BREND rangi, o'zgarmaydi.
  static const telegram = Color(0xFF229ED9);

  /// Telegram gradientining ochroq uchi.
  static const telegramLight = Color(0xFF2AABEE);
}

// ══════════════════════════════════════════════════════════════
//  KARTA — TEKIS, SOYASIZ
// ══════════════════════════════════════════════════════════════
//
// ── NEGA SOYA OLIB TASHLANDI ─────────────────────────────────
//
// Ikki sabab, ikkovi ham foydalanuvchi talabidan:
//
// 1) KO'RINISH. Rasmdagi kartalarda rangli yog'du yo'q — ular
//    shunchaki fondan sal ochroq to'rtburchak. Ilgari bu yerda
//    har bir kartaga binafsha `BoxShadow` (blurRadius: 20)
//    qo'yilardi.
//
// 2) TEZLIK. `BoxShadow` — bu har bir karta uchun ALOHIDA blur
//    o'tishi. Ro'yxatda 20 ta qator ko'rinib tursa, GPU har
//    kadrda 20 marta blur chizadi. Foydalanuvchi buni "ro'yxat
//    qotib-qotib suriladi" deb ko'radi.
//
// Soya baribir kerak bo'lgan joy uchun `shadows` parametri
// qolgan — lekin BOSHLANG'ICH holat endi soyasiz.

class Glass extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double blur; // saqlab qolindi — boshqa fayllar uzadi, ignore qilinadi
  final double tint;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final List<BoxShadow>? shadows;

  const Glass({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.blur = 0,
    this.tint = 0.12,
    this.padding,
    this.color,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    // ── KESISH: `ClipRRect` ────────────────────────────────
    //
    // `Container(clipBehavior: ...)` ham kesadi, lekin u ichkarida
    // UMUMIY `ClipPath` ga aylanadi. `ClipRRect` esa dvigatelning
    // TEZ yo'liga tushadi (yumaloq to'rtburchak alohida
    // qo'llab-quvvatlanadi), shu sabab aynan shu qoldirildi.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: color ?? AppColors.card,
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: shadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child:
            padding != null ? Padding(padding: padding!, child: child) : child,
      ),
    );
  }
}

// ── GlassLite (ro'yxat elementlari uchun — yengil) ───────────
class GlassLite extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double tint;
  final EdgeInsetsGeometry? padding;

  const GlassLite({
    super.key,
    required this.child,
    this.borderRadius = 18,
    this.tint = 0.10,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: AppColors.cardAlt,
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child:
            padding != null ? Padding(padding: padding!, child: child) : child,
      ),
    );
  }
}

// ── Accent card (urg'u ramkasi bilan) ─────────────────────────
//
// Rangli yog'du o'rniga — apelsin RAMKA. Ko'rinishi rasmdagidek
// tiniq, GPU uchun esa blur o'tishi yo'q.
class AccentCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final Color accentColor;
  final EdgeInsetsGeometry? padding;

  const AccentCard({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.accentColor = AppColors.accent,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: AppColors.card,
        border:
            Border.all(color: accentColor.withValues(alpha: 0.35), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child:
            padding != null ? Padding(padding: padding!, child: child) : child,
      ),
    );
  }
}

// ── Tappable (spring scale animatsiya) ────────────────────────
class GlassTappable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const GlassTappable({super.key, required this.child, required this.onTap});

  @override
  State<GlassTappable> createState() => _GlassTappableState();
}

class _GlassTappableState extends State<GlassTappable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
    lowerBound: 0.0,
    upperBound: 0.05,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) =>
            Transform.scale(scale: 1 - _ctrl.value, child: child),
        child: widget.child,
      ),
    );
  }
}
