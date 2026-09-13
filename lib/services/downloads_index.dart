// lib/services/downloads_index.dart — TELEFONDAGI YUKLANMALAR.
//
// ═══════════════════════════════════════════════════════════════
//  NIMA UCHUN
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): Kutubxonadagi bo'sh "Yuklanmalar" oynasi
// olib tashlanib, tomosha tarixining "Qism bo'yicha" oynasi
// yoniga qo'shilsin. Ichida:
//
//   * ro'yxat OXIRGI MARTA YUKLAB OLINGAN BO'LAK VAQTI bo'yicha
//     (eng yangisi tepada);
//   * ko'rinishi "Qism bo'yicha" oynasidagidek — to'xtab qolgan
//     joydagi kadr, ustida progress chizig'i va vaqt;
//   * o'ng tarafda anime nomi, nechanchi bo'lim va qism, hamda
//     `0.00%` necha foiz yuklangani;
//   * o'ng yuqorida tozalash tugmasi (bir marta tasdiq so'raydi);
//   * video ONLAYN ham, OFLAYN ham, to'liq yuklansa ham, ozgina
//     yuklansa ham ko'rsatiladi.
//
// ═══════════════════════════════════════════════════════════════
//  QANDAY YIG'ILADI
// ═══════════════════════════════════════════════════════════════
//
// Rust yadrosida "qaysi videolar keshda bor" degan ro'yxat YO'Q —
// u faqat berilgan manzillar bo'yicha holat qaytaradi. Shu sabab
// nomzodlar `OfflineLibrary` dagi kabi yig'iladi:
//
//   1. bo'limlar (anime keshi + tomosha tarixi + sevimlilar);
//   2. har bo'limning qismlari (`eps_<anime>_<season>`);
//   3. hamma sifat manzillari BITTA `videoStats` chaqiruviga —
//      u faqat xotiradagi hisobni o'qiydi, diskka chiqmaydi;
//   4. `downloaded > 0` bo'lganlari qoladi.
//
// ── TARTIB: OXIRGI BO'LAK QACHON YOZILGAN ────────────────────
//
// Rust har video uchun alohida papka ochadi:
// `<support>/video_byte_cache/<kalit>`. Papkaning O'ZGARTIRILGAN
// VAQTI — aynan oxirgi bo'lak yozilgan payt. Kalit qoidasi
// `rust/src/video_cache.rs` -> `cache_key` bilan BIR XIL bo'lishi
// shart (`_cacheKey` izohiga qarang).
//
// Bitta qism uchun bir nechta sifat yuklangan bo'lishi mumkin —
// ro'yxatda BITTA qator turadi (eng ko'p yuklangan sifat), lekin
// o'chirishda qismning HAMMA sifati o'chiriladi.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'rust_bridge.dart';
import 'season_info.dart';
import 'watch_history.dart';

/// Ro'yxatdagi bitta qator.
@immutable
class DownloadItem {
  final int animeId;
  final int seasonId;
  final int bolimId;
  final int epizodId;
  final int epizodNumber;

  /// Ko'rsatiladigan nom — BO'LIM nomi (tarix oynasidagi kabi).
  final String title;

  /// Poster (kadr yo'q bo'lsa shu ko'rsatiladi).
  final String poster;

  /// Eng ko'p yuklangan sifatning manzili.
  final String url;

  /// Shu qismning HAMMA sifat manzillari — o'chirish uchun.
  final List<String> allUrls;

  final int downloaded;
  final int total;

  /// Oxirgi bo'lak diskka qachon yozilgan (Unix ms).
  final int updatedAt;

  const DownloadItem({
    required this.animeId,
    required this.seasonId,
    required this.bolimId,
    required this.epizodId,
    required this.epizodNumber,
    required this.title,
    required this.poster,
    required this.url,
    required this.allUrls,
    required this.downloaded,
    required this.total,
    required this.updatedAt,
  });

  /// Yuklangan ulush (0..1).
  double get ratio {
    if (total <= 0) return 0;
    final r = downloaded / total;
    return r.isNaN ? 0 : r.clamp(0.0, 1.0);
  }

  bool get complete => total > 0 && downloaded >= total;

