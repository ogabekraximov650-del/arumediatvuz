// lib/widgets/emoji_text.dart — EMOJI XIRA KO'RINMASIN.
//
// ═══════════════════════════════════════════════════════════════
//  TOPILGAN XATO
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "support chatga va izohlarga yuborgan emojilar
// nimagadi qoramtir bo'lib ko'rinyapti".
//
// ── SABAB ───────────────────────────────────────────────────
//
// Matn ko'p joyda YARIM SHAFFOF oq rang bilan chiziladi — bu
// ataylab qilingan: muhimlik darajasini ko'rsatadi.
//
//   izoh matni            — alpha 0.86
//   o'chirilgan izoh      — alpha 0.35
//   suhbat ro'yxatidagi
//   oxirgi xabar          — alpha 0.88 (o'qilmagan) / 0.55 (o'qilgan)
//   shikoyat matni        — alpha 0.82
//
// `TextStyle.color` esa faqat HARFLARGA tegishli deb o'ylash —
// xato. Dvigatel undan bo'yoq (Paint) yasaydi va glifni O'SHA
// bo'yoq bilan chizadi. Oddiy harf bir rangli, shu sabab unga
// alpha "xiralik" bo'lib tushadi va aynan shu kutilgan natija.
//
// EMOJI esa bir rangli emas: u RANGLI glif (Android'da
// `NotoColorEmoji`). Unga alpha qo'llanganda emojining O'ZI
// shaffof bo'lib qoladi va orqadagi QORA fon ichidan ko'rinib
// turadi. Natija — "qoramtir emoji". alpha 0.55 da bu ayniqsa
// yaqqol.
//
// Ya'ni bu na qurilma, na shrift, na Impeller muammosi: alpha
// emojiga ham tushib ketgan.
//
// ── YECHIM ──────────────────────────────────────────────────
//
// Matn ikki xil bo'lakka bo'linadi:
//
//   * HARFLAR   — berilgan uslub (alpha bilan) o'zgarmaydi;
//   * EMOJI     — alpha OLIB TASHLANADI (to'liq qoramtirmas).
//
// Shu bilan dizayn buzilmaydi (matn xiraligi o'z joyida qoladi),
// emoji esa Telegramdagidek to'liq rangda chiqadi.
//
// ── NEGA `characters` PAKETI ────────────────────────────────
//
// Emoji bitta belgi EMAS: "👨‍👩‍👧" uchta odam + ikkita ulagichdan
// (ZWJ) iborat, "👍🏽" esa barmoq + teri rangi. Ularni kod
// nuqtalari bo'yicha kesish emojini BUZADI (huddi eski
// `String.length` muammosi — `pubspec.yaml` dagi izohga qarang).
//
// `characters` paketi matnni KO'ZGA KO'RINADIGAN belgilar
// (grapheme cluster) bo'yicha ajratadi — ya'ni emoji hech qachon
// o'rtasidan kesilmaydi. Paket allaqachon bog'liqliklar ichida.

import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

/// Matnni emoji bo'laklarini TO'LIQ RANGDA qoldirib chizadi.
///
/// `style` — harflar uchun uslub (alpha bilan). Emoji o'sha
/// uslubni oladi, lekin alpha'siz.
///
/// Odatdagi `Text` ning o'rniga ishlatiladi: emoji bo'lmasa
/// natija AYNAN bir xil.
class EmojiText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const EmojiText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    final spans = emojiSpans(text, style);
    // Emoji umuman yo'q — oddiy `Text` (eng arzon yo'l).
    if (spans == null) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}

/// Matnni bo'laklarga ajratadi. Emoji topilmasa `null` — chaqiruvchi
/// o'shanda oddiy `Text` ishlatadi va hech qanday ortiqcha ish
/// bajarilmaydi.
List<TextSpan>? emojiSpans(String text, TextStyle style) {
  if (text.isEmpty) return null;

  // Emoji uchun uslub: alpha OLIB TASHLANADI, qolgani o'sha-o'sha
  // (o'lcham, qalinlik, satr balandligi).
  final emojiStyle = style.copyWith(
    color: (style.color ?? Colors.white).withValues(alpha: 1),
  );

  final out = <TextSpan>[];
  final buf = StringBuffer();
  bool? bufIsEmoji;
  var sawEmoji = false;

  void flush() {
    if (buf.isEmpty) return;
    out.add(TextSpan(
      text: buf.toString(),
      style: bufIsEmoji == true ? emojiStyle : null,
    ));
    buf.clear();
  }

  for (final ch in text.characters) {
    final isEmoji = _isEmojiCluster(ch);
    if (isEmoji) sawEmoji = true;
    if (bufIsEmoji != null && bufIsEmoji != isEmoji) flush();
    bufIsEmoji = isEmoji;
    buf.write(ch);
  }
  flush();

  return sawEmoji ? out : null;
}

/// Ko'rinadigan bitta belgi emojimi.
///
/// ── QOIDA ATAYLAB EHTIYOTKOR ────────────────────────────────
//
/// "Balki emoji" deb taxmin qilinadigan belgilar (masalan oddiy
/// o'q `→` yoki `©`) emoji hisoblanmaydi — ular matn sifatida
/// chiziladi va ularga alpha TUSHISHI KERAK. Aks holda oddiy
/// tinish belgilari qolganidan yorqinroq bo'lib ajralib turardi.
///
/// Uchta belgi bo'yicha qaror qilinadi:
///   1. birinchi kod nuqtasi emoji oralig'idami;
///   2. ichida `U+FE0F` (emoji ko'rinishini MAJBURLAYDIGAN belgi)
///      bormi — `©️`, `❤️`, `▶️` aynan shu bilan rangli bo'ladi;
///   3. bayroq belgisimi (`U+1F1E6`..`U+1F1FF` juftligi).
bool _isEmojiCluster(String cluster) {
  final runes = cluster.runes.toList();
  if (runes.isEmpty) return false;

  // 2-qoida: emoji ko'rinishi majburlangan.
  if (runes.contains(0xFE0F)) return true;

  final c = runes.first;

  // 3-qoida: bayroqlar (mintaqa harflari).
  if (c >= 0x1F1E6 && c <= 0x1F1FF) return true;

  // 1-qoida: asosiy emoji oraliqlari.
  //
  //   1F300..1FAFF — emotikonlar, imo-ishoralar, hayvonlar, ovqat,
  //                  transport, buyumlar, yangi belgilar (1FA70+);
  //   1F000..1F2FF — o'yin toshlari, kartalar, ramkali harflar;
  //   2600..27BF   — umumiy belgilar va dingbatlar (☀ ✂ ✅ ➡);
  //   2B00..2BFF   — yulduz va o'qlar (⭐ ⬆);
  //   1F900..1F9FF — 1F300..1FAFF ichida.
  if (c >= 0x1F300 && c <= 0x1FAFF) return true;
  if (c >= 0x1F000 && c <= 0x1F2FF) return true;
  if (c >= 0x2600 && c <= 0x27BF) return true;
  if (c >= 0x2B00 && c <= 0x2BFF) return true;

  return false;
}
