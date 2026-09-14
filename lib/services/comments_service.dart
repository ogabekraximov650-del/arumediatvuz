// lib/services/comments_service.dart — IZOHLAR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "bo'limlar oynasidan keyin izohlar degan oyna
// qo'sh va xuddi YouTube'dek — izoh yozish, izohga javob
// qaytarish, izohga layk bosish; katta platformalardek to'g'ri va
// barqaror ishlaydigan qilib ber".
//
// ── "BARQAROR" BU YERDA NIMA DEGANI ─────────────────────────
//
// 1. LAYK DARHOL KO'RINADI, lekin HAQIQAT SERVERDA. Tugma
//    bosilishi bilan raqam o'zgaradi (kutish yo'q), so'rov esa
//    fon'da ketadi. Server javobi kelganda raqam AYNAN serverniki
//    bilan almashtiriladi. So'rov yiqilsa — eski holat qaytariladi
//    va xato ko'rsatiladi. Ya'ni ekranda hech qachon "yolg'on"
//    raqam qolib ketmaydi.
//
// 2. IKKI MARTA BOSISH ZARAR QILMAYDI. Har bir izoh uchun
//    "so'rov ketyapti" belgisi bor: javob kelmaguncha ikkinchi
//    so'rov yuborilmaydi. Ustiga serverda ham birlamchi kalit
//    bor, ya'ni takror layk bazaga umuman tushmaydi.
//
// 3. RO'YXAT SAHIFALAB KELADI. Bir yo'la 30 ta. Pastga tushilganda
//    keyingisi so'raladi — mingta izohli bo'limda ham ekran
//    qotmaydi.
//
// ── NEGA `SyncQueue` GA TUSHMAYDI ───────────────────────────
//
// Tarix va baholar telefonda yig'ilib, kuniga bir necha marta
// paket bo'lib ketadi. Izoh esa BOSHQACHA: odam yozgan izohini
// SHU ZAHOTI ko'rishi kerak va boshqalar ham darhol ko'rishi
// kerak. Kechiktirilgan izoh — ishlamaydigan izoh.
//
// Ustiga bu so'rovlar kam: odam kuniga bir necha marta izoh
// yozadi, tomosha esa soatlab davom etadi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'disk_cache.dart';

/// Bitta izoh (yoki javob).
class Comment {
  final String id;
  final String parentId;
  final int userId;
  final String firstName;
  final String username;
  final String photoUrl;
  final String body;
  final int createdAt;
  final bool deleted;

  /// Bular O'ZGARADI (layk bosilganda, javob yozilganda).
  int likes;
  int replyCount;
  bool liked;

  Comment({
    required this.id,
    required this.parentId,
    required this.userId,
    required this.firstName,
    required this.username,
    required this.photoUrl,
    required this.body,
    required this.createdAt,
    required this.deleted,
    required this.likes,
    required this.replyCount,
    required this.liked,
  });

  bool get isReply => parentId.isNotEmpty;

  /// Ekranda ko'rinadigan nom.
  String get name {
    final n = firstName.trim();
    if (n.isNotEmpty) return n;
    final u = username.trim();
    return u.isNotEmpty ? '@$u' : 'Foydalanuvchi';
  }

  static Comment fromJson(Map<String, dynamic> j) => Comment(
        id: '${j['id'] ?? ''}',
        parentId: '${j['parent_id'] ?? ''}',
        userId: ((j['user_id'] as num?) ?? 0).toInt(),
        firstName: '${j['first_name'] ?? ''}',
        username: '${j['username'] ?? ''}',
        photoUrl: '${j['photo_url'] ?? ''}',
        body: '${j['body'] ?? ''}',
        createdAt: ((j['created_at'] as num?) ?? 0).toInt(),
        deleted: j['deleted'] == true,
        likes: ((j['likes'] as num?) ?? 0).toInt(),
        replyCount: ((j['reply_count'] as num?) ?? 0).toInt(),
        liked: j['liked'] == true,
      );
}

/// Bitta bo'limning izohlari.
///
/// Pleyer ochilganda yaratiladi va yopilganda tashlanadi — ya'ni
/// xotirada bir vaqtda faqat ochiq bo'limning izohlari turadi.
class CommentsController extends ChangeNotifier {
  final int animeId;
  final int seasonId;

  CommentsController({required this.animeId, required this.seasonId});

  final List<Comment> _items = [];
  List<Comment> get items => List.unmodifiable(_items);

  /// Ochilgan javoblar: bosh izoh `id` -> javoblari.
  final Map<String, List<Comment>> _replies = {};
  List<Comment> repliesOf(String id) => _replies[id] ?? const [];
  bool isOpen(String id) => _replies.containsKey(id);

  /// Javoblari hozir yuklanayotgan izohlar.
  final Set<String> _loadingReplies = {};
  bool isLoadingReplies(String id) => _loadingReplies.contains(id);

  /// Layk so'rovi ketayotgan izohlar (ikki marta bosishdan himoya).
  final Set<String> _likeBusy = {};

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 0;
  String? _error;
  bool _loaded = false;

  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  bool get hasData => _loaded;
  String? get error => _error;