  /// Nechanchi bo'lim (yozuvda bo'lmasa ichki `seasonId`).
  int get bolimNumber => bolimId > 0 ? bolimId : seasonId;

  /// Sifat nomi (`720p`). Fayl nomidan olinadi, topilmasa `''`.
  String get quality => qualityOf(url);

  /// Shu qismning HAMMA sifati — nomi bo'yicha tartiblangan.
  List<String> get qualities =>
      allUrls.map(qualityOf).where((q) => q.isNotEmpty).toList();

  DownloadItem copyWith({int? downloaded, int? total, String? url}) =>
      DownloadItem(
        animeId: animeId,
        seasonId: seasonId,
        bolimId: bolimId,
        epizodId: epizodId,
        epizodNumber: epizodNumber,
        title: title,
        poster: poster,
        url: url ?? this.url,
        allUrls: allUrls,
        downloaded: downloaded ?? this.downloaded,
        total: total ?? this.total,
        updatedAt: updatedAt,
      );
}

/// Manzildan sifat nomini ajratadi.
///
/// Fayl nomi qolipi: `ep_<anime>_<season>_<sifat>_<vaqt>.mp4`
/// (masalan `ep_1_1_720p_1789229969480.mp4` -> `720p`).
String qualityOf(String url) {
  final name = url.split('?').first.split('/').last;
  final m = RegExp(r'_(\d{3,4}p)_').firstMatch(name);
  return m?.group(1) ?? '';
}

class DownloadsIndex extends ChangeNotifier {
  DownloadsIndex._();
  static final DownloadsIndex instance = DownloadsIndex._();

  List<DownloadItem> _items = const [];
  List<DownloadItem> get items => _items;

  bool _building = false;
  bool ready = false;

