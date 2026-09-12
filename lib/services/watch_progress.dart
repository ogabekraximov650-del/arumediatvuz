// lib/services/watch_progress.dart
//
// ── QAYERDA TO'XTAGANINGIZNI ESLAB QOLADI ───────────────────────
//
// Qismni qayta ochganda video boshidan emas, siz to'xtagan joydan
// davom etadi (YouTube va boshqa yirik pleyerlar shunday ishlaydi).
//
// ── QANDAY SAQLANADI ───────────────────────────────────────────
//
// Barcha nuqtalar BITTA kichik JSON ro'yxatda, Rust yadrosining
// kesh omboriga yoziladi (`watch_positions`). Har bir yozuv atigi
// ikkita maydondan iborat, ya'ni 300 ta qism uchun ham fayl bir
// necha o'nlab kilobayt bo'ladi.
//
// ── NIMA SAQLANMAYDI ───────────────────────────────────────────
//
//   * boshidagi qisqa oraliq — foydalanuvchi videoni endi ochgan,
//     "davom ettirish" mantiqsiz;
//   * oxiridagi qisqa oraliq — qism ko'rib bo'lingan, keyingi safar
//     boshidan boshlangani to'g'ri.
//
// ── CHEGARALAR QISM UZUNLIGIGA QARAB ───────────────────────────
//
// TOPILGAN XATO (foydalanuvchi ko'rgan): chegaralar QAT'IY 15 va
// 30 soniya edi. 17 soniyalik qismda esa bu ikkovi butun qismni
// qoplab olardi — ya'ni QISQA QISM HECH QACHON eslab qolinmasdi va
// har safar boshidan ochilardi.
//
// Endi chegara qism uzunligining 10% i (lekin ko'pi bilan 15 / 30
// soniya): uzun qismlarda hech narsa o'zgarmaydi, qisqa qismlar
// esa to'g'ri ishlaydi.
//
// Yozish TEZLIKKA ta'sir qilmaydi: nuqta HAR SONIYA, faqat
// O'ZGARGAN bo'lsa saqlanadi va faqat telefon xotirasiga yoziladi
// (serverga umuman yuborilmaydi).

import 'rust_bridge.dart';

class WatchProgress {
  WatchProgress._();
  static final WatchProgress instance = WatchProgress._();

  static const String _key = 'watch_positions';

  /// Eng ko'pi shuncha qism eslab qolinadi (eng eskisi tushib
  /// qoladi) — fayl cheksiz o'sib ketmasligi uchun.
  static const int _maxEntries = 300;

  /// Boshidagi shu vaqt ichida to'xtatilsa — eslab qolinmaydi.
  /// Qisqa qismlarda uzunlikning 10% iga tushadi.
  static const Duration _maxMinPosition = Duration(seconds: 15);

  /// Oxiriga shuncha qolganda — qism ko'rib bo'lingan hisoblanadi.
  /// Bu ham qisqa qismlarda 10% ga tushadi.
  static const Duration _maxEndMargin = Duration(seconds: 30);

  /// Qisqa qismlar uchun chegara: uzunlikning shuncha ulushi.
  static const double _shortShare = 0.10;

  /// Shu qism uchun "hali boshida" chegarasi.
  static Duration minPositionFor(Duration duration) {
    final share = duration * _shortShare;
    return share < _maxMinPosition ? share : _maxMinPosition;
  }

  /// Shu qism uchun "allaqachon oxirida" chegarasi.
  static Duration endMarginFor(Duration duration) {
    final share = duration * _shortShare;
    return share < _maxEndMargin ? share : _maxEndMargin;
  }

  /// url -> millisekund. Xotirada saqlanadi, diskka esa siyrak
  /// yoziladi.
  final Map<String, int> _positions = {};
  bool _loaded = false;
  bool _dirty = false;

  /// Diskdagi ro'yxatni bir marta o'qiydi.
  void ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      final rows = RustCore.instance.getCachedList(_key);
      if (rows == null) return;
      for (final r in rows) {
        final u = r['u'];
        final ms = r['ms'];
        if (u is String && u.isNotEmpty && ms is num && ms > 0) {
          _positions[u] = ms.toInt();
        }
      }
    } catch (_) {
      // O'qib bo'lmadi — hech narsa yo'qolmaydi, shunchaki
      // "davom ettirish" ishlamaydi.
    }
  }

  /// Shu video uchun saqlangan nuqta (yo'q bo'lsa `null`).
  Duration? positionOf(String url) {
    if (url.isEmpty) return null;
    ensureLoaded();
    final ms = _positions[url];
    if (ms == null || ms <= 0) return null;
    return Duration(milliseconds: ms);
  }

  /// Nuqtani eslab qoladi (yoki qism ko'rib bo'lingan bo'lsa —
  /// o'chiradi).
  void save(String url, Duration position, Duration duration) {
    if (url.isEmpty || duration <= Duration.zero) return;
    ensureLoaded();
    final atEnd = duration - position <= endMarginFor(duration);
    if (position < minPositionFor(duration) || atEnd) {
      if (_positions.remove(url) != null) _dirty = true;
      return;
    }
    final ms = position.inMilliseconds;
    final old = _positions[url];
    // 900 ms dan kam o'zgarish — yozishga arzimaydi (chaqiruv
    // sekundiga bir marta keladi).
    if (old != null && (old - ms).abs() < 900) return;
    _positions[url] = ms;
    _dirty = true;
    // ── DARHOL DISKKA ─────────────────────────────────────────
    // TALAB (foydalanuvchi): "har soniyada diskda yangilansin,
    // hech qanday 10 soniya farq bo'lmasin". Yozuv kichik
    // (bir necha kilobayt JSON) va telefon xotirasiga boradi —
    // serverga UMUMAN yuborilmaydi.
    flush();
  }

  /// Hisob almashdi — ro'yxat YANGI papkadan qaytadan o'qiladi.
  ///
  /// Hech narsa o'chirilmaydi: eski hisobning fayli o'z papkasida
  /// turaveradi va o'sha hisobga qaytilsa yana o'qiladi.
  void reload() {
    _positions.clear();
    _dirty = false;
    _loaded = false;
    ensureLoaded();
  }

  /// Video o'chirilganda uning nuqtasi ham kerak emas.
  void forget(String url) {
    ensureLoaded();
    if (_positions.remove(url) != null) {
      _dirty = true;
      flush();
    }
  }

  /// O'zgarishlarni diskka yozadi (o'zgarish bo'lmasa — hech narsa
  /// qilmaydi).
  void flush() {
    if (!_dirty) return;
    _dirty = false;
    try {
      final rows = <Map<String, dynamic>>[];
      for (final e in _positions.entries) {
        rows.add({'u': e.key, 'ms': e.value});
      }
      // Ro'yxat juda uzayib ketmasin.
      final trimmed =
          rows.length > _maxEntries ? rows.sublist(rows.length - _maxEntries) : rows;
      RustCore.instance.saveListCache(_key, trimmed);
    } catch (_) {}
  }
}