  /// Nechta izoh bor (javoblar bilan) — tab sarlavhasi uchun.
  int get total {
    var n = _items.length;
    for (final c in _items) {
      n += c.replyCount;
    }
    return n;
  }

  Map<String, String> _headers({bool json = false}) {
    final t = AuthService.instance.sessionToken;
    return {
      if (t != null) 'Authorization': 'Bearer $t',
      if (json) 'Content-Type': 'application/json',
    };
  }

  String get _base => '$kApiBase/api/comments';

  // ── O'QISH ────────────────────────────────────────────────

  /// Diskdagi kalit — bo'limga bog'langan.
  String get _diskKey => 'comments_${animeId}_$seasonId';

  /// Diskdagi nusxani DARHOL ko'rsatadi (tarmoq kutilmaydi).
  ///
  /// TALAB (foydalanuvchi): "izohlar ham diskda tursin, tezroq
  /// ishlashi uchun". Izohlar oynasi ochilganda ekran bo'sh
  /// turmasin — oxirgi ko'rilgan ro'yxat darhol chiqadi va
  /// yangisi fon'da keladi.
  ///
  /// Layk belgisi ham saqlanadi: u SHU ODAMNIKI va hisob
  /// almashsa papka ham almashadi, ya'ni begona odamga
  /// ko'rinmaydi.
  void loadFromDisk() {
    if (_items.isNotEmpty) return;
    final rows = DiskCache.read(_diskKey);
    if (rows == null) return;
    _items
      ..clear()
      ..addAll(rows.where(_alive).map(Comment.fromJson));
    _loaded = true;
    notifyListeners();
  }

