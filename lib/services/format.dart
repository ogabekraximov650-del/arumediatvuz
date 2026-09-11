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
