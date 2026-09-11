// lib/services/watch_history.dart — TOMOSHA TARIXI.
//
// ═══════════════════════════════════════════════════════════════
//  ASOSIY MANBA — TURSO, MAHALLIY NUSXA — FAQAT OFLAYN UCHUN
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "to'g'ridan-to'g'ri Turso bilan ishlasin,
// iloji boricha kamroq so'rov bilan; mahalliy baza faqat oflayn
// rejimda ishlatilsin".
//
// Shu sabab serverga atigi IKKI holatda murojaat qilinadi:
//
//   * `flush()` — pleyerdan chiqilganda, qism almashganda yoki
//     ilova fonga ketganda: BITTA `POST`. Ya'ni bir marta ko'rish =
//     bitta yozuv. To'xtagan joyning o'zi har soniya eslab
//     qolinadi, lekin u FAQAT telefon xotirasiga yoziladi
//     (`WatchProgress`);
//   * `load()` — tarix sahifasi ochilganda: BITTA `GET`. Javob
//     ro'yxat uchun kerak bo'lgan hamma narsani (anime nomi,
//     posteri, bo'lim raqami) bir yo'la olib keladi.
//
// Olingan ro'yxat 60 soniya xotirada turadi — oynalar orasida
// yurganda qayta so'ralmaydi.
//
// ── OFLAYN ────────────────────────────────────────────────────
//
// Yozib bo'lmasa — yozuv navbatga (diskda, SHIFRLANGAN) tushadi va
// keyingi imkoniyatda yuboriladi. O'qib bo'lmasa — oxirgi olingan
// ro'yxat ko'rsatiladi. Mahalliy nusxa boshqa hech qachon
// ishlatilmaydi.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'rust_bridge.dart';
import 'video_cache_server.dart';
import 'watch_progress.dart';

/// Tarixdagi bitta qism.
class HistoryItem {
  final int animeId;
  final int seasonId;
  final int bolimId;
  final int epizodNumber;
  final String animeName;

  /// Bo'lim (season) nomi — tarix oynalarida AYNAN shu ko'rsatiladi
  /// (foydalanuvchi talabi: "anime nomi emas, bo'lim nomi").
  final String seasonName;
  final String animePhoto;
  final String seasonPhoto;
  final String videoUrl;
  final int positionMs;
  final int durationMs;

  /// Shu odam shu qismni JAMI qancha ko'rgani (1x tezlikdagi
  /// haqiqiy vaqt; qism uzunligidan oshmaydi).
  final int watchedMs;

  /// Shu odam qismni necha marta ochib ko'rgani.
  final int viewCount;

  /// Oxirgi marta qachon ko'rilgani (Unix, millisekund).
  final int updatedAt;

  const HistoryItem({
    required this.animeId,
    required this.seasonId,
    required this.bolimId,
    required this.epizodNumber,
    required this.animeName,
    required this.seasonName,
    required this.animePhoto,
    required this.seasonPhoto,
    required this.videoUrl,
    required this.positionMs,
    required this.durationMs,
    this.watchedMs = 0,
    this.viewCount = 0,
    required this.updatedAt,
  });

  /// Ko'rilgan ulush (0..1) — progress chizig'i uchun.
  double get progress {
    if (durationMs <= 0) return 0;
    final r = positionMs / durationMs;
    if (r.isNaN || r < 0) return 0;
    if (r > 1) return 1;
    return r;
  }

  /// Ko'rilgan ulush foizda (progress chizig'i yonidagi yozuv).
  double get percent => progress * 100;

  /// Ro'yxatda ko'rsatiladigan poster: bo'lim rasmi bo'lsa o'sha,
  /// bo'lmasa anime rasmi.
  String get poster => seasonPhoto.isNotEmpty ? seasonPhoto : animePhoto;

  /// Ro'yxatdagi sarlavha — BO'LIM nomi. Bo'lmasa anime nomi
  /// (eski yozuvlar va noto'liq ma'lumot uchun zaxira).
  String get title {
    if (seasonName.trim().isNotEmpty) return seasonName.trim();
    if (animeName.trim().isNotEmpty) return animeName.trim();
    return 'Anime';
  }

  /// Nechanchi bo'lim (yozuvda bo'lmasa — bo'lim raqami o'rniga
  /// ichki `season_id` ishlatiladi).
  int get bolimNumber => bolimId > 0 ? bolimId : seasonId;

  /// Bir xil qismmi (anime + bo'lim + qism).
  bool sameEpisode(int a, int s, int e) =>
      animeId == a && seasonId == s && epizodNumber == e;

