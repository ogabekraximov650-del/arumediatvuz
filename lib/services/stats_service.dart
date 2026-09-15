// lib/services/stats_service.dart — SHAFFOF STATISTIKA.
//
// ═══════════════════════════════════════════════════════════════
//  BITTA SO'ROV, KAM MUROJAAT
// ═══════════════════════════════════════════════════════════════
//
// `GET /api/stats` hamma raqamni bir yo'la beradi va worker uni
// chekkada 5 daqiqa keshlaydi. Ilova esa yana 10 daqiqa o'zida
// saqlaydi — ya'ni bosh sahifa necha marta ochilsa ham serverga
// deyarli murojaat bo'lmaydi.
//
// Raqamlar diskka ham yoziladi (shifrlangan kesh): internet
// bo'lmasa oxirgi ma'lum holat ko'rsatiladi.
//
// Vaqt mintaqasi — UTC+5 (server shunga qarab kun ajratadi).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'rust_bridge.dart';

/// Bitta ko'rsatkichning davrlar bo'yicha qiymati.
/// YILLIK ko'rsatkich ATAYLAB YO'Q (foydalanuvchi talabi):
/// kunlik, haftalik, oylik va umumiy yetarli.
class StatBlock {
  final int daily;
  final int weekly;
  final int monthly;
  final int total;

  const StatBlock({
    this.daily = 0,
    this.weekly = 0,
    this.monthly = 0,
    this.total = 0,
  });

  factory StatBlock.fromJson(Map<String, dynamic>? j) {
    int v(String k) => ((j ?? const {})[k] as num?)?.toInt() ?? 0;
    return StatBlock(
      daily: v('daily'),
      weekly: v('weekly'),
      monthly: v('monthly'),
      total: v('total'),
    );
  }

  Map<String, dynamic> toJson() => {
        'daily': daily,
        'weekly': weekly,
        'monthly': monthly,
        'total': total,
      };
}

class AppStats {
  final StatBlock users;
  final StatBlock views;
  final StatBlock traffic;
  final StatBlock watch;

  const AppStats({
    required this.users,
    required this.views,
    required this.traffic,
    required this.watch,
  });

  static const empty = AppStats(
    users: StatBlock(),
    views: StatBlock(),
    traffic: StatBlock(),
    watch: StatBlock(),
  );

  factory AppStats.fromJson(Map<String, dynamic> j) => AppStats(
        users: StatBlock.fromJson(j['users'] as Map<String, dynamic>?),
        views: StatBlock.fromJson(j['views'] as Map<String, dynamic>?),
        traffic: StatBlock.fromJson(j['traffic'] as Map<String, dynamic>?),
        watch: StatBlock.fromJson(j['watch'] as Map<String, dynamic>?),
      );

  Map<String, dynamic> toJson() => {
        'users': users.toJson(),
        'views': views.toJson(),
        'traffic': traffic.toJson(),
        'watch': watch.toJson(),
      };
}

class StatsService extends ChangeNotifier {
  StatsService._();
  static final StatsService instance = StatsService._();

  static const String _cacheKey = 'app_stats';

  /// Shu muddat ichida qayta so'ralmaydi.
  static const Duration _freshFor = Duration(minutes: 10);

  AppStats _stats = AppStats.empty;
  DateTime? _loadedAt;
  bool _loading = false;
  bool _hasData = false;

  AppStats get stats => _stats;
  bool get isLoading => _loading;
  bool get hasData => _hasData;

  /// Diskdagi nusxani TARMOQSIZ o'qiydi (ilova ochilganda).
  void loadFromDisk() {
    if (_hasData) return;
    try {
      final rows = RustCore.instance.getCachedList(_cacheKey);
      if (rows == null || rows.isEmpty) return;
      _stats = AppStats.fromJson(rows.first);
      _hasData = true;
      notifyListeners();
    } catch (_) {
      // Nusxa o'qilmadi — raqamlar serverdan keladi.
    }
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    final at = _loadedAt;
    if (!force && at != null && DateTime.now().difference(at) < _freshFor) {
      return;
    }
    _loading = true;
    if (_hasData) notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$kApiBase/api/stats'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        _stats = AppStats.fromJson(data);
        _hasData = true;
        _loadedAt = DateTime.now();
        try {
          RustCore.instance.saveListCache(_cacheKey, [_stats.toJson()]);
        } catch (_) {}
      }
    } catch (_) {
      // Internet yo'q — diskdagi (yoki oldingi) raqamlar qoladi.
    }
    _loading = false;
    notifyListeners();
  }
}

/// ═══════════════════════════════════════════════════════════════
///  PROFIL SAHIFASIDAGI SHAXSIY STATISTIKA
/// ═══════════════════════════════════════════════════════════════
///
/// To'rtta raqam, BITTA so'rovda (`GET /api/me/stats`):
/// nechta anime, nechta qism, necha soat va qancha trafik.
class MyStats {
  final int animes;
  final int episodes;
  final int watchMs;
  final int traffic;

  /// TALAB (foydalanuvchi): "profil sahifasidagi statistikaga
  /// sevimlilar, bo'limlar, baholagan (animelar) va kommentariya
  /// statistikasini qo'sh".
  final int seasons;
  final int favorites;
  final int rated;
  final int comments;

  const MyStats({
    this.animes = 0,
    this.episodes = 0,
    this.watchMs = 0,
    this.traffic = 0,
    this.seasons = 0,
    this.favorites = 0,
    this.rated = 0,
    this.comments = 0,
  });

  factory MyStats.fromJson(Map<String, dynamic> j) {
    int v(String k) => (j[k] as num?)?.toInt() ?? 0;
    return MyStats(
      animes: v('animes'),
      episodes: v('episodes'),
      watchMs: v('watch_ms'),
      traffic: v('traffic'),
      seasons: v('seasons'),
      favorites: v('favorites'),
      rated: v('rated'),
      comments: v('comments'),
    );
  }

  Map<String, dynamic> toJson() => {
        'animes': animes,
        'episodes': episodes,
        'watch_ms': watchMs,
        'traffic': traffic,
        'seasons': seasons,
        'favorites': favorites,
        'rated': rated,
        'comments': comments,
      };
}

class MyStatsService extends ChangeNotifier {
  MyStatsService._();
  static final MyStatsService instance = MyStatsService._();

  static const String _cacheKey = 'my_stats';

  /// Profil sahifasi tez-tez ochiladi — 2 daqiqa yetarli.
  static const Duration _freshFor = Duration(minutes: 2);

  MyStats _stats = const MyStats();
  DateTime? _loadedAt;
  bool _loading = false;

  MyStats get stats => _stats;
  bool get isLoading => _loading;

  void loadFromDisk() {
    try {
      final rows = RustCore.instance.getCachedList(_cacheKey);
      if (rows == null || rows.isEmpty) return;
      _stats = MyStats.fromJson(rows.first);
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
      _stats = const MyStats();
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      final r = await http.get(
        Uri.parse('$kApiBase/api/me/stats'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        _stats = MyStats.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
        _loadedAt = DateTime.now();
        try {
          RustCore.instance.saveListCache(_cacheKey, [_stats.toJson()]);
        } catch (_) {}
      }
    } catch (_) {
      // Internet yo'q — oxirgi ma'lum raqamlar qoladi.
    }
    _loading = false;
    notifyListeners();
  }

  /// Hisobdan chiqilganda shaxsiy raqamlar ham yo'qoladi.
  void clear() {
    _stats = const MyStats();
    _loadedAt = null;
    notifyListeners();
  }
}