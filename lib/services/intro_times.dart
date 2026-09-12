// lib/services/intro_times.dart — OPENING VAQTLARI.
//
// ═══════════════════════════════════════════════════════════════
//  BITTA QOIDA, IKKI JOYDA
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "intro vaqtini 5:14 va 6:44 qilib
// yoziladigan qil, soniya bilan emas".
//
// Ya'ni bazada ham (`epizod_db.intro_1 ... intro_10`), admin
// oynasida ham AYNAN o'sha matn turadi. Hech qanday o'girish
// qatlami yo'q.
//
// Pleyer esa vaqtni son sifatida solishtiradi, shu sabab matn
// qism ochilganda BIR MARTA millisekundga o'giriladi. O'girish
// qoidasi ikki joyda kerak (admin oynasi va pleyer), shu sabab u
// SHU YERDA — nusxa ko'chirilsa, ikkovi bir kun ajralib qolardi.
//
// ── QANDAY YOZUV TUSHUNILADI ──────────────────────────────────
//
//   `5:14`      -> 5 daqiqa 14 soniya
//   `05:14`     -> o'sha
//   `1:02:03`   -> 1 soat 2 daqiqa 3 soniya
//   `314`       -> 314 soniya (eski yozuvlar: ilgari bazada
//                  soniya saqlanardi)
//   bo'sh/xato  -> 0, ya'ni "belgilanmagan"
//
// Xato yozuv PLEYERNI YIQITMAYDI — oraliq shunchaki e'tiborsiz
// qoladi. Admin nima yozsa ham video ko'rish buzilmasligi kerak.

/// `epizod_db` dagi intro ustunlari soni — 5 ta juftlik.
const int kIntroSlots = 10;

/// Bitta juftlikdagi qatorlar soni (2 ustun x 5 qator).
const int kIntroRows = kIntroSlots ~/ 2;

/// Yozuvni MILLISEKUNDGA o'giradi (0 — belgilanmagan yoki xato).
int introMs(Object? raw) {
  final t = '${raw ?? ''}'.trim();
  if (t.isEmpty) return 0;
  if (!t.contains(':')) {
    // Yalang son — soniya (eski yozuvlar).
    final sec = int.tryParse(t) ?? 0;
    return sec > 0 ? sec * 1000 : 0;
  }
  final parts = t.split(':');
  if (parts.length > 3) return 0;
  var total = 0;
  for (final part in parts) {
    final v = int.tryParse(part.trim());
    if (v == null || v < 0) return 0;
    total = total * 60 + v;
  }
  return total > 0 ? total * 1000 : 0;
}

/// Bazadan kelgan qiymatni OYNAGA qo'yish uchun matn.
///
/// Odatda bu o'sha matnning o'zi (`"5:14"`). Eski yozuvlarda
/// soniya (son) turgan bo'lishi mumkin — u `5:14` ko'rinishiga
/// o'giriladi, ya'ni eski qismlar ham to'g'ri ochiladi.
String introText(Object? raw) {
  final t = '${raw ?? ''}'.trim();
  if (t.isEmpty || t == '0') return '';
  if (t.contains(':')) return t;
  final sec = int.tryParse(t);
  if (sec == null || sec <= 0) return '';
  return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
}

/// Qism qatoridan intro oraliqlari: `(boshi, oxiri)` millisekundda.
///
/// Faqat TO'G'RI juftliklar olinadi: oxiri boshidan katta bo'lishi
/// shart, aks holda juftlik to'ldirilmagan yoki xato yozilgan.
List<(int, int)> introRangesOf(Map<String, dynamic>? ep) {
  if (ep == null) return const [];
  final out = <(int, int)>[];
  for (var i = 1; i < kIntroSlots; i += 2) {
    final from = introMs(ep['intro_$i']);
    final to = introMs(ep['intro_${i + 1}']);
    if (from <= 0 || to <= from) continue;
    out.add((from, to));
  }
  return out;
}
