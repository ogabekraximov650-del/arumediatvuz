// lib/services/offline_library.dart — OFLAYNDA NIMA KO'RSA BO'LADI.
//
// ═══════════════════════════════════════════════════════════════
//  NEGA KERAK
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi):
//
//   * "oflayn vaqtda ilovaning bosh sahifasida faqat yuklab
//     olingan qismlari bor anime kartochkasi ko'rinishi kerak";
//   * "oflayn vaqtda tomosha tarixi va saqlangan animelardan
//     faqatgina yuklab olingan epizodi borlari ko'rinsin,
//     qolganlari yashirilsin LEKIN XOTIRADA TURSIN".
//
// Ya'ni hech narsa o'chirilmaydi — shunchaki ro'yxat filtrlanadi.
// Internet yoqilishi bilan hammasi joyiga qaytadi.
//
// ═══════════════════════════════════════════════════════════════
//  QANDAY ISHLAYDI — VA NEGA AYNAN SHUNDAY
// ═══════════════════════════════════════════════════════════════
//
// Har bir qatorda "shu video diskda to'liq bormi" deb so'rash
// MUMKIN EMAS: `videoIsComplete` DISKKA chiqadi (bir marta
// skanerlaydi) va ro'yxat chizilayotganda buni qilish kadrlarni
// tashlab yuborardi.
//
// Shu sabab bu yerda BIR MARTA indeks yig'iladi:
//
//   1. bo'limlar ro'yxatidan (diskdagi kesh) har bir bo'limning
//      qismlari o'qiladi (`eps_<anime>_<season>`);
//   2. hamma sifat manzillari BITTA ro'yxatga yig'iladi;
//   3. `videoStats` bitta chaqiruvda hammasining holatini beradi —
//      u faqat XOTIRADAGI hisobni o'qiydi, diskka ham, tarmoqqa
//      ham chiqmaydi.
//
// Natija ikkita to'plamda turadi: qaysi QISM va qaysi BO'LIM
// oflaynda ochiladi. Ekranlar shu to'plamdan so'raydi — tekshiruv
// `Set.contains`, ya'ni deyarli bepul.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'rust_bridge.dart';
import 'season_info.dart';
import 'watch_history.dart';

class OfflineLibrary extends ChangeNotifier {
  OfflineLibrary._();
  static final OfflineLibrary instance = OfflineLibrary._();

  /// Oflaynda ochiladigan qismlar: `anime:season:epizodId`.
  Set<String> _episodes = {};

  /// Kamida bitta qismi yuklangan bo'limlar: `anime:season`.
  Set<String> _seasons = {};

  bool _building = false;

  /// Oxirgi marta indeks qaysi bo'limlar bo'yicha yig'ilgan.
  ///
  /// Internet uzilganda indeksni QAYTA yig'ish uchun kerak:
  /// shu paytgacha yuklab olingan qismlar qo'shilgan bo'lishi
  /// mumkin.
  List<Map<String, dynamic>> _lastSeasons = const [];

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  /// Hozir internet YO'Qmi.
  ///
  /// Bu bayroq shu yerda turadi, chunki uni uchta ekran
  /// (bosh sahifa, tarix, sevimlilar) bir xil o'qiydi — har biri
  /// alohida kuzatuvchi ochsa, uchta obuna va uchta har xil
  /// haqiqat bo'lardi.
  bool isOffline = false;

