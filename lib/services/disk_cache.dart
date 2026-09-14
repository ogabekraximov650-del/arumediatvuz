// lib/services/disk_cache.dart — HAMMA NARSA DISKDA TURSIN.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "Turso va B2'dan kelgan barcha narsa diskda
// saqlansin, keyingi safar sekin ochilmasligi uchun. Admin
// panelidagi ma'lumotlar ham, izohlar ham — hullas hammasi diskda
// tursin, tezroq ishlashi uchun".
//
// ── QOIDA: AVVAL DISK, KEYIN TARMOQ ─────────────────────────
//
// Har bir ro'yxat shu tartibda ishlaydi:
//
//   1. ekran ochilishi bilan DISKDAGI nusxa ko'rsatiladi —
//      tarmoq umuman kutilmaydi, ekran darhol to'ladi;
//   2. nusxa eskirgan bo'lsa, fon'da yangisi olinadi;
//   3. yangisi kelgach ekran o'zi yangilanadi va disk yoziladi.
//
// Ya'ni foydalanuvchi hech qachon bo'sh ekranga qaramaydi va
// internet sekin bo'lsa ham ilova tez tuyuladi.
//
// ── NEGA ALOHIDA FAYL ───────────────────────────────────────
//
// Bu naqsh ilovada allaqachon bir necha joyda bor edi (anime
// ro'yxati, bo'lim ma'lumoti, tarix, sevimlilar), lekin HAR
// BIRIDA qaytadan yozilgan edi. Yangi ro'yxat qo'shilganda esa
// keshni qo'shish esdan chiqardi — izohlar, yozishma va admin
// ro'yxatlari aynan shu sabab keshsiz qolgan edi.
//
// Endi bitta joy: kalit, muddat va vaqt belgisi shu yerda.
//
// ── VAQT BELGISI ────────────────────────────────────────────
//
// Rust yadrosidagi ro'yxat keshi vaqtni saqlamaydi, shu sabab uni
// yozuvning O'ZIGA qo'shamiz: birinchi qator — xizmat qatori
// (`__at`), qolgani ma'lumot. Shunday qilinganda eski (vaqtsiz)
// yozuvlar ham buzilmaydi — ular shunchaki "eskirgan" deb
// hisoblanadi.

import 'package:flutter/foundation.dart';

import 'rust_bridge.dart';

class DiskCache {
  const DiskCache._();

  /// Xizmat qatorining belgisi.
  static const String _stamp = '__at';

  /// Diskdagi nusxa. Yo'q bo'lsa `null`.
  ///
  /// `maxAge` berilsa va nusxa undan eski bo'lsa ham QAYTARILADI —
  /// "eskirgan, lekin bor" nusxa bo'sh ekrandan har doim yaxshi.
  /// Eskirgani `isStale` bilan alohida bilinadi.
  static List<Map<String, dynamic>>? read(String key) {
    try {
      final rows = RustCore.instance.getCachedList(key);
      if (rows == null || rows.isEmpty) return null;
      // Birinchi qator xizmat qatori bo'lsa — tashlab ketiladi.
      if (rows.first.containsKey(_stamp)) {
        final rest = rows.sublist(1);
        return rest.isEmpty ? null : rest;
      }
      return rows;
    } catch (_) {
      return null;
    }
  }

  /// Diskdagi nusxa shu muddatdan eskirganmi.
  ///
  /// Nusxa umuman bo'lmasa ham `true` — ya'ni "yangisini ol".
  static bool isStale(String key, Duration maxAge) {
    try {
      final rows = RustCore.instance.getCachedList(key);
      if (rows == null || rows.isEmpty) return true;
      if (!rows.first.containsKey(_stamp)) return true;
      final at = (rows.first[_stamp] as num?)?.toInt() ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - at;
      return age >= maxAge.inMilliseconds;
    } catch (_) {
      return true;
    }
  }

  /// Diskka yozadi (vaqt belgisi bilan).
  static void write(String key, List<Map<String, dynamic>> rows) {
    try {
      RustCore.instance.saveListCache(key, [
        {_stamp: DateTime.now().millisecondsSinceEpoch},
        ...rows,
      ]);
    } catch (_) {
      // Disk to'lgan yoki kalit yo'q — kesh shunchaki bo'lmaydi.
      // Bu XATO emas: ilova tarmoqdan olib ishlayveradi.
    }
  }

  /// Bitta yozuv uchun qulaylik (profil, holat va hokazo).
  static Map<String, dynamic>? readOne(String key) {
    final rows = read(key);
    return (rows == null || rows.isEmpty) ? null : rows.first;
  }

  static void writeOne(String key, Map<String, dynamic> row) =>
      write(key, [row]);

  /// Kalitni tozalaydi.
  static void drop(String key) {
    try {
      RustCore.instance.saveListCache(key, const []);
    } catch (_) {}
  }
}

/// Diskdan o'qib, keyin tarmoqdan yangilaydigan ro'yxat uchun
/// umumiy asos.
///
/// Voris faqat uchta narsani aytadi: kalit, muddat va tarmoqdan
/// qanday olish. Qolganini — diskdan ko'rsatish, eskirganda
/// yangilash, xatoda eski nusxada qolish — shu yerda.
abstract class CachedListController<T> extends ChangeNotifier {
  /// Diskdagi kalit.
  String get cacheKey;

  /// Nusxa shu muddatdan keyin eskirgan hisoblanadi.
  Duration get maxAge => const Duration(minutes: 5);

  /// Bitta qatorni ob'ektga aylantiradi.
  T fromJson(Map<String, dynamic> j);

  /// Ob'ektni saqlash uchun qatorga aylantiradi.
  Map<String, dynamic> toJson(T item);

  /// Tarmoqdan oladi. Xato bo'lsa `null` qaytaring — shunda
  /// diskdagi nusxa joyida qoladi.
  Future<List<Map<String, dynamic>>?> fetchRows();

  final List<T> items = [];

  bool _loading = false;
  bool _loaded = false;
  String? _error;

  /// Ekranda aylana chiqsinmi (faqat diskda ham hech narsa yo'q
  /// bo'lsa).
  bool get isLoading => _loading && items.isEmpty;
  bool get hasData => _loaded;
  String? get error => _error;

  /// Diskdan darhol ko'rsatadi va kerak bo'lsa yangilaydi.
  Future<void> load({bool force = false}) async {
    if (_loading) return;

    // 1) DISK — tarmoq umuman kutilmaydi.
    if (!_loaded) {
      final cached = DiskCache.read(cacheKey);
      if (cached != null) {
        items
          ..clear()
          ..addAll(cached.map(fromJson));
        _loaded = true;
        notifyListeners();
      }
    }

    // 2) Yangi bo'lsa — tarmoqqa umuman chiqilmaydi.
    if (!force && _loaded && !DiskCache.isStale(cacheKey, maxAge)) return;

    _loading = true;
    if (items.isEmpty) notifyListeners();

    final rows = await fetchRows();
    if (rows != null) {
      items
        ..clear()
        ..addAll(rows.map(fromJson));
      _loaded = true;
      _error = null;
      DiskCache.write(cacheKey, rows);
    }
    _loading = false;
    notifyListeners();
  }

  /// Xatoni voris shu orqali qo'yadi.
  @protected
  void setError(String? e) => _error = e;

  /// Ro'yxat o'zgardi — diskdagi nusxa ham yangilansin.
  @protected
  void persist() => DiskCache.write(cacheKey, items.map(toJson).toList());
}
