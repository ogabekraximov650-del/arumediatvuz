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

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'rust_bridge.dart';
import 'sync_queue.dart';

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

  // ── OFLAYN: MA'LUMOT OYNASI BO'SH QOLMASIN ─────────────────
  //
  // TOPILGAN XATO (foydalanuvchi: "oflayn vaqtda pleyer pastidagi
  // anime ma'lumotlari ko'rinmayapti").
  //
  // Sabab: bu yerda disk keshi YO'Q edi. Internet bo'lmasa so'rov
  // yiqilib `null` qaytardi va "Ma'lumot" oynasi bo'sh turardi —
  // studiya, tarjimon, janr, tavsif, raqamlar, hech nima.
  //
  // Endi muvaffaqiyatli javob diskka (shifrlangan holda)
  // yoziladi va oflaynda AYNAN o'sha ko'rsatiladi. Yozuv bitta
  // bo'lim uchun bitta kichik qator — bosh sahifa va qismlar
  // ro'yxati keshi bilan bir xil qoida.

  static String _cacheKey(int animeId, int seasonId) =>
      'season_${animeId}_$seasonId';

  /// Diskdagi nusxa — TARMOQSIZ o'qiladi.
  ///
  /// `null` bo'lsa bu bo'lim hech qachon onlayn ochilmagan.
  static SeasonInfo? fromDisk(int animeId, int seasonId) {
    try {
      final rows = RustCore.instance.getCachedList(_cacheKey(animeId, seasonId));
      if (rows == null || rows.isEmpty) return null;
      return _withPending(animeId, seasonId, SeasonInfo.fromJson(rows.first));
    } catch (_) {
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════
  //  NAVBATDAGI HOLAT SERVERNIKIDAN USTUN
  // ══════════════════════════════════════════════════════════
  //
  // TOPILGAN XATO (foydalanuvchi: "sevimlilar va baholash tugmasi
  // ishlamayapti").
  //
  // Tugma aslida ISHLARDI: holat darhol o'zgarar va navbatga
  // tushardi. Lekin navbat kuniga bir necha marta yuboriladi, ya'ni
  // serverda u bir necha SOAT davomida yo'q bo'lib turadi.
  //
  // Bo'lim ma'lumoti esa har ochilganda SERVERDAN olinardi va
  // xotiradagini BUTUNLAY almashtirardi. Natijada qism almashtirsa
  // yoki pleyer qayta ochilsa, hozirgina qo'yilgan baho va sevimli
  // belgisi YO'QOLARDI — foydalanuvchi uchun bu "tugma ishlamadi"
  // degani.
  //
  // Sevimlilar RO'YXATIDA bu qoida allaqachon bor edi
  // (`sync_queue.dart` -> `pendingFavorites` izohi), lekin pleyer
  // ma'lumotiga qo'llanmagan edi. Endi ikkalasi bir xil ishlaydi:
  // serverdan kelgan javob ustiga navbatdagi holat qo'yiladi.
  static SeasonInfo _withPending(int animeId, int seasonId, SeasonInfo info) {
    final key = '$animeId:$seasonId';
    var out = info;
    try {
      final fav = SyncQueue.instance.pendingFavorites()[key];
      if (fav != null && fav != out.isFav) {
        final season = Map<String, dynamic>.from(out.season);
        final count = (out.favCount + (fav ? 1 : -1)).clamp(0, 1 << 40);
        season['fav_count'] = count;
        out = SeasonInfo(
          season: season,
          rating: out.rating,
          myStars: out.myStars,
          isFav: fav,
        );
      }
      final stars = SyncQueue.instance.pendingRatings()[key];
      if (stars != null && stars != out.myStars) {
        out = SeasonInfo(
          season: out.season,
          rating: out.rating,
          myStars: stars,
          isFav: out.isFav,
        );
      }
    } catch (_) {
      // Navbat o'qilmasa — serverdan kelgani o'z holicha qoladi.
    }
    return out;
  }

  /// Bo'lim ma'lumoti. Xato bo'lsa DISKDAGI nusxa, u ham bo'lmasa
  /// `null` — ekran baribir ochilaveradi.
  static Future<SeasonInfo?> load(int animeId, int seasonId) async {
    try {
      final r = await http
          .get(
            Uri.parse('$kApiBase/api/season/$animeId/$seasonId'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return fromDisk(animeId, seasonId);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      try {
        RustCore.instance.saveListCache(_cacheKey(animeId, seasonId), [j]);
      } catch (_) {}
      return _withPending(animeId, seasonId, SeasonInfo.fromJson(j));
    } catch (_) {
      return fromDisk(animeId, seasonId);
    }
  }

  // ── BAHO VA SEVIMLILAR — AVVAL TELEFONDA ───────────────────
  //
  // TALAB (foydalanuvchi): "barcha yozish va tahrirlash so'rovlari
  // qurilmaning o'zida qilinadi va paket bo'lib yuboriladi".
  //
  // Shu sabab bu yerda serverga MUROJAAT YO'Q. Ikki ish bo'ladi:
  //
  //   1. yangi holat DARHOL hisoblanadi va diskdagi nusxaga
  //      yoziladi — ekranda o'zgarish shu zahoti ko'rinadi,
  //      internet bo'lmasa ham;
  //   2. yozuv `SyncQueue` navbatiga tushadi.
  //
  // Reytingni mahalliy hisoblash serverdagi bilan BIR XIL qoida
  // bo'yicha ketadi (oddiy o'rtacha): yig'indidan eski bahoyingiz
  // ayiriladi, yangisi qo'shiladi; birinchi marta baho berilsa
  // sanoq bittaga oshadi.

  /// Baho qo'yish (1..10). Yangi holat DARHOL qaytadi.
  ///
  /// `current` — ekranda hozir turgan holat. Uni chaqiruvchi
  /// beradi, chunki oflaynda diskda nusxa bo'lmasligi mumkin,
  /// lekin baho baribir qabul qilinishi kerak.
  static SeasonInfo rate(
      int animeId, int seasonId, int stars, SeasonInfo current) {
    final oldStars = current.myStars;
    final count = current.ratingCount + (oldStars > 0 ? 0 : 1);
    // Eski yig'indi saqlanmaydi — u o'rtacha × sanoq orqali
    // tiklanadi (yaxlitlash xatosi ko'pi bilan 0.01).
    final oldSum = (current.rating * current.ratingCount).round();
    final sum = oldSum + stars - oldStars;
    final rating = count <= 0 ? 0.0 : ((sum / count) * 100).round() / 100;

    final season = Map<String, dynamic>.from(current.season);
    season['rating_count'] = count;
    final next = SeasonInfo(
      season: season,
      rating: rating,
      myStars: stars,
      isFav: current.isFav,
    );
    _saveDisk(animeId, seasonId, next);
    SyncQueue.instance.putRating(animeId, seasonId, stars);
    return next;
  }

  /// Sevimlilarga qo'shish / olib tashlash. Yangi holat DARHOL
  /// qaytadi.
  static SeasonInfo setFavorite(
      int animeId, int seasonId, bool on, SeasonInfo current) {
    final count = current.isFav == on
        ? current.favCount
        : (current.favCount + (on ? 1 : -1)).clamp(0, 1 << 40);
    final season = Map<String, dynamic>.from(current.season);
    season['fav_count'] = count;
    final next = SeasonInfo(
      season: season,
      rating: current.rating,
      myStars: current.myStars,
      isFav: on,
    );
    _saveDisk(animeId, seasonId, next);
    SyncQueue.instance.putFavorite(animeId, seasonId, on);
    // Kutubxonadagi "Sevimlilar" oynasi ham DARHOL o'zgaradi —
    // server ro'yxati kelguncha kutilmaydi.
    FavoritesService.instance.applyLocal(animeId, seasonId, on, season);
    return next;
  }

  /// Diskdagi nusxani yangilaydi (server javobi kutilmaydi).
  static void _saveDisk(int animeId, int seasonId, SeasonInfo info) {
    try {
      RustCore.instance.saveListCache(_cacheKey(animeId, seasonId), [
        {
          'season': info.season,
          'rating': info.rating,
          'my_stars': info.myStars,
          'is_fav': info.isFav,
        }
      ]);
    } catch (_) {}
  }
}

/// Foydalanuvchining SEVIMLI bo'limlari.
///
/// Javob bo'lim qatorlarining o'zi — Kutubxonadagi "Sevimlilar"
/// oynasi kartochkani darhol chizadi va pleyer ham shu ma'lumot
/// bilan ochiladi (qo'shimcha so'rovsiz).
class FavoritesService extends ChangeNotifier {
  FavoritesService._();
  static final FavoritesService instance = FavoritesService._();

  static const String _cacheKey = 'favorites';

  /// Ro'yxat shu muddat ichida qayta so'ralmaydi.
  static const Duration _freshFor = Duration(seconds: 60);

  List<Map<String, dynamic>> _items = [];
  DateTime? _loadedAt;
  bool _loading = false;

  List<Map<String, dynamic>> get items => List.unmodifiable(_items);
  bool get isLoading => _loading;

  /// Diskdagi nusxa — TARMOQSIZ (oflaynda ham ko'rinadi).
  void loadFromDisk() {
    if (_items.isNotEmpty) return;
    try {
      final rows = RustCore.instance.getCachedList(_cacheKey);
      if (rows == null || rows.isEmpty) return;
      _items = rows;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    final at = _loadedAt;
    if (!force && at != null && DateTime.now().difference(at) < _freshFor) {
      return;
    }
    final token = AuthService.instance.sessionToken;
    if (token == null) {
      if (_items.isNotEmpty) {
        _items = [];
        notifyListeners();
      }
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      final r = await http.get(
        Uri.parse('$kApiBase/api/favorites'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        final fresh = ((data['items'] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .toList();
        _items = _mergeLocal(fresh);
        _loadedAt = DateTime.now();
        try {
          RustCore.instance.saveListCache(_cacheKey, _items);
        } catch (_) {}
      }
    } catch (_) {
      // Internet yo'q — diskdagi nusxa qoladi.
    }
    _loading = false;
    notifyListeners();
  }

  /// Pleyerda yurakcha bosilganda ro'yxat DARHOL yangilansin.
  void markChanged() {
    _loadedAt = null;
  }

  /// Yurakcha bosildi — ro'yxat SHU ZAHOTI o'zgaradi.
  ///
  /// Yozuv serverga navbat bilan ketadi, ya'ni javob kutilmaydi.
  void applyLocal(
      int animeId, int seasonId, bool on, Map<String, dynamic> season) {
    bool same(Map<String, dynamic> e) =>
        ((e['anime_id'] as num?)?.toInt() ?? 0) == animeId &&
        ((e['season_id'] as num?)?.toInt() ?? 0) == seasonId;

    final next = _items.where((e) => !same(e)).toList();
    if (on) {
      final row = Map<String, dynamic>.from(season);
      row['anime_id'] = animeId;
      row['season_id'] = seasonId;
      next.insert(0, row);
    }
    _items = next;
    _loadedAt = null;
    try {
      RustCore.instance.saveListCache(_cacheKey, _items);
    } catch (_) {}
    notifyListeners();
  }

  /// Server ro'yxatining ustiga YUBORILMAGAN o'zgarishlarni
  /// qo'yadi.
  ///
  /// Aks holda hozirgina sevimliga qo'shilgan anime ro'yxat
  /// yangilangan zahoti yo'qolib qolardi (serverda hali yo'q).
  List<Map<String, dynamic>> _mergeLocal(List<Map<String, dynamic>> server) {
    final pend = SyncQueue.instance.pendingFavorites();
    if (pend.isEmpty) return server;
    String keyOf(Map<String, dynamic> e) =>
        '${(e['anime_id'] as num?)?.toInt() ?? 0}:'
        '${(e['season_id'] as num?)?.toInt() ?? 0}';

    final out = <Map<String, dynamic>>[];
    for (final e in server) {
      final on = pend[keyOf(e)];
      if (on == false) continue; // olib tashlangan
      out.add(e);
    }
    pend.forEach((k, on) {
      if (!on) return;
      if (out.any((e) => keyOf(e) == k)) return;
      // Qator faqat telefonda bor — eski ro'yxatdan olinadi.
      for (final e in _items) {
        if (keyOf(e) == k) {
          out.insert(0, e);
          break;
        }
      }
    });
    return out;
  }

  /// Hisob almashganda xotiradagi ro'yxat bo'shatiladi. Diskdagi
  /// nusxa O'CHIRILMAYDI — u hisobning o'z papkasida qoladi
  /// (`AccountData` izohiga qarang).
  void clear() {
    _items = [];
    _loadedAt = null;
    notifyListeners();
  }
}