  /// Kadr fayli uchun kalit — qaysi video va QAYSI MILLISEKUND.
  ///
  /// TUZATILGAN XATO: ilgari vaqt 10 soniyalik bo'laklarga
  /// yaxlitlanardi, ya'ni ro'yxatdagi rasm to'xtagan joydan bir
  /// necha soniya narida bo'lishi mumkin edi. Endi kalit aniq
  /// millisekundga bog'langan; eski (endi kerak bo'lmagan) kadrlar
  /// yangisi yasalgach o'chiriladi (`_removeStaleThumbs`).
  String get thumbKey => '${videoKey}_$positionMs';

  /// Kadr qaysi videoga tegishli (eskirganini o'chirish uchun).
  String get videoKey {
    final name = videoUrl.split('/').last.split('?').first;
    return name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  }

  Map<String, dynamic> toJson() => {
        'anime_id': animeId,
        'season_id': seasonId,
        'bolim_id': bolimId,
        'epizod_number': epizodNumber,
        'anime_name': animeName,
        'season_name': seasonName,
        'anime_photo': animePhoto,
        'season_photo': seasonPhoto,
        'video_url': videoUrl,
        'position_ms': positionMs,
        'duration_ms': durationMs,
        'watched_ms': watchedMs,
        'view_count': viewCount,
        'updated_at': updatedAt,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> j) {
    // Maydon nomi `num` bo'lishi MUMKIN EMAS: u Dart'dagi son
    // turining nomi va funksiya ichida o'sha turni to'sib qo'yadi
    // ("'num' isn't a type" xatosi).
    int intOf(String k) => (j[k] as num?)?.toInt() ?? 0;
    String strOf(String k) => (j[k] ?? '').toString();
    return HistoryItem(
      animeId: intOf('anime_id'),
      seasonId: intOf('season_id'),
      bolimId: intOf('bolim_id'),
      epizodNumber: intOf('epizod_number'),
      animeName: strOf('anime_name'),
      seasonName: strOf('season_name'),
      animePhoto: strOf('anime_photo'),
      seasonPhoto: strOf('season_photo'),
      videoUrl: strOf('video_url'),
      positionMs: intOf('position_ms'),
      durationMs: intOf('duration_ms'),
      watchedMs: intOf('watched_ms'),
      viewCount: intOf('view_count'),
      updatedAt: intOf('updated_at'),
    );
  }
}

class WatchHistory extends ChangeNotifier {
  WatchHistory._();
  static final WatchHistory instance = WatchHistory._();

  /// Diskdagi nusxa HAR BIR HISOB UCHUN ALOHIDA saqlanadi.
  ///
  /// NEGA: bitta telefondan ikki kishi kirishi mumkin. Kalit umumiy
  /// bo'lsa, ikkinchi odam bir zumga BIRINCHISINING tarixini ko'rib
  /// qolardi (server javobi kelguncha).
  String get _listKey {
    final id = AuthService.instance.user?.id ?? 0;
    return 'watch_history_$id';
  }

  String get _outboxKey {
    final id = AuthService.instance.user?.id ?? 0;
    return 'watch_history_outbox_$id';
  }

  /// Ro'yxat shu muddat ichida qayta so'ralmaydi.
  static const Duration _freshFor = Duration(seconds: 60);

  /// Bir vaqtda shuncha kadr yasaladi — ro'yxat sirg'alayotganda
  /// tarmoq ham, protsessor ham bo'g'ilib qolmasin.
  static const int _maxParallelThumbs = 2;

  List<HistoryItem> _items = [];
  DateTime? _loadedAt;
  bool _loading = false;

  /// Ro'yxat QAYSI hisob uchun olingan.
  ///
  /// Bitta telefondan boshqa odam kirsa, eski ro'yxat bir zumga
  /// ko'rinib qolmasligi kerak.
  int _loadedForUser = 0;

  List<HistoryItem> get items => List.unmodifiable(_items);
  bool get isLoading => _loading;

  // ── HOZIR KO'RILAYOTGAN QISM ────────────────────────────────
  //
  // Pleyer shu yerga yozib turadi (xotirada, arzon), serverga esa
  // faqat `flush()` da bitta so'rov ketadi.
  Map<String, dynamic>? _pending;

  /// Shu ochilish hali tarixga "yangi ko'rish" deb yozilmagan.
  ///
  /// Bitta ochilish = BITTA ko'rish: ilova fonga chiqib qaytsa
  /// yoki yozuv ikki marta yuborilsa, hisob ikkilanmaydi.
  bool _pendingNewView = false;

