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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'rust_bridge.dart';
import 'sync_queue.dart';
import 'video_cache_server.dart';
import 'video_gate.dart';
import 'watch_progress.dart';

/// Tarixdagi bitta qism.
class HistoryItem {
  final int animeId;
  final int seasonId;
  final int bolimId;

  /// Qismning O'ZGARMAS raqami (`epizod_db.epizod_id`).
  ///
  /// ── NEGA KALIT AYNAN SHU (TOPILGAN XATO) ──────────────────
  ///
  /// Ilgari yozuv `epizod_number` bo'yicha saqlanardi. Admin
  /// qism raqamini o'zgartirishi bilan tarixdagi yozuv HECH
  /// QAYSI qismga tegmay qolardi: kadr yangilanmasdi, "davom
  /// ettirish" ishlamasdi — foydalanuvchi buni "tarixdagi
  /// kadrlar qotib qoldi" deb ko'rgan.
  ///
  /// `epizodId` qism qo'shilganda bir marta beriladi va hech
  /// qachon o'zgarmaydi.
  final int epizodId;

  /// Ko'rsatish uchun qism raqami ("3-qism").
  ///
  /// Bazaning tarix jadvalida bunday ustun YO'Q (foydalanuvchi
  /// talabi: "jurnaldan epizod number'ni olib tashla, epizod id
  /// yetadi") — server uni har safar `epizod_db` dan qo'shib
  /// beradi. Ya'ni admin raqamni o'zgartirsa ro'yxatda darhol
  /// yangisi ko'rinadi.
  ///
  /// Diskdagi nusxada esa saqlanadi: oflaynda "N-qism" deb
  /// yozish uchun boshqa manba yo'q.
  final int epizodNumber;
  final String animeName;

  /// Bo'lim (season) nomi — tarix oynalarida AYNAN shu ko'rsatiladi
  /// (foydalanuvchi talabi: "anime nomi emas, bo'lim nomi").
  final String seasonName;
  final String animePhoto;
  final String seasonPhoto;
  final String videoUrl;

  /// Foydalanuvchi shu qismni OXIRGI marta qaysi sifatda ko'rgani
  /// ("720p"). Keyingi safar internet yoqilganda video aynan shu
  /// sifatdan davom etadi (foydalanuvchi talabi).
  final String lastQuality;
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
    required this.epizodId,
    required this.epizodNumber,
    required this.animeName,
    required this.seasonName,
    required this.animePhoto,
    required this.seasonPhoto,
    required this.videoUrl,
    required this.positionMs,
    required this.durationMs,
    this.lastQuality = '',
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

  /// Bir xil qismmi (anime + bo'lim + qism IDsi).
  ///
  /// Solishtirish RAQAM bo'yicha emas, ID bo'yicha — raqam
  /// o'zgarishi mumkin, ID esa yo'q.
  bool sameEpisode(int a, int s, int id) =>
      animeId == a && seasonId == s && epizodId == id;

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
        'epizod_id': epizodId,
        'epizod_number': epizodNumber,
        'anime_name': animeName,
        'season_name': seasonName,
        'anime_photo': animePhoto,
        'season_photo': seasonPhoto,
        'video_url': videoUrl,
        'last_quality': lastQuality,
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
      epizodId: intOf('epizod_id'),
      epizodNumber: intOf('epizod_number'),
      animeName: strOf('anime_name'),
      seasonName: strOf('season_name'),
      animePhoto: strOf('anime_photo'),
      seasonPhoto: strOf('season_photo'),
      videoUrl: strOf('video_url'),
      lastQuality: strOf('last_quality'),
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