  /// O'chirilgan izoh ro'yxatga UMUMAN tushmaydi.
  ///
  /// TALAB (foydalanuvchi): "izoh o'chirilgan bo'lsa ham profil
  /// va bitta javob ko'rsatilyapti, men esa butunlay o'chirib
  /// tashlansin degandim".
  ///
  /// Server endi qatorni haqiqatan o'chiradi, lekin DISKDA eski
  /// nusxa qolgan bo'lishi mumkin — shu sabab bu yerda ham
  /// tekshiriladi.
  static bool _alive(Map<String, dynamic> j) => j['deleted'] != true;

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$_base/$animeId/$seasonId?page=0'),
              headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final rows = ((j['items'] as List?) ?? [])
            .cast<Map<String, dynamic>>();
        _items
          ..clear()
          ..addAll(rows.where(_alive).map(Comment.fromJson));
        _page = 0;
        _hasMore = j['has_more'] == true;
        _loaded = true;
        // Ochiq javoblar eskirdi — qayta ochilganda yangisi keladi.
        _replies.clear();
        // Keyingi ochilishda ekran darhol to'lsin.
        DiskCache.write(_diskKey, rows);
      } else {
        _error = 'Izohlar yuklanmadi (${r.statusCode})';
      }
    } catch (_) {
      _error = 'Internet yo\'q';
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;
    _loadingMore = true;
    notifyListeners();
    final next = _page + 1;
    try {
      final r = await http
          .get(Uri.parse('$_base/$animeId/$seasonId?page=$next'),
              headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final rows = _parse(j['items']);
        // Takrorlanmasin: tarmoq sekin bo'lsa bir sahifa ikki marta
        // kelishi mumkin.
        final have = _items.map((c) => c.id).toSet();
        _items.addAll(rows.where((c) => !have.contains(c.id)));
        _page = next;
        _hasMore = j['has_more'] == true;
      }
    } catch (_) {
      // Jim: keyingi urinishda yana so'raladi.
    }
    _loadingMore = false;
    notifyListeners();
  }

  /// Bitta izohning javoblarini ochadi (yoki yopadi).
  Future<void> toggleReplies(String id) async {
    if (_replies.containsKey(id)) {
      _replies.remove(id);
      notifyListeners();
      return;
    }
    if (_loadingReplies.contains(id)) return;
    _loadingReplies.add(id);
    notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$_base/$animeId/$seasonId/$id'), headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        // Javoblar eskisidan yangisiga — suhbat tartibida.
        _replies[id] = _parse(j['items']).reversed.toList();
      }
    } catch (_) {
      // Ochilmadi — belgisi qaytadi, foydalanuvchi yana urinadi.
    }
    _loadingReplies.remove(id);
    notifyListeners();
  }

  List<Comment> _parse(dynamic raw) => ((raw as List?) ?? [])
      .cast<Map<String, dynamic>>()
      .where(_alive)
      .map(Comment.fromJson)
      .toList();

  // ── YOZISH ────────────────────────────────────────────────

  /// Izoh yoki javob yozadi. Xato bo'lsa matn qaytadi.
  Future<String?> add(String body, {String parentId = ''}) async {
    final text = body.trim();
    if (text.isEmpty) return 'Izoh bo\'sh';
    try {
      final r = await http
          .post(
            Uri.parse(_base),
            headers: _headers(json: true),
            body: jsonEncode({
              'anime_id': animeId,
              'season_id': seasonId,
              'parent_id': parentId,
              'body': text,
            }),
          )
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 && r.statusCode != 201) {
        return '${j['error'] ?? 'Izoh yuborilmadi'}';
      }
      final c = Comment.fromJson(j);
      if (c.isReply) {
        // Javob o'z joyiga qo'shiladi va bosh izohning hisobi oshadi.
        final list = _replies[c.parentId];
        if (list != null) list.add(c);
        final idx = _items.indexWhere((x) => x.id == c.parentId);
        if (idx >= 0) _items[idx].replyCount += 1;
      } else {
        // Yangi izoh eng tepada.
        _items.insert(0, c);
      }
      notifyListeners();
      return null;
    } catch (_) {
      return 'Internet yo\'q — qaytadan urinib ko\'ring';
    }
  }

  /// O'z izohini o'chiradi.
  Future<String?> remove(String id) async {
    try {
      final r = await http
          .delete(Uri.parse('$_base/$id'), headers: _headers())
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return '${j['error'] ?? 'O\'chirilmadi'}';
      }
      // ── JAVOB O'CHDI — BOSH IZOHNING HISOBI KAMAYADI ────────
      //
      // TOPILGAN XATO (foydalanuvchi: "izoh o'chirilsa ham bitta
      // javob deb chiqmasligi kerak"). Server `parent_id` ni
      // qaytaradi, ya'ni qaysi izohning hisobi kamayishini ilova
      // taxmin qilmaydi.
      final parent = '${j['parent_id'] ?? ''}';
      if (parent.isNotEmpty) {
        final idx = _items.indexWhere((x) => x.id == parent);
        if (idx >= 0 && _items[idx].replyCount > 0) {
          _items[idx].replyCount -= 1;
        }
      }
      _items.removeWhere((c) => c.id == id);
      for (final list in _replies.values) {
        list.removeWhere((c) => c.id == id);
      }
      _replies.remove(id);
      notifyListeners();
      return null;
    } catch (_) {
      return 'Internet yo\'q';
    }
  }

  // ── LAYK ──────────────────────────────────────────────────

  /// Laykni yoqadi/o'chiradi.
  ///
  /// Ekranda DARHOL o'zgaradi, so'rov fon'da ketadi. Server javobi
  /// kelganda raqam AYNAN serverniki bilan almashtiriladi — ya'ni
  /// ikkovi hech qachon farq qilib qolmaydi. So'rov yiqilsa eski
  /// holat qaytariladi.
  Future<String?> toggleLike(String id) async {
    if (_likeBusy.contains(id)) return null;
    final c = _find(id);
    if (c == null) return null;
    if (AuthService.instance.sessionToken == null) {
      return 'Layk bosish uchun hisobingizga kiring';
    }

    _likeBusy.add(id);
    final wasLiked = c.liked;
    final wasLikes = c.likes;
    // 1) Darhol ko'rsatamiz.
    c.liked = !wasLiked;
    c.likes = wasLiked ? (wasLikes - 1).clamp(0, 1 << 30) : wasLikes + 1;
    notifyListeners();

    try {
      final r = await http
          .post(
            Uri.parse('$_base/like'),
            headers: _headers(json: true),
            body: jsonEncode({'id': id}),
          )
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        c.liked = wasLiked;
        c.likes = wasLikes;
        notifyListeners();
        return '${j['error'] ?? 'Layk yuborilmadi'}';
      }
      // 2) Serverning yakuniy so'zi.
      c.liked = j['liked'] == true;
      c.likes = ((j['likes'] as num?) ?? c.likes).toInt();
      notifyListeners();
      return null;
    } catch (_) {
      c.liked = wasLiked;
      c.likes = wasLikes;
      notifyListeners();
      return 'Internet yo\'q';
    } finally {
      _likeBusy.remove(id);
    }
  }

  /// Izohni ham bosh ro'yxatdan, ham javoblardan qidiradi.
  Comment? _find(String id) {
    for (final c in _items) {
      if (c.id == id) return c;
    }
    for (final list in _replies.values) {
      for (final c in list) {
        if (c.id == id) return c;
      }
    }
    return null;
  }
}

/// Aniq vaqt: `14:32` (bugun) yoki `12.09.2026`.
///
/// TALAB (foydalanuvchi): "izoh yozganda vaqti ham ko'rsatilsin".
/// "7 daqiqa oldin" ko'z uchun qulay, lekin aniq vaqtni bermaydi —
/// shu sabab yonida shu ham turadi.
String commentClock(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${two(d.hour)}:${two(d.minute)}';
  }
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// "3 daqiqa oldin" ko'rinishidagi vaqt.
String commentAgo(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.now().millisecondsSinceEpoch - ms;
  if (d < 60000) return 'hozir';
  final min = d ~/ 60000;
  if (min < 60) return '$min daqiqa oldin';
  final h = min ~/ 60;
  if (h < 24) return '$h soat oldin';
  final days = h ~/ 24;
  if (days < 30) return '$days kun oldin';
  final mo = days ~/ 30;
  if (mo < 12) return '$mo oy oldin';
  return '${days ~/ 365} yil oldin';
}