  /// Ro'yxatni qaytadan yig'adi.
  Future<void> refresh() async {
    if (_building) return;
    _building = true;
    try {
      final cacheRoot = await _cacheRoot();
      final rows = await _collect(cacheRoot);
      rows.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _items = rows;
      ready = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Yuklanmalar ro\'yxati yig\'ilmadi: $e');
    } finally {
      _building = false;
    }
  }

  /// ── FAQAT RAQAMLARNI YANGILAYDI ─────────────────────────
  ///
  /// TALAB (foydalanuvchi): "yuklab olish foizi real vaqtda o'zi
  /// yangilansin — qo'lda tortib yangilash kerak bo'lyapti".
  ///
  /// To'liq `refresh()` diskni skanerlaydi va bo'limlar ro'yxatini
  /// qaytadan yig'adi — uni har soniyada chaqirib bo'lmaydi. Bu
  /// yerdagisi esa FAQAT mavjud qatorlarning `downloaded`/`total`
  /// sonini yangilaydi: bitta `videoStats` chaqiruvi, u ham
  /// xotiradagi hisobni o'qiydi, diskka chiqmaydi.
  ///
  /// Ro'yxatning O'ZI (yangi qism qo'shilishi) `refresh()` bilan
  /// yangilanadi.
  void refreshStats() {
    if (_items.isEmpty) return;
    final urls = <String>[];
    for (final e in _items) {
      urls.addAll(e.allUrls);
    }
    final Map<String, Map<String, dynamic>> stats;
    try {
      stats = RustCore.instance.videoStats(urls);
    } catch (_) {
      return;
    }
    var changed = false;
    final next = <DownloadItem>[];
    for (final e in _items) {
      var bestUrl = e.url;
      var bestDone = 0;
      var bestTotal = e.total;
      for (final url in e.allUrls) {
        final m = stats[url];
        if (m == null) continue;
        final done = (m['downloaded'] as num?)?.toInt() ?? 0;
        if (done <= bestDone) continue;
        bestDone = done;
        bestTotal = (m['total'] as num?)?.toInt() ?? 0;
        bestUrl = url;
      }
      if (bestDone != e.downloaded || bestTotal != e.total || bestUrl != e.url) {
        changed = true;
        next.add(e.copyWith(
            downloaded: bestDone, total: bestTotal, url: bestUrl));
      } else {
        next.add(e);
      }
    }
    if (!changed) return;
    _items = next;
    notifyListeners();
  }

  /// Bitta sifatning HAJMINI serverdan so'raydi (bir baytlik
  /// `Range` so'rovi — javobdagi `Content-Range` da to'liq hajm
  /// bor). Bilib bo'lmasa 0.
  ///
  /// Avval diskdagi hisob ko'riladi: yuklab olingan sifat uchun
  /// tarmoqqa umuman chiqilmaydi.
  Future<int> sizeOf(String url) async {
    try {
      final st = RustCore.instance.videoStats([url])[url];
      final t = (st?['total'] as num?)?.toInt() ?? 0;
      if (t > 0) return t;
    } catch (_) {}
    try {
      final r = await http.get(
        Uri.parse(url),
        headers: const {'Range': 'bytes=0-0'},
      ).timeout(const Duration(seconds: 12));
      final cr = r.headers['content-range'] ?? '';
      final total = cr.split('/').last.trim();
      return int.tryParse(total) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Bitta qismning HAMMA sifatini o'chiradi.
  Future<void> remove(DownloadItem item) async {
    for (final url in item.allUrls) {
      try {
        RustCore.instance.videoDelete(url);
      } catch (_) {
        // Bittasi o'chmasa qolganlari baribir o'chadi.
      }
    }
    // Ro'yxatdan DARHOL yo'qoladi — Rust diskni fon'da tozalaydi.
    _items = _items.where((e) => e.epizodId != item.epizodId).toList();
    notifyListeners();
    // Bir lahzadan keyin haqiqiy holat bilan solishtiramiz.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await refresh();
  }

  Future<String?> _cacheRoot() async {
    try {
      final support = await getApplicationSupportDirectory();
      return '${support.path}/video_byte_cache';
    } catch (_) {
      return null;
    }
  }

  Future<List<DownloadItem>> _collect(String? cacheRoot) async {
    // ── 1. QAYSI BO'LIMLAR ──────────────────────────────────
    final seen = <String>{};
    final pairs = <(int, int)>[];
    // Bo'lim qatorlari (nom va poster shu yerdan olinadi).
    final seasonRows = <String, Map<String, dynamic>>{};

    void addSeason(Map<String, dynamic> row) {
      final a = int.tryParse('${row['anime_id'] ?? ''}') ?? 0;
      final sid = int.tryParse('${row['season_id'] ?? ''}') ?? 0;
      if (a <= 0) return;
      final key = '$a:$sid';
      seasonRows.putIfAbsent(key, () => row);
      if (!seen.add(key)) return;
      pairs.add((a, sid));
    }

    for (final row in RustCore.instance.getCachedAnimes() ?? const []) {
      addSeason(row);
    }
    for (final f in FavoritesService.instance.items) {
      addSeason(f);
    }
    for (final h in WatchHistory.instance.items) {
      addSeason({
        'anime_id': h.animeId,
        'season_id': h.seasonId,
        'bolim_id': h.bolimId,
        'nomi': h.title,
        'photo_url': h.poster,
      });
    }
    if (pairs.isEmpty) return const [];

    // ── 2. QISMLAR VA MANZILLAR ─────────────────────────────
    final urlOwner = <String, int>{}; // manzil -> ro'yxatdagi indeks
    final drafts = <_Draft>[];
    var i = 0;
    for (final (animeId, seasonId) in pairs) {
      if (++i % 10 == 0) await Future<void>.delayed(Duration.zero);
      final eps = RustCore.instance.getCachedList('eps_${animeId}_$seasonId');
      if (eps == null) continue;
      final season = seasonRows['$animeId:$seasonId'] ?? const {};
      for (final ep in eps) {
        final epId = int.tryParse('${ep['epizod_id'] ?? ''}') ?? 0;
        if (epId <= 0) continue;
        final urls = <String>[];
        for (final q in const ['1080p', '720p', '480p', '360p']) {
          final url = (ep['url_$q'] ?? '').toString();
          if (url.isNotEmpty) urls.add(url);
        }
        if (urls.isEmpty) continue;
        final draft = _Draft(
          animeId: animeId,
          seasonId: seasonId,
          bolimId: int.tryParse('${season['bolim_id'] ?? ''}') ?? 0,
          epizodId: epId,
          epizodNumber: int.tryParse('${ep['epizod_number'] ?? ''}') ?? 0,
          title: (season['nomi'] ?? '').toString(),
          poster: (season['photo_url'] ?? '').toString(),
          urls: urls,
        );
        final index = drafts.length;
        drafts.add(draft);
        for (final url in urls) {
          urlOwner[url] = index;
        }
      }
    }
    if (urlOwner.isEmpty) return const [];

    // ── 3. HOLAT — BITTA CHAQIRUV ───────────────────────────
    //
    // `videoStats` faqat XOTIRADAGI hisobni o'qiydi va diskni
    // skanerlashni fon oqimiga topshiradi. Ilova endi ochilgan
    // bo'lsa birinchi javob bo'sh chiqishi mumkin — o'shanda bir
    // marta kutib qayta so'raymiz, aks holda ro'yxat "bo'sh" deb
    // ko'rinardi (`OfflineLibrary` bilan bir xil qoida).
    final urls = urlOwner.keys.toList();
    var stats = RustCore.instance.videoStats(urls);
    if (!stats.values.any((m) => ((m['downloaded'] as num?) ?? 0) > 0)) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      stats = RustCore.instance.videoStats(urls);
    }

    // ── 4. YUKLANGANLARI ────────────────────────────────────
    final out = <DownloadItem>[];
    for (var k = 0; k < drafts.length; k++) {
      final d = drafts[k];
      var bestUrl = '';
      var bestDone = 0;
      var bestTotal = 0;
      for (final url in d.urls) {
        final m = stats[url];
        if (m == null) continue;
        final done = (m['downloaded'] as num?)?.toInt() ?? 0;
        if (done <= 0 || done <= bestDone) continue;
        bestDone = done;
        bestTotal = (m['total'] as num?)?.toInt() ?? 0;
        bestUrl = url;
      }
      if (bestUrl.isEmpty) continue;
      out.add(DownloadItem(
        animeId: d.animeId,
        seasonId: d.seasonId,
        bolimId: d.bolimId,
        epizodId: d.epizodId,
        epizodNumber: d.epizodNumber,
        title: d.title,
        poster: d.poster,
        url: bestUrl,
        allUrls: d.urls,
        downloaded: bestDone,
        total: bestTotal,
        updatedAt: _lastWriteMs(cacheRoot, bestUrl),
      ));
    }
    return out;
  }

  /// Video papkasining o'zgartirilgan vaqti (Unix ms), 0 — noma'lum.
  int _lastWriteMs(String? cacheRoot, String url) {
    if (cacheRoot == null) return 0;
    try {
      final dir = Directory('$cacheRoot/${cacheKeyOf(url)}');
      if (!dir.existsSync()) return 0;
      return dir.statSync().modified.millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }
}

/// Yig'ish paytidagi vaqtinchalik yozuv.
class _Draft {
  final int animeId;
  final int seasonId;
  final int bolimId;
  final int epizodId;
  final int epizodNumber;
  final String title;
  final String poster;
  final List<String> urls;

  const _Draft({
    required this.animeId,
    required this.seasonId,
    required this.bolimId,
    required this.epizodId,
    required this.epizodNumber,
    required this.title,
    required this.poster,
    required this.urls,
  });
}

/// Video papkasining nomi.
///
/// ── QOIDA RUST BILAN BIR XIL BO'LISHI SHART ──────────────────
///
/// `rust/src/video_cache.rs` -> `cache_key`: manzilning so'rov
/// qismisiz oxirgi bo'lagi olinadi, undan faqat harf, raqam,
/// `.`, `_` va `-` qoldiriladi, 120 belgidan uzuni esa OXIRIDAN
/// qisqartiriladi.
///
/// Nomi bo'sh chiqsa Rust hash ishlatadi — bunday manzil bizda
/// yo'q (fayl nomlari har doim oddiy), shu sabab bu yerda
/// shunchaki bo'sh satr qaytadi va vaqt "noma'lum" bo'ladi.
String cacheKeyOf(String url) {
  final withoutQuery = url.split('?').first;
  final last = withoutQuery.split('/').last;
  final safe = last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
  if (safe.isEmpty || safe == '.' || safe == '..') return '';
  if (safe.length > 120) return safe.substring(safe.length - 120);
  return safe;
}
