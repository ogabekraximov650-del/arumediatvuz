// lib/services/sync_queue.dart — YAGONA YOZUV NAVBATI.
//
// ═══════════════════════════════════════════════════════════════
//  NEGA BU FAYL BOR
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "barcha yozish va tahrirlash so'rovlari
// qurilmaning o'zida qilinadi va bir necha marta bitta paket
// bo'lib Turso'ga yuboriladi; bitta foydalanuvchining kunlik
// yozish so'rovlari 50 tadan oshmasligi kerak".
//
// Sabab — pul. Turso har bir YOZILGAN QATOR uchun to'lov oladi.
// Eski tartibda bitta qism ko'rilganda 7 ta qator yozilardi
// (tarix + epizod + bo'lim + 4 ta statistika chelagi), ustiga
// `sessions_db.last_seen_at` har 60 soniyada bir marta. Bitta
// faol odam kuniga ~149 qator; 100 ming odamda oyiga ~420
// million qator, ya'ni $250 dan oshiq. Endi hammasi telefonda
// yig'iladi va siqiladi: kuniga ~15 qator va 2-4 ta so'rov.
//
// ═══════════════════════════════════════════════════════════════
//  UCHTA QOIDA
// ═══════════════════════════════════════════════════════════════
//
// 1. HAMMA YOZUV AVVAL TELEFONDA. Ekranda o'zgarish DARHOL
//    ko'rinadi (ro'yxatlar mahalliy nusxadan chiziladi), serverga
//    esa keyin xabar beriladi.
//
// 2. NAVBAT SIQILADI. Har bir yozuvning `key` si bor. O'sha kalit
//    navbatda allaqachon bo'lsa, eskisi ALMASHTIRILADI. Ya'ni bir
//    qismni 50 marta ko'rgan odam ham navbatda bitta qator
//    qoldiradi.
//
//    Ikki xil maydon bor va ular HAR XIL siqiladi:
//      * holat maydonlari (pozitsiya, sifat, baho, sevimli) —
//        oxirgisi o'rnini bosadi;
//      * "birinchi ko'rish" belgisi — YO'QOLMAYDI (`||`), aks
//        holda ko'rishlar hisobi kam chiqardi.
//    Tomosha vaqti (`watched_ms`) esa JAMI qiymat sifatida
//    yuboriladi (`WatchHistory` uni eski yozuvdan davom
//    ettiradi), farqni server o'zi hisoblaydi.
//
// 3. YUBORISH SHARTLARI + QAT'IY KUNLIK CHEGARA. Quyidagilarning
//    qaysi biri avval kelsa (`_maybeFlush`), lekin kuniga eng
//    ko'pi `_normalPerDay` marta.
//
// ═══════════════════════════════════════════════════════════════
//  MA'LUMOT YO'QOLMASLIGI
// ═══════════════════════════════════════════════════════════════
//
// Navbat DISKDA (shifrlangan) yotadi va hisobga tegishli
// papkada saqlanadi. Ilova yopilsa, telefon o'chsa yoki internet
// bo'lmasa — yozuvlar joyida qoladi va keyingi imkoniyatda
// yuboriladi. Sof "kuniga bir marta" tartibida bir kunlik tarix
// yo'qolishi mumkin edi; shu sabab qo'shimcha shartlar bor.
//
// ═══════════════════════════════════════════════════════════════
//  IKKI MARTA SANALMASLIK
// ═══════════════════════════════════════════════════════════════
//
// Har bir paketda bir martalik `batch_id` bo'ladi. Javob yo'lda
// yo'qolib, ilova paketni qayta yuborsa, worker uni tanib oladi
// va hech narsa yozmaydi. Bu MUHIM: ko'rishlar soni va tomosha
// vaqti QO'SHILADIGAN raqamlar.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'rust_bridge.dart';
import 'stats_service.dart';
import 'traffic_service.dart';

/// Navbatdagi yozuv turlari.
class SyncKind {
  const SyncKind._();
  static const String history = 'history';
  static const String rating = 'rating';
  static const String favorite = 'favorite';
}

