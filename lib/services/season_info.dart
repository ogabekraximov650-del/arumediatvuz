// lib/services/season_info.dart — BO'LIM MA'LUMOTI, BAHO, SEVIMLILAR.
//
// Pleyerdagi "Ma'lumot" oynasi uchun BITTA so'rov:
// `GET /api/season/:anime_id/:season_id` — bo'lim qatori, ko'rishlar
// soni, tomosha vaqti, sevimlilar soni, reyting va shu odamning
// O'Z bahosi bir yo'la keladi.
//
// Baho — IMDb uslubidagi VAZNLI o'rtacha (serverda hisoblanadi):
// bitta odam 10 qo'yishi bilan reyting 10.00 bo'lib qolmaydi.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'video_cache_server.dart';

class SeasonInfo {
  final Map<String, dynamic> season;

  /// Vaznli reyting (0..10).
  final double rating;

  /// Shu foydalanuvchi qo'ygan baho (0 — qo'ymagan).
  final int myStars;

  /// Sevimlilardami.
  final bool isFav;

  const SeasonInfo({
    required this.season,
    required this.rating,
    required this.myStars,
    required this.isFav,
  });

  int _int(String k) => (season[k] as num?)?.toInt() ?? 0;

  int get views => _int('views_total');
  int get watchMs => _int('watch_ms_total');
  int get favCount => _int('fav_count');
  int get ratingCount => _int('rating_count');
  int get epizodCount => _int('epizod_count');
  int get bolimId => _int('bolim_id');
  int get createdAt => _int('created_at');

  SeasonInfo copyWith({double? rating, int? myStars, bool? isFav, int? favCount}) {
    final s = Map<String, dynamic>.from(season);
    if (favCount != null) s['fav_count'] = favCount;
    return SeasonInfo(
      season: s,
      rating: rating ?? this.rating,
      myStars: myStars ?? this.myStars,
      isFav: isFav ?? this.isFav,
    );
  }

  factory SeasonInfo.fromJson(Map<String, dynamic> j) => SeasonInfo(
        season: (j['season'] as Map?)?.cast<String, dynamic>() ?? {},
        rating: ((j['rating'] as num?) ?? 0).toDouble(),
        myStars: ((j['my_stars'] as num?) ?? 0).toInt(),
        isFav: j['is_fav'] == true,
      );
}

class SeasonService {
  const SeasonService._();

  static Map<String, String> _headers({bool json = false}) {
    final token = AuthService.instance.sessionToken;
    return {
      if (token != null) 'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// Bo'lim ma'lumoti. Xato bo'lsa `null` — ekran baribir
  /// ochilaveradi, shunchaki raqamlar ko'rinmaydi.
  static Future<SeasonInfo?> load(int animeId, int seasonId) async {
    try {
      final r = await http
          .get(
            Uri.parse('$kApiBase/api/season/$animeId/$seasonId'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      return SeasonInfo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Baho qo'yish (1..10). Javobda yangi reyting keladi.
  static Future<({double rating, int count})?> rate(
      int animeId, int seasonId, int stars) async {
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/rating'),
            headers: _headers(json: true),
            body: jsonEncode({
              'anime_id': animeId,
              'season_id': seasonId,
              'stars': stars,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return (
        rating: ((j['rating'] as num?) ?? 0).toDouble(),
        count: ((j['rating_count'] as num?) ?? 0).toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Sevimlilarga qo'shish / olib tashlash.
  static Future<int?> setFavorite(int animeId, int seasonId, bool on) async {
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/favorite'),
            headers: _headers(json: true),
            body: jsonEncode({
              'anime_id': animeId,
              'season_id': seasonId,
              'on': on,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return ((j['fav_count'] as num?) ?? 0).toInt();
    } catch (_) {
      return null;
    }
  }
}
