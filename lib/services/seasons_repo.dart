// lib/services/seasons_repo.dart — BO'LIMLAR RO'YXATI BITTA JOYDA.
//
// ═══════════════════════════════════════════════════════════════
//  NEGA ALOHIDA XIZMAT
// ═══════════════════════════════════════════════════════════════
//
// Bo'limlar ro'yxati endi IKKI sahifada kerak: Bosh sahifada va
// Katalogda. Agar ikkovi ham o'zi so'rov qilsa, ilova ochilganda
// AYNI BIR ro'yxat ikki marta so'ralardi.
//
// Shu sabab so'rov shu yerda, bitta joyda. Ikkala sahifa ham
// shu ro'yxatga obuna bo'ladi va yangilanish ikkalasida ham bir
// vaqtda ko'rinadi.
//
// ── KESH ────────────────────────────────────────────────────
//
// Ro'yxat Rust yadrosidagi diskdagi keshda yotadi — ya'ni ilova
// ochilganda ekran TARMOQNI KUTMASDAN to'ladi. Kesh eskirgan
// bo'lsa yangisi fon'da olinadi va kelgach ekran yangilanadi.
//
// Bosh sahifa ham AYNAN shu keshga yozadi (`saveAnimesCache`),
// shu sabab ikkovi bir-birining ishini takrorlamaydi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'offline_library.dart';
import 'rust_bridge.dart';

const String _apiBase = 'https://arumediatv.uzcom.workers.dev';

class SeasonsRepo extends ChangeNotifier {
  SeasonsRepo._();
  static final SeasonsRepo instance = SeasonsRepo._();

  List<Map<String, dynamic>> _items = const [];
  bool _loading = false;
  bool _offline = false;

  List<Map<String, dynamic>> get items => _items;
  bool get isLoading => _loading;
  bool get isOffline => _offline;

  /// Hech qachon ro'yxat kelmaganmi (birinchi ochilish).
  bool get isEmpty => _items.isEmpty;

  /// Diskdagi nusxani darhol ko'rsatadi, kerak bo'lsa yangisini
  /// fon'da oladi.
  Future<void> load() async {
    final cached = RustCore.instance.getCachedAnimes();
    if (cached != null && cached.isNotEmpty) {
      _items = cached;
      _loading = false;
      notifyListeners();
      // Oflayn indeksi ham ro'yxat bilan birga yangilanadi —
      // "qaysi bo'lim telefonda to'liq bor" shundan bilinadi.
      unawaited(OfflineLibrary.instance.refresh(cached));
      // Kesh yangi bo'lsa so'rov umuman ketmaydi.
      if (!RustCore.instance.isCacheFresh()) unawaited(fetch());
      return;
    }
    await fetch(showLoading: true);
  }

  /// Serverdan oladi. `showLoading` — ekranda aylana chiqsin.
  Future<void> fetch({bool showLoading = false}) async {
    if (_loading) return;
    if (showLoading) {
      _loading = true;
      notifyListeners();
    }
    try {
      final r = await http
          .get(Uri.parse('$_apiBase/api/seasons'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final data =
            (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
        RustCore.instance.saveAnimesCache(data);
        _items = data;
        _offline = false;
        unawaited(OfflineLibrary.instance.refresh(data));
      }
    } catch (_) {
      _offline = true;
    }
    _loading = false;
    notifyListeners();
  }

  /// "Yuqoriga tortish" — keshni tashlab, yangisini oladi.
  Future<void> refresh() async {
    RustCore.instance.clearCache();
    await fetch();
  }

  // ── BAZADA MAVJUD JANRLAR VA YILLAR ────────────────────────
  //
  // Filtr oynasi O'YLAB TOPILGAN ro'yxatni emas, AYNAN bazada
  // bor qiymatlarni ko'rsatishi kerak (foydalanuvchi talabi:
  // "bazada mavjud bo'lgan janrlar, yillar"). Aks holda odam
  // hech qachon natija bermaydigan janrni tanlab qolardi.

  /// Ro'yxatdagi barcha janrlar — alifbo tartibida, takrorsiz.
  List<String> get genres {
    final set = <String>{};
    for (final s in _items) {
      for (final part in '${s['janri'] ?? ''}'.split(',')) {
        final t = part.trim();
        if (t.isNotEmpty) set.add(t);
      }
    }
    final out = set.toList()..sort();
    return out;
  }

  /// Ro'yxatdagi barcha yillar — yangisidan eskisiga.
  List<String> get years {
    final set = <String>{};
    for (final s in _items) {
      final t = '${s['yili'] ?? ''}'.trim();
      if (t.isNotEmpty) set.add(t);
    }
    final out = set.toList()
      ..sort((a, b) {
        final x = int.tryParse(a) ?? 0;
        final y = int.tryParse(b) ?? 0;
        return y.compareTo(x);
      });
    return out;
  }
}

// ═══════════════════════════════════════════════════════════════
//  BITTA BO'LIMDAN RAQAM O'QISH
// ═══════════════════════════════════════════════════════════════
//
// Server qiymatlarni son ham, matn ham qilib yuborishi mumkin
// (Turso ustunlari matn bo'lib qaytishi mumkin). Shu sabab
// o'qish hamma joyda AYNAN shu funksiyalar orqali.

int seasonInt(Map<String, dynamic> s, String key) =>
    int.tryParse('${s[key] ?? 0}') ?? 0;

/// Bo'limning o'rtacha bahosi (baho berilmagan bo'lsa 0).
double seasonRating(Map<String, dynamic> s) {
  final c = seasonInt(s, 'rating_count');
  if (c <= 0) return 0;
  return seasonInt(s, 'rating_sum') / c;
}

/// Bo'limning janrlari ro'yxati.
List<String> seasonGenres(Map<String, dynamic> s) => '${s['janri'] ?? ''}'
    .split(',')
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();