  /// Pleyer qaysi qismni ochganini bildiradi.
  ///
  /// Nom va rasmlar ham shu yerda beriladi: ular mahalliy ro'yxatni
  /// DARHOL yangilash uchun kerak — internet bo'lmasa ham tarixda
  /// to'g'ri nom, bo'lim va rasm turadi (foydalanuvchi talabi:
  /// "oflayn rejimda ham to'g'ri ishlashi uchun").
  void startEpisode({
    required int animeId,
    required int seasonId,
    required int epizodNumber,
    required String videoUrl,
    int bolimId = 0,
    String animeName = '',
    String seasonName = '',
    String animePhoto = '',
    String seasonPhoto = '',
  }) {
    if (animeId <= 0 || epizodNumber <= 0) return;
    // Oldingi qism yozuvi hali yuborilmagan bo'lsa — avval o'sha
    // yuboriladi, aks holda u yo'qolib ketardi.
    final prev = _pending;
    if (prev != null &&
        (prev['anime_id'] != animeId ||
            prev['epizod_number'] != epizodNumber ||
            prev['season_id'] != seasonId)) {
      unawaited(flush());
    }
    // ── TOMOSHA VAQTI DAVOM ETADI ───────────────────────
    //
    // Serverga JAMI vaqt yuboriladi (shu odam shu qismni qancha
    // ko'rgani), shu sabab avvalgi yozuvdan davom etamiz.
    final before = findEpisode(animeId, seasonId, epizodNumber);

    // ── QAYSI HOLAT "YANGI KO'RISH" ─────────────────────
    //
    // Faqat BOSHQA qism ochilganda. Sifat almashtirilganda yoki
    // pleyer qaytadan ochilganda (xatodan tiklanish) qism
    // O'ZGARMAYDI — u paytda hisob oshmasligi kerak.
    final sameEpisode = prev != null &&
        prev['anime_id'] == animeId &&
        prev['season_id'] == seasonId &&
        prev['epizod_number'] == epizodNumber;
    if (!sameEpisode) _pendingNewView = true;

    // Sifat almashtirilganda shu seansda yig'ilgan vaqt
    // YO'QOLMASLIGI kerak, shu sabab kattasini olamiz.
    final carried = sameEpisode ? ((prev['watched_ms'] as int?) ?? 0) : 0;
    final saved = before?.watchedMs ?? 0;
    _pending = {
      'anime_id': animeId,
      'season_id': seasonId,
      'bolim_id': bolimId,
      'epizod_number': epizodNumber,
      'watched_ms': carried > saved ? carried : saved,
      'anime_name': animeName,
      'season_name': seasonName,
      'anime_photo': animePhoto,
      'season_photo': seasonPhoto,
      'video_url': videoUrl,
      'position_ms': 0,
      'duration_ms': 0,
    };
  }

  /// Pleyer joriy nuqtani bildiradi (faqat xotira).
  void note(Duration position, Duration duration) {
    final p = _pending;
    if (p == null || duration <= Duration.zero) return;
    p['position_ms'] = position.inMilliseconds;
    p['duration_ms'] = duration.inMilliseconds;
  }

  /// Haqiqatda ko'rilgan vaqt qo'shiladi.
  ///
  /// TALAB (foydalanuvchi): "videoni 1x tezlikda ko'rganda
  /// hisoblansin" va "ko'rish vaqti epizod vaqtidan oshmasligi
  /// kerak". Shu sabab:
  ///
  ///   * pleyer FAQAT ijro ketayotganda va tezlik 1x bo'lganda
  ///     chaqiradi (`video_player_screen.dart`);
  ///   * bu yerda esa yig'indi qism uzunligidan oshmaydi.
  ///
  /// Sek (oldinga surish) hisoblanmaydi: pleyer o'tgan HAQIQIY
  /// vaqtni beradi, sakrash emas.
  void addWatched(int deltaMs) {
    final p = _pending;
    if (p == null || deltaMs <= 0) return;
    final duration = (p['duration_ms'] as int?) ?? 0;
    var total = ((p['watched_ms'] as int?) ?? 0) + deltaMs;
    if (duration > 0 && total > duration) total = duration;
    p['watched_ms'] = total;
  }

