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

/// Tarixdagi bitta qism.
class HistoryItem {
  final int animeId;
  final int seasonId;
  final int bolimId;
  final int epizodNumber;
  final String animeName;
  final String animePhoto;
  final String seasonPhoto;
  final String videoUrl;
  final int positionMs;
  final int durationMs;

  /// Oxirgi marta qachon ko'rilgani (Unix, millisekund).
  final int updatedAt;

  const HistoryItem({
    required this.animeId,
    required this.seasonId,
    required this.bolimId,
    required this.epizodNumber,
    required this.animeName,
    required this.animePhoto,
    required this.seasonPhoto,
    required this.videoUrl,
    required this.positionMs,
    required this.durationMs,
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

  /// Ro'yxatda ko'rsatiladigan poster: bo'lim rasmi bo'lsa o'sha,
  /// bo'lmasa anime rasmi.
  String get poster => seasonPhoto.isNotEmpty ? seasonPhoto : animePhoto;

  /// Kadr fayli uchun kalit — qaysi video va qaysi soniya.
  ///
  /// Soniya 10 soniyalik bo'laklarga yaxlitlanadi: foydalanuvchi
  /// videoni bir oz oldinga surgani uchun kadr qayta yasalib
  /// o'tirmasin.
  String get thumbKey {
    final name = videoUrl.split('/').last.split('?').first;
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return '${safe}_${positionMs ~/ 10000}';
  }

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
        'anime_photo': animePhoto,
        'season_photo': seasonPhoto,
        'video_url': videoUrl,
        'position_ms': positionMs,
        'duration_ms': durationMs,
        'updated_at': updatedAt,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> j) {
    int num(String k) => (j[k] as num?)?.toInt() ?? 0;
    String str(String k) => (j[k] ?? '').toString();
    return HistoryItem(
      animeId: num('anime_id'),
      seasonId: num('season_id'),
      bolimId: num('bolim_id'),
      epizodNumber: num('epizod_number'),
      animeName: str('anime_name'),
      animePhoto: str('anime_photo'),
      seasonPhoto: str('season_photo'),
      videoUrl: str('video_url'),
      positionMs: num('position_ms'),
      durationMs: num('duration_ms'),
      updatedAt: num('updated_at'),
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

  /// Pleyer qaysi qismni ochganini bildiradi.
  void startEpisode({
    required int animeId,
    required int seasonId,
    required int epizodNumber,
    required String videoUrl,
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
    _pending = {
      'anime_id': animeId,
      'season_id': seasonId,
      'epizod_number': epizodNumber,
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

  /// Kutayotgan yozuvni serverga yuboradi. Pleyerdan chiqilganda,
  /// qism almashganda va ilova fonga ketganda chaqiriladi.
  Future<void> flush() async {
    final p = _pending;
    if (p == null) return;
    final duration = (p['duration_ms'] as int?) ?? 0;
    final position = (p['position_ms'] as int?) ?? 0;
    // Boshidagi 15 soniya — foydalanuvchi qismni endi ochgan,
    // tarixga tushirishning ma'nosi yo'q (`WatchProgress` dagi
    // qoida bilan bir xil).
    if (duration <= 0 || position < 15000) {
      _pending = null;
      return;
    }
    _pending = null;
    await _send(Map<String, dynamic>.from(p));
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
  int _thumbRunning = 0;

  /// Xotiradagi kadrlar soni cheklangan: ro'yxat uzun bo'lsa ham
  /// ilova o'nlab megabaytni ushlab turmasin (har biri ~20 KB).
  static const int _thumbMemoryLimit = 60;

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

    // 2) Navbat: bir vaqtda ikkitadan ko'p yasalmasin.
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
    }
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
