// lib/services/user_stats.dart — STATISTIKA OYNALARI UCHUN RO'YXAT.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "qismlar, sevimlilar, bo'limlar, baholangan,
// kommentariya statistikalari ustiga bossa o'sha statistikaga
// tegishli oyna ochilishi va barchasini ko'ra olishi kerak ...
// boshqa foydalanuvchi ko'ringan statistikani bemalol account
// egasidek ochib ko'rishi mumkin bo'lsin — bu majburiy".
//
// Ya'ni ro'yxat O'ZINIKI ham, BEGONA hisobniki ham bo'lishi
// mumkin. Shu sabab bu yerda hech qanday "yagona nusxa"
// (singleton) yo'q: har bir ochilgan oyna o'zining yuklovchisini
// yaratadi va yopilganda u yo'qoladi.
//
// ── NEGA SAHIFALAB ──────────────────────────────────────────
//
// Faol odamda mingta ko'rilgan qism bo'lishi mumkin. Hammasini
// bir yo'la tortish ham tarmoqni, ham xotirani behuda band
// qiladi. Shu sabab 40 talab keladi va ro'yxat oxiriga
// yetganda keyingisi so'raladi.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// Profildagi har bir statistika katagi.
///
/// `key` — serverdagi nom: `/api/user/:id/stats/:key` yo'lida ham,
/// "yashirilgan" ro'yxatida ham AYNAN shu ishlatiladi.
enum StatKind {
  /// Anime — YAGONA ochilmaydigan katak (foydalanuvchi talabi:
  /// "Anime statistikasini hech kim ko'ra olmaydi").
  anime('anime', 'Anime'),
  episodes('episodes', 'Qismlar'),
  seasons('seasons', 'Bo\'limlar'),
  favorites('favorites', 'Sevimlilar'),
  rated('rated', 'Baholangan'),
  comments('comments', 'Izohlar'),
  watch('watch', 'Tomosha vaqti');

  final String key;
  final String label;
  const StatKind(this.key, this.label);

  /// Ustiga bosilganda oyna ochiladimi.
  bool get openable =>
      this != StatKind.anime && this != StatKind.watch;

  static StatKind? byKey(String key) {
    for (final k in StatKind.values) {
      if (k.key == key) return k;
    }
    return null;
  }
}

/// Bitta statistika oynasining ro'yxati.
class UserStatsList extends ChangeNotifier {
  UserStatsList({required this.userId, required this.kind});

  final int userId;
  final StatKind kind;

  final List<Map<String, dynamic>> _items = [];
  int _page = 0;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  List<Map<String, dynamic>> get items => List.unmodifiable(_items);
  bool get isLoading => _loading;
  bool get hasMore => _hasMore;

  /// Bo'sh bo'lmasa — ekranda shu matn ko'rsatiladi (masalan
  /// "Bu statistika yashirilgan").
  String? get error => _error;

  /// Birinchi sahifa. Qayta chaqirilsa ro'yxat noldan yig'iladi.
  Future<void> refresh() async {
    _page = 0;
    _hasMore = true;
    _items.clear();
    _error = null;
    notifyListeners();
    await loadMore();
  }

  /// Keyingi sahifa. Ro'yxat oxiriga yetganda chaqiriladi.
  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    notifyListeners();
    try {
      final token = AuthService.instance.sessionToken;
      final r = await http.get(
        Uri.parse('$kApiBase/api/user/$userId/stats/${kind.key}?page=$_page'),
        headers: {
          if (token != null) 'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 20));

      if (r.statusCode == 403) {
        // Egasi shu statistikani yashirgan. Ro'yxat javobda UMUMAN
        // yo'q — ilovani o'zgartirish bilan ham ochib bo'lmaydi.
        _error = 'Bu statistika yashirilgan';
        _hasMore = false;
      } else if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final rows = (j['items'] as List?) ?? const [];
        _items.addAll(rows.cast<Map<String, dynamic>>());
        _hasMore = j['has_more'] == true;
        _page++;
        _error = null;
      } else {
        _error = 'Ro\'yxat kelmadi';
        _hasMore = false;
      }
    } catch (_) {
      // Internet yo'q — allaqachon kelgan qatorlar qolaveradi.
      _error = _items.isEmpty ? 'Internet yo\'q' : null;
      _hasMore = false;
    }
    _loading = false;
    notifyListeners();
  }
}
