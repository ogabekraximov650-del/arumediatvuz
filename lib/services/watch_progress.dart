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
//   * boshidagi 15 soniya — foydalanuvchi videoni endi ochgan,
//     "davom ettirish" mantiqsiz;
//   * oxiridagi 30 soniya — qism ko'rib bo'lingan, keyingi safar
//     boshidan boshlangani to'g'ri.
//
// Yozish TEZLIKKA ta'sir qilmaydi: nuqta har 5 soniyada bir marta
// va faqat O'ZGARGAN bo'lsa saqlanadi.

import 'rust_bridge.dart';

class WatchProgress {
  WatchProgress._();
  static final WatchProgress instance = WatchProgress._();

  static const String _key = 'watch_positions';

  /// Eng ko'pi shuncha qism eslab qolinadi (eng eskisi tushib
  /// qoladi) — fayl cheksiz o'sib ketmasligi uchun.
  static const int _maxEntries = 300;

  /// Boshidagi shu vaqt ichida to'xtatilsa — eslab qolinmaydi.
  static const Duration _minPosition = Duration(seconds: 15);

  /// Oxiriga shuncha qolganda — qism ko'rib bo'lingan hisoblanadi.
  static const Duration _endMargin = Duration(seconds: 30);

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
    final atEnd = duration - position <= _endMargin;
    if (position < _minPosition || atEnd) {
      if (_positions.remove(url) != null) _dirty = true;
      return;
    }
    final ms = position.inMilliseconds;
    final old = _positions[url];
    // 3 soniyadan kam o'zgarish uchun diskka yozmaymiz.
    if (old != null && (old - ms).abs() < 3000) return;
    _positions[url] = ms;
    _dirty = true;
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