  /// Kutayotgan yozuvni serverga yuboradi. Pleyerdan chiqilganda,
  /// qism almashganda va ilova fonga ketganda chaqiriladi.
  Future<void> flush() async {
    final p = _pending;
    if (p == null) return;
    final duration = (p['duration_ms'] as int?) ?? 0;
    final position = (p['position_ms'] as int?) ?? 0;

    // ── QANCHA KO'RILSA TARIXGA TUSHADI ─────────────────────
    //
    // TOPILGAN XATO (foydalanuvchi ko'rgan): chegara QAT'IY 15
    // soniya edi. 17 soniyalik qismni necha marta ko'rsa ham
    // tarixga UMUMAN tushmasdi.
    //
    // Endi chegara qism uzunligiga bog'langan (`WatchProgress`
    // bilan bitta qoida): uzunlikning 10% i, lekin ko'pi bilan
    // 15 soniya.
    final minMs = WatchProgress.minPositionFor(
      Duration(milliseconds: duration),
    ).inMilliseconds;
    if (duration <= 0 || position < minMs) {
      _pending = null;
      return;
    }
    _pending = null;

    final row = Map<String, dynamic>.from(p);
    row['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    row['new_view'] = _pendingNewView;
    _pendingNewView = false;

    // 1) Mahalliy ro'yxat DARHOL yangilanadi — qator eng tepaga
    //    chiqadi va sana yangilanadi. Internet bo'lmasa ham.
    _applyLocal(row);
    // 2) To'xtagan joydagi kadr SHU ZAHOTI yasalib diskka
    //    yoziladi — tarix oynasi oflaynda ham rasmli ochiladi.
    unawaited(_prepareThumb(row));
    // 3) Va nihoyat serverga BITTA so'rov.
    await _send(row);
  }

  // ── MAHALLIY RO'YXATNI YANGILASH ────────────────────────────
  //
  // Serverdan javob kutilmaydi: foydalanuvchi Kutubxonani ochganda
  // hozirgina ko'rgan qismi eng tepada turishi kerak — internet
  // bor-yo'qligidan qat'iy nazar.

  void _applyLocal(Map<String, dynamic> row) {
    int intOf(String k) => (row[k] as num?)?.toInt() ?? 0;
    String strOf(String k) => (row[k] ?? '').toString();

    final animeId = intOf('anime_id');
    final seasonId = intOf('season_id');
    final epizod = intOf('epizod_number');
    if (animeId <= 0 || epizod <= 0) return;

    final list = List<HistoryItem>.from(_items);
    final at = list.indexWhere((e) => e.sameEpisode(animeId, seasonId, epizod));
    // Eski yozuvdagi ma'lumot (nom, rasm) yo'qolmasin: pleyer
    // ularning hammasini bilmasligi mumkin.
    final old = at >= 0 ? list[at] : _anyOf(animeId, seasonId);
    String pick(String fresh, String? saved) =>
        fresh.isNotEmpty ? fresh : (saved ?? '');

    final item = HistoryItem(
      animeId: animeId,
      seasonId: seasonId,
      bolimId: intOf('bolim_id') > 0 ? intOf('bolim_id') : (old?.bolimId ?? 0),
      epizodNumber: epizod,
      animeName: pick(strOf('anime_name'), old?.animeName),
      seasonName: pick(strOf('season_name'), old?.seasonName),
      animePhoto: pick(strOf('anime_photo'), old?.animePhoto),
      seasonPhoto: pick(strOf('season_photo'), old?.seasonPhoto),
      videoUrl: pick(strOf('video_url'), old?.videoUrl),
      positionMs: intOf('position_ms'),
      durationMs: intOf('duration_ms'),
      watchedMs: intOf('watched_ms'),
      viewCount: (old?.viewCount ?? 0) + (row['new_view'] == true ? 1 : 0),
      updatedAt: intOf('updated_at') > 0
          ? intOf('updated_at')
          : DateTime.now().millisecondsSinceEpoch,
    );

    if (at >= 0) {
      list[at] = item;
    } else {
      list.add(item);
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _items = list;
    _loadedForUser = AuthService.instance.user?.id ?? _loadedForUser;
    _saveDisk();
    notifyListeners();
  }

  /// Shu anime (yoki shu bo'lim) bo'yicha istalgan eski yozuv —
  /// nom va rasmlarni undan olamiz.
  HistoryItem? _anyOf(int animeId, int seasonId) {
    for (final e in _items) {
      if (e.animeId == animeId && e.seasonId == seasonId) return e;
    }
    for (final e in _items) {
      if (e.animeId == animeId) return e;
    }
    return null;
  }

  /// Ro'yxatni diskdagi (shifrlangan) nusxaga yozadi.
  void _saveDisk() {
    try {
      RustCore.instance
          .saveListCache(_listKey, _items.map((e) => e.toJson()).toList());
    } catch (_) {
      // Diskka yozib bo'lmadi — ro'yxat xotirada baribir to'g'ri.
    }
  }

  // ── SERVER BILAN ISHLASH ────────────────────────────────────

  Future<void> _send(Map<String, dynamic> row) async {
    final token = AuthService.instance.sessionToken;
    if (token == null) return;
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/history'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(row),
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        // Ro'yxat endi eskirdi — keyingi ochilishda yangilanadi.
        _loadedAt = null;
        return;
      }
    } catch (_) {
      // Tarmoq yo'q — pastda navbatga tushadi.
    }
    _queue(row);
  }