  /// `main()` da bir marta chaqiriladi.
  void start() {
    if (_connSub != null) return;

    // ── BOSHLANG'ICH HOLAT ────────────────────────────────────
    //
    // `onConnectivityChanged` faqat O'ZGARISHDA xabar beradi.
    // Ilova internetsiz ochilgan bo'lsa hech qanday hodisa
    // kelmaydi va bayroq `false` (ya'ni "onlayn") bo'lib
    // qolardi — ro'yxatlar esa filtrlanmasdi.
    unawaited(Connectivity().checkConnectivity().then((results) {
      final online =
          results.isNotEmpty && results.any((r) => r != ConnectivityResult.none);
      if (isOffline == !online) return;
      isOffline = !online;
      notifyListeners();
    }).catchError((_) {}));

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online =
          results.isNotEmpty && results.any((r) => r != ConnectivityResult.none);
      final wasOffline = isOffline;
      isOffline = !online;
      if (wasOffline == isOffline) return;
      notifyListeners();
      // Internet uzildi — indeksni yangilaymiz: ro'yxatlar
      // shu zahoti to'g'ri filtrlansin.
      if (isOffline) unawaited(refresh(_lastSeasons));
    });

    // Ilova OFLAYN ochilgan bo'lishi mumkin — indeks darhol
    // yig'iladi, aks holda tomosha tarixi va bosh sahifa
    // "hali ma'lum emas" holatida hamma narsani ko'rsatib
    // turardi. Diskdagi bo'limlar ro'yxati tarmoqsiz o'qiladi.
    unawaited(refresh(RustCore.instance.getCachedAnimes() ?? const []));
  }

  /// Indeks kamida bir marta yig'ilganmi.
  ///
  /// Yig'ilmagan bo'lsa ekranlar hech narsani yashirmaydi — aks
  /// holda oflaynda ochilgan ilova bir lahzaga BO'M-BO'SH
  /// ko'rinardi.
  bool ready = false;

  static String seasonKey(int animeId, int seasonId) => '$animeId:$seasonId';

  static String episodeKey(int animeId, int seasonId, int epizodId) =>
      '$animeId:$seasonId:$epizodId';

  /// Shu bo'limning kamida bitta qismi telefonda to'liq bormi.
  bool hasSeason(int animeId, int seasonId) =>
      _seasons.contains(seasonKey(animeId, seasonId));

  /// Aynan shu qism telefonda to'liq bormi.
  bool hasEpisode(int animeId, int seasonId, int epizodId) =>
      _episodes.contains(episodeKey(animeId, seasonId, epizodId));

  /// Holat javobidan TO'LIQ yuklangan qismlar kalitini ajratadi.
  Set<String> _completed(
    Map<String, Map<String, dynamic>> stats,
    Map<String, String> urlOwner,
  ) {
    final out = <String>{};
    stats.forEach((url, m) {
      final total = (m['total'] as num?)?.toInt() ?? 0;
      final done = (m['downloaded'] as num?)?.toInt() ?? 0;
      if (total <= 0 || done < total) return;
      final key = urlOwner[url];
      if (key != null) out.add(key);
    });
    return out;
  }

  /// Indeksni qayta yig'adi.
  ///
  /// [seasons] — bosh sahifadagi bo'limlar ro'yxati (diskdagi
  /// keshdan kelgan qatorlar). Har bir qatordan faqat `anime_id`
  /// va `season_id` olinadi.
  Future<void> refresh(Iterable<Map<String, dynamic>> seasons) async {
    if (_building) return;
    _building = true;
    try {
      if (seasons is List<Map<String, dynamic>> && seasons.isNotEmpty) {
        _lastSeasons = seasons;
      }
      // ── QAYSI BO'LIMLAR TEKSHIRILADI ──────────────────────
      //
      // Bosh sahifadagi ro'yxat YETARLI EMAS: foydalanuvchi
      // ko'rgan yoki sevimlilarga qo'shgan bo'lim u yerda
      // bo'lmasligi mumkin (ro'yxat `LIMIT 100`, va u eskirgan
      // bo'lishi ham mumkin). Shunday holda tomosha tarixi
      // oflaynda BO'M-BO'SH ko'rinib qolardi.
      //
      // Shu sabab uchta manba birlashtiriladi. Takrorlanmasin
      // deb to'plam ishlatiladi.
      final seen = <String>{};
      final pairs = <(int, int)>[];
      void addPair(Object? animeId, Object? seasonId) {
        final a = int.tryParse('${animeId ?? ''}') ?? 0;
        final sid = int.tryParse('${seasonId ?? ''}') ?? 0;
        if (a <= 0) return;
        if (!seen.add(seasonKey(a, sid))) return;
        pairs.add((a, sid));
      }

      for (final s in seasons) {
        addPair(s['anime_id'], s['season_id']);
      }
      for (final h in WatchHistory.instance.items) {
        addPair(h.animeId, h.seasonId);
      }
      for (final f in FavoritesService.instance.items) {
        addPair(f['anime_id'], f['season_id']);
      }

      if (pairs.isEmpty) {
        _episodes = {};
        _seasons = {};
        ready = true;
        notifyListeners();
        return;
      }

      // 1) Diskdagi qismlar ro'yxatlari. Har biri kichik JSON,
      //    lekin o'qish SINXRON — shu sabab har o'nta bo'limdan
      //    keyin kadrga yo'l beriladi.
      final urlOwner = <String, String>{}; // manzil -> "a:s:epizodId"
      var i = 0;
      for (final (animeId, seasonId) in pairs) {
        if (++i % 10 == 0) await Future<void>.delayed(Duration.zero);
        final rows =
            RustCore.instance.getCachedList('eps_${animeId}_$seasonId');
        if (rows == null) continue;
        for (final ep in rows) {
          final epId = int.tryParse('${ep['epizod_id'] ?? ''}') ?? 0;
          if (epId <= 0) continue;
          final key = episodeKey(animeId, seasonId, epId);
          for (final q in const ['1080p', '720p', '480p', '360p']) {
            final url = (ep['url_$q'] ?? '').toString();
            if (url.isNotEmpty) urlOwner[url] = key;
          }
        }
      }
      if (urlOwner.isEmpty) {
        _episodes = {};
        _seasons = {};
        ready = true;
        notifyListeners();
        return;
      }

      // 2) BITTA chaqiruv — hamma manzilning holati.
      //
      // ── NEGA IKKI MARTA SO'RALADI ─────────────────────────
      //
      // `videoStats` faqat XOTIRADAGI hisobni o'qiydi va diskni
      // skanerlashni fon oqimiga topshiradi. Ya'ni ilova endi
      // ochilgan bo'lsa, birinchi javob BO'SH bo'lishi mumkin —
      // diskdagi bo'laklar hali sanalmagan. Bo'sh javobni
      // "hech narsa yuklanmagan" deb qabul qilsak, oflayn bosh
      // sahifa bir zumga bo'm-bo'sh ko'rinardi.
      //
      // Shu sabab birinchi javob bo'sh chiqsa bir marta kutib
      // qayta so'raymiz — fon skaneri shu vaqtda ulguradi.
      final urls = urlOwner.keys.toList();
      var stats = RustCore.instance.videoStats(urls);
      var eps = _completed(stats, urlOwner);
      if (eps.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        stats = RustCore.instance.videoStats(urls);
        eps = _completed(stats, urlOwner);
      }

      final ses = <String>{};
      for (final key in eps) {
        // "a:s:epizodId" -> "a:s"
        final cut = key.lastIndexOf(':');
        if (cut > 0) ses.add(key.substring(0, cut));
      }

      _episodes = eps;
      _seasons = ses;
      ready = true;
      notifyListeners();
    } catch (_) {
      // Indeks yig'ilmadi — ekranlar hech narsani yashirmaydi.
      ready = false;
    } finally {
      _building = false;
    }
  }
}