  /// Oxirgi yuborilgan holat ("nuqta/ko'rilgan vaqt/sifat").
  ///
  /// `flush()` endi tez-tez chaqiriladi va `_pending` o'chmaydi,
  /// shu sabab AYNAN o'sha holatni qayta yuborib yurmaslik uchun
  /// oxirgisi eslab qolinadi.
  String _flushedStamp = '';

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
    required int epizodId,
    required int epizodNumber,
    required String videoUrl,
    String quality = '',
    int bolimId = 0,
    String animeName = '',
    String seasonName = '',
    String animePhoto = '',
    String seasonPhoto = '',
  }) {
    if (animeId <= 0 || epizodId <= 0) return;
    // Oldingi qism yozuvi hali yuborilmagan bo'lsa — avval o'sha
    // yuboriladi, aks holda u yo'qolib ketardi.
    final prev = _pending;
    if (prev != null &&
        (prev['anime_id'] != animeId ||
            prev['epizod_id'] != epizodId ||
            prev['season_id'] != seasonId)) {
      unawaited(flush());
    }
    // ── TOMOSHA VAQTI DAVOM ETADI ───────────────────────
    //
    // Serverga JAMI vaqt yuboriladi (shu odam shu qismni qancha
    // ko'rgani), shu sabab avvalgi yozuvdan davom etamiz.
    final before = findEpisode(animeId, seasonId, epizodId);

    // ── QAYSI HOLAT "YANGI KO'RISH" ─────────────────────
    //
    // Faqat BOSHQA qism ochilganda. Sifat almashtirilganda yoki
    // pleyer qaytadan ochilganda (xatodan tiklanish) qism
    // O'ZGARMAYDI — u paytda hisob oshmasligi kerak.
    final sameEpisode = prev != null &&
        prev['anime_id'] == animeId &&
        prev['season_id'] == seasonId &&
        prev['epizod_id'] == epizodId;
    if (!sameEpisode) _pendingNewView = true;

    // Sifat almashtirilganda shu seansda yig'ilgan vaqt
    // YO'QOLMASLIGI kerak, shu sabab kattasini olamiz.
    final carried = sameEpisode ? ((prev['watched_ms'] as int?) ?? 0) : 0;
    final saved = before?.watchedMs ?? 0;
    // Yangi yozuv — oldingi "yuborilgan holat" belgisi bekor.
    if (!sameEpisode) _flushedStamp = '';
    // Birinchi oldindan tayyorlash qism ochilganidan 45 soniya
    // keyin bo'lsin (boshidagi nuqtadan kadr yasashning ma'nosi
    // yo'q).
    _lastPrewarm = DateTime.now();
    _pending = {
      'anime_id': animeId,
      'season_id': seasonId,
      'bolim_id': bolimId,
      'epizod_id': epizodId,
      // Serverga BORMAYDI (u raqamni `epizod_db` dan oladi) —
      // faqat diskdagi nusxa va ro'yxat uchun.
      'epizod_number': epizodNumber,
      // Sifat almashtirilsa oxirgisi yoziladi — keyingi safar
      // aynan shundan davom etadi.
      'last_quality': quality,
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

  /// Kadr oxirgi marta qachon OLDINDAN tayyorlangan.
  DateTime _lastPrewarm = DateTime.fromMillisecondsSinceEpoch(0);

  /// Ko'rish davomida kadr shuncha vaqtda bir marta tayyorlanadi.
  static const Duration _prewarmGap = Duration(seconds: 45);

  /// KADRNI KO'RISH DAVOMIDA TAYYORLAB QO'YADI.
  ///
  /// TOPILGAN MUAMMO (foydalanuvchi: "tomosha tarixidagi kadr
  /// yangilanishi juda sekin").
  ///
  /// Sabab: kadr FAQAT pleyerdan chiqqanda yasala boshlardi.
  /// O'shanda esa hamma ish bir joyga to'planardi — mahalliy
  /// serverni ko'tarish, `moov` jadvalini o'qish, kalit kadrni
  /// olish, undan JPEG ajratish. Foydalanuvchi tarixni darhol
  /// ochsa, u yerda hali eski rasm turardi.
  ///
  /// Endi bu ish KO'RISH DAVOMIDA, 45 soniyada bir marta fon'da
  /// bajariladi. Shu sabab pleyerdan chiqqanda:
  ///
  ///   * shu qismning yaqinginadagi kadri ALLAQACHON diskda
  ///     bo'ladi va tarixda DARHOL ko'rinadi;
  ///   * aniq nuqtadagi kadr esa tez yasaladi — `moov` jadvali
  ///     Rust yadrosida hali xotirada turadi.
  ///
  /// Trafik ortmaydi: kerakli baytlar ko'rish paytida allaqachon
  /// keshga tushgan bo'ladi, ya'ni kadr diskdan olinadi.
  void prewarmThumb() {
    final p = _pending;
    if (p == null) return;
    final position = (p['position_ms'] as int?) ?? 0;
    final duration = (p['duration_ms'] as int?) ?? 0;
    if (duration <= 0 || position <= 0) return;
    // Kadr yasash ketayotgan bo'lsa — aralashmaymiz.
    if (_thumbRunning > 0) return;
    final now = DateTime.now();
    if (now.difference(_lastPrewarm) < _prewarmGap) return;
    _lastPrewarm = now;
    // FAQAT KALIT KADR: aniq kadr uchun 8 MB gacha oraliq olinardi
    // va u ijro bilan bitta kanalni bo'lishib, videoni
    // sekinlashtirardi. Aniq kadr pleyer yopilgach yasaladi.
    unawaited(_prepareThumb(Map<String, dynamic>.from(p), exact: false));
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
  ///
  /// ── TOPILGAN XATO: YOZUV BIR MARTADAN KEYIN O'LIB QOLARDI ──
  ///
  /// Foydalanuvchi: "tomosha tarixidagi kadr yangilanishi ba'zida
  /// ishlamay qolyabdi".
  ///
  /// Sabab shu yerda edi: `flush()` yuborgandan keyin `_pending`
  /// NI TOZALAB YUBORARDI. Bu esa faqat pleyerdan chiqishda emas,
  /// ILOVA FONGA KETGANDA ham chaqiriladi (`didChangeAppLifecycle`).
  /// Ya'ni odam ko'rish o'rtasida boshqa ilovaga chiqib qaytsa:
  ///
  ///   * `_pending` null bo'lib qolardi;
  ///   * `note()` (har soniya keladigan nuqta) JIMGINA tashlanardi;
  ///   * pleyerdan chiqqanda `flush()` "yuboradigan narsa yo'q" deb
  ///     darhol qaytardi.
  ///
  /// Natijada tarixda na to'xtagan joy, na kadr yangilanardi —
  /// yozuv fonga chiqqan lahzadagi holatda qotib qolardi.
  ///
  /// Endi `_pending` YASHAB QOLADI: u faqat `startEpisode` boshqa
  /// qismni ochganda almashadi. `flush()` esa istalgancha marta
  /// chaqirilishi mumkin — har safar o'sha damdagi holatni
  /// yuboradi.
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
    // Hali chegaraga yetmagan — yozuv KUTIB TURADI (yo'q
    // qilinmaydi: ko'rish davom etsa chegaradan o'tadi).
    if (duration <= 0 || position < minMs) return;

    // ── AYNAN O'SHA HOLAT IKKINCHI MARTA YUBORILMAYDI ───────
    //
    // `flush()` endi tez-tez chaqiriladi (fonga chiqish, qism
    // almashish, chiqish). Holat o'zgarmagan bo'lsa serverga ham,
    // ro'yxatga ham tegishning hojati yo'q.
    final watched = (p['watched_ms'] as int?) ?? 0;
    final stamp = '$position/$watched/${p['last_quality']}';
    if (!_pendingNewView && stamp == _flushedStamp) return;
    _flushedStamp = stamp;

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
    // 3) Va nihoyat navbatga — serverga keyin, paket bilan ketadi.
    SyncQueue.instance.putHistory(row);
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
    final epizodId = intOf('epizod_id');
    if (animeId <= 0 || epizodId <= 0) return;

    final list = List<HistoryItem>.from(_items);
    final at =
        list.indexWhere((e) => e.sameEpisode(animeId, seasonId, epizodId));
    // Eski yozuvdagi ma'lumot (nom, rasm) yo'qolmasin: pleyer
    // ularning hammasini bilmasligi mumkin.
    final old = at >= 0 ? list[at] : _anyOf(animeId, seasonId);
    String pick(String fresh, String? saved) =>
        fresh.isNotEmpty ? fresh : (saved ?? '');

    final item = HistoryItem(
      animeId: animeId,
      seasonId: seasonId,
      bolimId: intOf('bolim_id') > 0 ? intOf('bolim_id') : (old?.bolimId ?? 0),
      epizodId: epizodId,
      epizodNumber:
          intOf('epizod_number') > 0 ? intOf('epizod_number') : (old?.epizodNumber ?? 0),
      animeName: pick(strOf('anime_name'), old?.animeName),
      seasonName: pick(strOf('season_name'), old?.seasonName),
      animePhoto: pick(strOf('anime_photo'), old?.animePhoto),
      seasonPhoto: pick(strOf('season_photo'), old?.seasonPhoto),
      videoUrl: pick(strOf('video_url'), old?.videoUrl),
      lastQuality: pick(strOf('last_quality'), old?.lastQuality),
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
  //
  // YOZUV SERVERGA DARHOL BORMAYDI. U `SyncQueue` navbatiga
  // tushadi va bir necha soatda bir marta, boshqa yozuvlar bilan
  // BIRGA, bitta paket bo'lib yuboriladi.
  //
  // NEGA (foydalanuvchi talabi va hisob-kitob): Turso har bir
  // yozilgan qator uchun pul oladi. Bitta qism ko'rilganda 7 ta
  // qator yozilardi; endi paket ichida hammasi jamlanadi va
  // kunlik so'rov 2-4 taga tushadi. Batafsil — `sync_queue.dart`.
  //
  // Mahalliy ro'yxat (`_applyLocal`) DARHOL yangilanadi, ya'ni
  // ekranda hech narsa kutilmaydi.

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
    // hozirgina ko'rgan qismini serverdagi ro'yxatda ko'rmasdi.
    // Shartlar bajarilmagan bo'lsa hech narsa yuborilmaydi; ekranda
    // baribir MAHALLIY ro'yxat ko'rinadi, ya'ni yozuv yo'qolmaydi.
    await SyncQueue.instance.maybeFlush('ochilish');

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
          _loadedAt = DateTime.now();
        }
      } catch (_) {
        // Pastda diskdagi nusxaga tushamiz.
      }
    }

    if (fresh == null) {
      final cached = RustCore.instance.getCachedList(_listKey);
      if (cached != null) {
        fresh = _fromRows(cached);
      }
    }

    if (fresh != null) {
      fresh = _mergeLocal(fresh);
      fresh.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _items = fresh;
      _loadedForUser = userId;
      // Oflayn uchun nusxa — navbat qo'shilgandan KEYIN, aks holda
      // yuborilmagan yozuvlar diskdan ham yo'qolardi.
      _saveDisk();
      // Kadrlar fon'da xotiraga ko'chiriladi — ro'yxat ochilganda
      // ular allaqachon tayyor bo'ladi.
      unawaited(_warmThumbs());
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
      final rows = _fromRows(cached)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (rows.isEmpty) return;
      _items = rows;
      _loadedForUser = userId;
      unawaited(_warmThumbs());
      notifyListeners();
    } catch (_) {
      // Nusxa o'qilmadi — ro'yxat keyin serverdan keladi.
    }
  }

  /// Server ro'yxatining ustiga YUBORILMAGAN o'zgarishlarni
  /// qo'yadi.
  ///
  /// TOPILISHI MUMKIN BO'LGAN XATO: yozuvlar endi navbatda turadi
  /// va serverda hali yo'q. Server javobini shundayligicha olsak,
  /// foydalanuvchi hozirgina ko'rgan qismi (yoki o'chirgan yozuvi)
  /// ro'yxat yangilangan zahoti qaytib kelardi/yo'qolardi.
  List<HistoryItem> _mergeLocal(List<HistoryItem> server) {
    final pend = SyncQueue.instance.pendingHistory();
    if (pend.isEmpty) return server;
    String keyOf(HistoryItem e) => '${e.animeId}:${e.seasonId}:${e.epizodId}';
    HistoryItem? localOf(String k) {
      for (final e in _items) {
        if (keyOf(e) == k) return e;
      }
      return null;
    }

    final out = <HistoryItem>[];
    for (final e in server) {
      final op = pend[keyOf(e)];
      if (op == true) continue; // yashirilgan
      out.add(op == false ? (localOf(keyOf(e)) ?? e) : e);
    }
    // Serverda hali umuman yo'q, faqat telefonda turgan yozuvlar.
    pend.forEach((k, hidden) {
      if (hidden) return;
      if (out.any((e) => keyOf(e) == k)) return;
      final local = localOf(k);
      if (local != null) out.add(local);
    });
    return out;
  }

  /// Diskdagi qatorlardan ro'yxat yasaydi.
  ///
  /// ── ESKI YOZUVLAR TASHLANADI ───────────────────────────────
  ///
  /// Tarix endi `epizod_id` bo'yicha saqlanadi. Ilovaning eski
  /// versiyasi yozgan qatorlarda bu maydon yo'q (ya'ni 0) —
  /// ularni qoldirsak hammasi BITTA kalitga (0) tushib,
  /// bir-birining ustiga yozilardi. Server tomonidagi tarix
  /// baribir yangi kalit bilan qaytadan to'ldiriladi, shu sabab
  /// bunday qatorlar shunchaki o'tkazib yuboriladi.
  List<HistoryItem> _fromRows(List<Map<String, dynamic>> rows) {
    final out = <HistoryItem>[];
    for (final r in rows) {
      final item = HistoryItem.fromJson(r);
      if (item.epizodId > 0) out.add(item);
    }
    return out;
  }

  /// Shu qism oxirgi marta qaysi sifatda ko'rilgan ('' — noma'lum).
  ///
  /// Pleyer video ochishdan oldin shu yerdan so'raydi: foydalanuvchi
  /// oxirgi marta 720p ko'rgan bo'lsa, keyingi safar ham 720p
  /// ochiladi (foydalanuvchi talabi).
  String qualityOf(int animeId, int seasonId, int epizodId) =>
      findEpisode(animeId, seasonId, epizodId)?.lastQuality ?? '';

  /// Aniq bir qismning tarixdagi yozuvi (yo'q — `null`).
  ///
  /// Qism RAQAMI bilan emas, o'zgarmas `epizodId` bilan izlanadi.
  HistoryItem? findEpisode(int animeId, int seasonId, int epizodId) {
    for (final e in _items) {
      if (e.sameEpisode(animeId, seasonId, epizodId)) return e;
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
            !e.sameEpisode(item.animeId, item.seasonId, item.epizodId))
        .toList();
    _saveDisk();
    notifyListeners();

    _dropThumb(item);

    // Serverda yozuv O'CHIRILMAYDI, faqat yashiriladi — qism
    // keyin qayta ko'rilsa yana ro'yxatga chiqadi.
    SyncQueue.instance
        .hideHistory(item.animeId, item.seasonId, item.epizodId);
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

  /// VAQTINCHA kadrlar: shu videoning boshqa nuqtasidagi eski
  /// rasmi, haqiqiysi tayyor bo'lgunicha ko'rsatib turish uchun.
  ///
  /// ── NEGA ALOHIDA SAQLANADI (TOPILGAN XATO) ────────────────
  ///
  /// Foydalanuvchi: "tomosha tarixidagi kadr yangilanishi juda
  /// sekin va ba'zida ishlamay qolyabdi".
  ///
  /// Ilgari eski rasm YANGI kalit bilan `_thumbMemory` ga
  /// yozilardi. Shundan keyin:
  ///
  ///   * `peekThumb` "kadr tayyor" deb o'sha ESKI rasmni berardi;
  ///   * `thumbnail()` xotiradan topib, DARHOL qaytarardi;
  ///   * ya'ni haqiqiy kadrni yasash boshqa HECH QACHON
  ///     takrorlanmasdi — bir marta yasalmay qolsa (internet
  ///     uzildi, kanal javob bermadi), o'sha eski rasm butunlay
  ///     qotib qolardi.
  ///
  /// Endi vaqtinchalik rasm ALOHIDA turadi: ekranda darhol
  /// ko'rinadi, lekin "kadr tayyor" deb hisoblanmaydi va haqiqiysi
  /// yasalishda davom etadi (kerak bo'lsa qaytadan urinib).
  final Map<String, Uint8List> _thumbFallback = {};

  /// Xotirada tayyor kadr bormi (kutmasdan).
  ///
  /// Tarix qatorlari shu orqali REAL VAQTDA yangilanadi: kadr
  /// tayyor bo'lishi bilan `notifyListeners` chaqiriladi va qator
  /// o'sha zahoti yangi rasmni oladi.
  ///
  /// Haqiqiy kadr bo'lmasa vaqtinchasi beriladi — bo'sh joy
  /// ko'rinib turgandan ko'ra shu yaxshi.
  Uint8List? peekThumb(String key) => _thumbMemory[key] ?? _thumbFallback[key];

  /// HAQIQIY (aniq) kadr tayyormi — vaqtinchasi hisoblanmaydi.
  bool hasThumb(String key) =>
      _thumbMemory.containsKey(key) && !_roughKeys.contains(key);

  /// Taxminiy kadrlar: ko'rish davomida olingan KALIT KADR
  /// (`prewarmThumb`). Ular ekranda ko'rinadi, lekin aniq kadr
  /// so'ralganda qaytadan yasaladi.
  final Set<String> _roughKeys = {};

  /// Oxirgi muvaffaqiyatsiz urinish vaqti — qator qayta-qayta
  /// so'rab tarmoqni band qilmasin.
  final Map<String, DateTime> _thumbFailedAt = {};
  static const Duration _thumbRetryAfter = Duration(seconds: 20);

  /// Kadr hali yo'q (yoki faqat vaqtinchasi bor) bo'lsa — yasashni
  /// boshlaydi.
  ///
  /// TOPILGAN XATO (foydalanuvchi: "tarixdagi kadrlar sekin
  /// yangilanyapti"): qatorda VAQTINCHA (eski nuqtadagi) rasm
  /// turgan bo'lsa, qator uni "tayyor" deb hisoblab, haqiqiy
  /// kadrni boshqa so'ramasdi. Bitta urinish yiqilsa, eski rasm
  /// ro'yxat qayta ochilguncha qotib qolardi.
  void ensureThumb(HistoryItem item) {
    final key = item.thumbKey;
    if (hasThumb(key) || _thumbWork.containsKey(key)) return;
    final failed = _thumbFailedAt[key];
    if (failed != null &&
        DateTime.now().difference(failed) < _thumbRetryAfter) {
      return;
    }
    unawaited(thumbnail(item));
  }

  void _rememberFallback(String key, Uint8List bytes) {
    if (_thumbFallback.length >= _thumbMemoryLimit) {
      _thumbFallback.remove(_thumbFallback.keys.first);
    }
    _thumbFallback[key] = bytes;
  }

  void _rememberThumb(String key, Uint8List bytes) {
    if (_thumbMemory.length >= _thumbMemoryLimit) {
      _thumbMemory.remove(_thumbMemory.keys.first);
    }
    _thumbMemory[key] = bytes;
    // Haqiqiysi keldi — vaqtinchasi endi kerak emas.
    _thumbFallback.remove(key);
    _thumbFailedAt.remove(key);
  }

  String? _thumbPath(String key) {
    final dir = RustCore.instance.dataDirPath;
    if (dir == null) return null;
    return '$dir/thumb_$key.rustbin';
  }

  // ══════════════════════════════════════════════════════════
  //  KADRLAR OLDINDAN XOTIRAGA OLINADI
  // ══════════════════════════════════════════════════════════
  //
  // Ikki xato ketma-ket tuzatildi va yechim AYNAN shu:
  //
  // 1) "Anime bo'yicha oynasidan Qism bo'yicha oynasiga surib
  //    o'tkazganda birozga qotib turib keyin o'tyabdi."
  //
  //    Sabab: qo'shni oyna surish boshlangan zahoti quriladi
  //    (`allowImplicitScrolling`) va o'sha damda ro'yxatdagi har
  //    bir qator kadr so'rardi. Kadr esa diskdan SINXRON o'qilib
  //    shifri ochilardi (`secureLoad` — FFI), ya'ni bu ish UI
  //    oqimida, aynan surish boshlangan kadrda bajarilardi.
  //
  // 2) Birinchi yechim — surish davom etayotganda kadr
  //    so'rovlarini KUTDIRISH — qotishni oldini oldi, lekin
  //    rasmlar KECHIKIB chiqadigan bo'ldi ("juda sekin
  //    yangilanyapti"). Chunki kutish barmoq ko'tarilgunicha
  //    (fling bilan bir-ikki soniya) davom etardi.
  //
  // ── HOZIRGI YECHIM: KUTISH YO'Q, OLDINDAN TAYYOR ──────────
  //
  // Ro'yxat o'qilishi bilan diskdagi kadrlar FON'DA xotiraga
  // ko'chiriladi (`_warmThumbs`) — har bir fayldan keyin kadrga
  // yo'l beriladi, ya'ni UI qotmaydi. Ro'yxat qurilganda esa
  // qatorlar kadrni XOTIRADAN oladi (`peekThumb`) — na disk, na
  // kutish, ya'ni rasm o'sha zahoti chiqadi.
  //
  // Shu sabab surish paytidagi qulf endi KERAK EMAS va olib
  // tashlandi: qulf bo'lmasa ham surish silliq, chunki surish
  // paytida bajariladigan ish umuman qolmadi.

  /// Xotiraga ko'chirish ketyaptimi (ikki marta boshlanmasin).
  bool _warming = false;

  /// Diskdagi kadrlarni fon'da xotiraga ko'chiradi.
  ///
  /// Ro'yxat o'zgargan sayin chaqiriladi; allaqachon xotirada
  /// bo'lganlari o'tkazib yuboriladi, ya'ni takroriy chaqiruv
  /// arzon.
  Future<void> _warmThumbs() async {
    if (_warming) return;
    _warming = true;
    try {
      var added = 0;
      // Ro'yxat ish davomida o'zgarishi mumkin — nusxa olamiz.
      for (final item in List<HistoryItem>.from(_items)) {
        final key = item.thumbKey;
        if (_thumbMemory.containsKey(key)) continue;
        final path = _thumbPath(key);
        if (path == null) continue;
        // Har bir fayldan OLDIN kadrga yo'l beramiz: o'qish
        // sinxron (FFI + shifr ochish), ya'ni bir yo'la o'nlab
        // fayl o'qilsa ekran qotardi.
        await Future<void>.delayed(Duration.zero);
        try {
          final saved = RustCore.instance.secureLoad(path, 'thumb:$key');
          if (saved.isEmpty) continue;
          _rememberThumb(key, base64Decode(saved));
          added++;
          // Har bir kadr tayyor bo'lishi bilan ro'yxat
          // yangilanadi — foydalanuvchi kutib turmaydi.
          notifyListeners();
        } catch (_) {
          // Buzilgan yozuv — qator posterni ko'rsatadi.
        }
      }
      if (added > 0) notifyListeners();
    } finally {
      _warming = false;
    }
  }

  /// Kadrni beradi: avval xotiradan, keyin diskdan, bo'lmasa
  /// yasaydi. Hech qanday holatda xato tashlamaydi — `null`
  /// qaytsa, ro'yxat posterni ko'rsatadi.
  Future<Uint8List?> thumbnail(HistoryItem item, {bool exact = true}) async {
    final key = item.thumbKey;
    // FAQAT haqiqiy kadr ishni to'xtatadi: vaqtinchasi turgan
    // bo'lsa ham yasash davom etishi kerak. Taxminiy (kalit) kadr
    // esa aniq kadr so'ralganda qaytadan yasaladi.
    final inMemory = _thumbMemory[key];
    if (inMemory != null && (!exact || !_roughKeys.contains(key))) {
      return inMemory;
    }

    final running = _thumbWork[key];
    if (running != null) return running;

    final work = _makeThumb(item, key, exact);
    _thumbWork[key] = work;
    try {
      final data = await work;
      if (data == null) _thumbFailedAt[key] = DateTime.now();
      return data;
    } finally {
      _thumbWork.remove(key);
    }
  }

  Future<Uint8List?> _makeThumb(
      HistoryItem item, String key, bool exact) async {
    final path = _thumbPath(key);
    if (path == null) return null;

    // ── DISKKA QURILISH PAYTIDA CHIQILMAYDI ──────────────────
    //
    // Bu metod ro'yxat qurilayotganda (`initState` -> `_load`)
    // chaqiriladi. Birinchi `await` gacha bo'lgan hamma narsa
    // SHU ZAHOTI, o'sha kadrning ichida bajariladi — pastdagi
    // sinxron `secureLoad` esa aynan shu yerda qotishga olib
    // kelardi. Shu sabab avval kadr yakunlanadi, keyin diskka
    // chiqiladi.
    //
    // Bu bitta kadrlik kechikish, xolos: kadrlarning KO'PCHILIGI
    // bu yergacha yetib kelmaydi — ular allaqachon xotirada
    // bo'ladi (`_warmThumbs`).
    await Future<void>.delayed(Duration.zero);

    // 1) Diskda bormi? (Taxminiy kadr diskda bo'lsa ham aniq
    //    kadr so'ralganda qaytadan yasaladi.)
    final saved = _roughKeys.contains(key) && exact
        ? ''
        : RustCore.instance.secureLoad(path, 'thumb:$key');
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
      // MUHIM: VAQTINCHA javonga — `_thumbMemory` ga EMAS
      // (`_thumbFallback` izohiga qarang). Aks holda haqiqiy kadr
      // boshqa hech qachon yasalmasdi.
      _rememberFallback(key, previous);
      // Yangisini yasash FON'DA davom etadi — tayyor bo'lishi
      // bilan ro'yxat o'zi yangilanadi (`notifyListeners`).
      if (!_thumbBuilding.contains(key)) {
        unawaited(_buildThumb(item, key, exact));
      }
      return previous;
    }

    return _buildThumb(item, key, exact);
  }

  /// Bitta kadr uchun eng ko'pi shuncha marta urinib ko'riladi.
  ///
  /// TOPILGAN XATO (foydalanuvchi: "kadr ba'zida yangilanmay
  /// qolyabdi"): urinish BITTA edi. Kadr yasash mahalliy serverni
  /// ishga tushirishni va faylning bir necha yuz kilobaytini
  /// o'qishni talab qiladi — pleyerdan chiqqan lahzada (tarmoq
  /// almashayotgan, server hali ko'tarilayotgan payt) bu urinish
  /// oson uzilardi va rasm o'sha holicha eski qolib ketardi.
  static const int _thumbTries = 3;

  /// Kadrni HAQIQATAN yasaydi (tarmoq yoki diskdagi bo'laklardan).
  Future<Uint8List?> _buildThumb(
      HistoryItem item, String key, bool exact) async {
    final path = _thumbPath(key);
    if (path == null) return null;
    if (!_thumbBuilding.add(key)) return null;
    try {
      // Taxminiy kadr bitta urinish bilan cheklanadi — u ijro
      // paytida ishlaydi va takror urinish kanalni band qiladi.
      final tries = exact ? _thumbTries : 1;
      for (var attempt = 1; attempt <= tries; attempt++) {
        final data = await _grabThumb(item, exact);
        if (data != null) {
          _rememberThumb(key, data);
          if (exact) {
            _roughKeys.remove(key);
          } else {
            _roughKeys.add(key);
          }
          // Ro'yxat DARHOL yangi kadrga o'tsin (kutib turmasin).
          notifyListeners();
          // Shifrlab saqlaymiz va shu videoning eski kadrlarini
          // o'chiramiz (foydalanuvchi oldinga surgan bo'lsa,
          // eskisi endi noto'g'ri).
          RustCore.instance.secureSave(path, 'thumb:$key', base64Encode(data));
          _removeStaleThumbs(item.videoKey, key);
          return data;
        }
        if (attempt < tries) {
          await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
      return null;
    } finally {
      _thumbBuilding.remove(key);
    }
  }

  /// BITTA urinish: mahalliy serverdan kadr olib, JPEG qaytaradi.
  ///
  /// Navbat AYNAN shu yerda: bir vaqtda ikkitadan ko'p kadr
  /// yasalmasin. Urinishlar orasidagi tanaffusda navbat BAND
  /// QILINMAYDI — aks holda bitta muvaffaqiyatsiz kadr qolgan
  /// qatorlarni ushlab turardi.
  Future<Uint8List?> _grabThumb(HistoryItem item, bool exact) async {
    // ── VIDEO OCHIQ TURGANDA ANIQ KADR YASALMAYDI ───────────
    //
    // TOPILGAN XATO (foydalanuvchi: "pleyer va yozishmadagi video
    // judayam sekin ochilyapti, ba'zida ochilmay qolyapti").
    //
    // Aniq kadr uchun faylning bir necha megabayti olinadi.
    // Qism almashganda, ilova fonga chiqqanda yoki tarixdan
    // qism ochilganda bu ish AYNAN pleyer ochilayotgan lahzada
    // boshlanardi va ExoPlayer bilan bitta tor kanalni bo'lishardi.
    // Yozishmadagi kadrlar allaqachon shu qoidaga bo'ysunadi
    // (`VideoGate`) — endi tarix kadrlari ham kutadi. Pleyer
    // yopilishi bilan kadr darhol yasaladi.
    //
    // Taxminiy (kalit) kadr kutmaydi: u bitta kichik o'qish va
    // aynan ko'rish davomida olinishi kerak.
    if (exact) {
      while (VideoGate.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    while (_thumbRunning >= _maxParallelThumbs) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    _thumbRunning++;
    try {
      final uri = await VideoCacheServer.instance
          .thumbUri(item.videoUrl, item.positionMs, exact: exact);
      final data = await _thumbChannel.invokeMethod<Uint8List>('grab', {
        'url': uri.toString(),
        'maxWidth': 640,
        'quality': 72,
      }).timeout(const Duration(seconds: 25));
      if (data == null || data.isEmpty) return null;
      return data;
    } catch (_) {
      // Urinish uzildi — yuqorida yana bir marta sinaladi.
      return null;
    } finally {
      _thumbRunning--;
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
  Future<void> _prepareThumb(Map<String, dynamic> row,
      {bool exact = true}) async {
    try {
      final item = HistoryItem.fromJson(row);
      if (item.videoUrl.isEmpty || item.positionMs <= 0) return;
      await thumbnail(item, exact: exact);
    } catch (_) {
      // Kadr yasalmadi — ro'yxat posterni ko'rsatadi.
    }
  }

  /// Yozuv o'chirilganda uning kadri ham kerak emas.
  void _dropThumb(HistoryItem item) {
    _thumbMemory.remove(item.thumbKey);
    _thumbFallback.remove(item.thumbKey);
    _roughKeys.remove(item.thumbKey);
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