  /// Yuborilmagan yozuvni diskdagi (shifrlangan) navbatga qo'yadi.
  void _queue(Map<String, dynamic> row) {
    final box = RustCore.instance.getCachedList(_outboxKey) ?? [];
    // Bir xil qism uchun ikkinchi yozuv saqlanmaydi — eng
    // oxirgisi to'g'ri.
    box.removeWhere((e) =>
        e['anime_id'] == row['anime_id'] &&
        e['season_id'] == row['season_id'] &&
        e['epizod_number'] == row['epizod_number']);
    box.add(row);
    // Navbat cheksiz o'smasin.
    final trimmed = box.length > 200 ? box.sublist(box.length - 200) : box;
    RustCore.instance.saveListCache(_outboxKey, trimmed);
  }

  /// Navbatdagi yozuvlarni yuborishga urinadi.
  Future<void> _drainOutbox() async {
    final box = RustCore.instance.getCachedList(_outboxKey) ?? [];
    if (box.isEmpty) return;
    final token = AuthService.instance.sessionToken;
    if (token == null) return;

    final left = <Map<String, dynamic>>[];
    for (final row in box) {
      try {
        final isDelete = row['_op'] == 'delete';
        final uri = Uri.parse('$kApiBase/api/history');
        final headers = {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        };
        final body = jsonEncode(row);
        final r = await (isDelete
                ? http.delete(uri, headers: headers, body: body)
                : http.post(uri, headers: headers, body: body))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode != 200 && r.statusCode < 500) {
          // Server yozuvni rad etdi (masalan to'liq emas) —
          // uni abadiy qayta yuborib o'tirmaymiz.
          continue;
        }
        if (r.statusCode != 200) left.add(row);
      } catch (_) {
        // Tarmoq hali yo'q — qolganini keyingi safarga qoldiramiz.
        left.add(row);
      }
    }
    RustCore.instance.saveListCache(_outboxKey, left);
  }

  /// Tarixni yuklaydi.
  ///
  /// [force] — foydalanuvchi ro'yxatni pastga tortib yangilaganda.
  Future<void> load({bool force = false}) async {
    if (_loading) return;
    final at = _loadedAt;
    if (!force && at != null && DateTime.now().difference(at) < _freshFor) {
      return;
    }

    // Hisobdan chiqilgan bo'lsa — tarix ham ko'rsatilmaydi.
    if (AuthService.instance.sessionToken == null) {
      if (_items.isNotEmpty) {
        _items = [];
        _loadedForUser = 0;
        notifyListeners();
      }
      return;
    }

    // Boshqa hisob kirgan bo'lsa — eskisi darhol tozalanadi.
    final userId = AuthService.instance.user?.id ?? 0;
    if (userId != _loadedForUser) {
      _items = [];
      _loadedAt = null;
      _loadedForUser = userId;
    }

    _loading = true;
    notifyListeners();

    // Avval kutayotgan yozuvlar yuboriladi — aks holda foydalanuvchi
    // hozirgina ko'rgan qismini ro'yxatda ko'rmasdi.
    await _drainOutbox();

    final token = AuthService.instance.sessionToken;
    List<HistoryItem>? fresh;
    if (token != null) {
      try {
        final r = await http.get(
          Uri.parse('$kApiBase/api/history'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200) {
          final data = jsonDecode(r.body) as Map<String, dynamic>;
          final rows = (data['items'] as List?) ?? [];
          fresh = rows
              .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
              .toList();
          // Oflayn uchun nusxa.
          RustCore.instance.saveListCache(
              _listKey, fresh.map((e) => e.toJson()).toList());
          _loadedAt = DateTime.now();
        }
      } catch (_) {
        // Pastda diskdagi nusxaga tushamiz.
      }
    }

    if (fresh == null) {
      final cached = RustCore.instance.getCachedList(_listKey);
      if (cached != null) {
        fresh = cached.map(HistoryItem.fromJson).toList();
      }
    }

    if (fresh != null) {
      fresh.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _items = fresh;
      _loadedForUser = userId;
    }
    _loading = false;
    notifyListeners();
  }

  /// Diskdagi nusxani TARMOQSIZ o'qiydi.
  ///
  /// Ilova ochilganda va kirilganda chaqiriladi: bosh sahifadan
  /// anime bosilganda "oxirgi ko'rilgan qism" darhol ma'lum
  /// bo'lishi kerak, buning uchun esa hech qanday so'rov
  /// yubormaymiz (foydalanuvchi talabi: "iloji boricha kamroq
  /// so'rov").
  void loadFromDisk() {
    final userId = AuthService.instance.user?.id ?? 0;
    if (userId == 0) return;
    if (_items.isNotEmpty && _loadedForUser == userId) return;
    try {
      final cached = RustCore.instance.getCachedList(_listKey);
      if (cached == null || cached.isEmpty) return;
      final rows = cached.map(HistoryItem.fromJson).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _items = rows;
      _loadedForUser = userId;
      notifyListeners();
    } catch (_) {
      // Nusxa o'qilmadi — ro'yxat keyin serverdan keladi.
    }
  }

  /// Aniq bir qismning tarixdagi yozuvi (yo'q — `null`).
  HistoryItem? findEpisode(int animeId, int seasonId, int epizodNumber) {
    for (final e in _items) {
      if (e.sameEpisode(animeId, seasonId, epizodNumber)) return e;
    }
    return null;
  }

  /// Shu BO'LIM bo'yicha eng oxirgi ko'rilgan qism (yo'q — `null`).
  ///
  /// Bosh sahifadan anime bosilganda pleyer aynan shu qismni,
  /// aynan to'xtagan joyidan ochadi.
  HistoryItem? lastOfSeason(int animeId, int seasonId) {
    for (final e in _items) {
      if (e.animeId == animeId && e.seasonId == seasonId) return e;
    }
    return null;
  }

  /// Bitta yozuvni o'chiradi (kadr ustida uzoq bosilganda).
  ///
  /// Ro'yxatdan DARHOL yo'qoladi, kadr fayli ham o'chiriladi.
  /// Serverga yuborib bo'lmasa — navbatga tushadi va keyin
  /// yuboriladi, ya'ni yozuv qaytib kelmaydi.
  Future<void> remove(HistoryItem item) async {
    _items = _items
        .where((e) =>
            !e.sameEpisode(item.animeId, item.seasonId, item.epizodNumber))
        .toList();
    _saveDisk();
    notifyListeners();

    _dropThumb(item);

    final row = <String, dynamic>{
      '_op': 'delete',
      'anime_id': item.animeId,
      'season_id': item.seasonId,
      'epizod_number': item.epizodNumber,
    };
    final token = AuthService.instance.sessionToken;
    if (token == null) return;
    try {
      final r = await http
          .delete(
            Uri.parse('$kApiBase/api/history'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(row),
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        _loadedAt = null;
        return;
      }
    } catch (_) {
      // Tarmoq yo'q — pastda navbatga tushadi.
    }
    _queue(row);
  }

  /// Hisobdan chiqilganda tarix ham tozalanadi.
  void clear() {
    _items = [];
    _loadedAt = null;
    _loadedForUser = 0;
    _pending = null;
    notifyListeners();
  }

  // ── ANIME BO'YICHA GURUHLASH ────────────────────────────────

  /// Har bir anime uchun ENG SO'NGGI ko'rilgan qism.
  ///
  /// Ro'yxat allaqachon vaqt bo'yicha saralangan, shu sabab har bir
  /// animening birinchi uchragan yozuvi — eng oxirgisi.
  List<HistoryItem> get byAnime {
    final seen = <int>{};
    final out = <HistoryItem>[];
    for (final it in _items) {
      if (seen.add(it.animeId)) out.add(it);
    }
    return out;
  }

  /// Bitta animening barcha ko'rilgan qismlari (oxirgisi tepada).
  List<HistoryItem> episodesOf(int animeId) =>
      _items.where((e) => e.animeId == animeId).toList();

  // ═══════════════════════════════════════════════════════════
  //  TO'XTAGAN JOYDAGI KADR
  // ═══════════════════════════════════════════════════════════
  //
  // Kadr Rust yadrosidagi "/thumb" yo'lidan olinadi: u faylning
  // faqat KERAKLI baytlarini (moov + bitta kalit kadr) olib,
  // bitta kadrlik MP4 yasab beradi. Android'ning kadr ajratuvchisi
  // esa undan JPEG chiqaradi.
  //
  // Natija diskda SHIFRLANGAN holda saqlanadi (`secureSave`) —
  // ilovaga tegishli barcha fayllar shifrlanadi degan qoida shu
  // rasmlar uchun ham amal qiladi. JPEG ikkilik ma'lumot bo'lgani
  // uchun base64 bilan matnga o'giriladi: yangi FFI qo'shishdan
  // ko'ra arzonroq va 20 KB rasm uchun farqi sezilmaydi.
  //
  // ── NEGA TASHQI PAKET EMAS ────────────────────────────────
  //
  // Avval `video_thumbnail` paketi ishlatilgan edi va u build'ni
  // YIQITDI: paket 2023-yildan beri yangilanmagan, uning Gradle
  // faylida allaqachon yopilgan `jcenter()` ombori va eski DSL
  // turibdi. Uni "tuzatib" ishlatish — har bir Flutter/Gradle
  // yangilanishida qaytadan sinadigan qarz.
  //
  // Kerak bo'lgan ish esa atigi bir necha qator: Android'ning
  // `MediaMetadataRetriever` iga manzilni berish va JPEG olish.
  // Shu sabab u ILOVANING O'ZIDA yozilgan (`MainActivity.kt`,
  // CI tomonidan joylashtiriladi) va bu yerda oddiy kanal orqali
  // chaqiriladi. Tashqi bog'liqlik yo'q, Gradle xavfi yo'q.

  /// Kadr ajratuvchi bilan aloqa kanali (`MainActivity.kt`).
  static const MethodChannel _thumbChannel = MethodChannel('aru/thumb');

  final Map<String, Uint8List> _thumbMemory = {};
  final Map<String, Future<Uint8List?>> _thumbWork = {};

  /// Ayni paytda yasalayotgan kadrlar — bitta kadr uchun ikkita
  /// (ya'ni ikkita tarmoq so'rovi) ketmasin.
  final Set<String> _thumbBuilding = {};
  int _thumbRunning = 0;

  /// Xotiradagi kadrlar soni cheklangan: ro'yxat uzun bo'lsa ham
  /// ilova o'nlab megabaytni ushlab turmasin (har biri ~20 KB).
  static const int _thumbMemoryLimit = 60;

  /// Xotirada tayyor kadr bormi (kutmasdan).
  ///
  /// Tarix qatorlari shu orqali REAL VAQTDA yangilanadi: kadr
  /// tayyor bo'lishi bilan `notifyListeners` chaqiriladi va qator
  /// o'sha zahoti yangi rasmni oladi.
  Uint8List? peekThumb(String key) => _thumbMemory[key];

  void _rememberThumb(String key, Uint8List bytes) {
    if (_thumbMemory.length >= _thumbMemoryLimit) {
      _thumbMemory.remove(_thumbMemory.keys.first);
    }
    _thumbMemory[key] = bytes;
  }

  String? _thumbPath(String key) {
    final dir = RustCore.instance.dataDirPath;
    if (dir == null) return null;
    return '$dir/thumb_$key.rustbin';
  }

  /// Kadrni beradi: avval xotiradan, keyin diskdan, bo'lmasa
  /// yasaydi. Hech qanday holatda xato tashlamaydi — `null`
  /// qaytsa, ro'yxat posterni ko'rsatadi.
  Future<Uint8List?> thumbnail(HistoryItem item) async {
    final key = item.thumbKey;
    final inMemory = _thumbMemory[key];
    if (inMemory != null) return inMemory;

    final running = _thumbWork[key];
    if (running != null) return running;

    final work = _makeThumb(item, key);
    _thumbWork[key] = work;
    try {
      return await work;
    } finally {
      _thumbWork.remove(key);
    }
  }

  Future<Uint8List?> _makeThumb(HistoryItem item, String key) async {
    final path = _thumbPath(key);
    if (path == null) return null;

    // 1) Diskda bormi?
    final saved = RustCore.instance.secureLoad(path, 'thumb:$key');
    if (saved.isNotEmpty) {
      try {
        final bytes = base64Decode(saved);
        _rememberThumb(key, bytes);
        return bytes;
      } catch (_) {
        // Buzilgan — qaytadan yasaymiz.
      }
    }

    if (item.videoUrl.isEmpty || item.positionMs <= 0) return null;

    // 1.5) Shu videoning ESKI kadri bo'lsa — uni darhol
    //      ko'rsatamiz. Oflaynda yangisini yasab bo'lmasligi
    //      mumkin, eski kadr esa posterdan ancha yaxshi.
    final previous = _anyThumbOfVideo(item.videoKey);
    if (previous != null) {
      _rememberThumb(key, previous);
      // Yangisini yasashga baribir urinamiz — tayyor bo'lsa
      // ro'yxat keyingi qurilishda uni oladi.
      if (!_thumbBuilding.contains(key)) {
        unawaited(_buildThumb(item, key));
      }
      return previous;
    }

    return _buildThumb(item, key);
  }

  /// Kadrni HAQIQATAN yasaydi (tarmoq yoki diskdagi bo'laklardan).
  Future<Uint8List?> _buildThumb(HistoryItem item, String key) async {
    final path = _thumbPath(key);
    if (path == null) return null;
    if (!_thumbBuilding.add(key)) return null;

    // Navbat: bir vaqtda ikkitadan ko'p yasalmasin.
    while (_thumbRunning >= _maxParallelThumbs) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    _thumbRunning++;
    try {
      final uri = await VideoCacheServer.instance
          .thumbUri(item.videoUrl, item.positionMs);
      final data = await _thumbChannel.invokeMethod<Uint8List>('grab', {
        'url': uri.toString(),
        'maxWidth': 640,
        'quality': 72,
      }).timeout(const Duration(seconds: 25));
      if (data == null || data.isEmpty) return null;

      _rememberThumb(key, data);
      // Ro'yxat DARHOL yangi kadrga o'tsin (kutib turmasin).
      notifyListeners();
      // Shifrlab saqlaymiz va shu videoning eski kadrlarini
      // o'chiramiz (foydalanuvchi oldinga surgan bo'lsa, eskisi
      // endi noto'g'ri).
      RustCore.instance.secureSave(path, 'thumb:$key', base64Encode(data));
      _removeStaleThumbs(item.videoKey, key);
      return data;
    } catch (_) {
      return null;
    } finally {
      _thumbRunning--;
      _thumbBuilding.remove(key);
    }
  }

  /// Shu videoning diskda saqlangan ISTALGAN kadri.
  ///
  /// Oflayn uchun: yangi nuqtaga kadr yasab bo'lmasa ham, ro'yxatda
  /// posterdan ko'ra o'sha qismning o'z kadri turgani yaxshi.
  Uint8List? _anyThumbOfVideo(String videoKey) {
    final dir = RustCore.instance.dataDirPath;
    if (dir == null) return null;
    try {
      final prefix = 'thumb_${videoKey}_';
      for (final f in Directory(dir).listSync()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        if (!name.startsWith(prefix) || !name.endsWith('.rustbin')) continue;
        final savedKey =
            name.substring('thumb_'.length, name.length - '.rustbin'.length);
        final saved =
            RustCore.instance.secureLoad(f.path, 'thumb:$savedKey');
        if (saved.isEmpty) continue;
        try {
          return base64Decode(saved);
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      // Papkani o'qib bo'lmadi — poster ko'rsatiladi.
    }
    return null;
  }

  /// Kadrni OLDINDAN yasab diskka yozadi.
  ///
  /// Ko'rish tugagan zahoti chaqiriladi. Sababi ikkita:
  ///
  ///   * tarix oynasi ochilganda og'ir ish qolmaydi — ro'yxat
  ///     qotmasdan sirg'aladi (foydalanuvchi shikoyati);
  ///   * oflaynda ham rasm ko'rinadi: qism yuklab olinmagan
  ///     bo'lsa kadr uchun internet kerak, internet esa AYNAN
  ///     ko'rish paytida bor edi.
  Future<void> _prepareThumb(Map<String, dynamic> row) async {
    try {
      final item = HistoryItem.fromJson(row);
      if (item.videoUrl.isEmpty || item.positionMs <= 0) return;
      await thumbnail(item);
    } catch (_) {
      // Kadr yasalmadi — ro'yxat posterni ko'rsatadi.
    }
  }

  /// Yozuv o'chirilganda uning kadri ham kerak emas.
  void _dropThumb(HistoryItem item) {
    _thumbMemory.remove(item.thumbKey);
    final dir = RustCore.instance.dataDirPath;
    if (dir == null) return;
    try {
      final prefix = 'thumb_${item.videoKey}_';
      for (final f in Directory(dir).listSync()) {
        if (f is! File) continue;
        if (f.uri.pathSegments.last.startsWith(prefix)) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _removeStaleThumbs(String videoKey, String keepKey) {
    final dir = RustCore.instance.dataDirPath;
    if (dir == null) return;
    try {
      final prefix = 'thumb_${videoKey}_';
      final keep = 'thumb_$keepKey.rustbin';
      for (final f in Directory(dir).listSync()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        if (name.startsWith(prefix) && name != keep) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {
      // Papkani o'qib bo'lmadi — muhim emas, eski kadr shunchaki
      // joyida qoladi.
    }
  }
}
