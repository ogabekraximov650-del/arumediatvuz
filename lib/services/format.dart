// lib/services/format.dart — RAQAMLARNI KO'RSATISH.
//
// Statistika, pleyer va tarix oynalari BIR XIL ko'rinishda raqam
// chiqarishi kerak, shu sabab hammasi shu yerda.

/// `1284512` -> `1.284.512` (uch xonadan ajratiladi).
///
/// Xona soni raqamning O'ZIGA qarab o'sadi — hech qachon
/// `000.000.000` bo'lib turmaydi (foydalanuvchi talabi).
String formatCount(num value) {
  final n = value.round();
  final neg = n < 0;
  final digits = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  return neg ? '-$buf' : buf.toString();
}

/// Trafik: baytdan odam o'qiydigan ko'rinishga.
///
/// `1288490188` -> `1,20 GB`. Bayt bilan ko'rsatish ma'nosiz —
/// hech kim `1.288.490.188` ni o'qiy olmaydi.
String formatBytes(num bytes) {
  final b = bytes.toDouble();
  if (b < 1024) return '${b.round()} B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final text = v >= 100
      ? v.toStringAsFixed(0)
      : (v >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2));
  return '${text.replaceAll('.', ',')} ${units[i]}';
}

/// Tomosha vaqti: `1:59` — FAQAT soat va daqiqa (foydalanuvchi
/// talabi). Soat qismi uch xonadan ajratiladi: `1.284:05`.
String formatHours(num ms) {
  final total = ms.round() ~/ 1000;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  return '${formatCount(hours)}:${minutes.toString().padLeft(2, '0')}';
}

/// `12:34/01/01/2026` — soat/kun/oy/yil.
///
/// Ilovadagi BARCHA sanalar shu ko'rinishda (foydalanuvchi
/// talabi) va telefonning O'Z mintaqasida ko'rsatiladi.
String formatMoment(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}/'
      '${two(d.day)}/${two(d.month)}/${d.year}';
}

/// Reyting: `07.62` — ikki xonali butun qism, ikkita kasr.
String formatRating(num value) {
  final v = value.toDouble().clamp(0, 10).toDouble();
  final text = v.toStringAsFixed(2);
  return text.length < 5 ? '0$text' : text;
}

/// Kartochkadagi kichkina belgi uchun QISQA raqam.
///
/// `formatCount` (`1.284.512`) kartochkaga sig'maydi — u yerda
/// atigi bir necha belgi joy bor. Shu sabab bu yerda qisqartma:
/// `1.284.512` -> `1,3 mln`, `12.400` -> `12,4 ming`.
///
/// Mingdan kichik son o'z holicha qoladi: `843`.
String formatCompact(num value) {
  final n = value.round();
  if (n < 1000) return '$n';
  String cut(double v) {
    // `12,0 ming` emas, `12 ming` — ortiqcha nol ko'zni charchatadi.
    final t = v.toStringAsFixed(1).replaceAll('.', ',');
    return t.endsWith(',0') ? t.substring(0, t.length - 2) : t;
  }

  if (n < 1000000) return '${cut(n / 1000)} ming';
  return '${cut(n / 1000000)} mln';
}

// ══════════════════════════════════════════════════════════════
//  VAQT
// ══════════════════════════════════════════════════════════════
//
// Bu ikkovi ilgari `comments_service.dart` da edi, lekin endi
// izohlardan tashqari shaxsiy yozishmalar, admin shikoyatlari va
// suhbatlar ro'yxati ham shu ko'rinishni ishlatadi. Ekranlar
// vaqtni BIR XIL ko'rsatishi uchun ular shu yerga — umumiy joyga
// ko'chirildi.

/// Aniq vaqt: `14:32` (bugun) yoki `12.09.2026`.
///
/// TALAB (foydalanuvchi): "izoh yozganda vaqti ham ko'rsatilsin".
/// "7 daqiqa oldin" ko'z uchun qulay, lekin aniq vaqtni bermaydi —
/// shu sabab yonida shu ham turadi.
String commentClock(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${two(d.hour)}:${two(d.minute)}';
  }
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// "3 daqiqa oldin" ko'rinishidagi vaqt.
String commentAgo(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.now().millisecondsSinceEpoch - ms;
  if (d < 60000) return 'hozir';
  final min = d ~/ 60000;
  if (min < 60) return '$min daqiqa oldin';
  final h = min ~/ 60;
  if (h < 24) return '$h soat oldin';
  final days = h ~/ 24;
  if (days < 30) return '$days kun oldin';
  final mo = days ~/ 30;
  if (mo < 12) return '$mo oy oldin';
  return '${days ~/ 365} yil oldin';
}
