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