/// Sinxronlash natijasi — chiqish oynasidagi xabar shunga qarab
/// tanlanadi.
enum SyncResult {
  /// Hammasi yuborildi (yoki yuboradigan narsa yo'q edi).
  done,

  /// Internet yo'q yoki server javob bermadi — navbat joyida
  /// qoldi va keyingi imkoniyatda yuboriladi.
  offline,

  /// Hisobga kirilmagan — yuboriladigan joy yo'q.
  noAccount,
}

class SyncQueue extends ChangeNotifier with WidgetsBindingObserver {
  SyncQueue._();
  static final SyncQueue instance = SyncQueue._();

  /// `main()` da bir marta chaqiriladi: ilova fonga ketishi va
  /// qaytishini kuzatib boradi.
  void start() {
    load();
    WidgetsBinding.instance.addObserver(this);
    unawaited(maybeFlush('ochilish'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // MUHIM: `inactive` HISOBGA OLINMAYDI. Android bildirishnoma
    // pardasi tushirilganda ham shuni yuboradi — ilova fonga
    // KETMAYDI. (Bir marta shu sabab pleyer pauza bo'lib qolgan
    // edi, o'sha xato bu yerda takrorlanmasin.)
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      onBackground();
    } else if (state == AppLifecycleState.resumed) {
      onResume();
    }
  }

  // ── DISKDAGI KALITLAR ───────────────────────────────────────

  /// Navbatning o'zi.
  static const String _queueKey = 'sync_queue';

  /// Kunlik hisoblagich va oxirgi yuborish vaqti.
  static const String _stateKey = 'sync_state';

  // ── CHEGARALAR ──────────────────────────────────────────────

  /// Oddiy (shartlar bo'yicha) yuborishlar soni — kuniga.
  static const int normalPerDay = 12;

  /// Umumiy qat'iy chegara — majburiy yuborishlar bilan birga.
  /// Foydalanuvchi qo'ygan shart: kuniga 50 tadan oshmasin.
  static const int hardPerDay = 50;

  /// Navbat shuncha qatorga yetsa — kutilmaydi, yuboriladi.
  static const int rowsTrigger = 20;

  /// Bitta paketda yuboriladigan eng ko'p qator (worker ham shu
  /// chegarani biladi). Qolgani keyingi paketga qoladi.
  static const int maxRowsPerBatch = 150;

  /// Navbat bundan uzun bo'lib ketmaydi — eng eskisi tashlanadi.
  /// (Bunga yetish uchun bir necha hafta internetsiz yurish kerak.)
  static const int maxQueueRows = 1000;

  /// Ilova fonga ketganda: oxirgi yuborishdan shuncha o'tgan bo'lsa.
  static const Duration _bgAfter = Duration(minutes: 30);

  /// Ilova ochilganda: oxirgi yuborishdan shuncha o'tgan bo'lsa.
  static const Duration _openAfter = Duration(hours: 6);

  /// Har holda shu muddatda bir marta yuboriladi.
  static const Duration _atLeastEvery = Duration(hours: 24);

  // ── HOLAT ───────────────────────────────────────────────────

  final List<Map<String, dynamic>> _rows = [];
  int _sentToday = 0;
  String _day = '';
  int _lastSentAt = 0;
  bool _sending = false;
  bool _loaded = false;

  /// Yuborilmagan yozuvlar soni (ekranda ko'rsatish uchun).
  int get pendingCount => _rows.length;

  /// Hozir yuborilyaptimi.
  bool get isSending => _sending;

  /// Bugun nechta paket ketdi.
  int get sentToday => _sentToday;

  // ── DISK ────────────────────────────────────────────────────

  void load() {
    if (_loaded) return;
    _loaded = true;
    _read();
  }

  void _read() {
    _rows.clear();
    try {
      final q = RustCore.instance.getCachedList(_queueKey);
      if (q != null) {
        for (final e in q) {
          if (e['key'] is String && e['kind'] is String) _rows.add(e);
        }
      }
    } catch (_) {
      // Navbat o'qilmadi — bo'sh navbat bilan davom etamiz.
      // Mahalliy ro'yxatlar joyida, ya'ni ekranda hech narsa
      // yo'qolmaydi.
    }
    try {
      final st = RustCore.instance.getCachedList(_stateKey);
      if (st != null && st.isNotEmpty) {
        final m = st.first;
        _day = (m['day'] as String?) ?? '';
        _sentToday = (m['sent'] as num?)?.toInt() ?? 0;
        _lastSentAt = (m['last_at'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
  }

  void _saveQueue() {
    try {
      RustCore.instance.saveListCache(_queueKey, _rows);
    } catch (_) {}
  }

  void _saveState() {
    try {
      RustCore.instance.saveListCache(_stateKey, [
        {'day': _day, 'sent': _sentToday, 'last_at': _lastSentAt}
      ]);
    } catch (_) {}
  }

  /// Mahalliy yarim tunda hisoblagich nolga tushadi.
  void _rollDay() {
    final now = DateTime.now();
    final today = '${now.year}-${now.month}-${now.day}';
    if (_day != today) {
      _day = today;
      _sentToday = 0;
      _saveState();
    }
  }

  // ── NAVBATGA QO'SHISH ───────────────────────────────────────

  void _put(String kind, String key, Map<String, dynamic> data,
      {String op = 'set'}) {
    load();
    final at = DateTime.now().millisecondsSinceEpoch;
    _rows.removeWhere((e) => e['key'] == key);
    _rows.add({'kind': kind, 'key': key, 'op': op, 'at': at, 'data': data});
    // Chegaradan oshsa eng eskisi tashlanadi — yangi yozuv har
    // doim eskisidan qimmatliroq.
    while (_rows.length > maxQueueRows) {
      _rows.removeAt(0);
    }
    _saveQueue();
    notifyListeners();
    unawaited(maybeFlush('yozuv'));
  }

  Map<String, dynamic>? _find(String key) {
    for (final e in _rows) {
      if (e['key'] == key) return e;
    }
    return null;
  }

  /// Tomosha tarixi yozuvi (yoki uni yangilash).
  ///
  /// `row` — `WatchHistory` tayyorlagan qator. Bu yerdan serverga
  /// faqat kerakli maydonlar ketadi (anime nomi, posteri va qism
  /// raqami serverda allaqachon bor).
  void putHistory(Map<String, dynamic> row) {
    final a = (row['anime_id'] as num?)?.toInt() ?? 0;
    final s = (row['season_id'] as num?)?.toInt() ?? 0;
    final e = (row['epizod_id'] as num?)?.toInt() ?? 0;
    if (a <= 0 || e <= 0) return;
    final key = 'h:$a:$s:$e';

    // "Birinchi ko'rish" belgisi siqilganda YO'QOLMAYDI: navbatda
    // turgan yozuvda u bor bo'lsa, yangisida ham qoladi.
    final prev = _find(key);
    final prevNew = prev != null &&
        prev['op'] == 'set' &&
        ((prev['data'] as Map?)?['new_view'] == true);

    _put(SyncKind.history, key, {
      'anime_id': a,
      'season_id': s,
      'epizod_id': e,
      'video_url': (row['video_url'] as String?) ?? '',
      'last_quality': (row['last_quality'] as String?) ?? '',
      'position_ms': (row['position_ms'] as num?)?.toInt() ?? 0,
      'duration_ms': (row['duration_ms'] as num?)?.toInt() ?? 0,
      'watched_ms': (row['watched_ms'] as num?)?.toInt() ?? 0,
      'new_view': (row['new_view'] == true) || prevNew,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Tarixdan yashirish (yozuv serverda O'CHIRILMAYDI, faqat
  /// belgilanadi).
  void hideHistory(int animeId, int seasonId, int epizodId) {
    if (animeId <= 0 || epizodId <= 0) return;
    _put(
      SyncKind.history,
      'h:$animeId:$seasonId:$epizodId',
      {
        'anime_id': animeId,
        'season_id': seasonId,
        'epizod_id': epizodId,
        'deleted': true,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      op: 'delete',
    );
  }

  /// Baho (1..10).
  void putRating(int animeId, int seasonId, int stars) {
    if (animeId <= 0 || stars < 1 || stars > 10) return;
    _put(SyncKind.rating, 'r:$animeId:$seasonId', {
      'anime_id': animeId,
      'season_id': seasonId,
      'stars': stars,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Sevimlilarga qo'shish / olib tashlash.
  void putFavorite(int animeId, int seasonId, bool on) {
    if (animeId <= 0) return;
    _put(SyncKind.favorite, 'f:$animeId:$seasonId', {
      'anime_id': animeId,
      'season_id': seasonId,
      'on': on,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ── YUBORILMAGAN YOZUVLARNI KO'RSATISH ──────────────────────
  //
  // NEGA KERAK (yo'l qo'yilishi mumkin bo'lgan xato): tarix va
  // sevimlilar ro'yxati SERVERDAN keladi va xotiradagini butunlay
  // almashtiradi. Navbatda turgan yozuvlar serverda hali yo'q,
  // ya'ni ro'yxat yangilangan zahoti foydalanuvchi hozirgina
  // qo'shgan narsasi EKRANDAN YO'QOLIB qolardi.
  //
  // Shu sabab ro'yxatlar server javobining ustiga navbatdagi
  // holatni qo'yadi.

  /// Yuborilmagan tarix yozuvlari: `'anime:season:epizod'` ->
  /// yashirilganmi (`true` — o'chirilgan).
  Map<String, bool> pendingHistory() {
    load();
    final out = <String, bool>{};
    for (final e in _rows) {
      if (e['kind'] != SyncKind.history) continue;
      final d = e['data'] as Map?;
      if (d == null) continue;
      final k = '${d['anime_id']}:${d['season_id']}:${d['epizod_id']}';
      out[k] = e['op'] == 'delete';
    }
    return out;
  }

  /// Yuborilmagan sevimlilar: `'anime:season'` -> yoqilganmi.
  Map<String, bool> pendingFavorites() {
    load();
    final out = <String, bool>{};
    for (final e in _rows) {
      if (e['kind'] != SyncKind.favorite) continue;
      final d = e['data'] as Map?;
      if (d == null) continue;
      out['${d['anime_id']}:${d['season_id']}'] = d['on'] == true;
    }
    return out;
  }

  /// Yuborilmagan baholar: `'anime:season'` -> yulduzlar soni.
  ///
  /// NEGA KERAK: bo'lim ma'lumoti SERVERDAN keladi va xotiradagini
  /// butunlay almashtiradi. Navbatdagi baho serverda hali yo'q —
  /// ya'ni foydalanuvchi hozirgina qo'ygan bahosi qism almashtirsa
  /// yoki pleyer qayta ochilsa EKRANDAN YO'QOLIB qolardi va tugma
  /// "ishlamayaptidek" ko'rinardi.
  Map<String, int> pendingRatings() {
    load();
    final out = <String, int>{};
    for (final e in _rows) {
      if (e['kind'] != SyncKind.rating) continue;
      final d = e['data'] as Map?;
      if (d == null) continue;
      final stars = (d['stars'] as num?)?.toInt() ?? 0;
      if (stars > 0) out['${d['anime_id']}:${d['season_id']}'] = stars;
    }
    return out;
  }

  // ── YUBORISH SHARTLARI ──────────────────────────────────────

  /// Shartlar bajarilgan bo'lsa yuboradi; aks holda hech nima
  /// qilmaydi. Har qanday hodisadan keyin chaqirsa bo'ladi.
  Future<void> maybeFlush(String reason) async {
    load();
    _rollDay();
    if (_sending) return;
    if (!_hasWork) return;
    if (_sentToday >= normalPerDay) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final since = now - _lastSentAt;
    final due = switch (reason) {
      'fon' => since >= _bgAfter.inMilliseconds,
      'ochilish' => since >= _openAfter.inMilliseconds,
      // Oddiy yozuv: navbat to'lgan bo'lsa yoki sutka o'tgan bo'lsa.
      _ => _rows.length >= rowsTrigger ||
          since >= _atLeastEvery.inMilliseconds,
    };
    if (!due) return;
    await flush();
  }

  /// Yuboradigan narsa bormi (trafik hisoboti ham hisobga kiradi).
  bool get _hasWork =>
      _rows.isNotEmpty || TrafficService.instance.pendingBytes > 0;

  // ── YUBORISH ────────────────────────────────────────────────

  /// Navbatni serverga yuboradi.
  ///
  /// `onStep` — chiqish/o'chirish oynasidagi progress chizig'i
  /// uchun: bosqich nomi va 0..1 oralig'idagi ulush.
  Future<SyncResult> flush({
    bool force = false,
    void Function(String step, double progress)? onStep,
  }) async {
    load();
    _rollDay();
    if (_sending) return SyncResult.offline;

    final token = AuthService.instance.sessionToken;
    if (token == null || token.isEmpty) return SyncResult.noAccount;

    // Qat'iy chegara — majburiy yuborishda ham buziladigan emas.
    if (_sentToday >= hardPerDay) return SyncResult.offline;
    if (!force && _sentToday >= normalPerDay) return SyncResult.offline;

    _sending = true;
    notifyListeners();
    try {
      onStep?.call('Trafik hisobi', 0.10);
      // Oxirgi baytlar ham shu paketga tushsin.
      try {
        await TrafficService.instance.sampleNow();
        // Hisob almashgan bo'lsa eski yig'indi begona odamga
        // yozilmasin.
        TrafficService.instance.dropIfForeignAccount();
      } catch (_) {}

      if (!_hasWork) {
        onStep?.call('Hammasi saqlangan', 1.0);
        return SyncResult.done;
      }

      // Navbat bo'laklab yuboriladi: bir necha hafta internetsiz
      // yurgan telefonda paket juda katta bo'lib ketmasin.
      var ok = true;
      var guard = 0;
      while (_hasWork && guard < 5 && _sentToday < hardPerDay) {
        guard++;
        final share = 0.15 + 0.75 * (guard == 1 ? 0.6 : 1.0);
        onStep?.call('Ma\'lumotlar yuborilmoqda', share.clamp(0.0, 0.95));
        ok = await _sendOnce(token);
        if (!ok) break;
        if (_rows.isEmpty) break;
      }

      if (ok) {
        onStep?.call('Hammasi saqlandi', 1.0);
        return SyncResult.done;
      }
      onStep?.call('Internet yo\'q', 1.0);
      return SyncResult.offline;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  /// Bitta paketni yuboradi. `true` — muvaffaqiyat.
  Future<bool> _sendOnce(String token) async {
    final batch = _rows.take(maxRowsPerBatch).toList();
    final trafficBytes = TrafficService.instance.pendingBytes;

    final history = <Map<String, dynamic>>[];
    final ratings = <Map<String, dynamic>>[];
    final favorites = <Map<String, dynamic>>[];
    for (final e in batch) {
      final data = Map<String, dynamic>.from(e['data'] as Map);
      switch (e['kind']) {
        case SyncKind.history:
          history.add(data);
        case SyncKind.rating:
          ratings.add(data);
        case SyncKind.favorite:
          favorites.add(data);
      }
    }

    final batchId = _newBatchId();
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/sync'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'batch_id': batchId,
              'history': history,
              'ratings': ratings,
              'favorites': favorites,
              'traffic_bytes': trafficBytes,
            }),
          )
          .timeout(const Duration(seconds: 25));

      // Har qanday javob — hatto rad etilgan bo'lsa ham — so'rov
      // sifatida sanaladi.
      _sentToday++;
      _lastSentAt = DateTime.now().millisecondsSinceEpoch;
      _saveState();

      if (r.statusCode == 200) {
        _dropSent(batch);
        _saveQueue();
        if (trafficBytes > 0) {
          TrafficService.instance.markReported(trafficBytes);
        }
        // Profil sahifasidagi shaxsiy statistika serverdan
        // hisoblanadi — paket ketgach u endi yangi raqamni biladi.
        unawaited(MyStatsService.instance.load(force: true));
        notifyListeners();
        return true;
      }
      if (r.statusCode == 401) {
        // Sessiya tugagan — qayta urinishning ma'nosi yo'q.
        return false;
      }
      if (r.statusCode >= 400 && r.statusCode < 500) {
        // Server yozuvni rad etdi (masalan to'liq emas). Uni
        // abadiy qayta yuborib o'tirmaymiz.
        _dropSent(batch);
        _saveQueue();
        notifyListeners();
        return false;
      }
      return false;
    } catch (_) {
      // Tarmoq yo'q — navbat joyida qoladi.
      return false;
    }
  }

  /// Yuborilgan yozuvlarni navbatdan olib tashlaydi.
  ///
  /// ── NEGA KALITNING O'ZI YETARLI EMAS ───────────────────────
  ///
  /// So'rov ketayotgan paytda foydalanuvchi O'SHA qismni ko'rishda
  /// davom etishi mumkin: `putHistory` bir xil kalit bilan YANGI
  /// yozuv qo'yadi (kattaroq `watched_ms`). Faqat kalit bo'yicha
  /// o'chirsak, hali yuborilmagan o'sha yangi yozuv ham o'chib
  /// ketardi.
  ///
  /// Shu sabab yozuvning VAQTI (`at`) ham solishtiriladi:
  /// almashtirilgan yozuv navbatda qoladi va keyingi paketda
  /// yuboriladi.
  void _dropSent(List<Map<String, dynamic>> batch) {
    final sent = <String, int>{};
    for (final e in batch) {
      sent['${e['key']}'] = (e['at'] as num?)?.toInt() ?? 0;
    }
    _rows.removeWhere((e) {
      final at = sent['${e['key']}'];
      if (at == null) return false;
      return ((e['at'] as num?)?.toInt() ?? 0) <= at;
    });
  }

  /// Bir martalik paket raqami: vaqt + tasodifiy son.
  String _newBatchId() {
    final t = DateTime.now().millisecondsSinceEpoch;
    final r = Random().nextInt(0x7fffffff);
    return '$t-$r';
  }

  // ── HODISALAR ───────────────────────────────────────────────

  /// Ilova fonga ketdi.
  void onBackground() => unawaited(maybeFlush('fon'));

  /// Ilova ochildi / oldinga qaytdi.
  void onResume() => unawaited(maybeFlush('ochilish'));

  // ── HISOB ALMASHGANDA ───────────────────────────────────────
  //
  // Navbat ham hisobga tegishli ma'lumot: u `accountid_<id>`
  // papkasida yotadi. Almashish ikki bosqichda bo'ladi —
  // `detach()` eski papkaga yozadi, `attach()` yangisidan o'qiydi.
  // Hech narsa O'CHIRILMAYDI: eski hisobga qaytilsa, uning
  // yuborilmagan yozuvlari o'z joyida turgan bo'ladi.

  void detach() {
    if (!_loaded) return;
    _saveQueue();
    _saveState();
  }

  void attach() {
    _loaded = false;
    _rows.clear();
    _sentToday = 0;
    _day = '';
    _lastSentAt = 0;
    load();
    notifyListeners();
  }

  /// Hisob o'chirilganda — navbat butunlay tashlanadi.
  ///
  /// Yuborishning ma'nosi yo'q: bir soniyadan keyin o'sha
  /// yozuvlarning hammasi serverdan o'chiriladi.
  void wipe() {
    _rows.clear();
    _sentToday = 0;
    _lastSentAt = 0;
    _saveQueue();
    _saveState();
    notifyListeners();
  }
}
