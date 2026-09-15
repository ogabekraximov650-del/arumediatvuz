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

/// ── IZOHLAR TARTIBI ──────────────────────────────────────────
///
/// TALAB (foydalanuvchi): "o'ng yuqori qismida yangilar, layklar,
/// javoblar degan tugma bo'lsin".
///
/// `code` — serverga yuboriladigan qiymat (`?sort=`), `label` —
/// tugmadagi yozuv.
enum CommentSort {
  yangi('yangi', 'Yangilar'),
  layk('layk', 'Layklar'),
  javob('javob', 'Javoblar');

  final String code;
  final String label;
  const CommentSort(this.code, this.label);
}

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

  /// Diskka yozish uchun — `fromJson` bilan bir xil kalitlar.
  Map<String, dynamic> toJson() => {
        'id': id,
        'parent_id': parentId,
        'user_id': userId,
        'first_name': firstName,
        'username': username,
        'photo_url': photoUrl,
        'body': body,
        'created_at': createdAt,
        'deleted': deleted,
        'likes': likes,
        'reply_count': replyCount,
        'liked': liked,
      };
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

  /// Hozirgi tartib. Oyna ochilganda har doim "Yangilar".
  CommentSort _sort = CommentSort.yangi;
  CommentSort get sort => _sort;

  /// Tartibni almashtiradi va ro'yxatni QAYTADAN so'raydi.
  ///
  /// Ro'yxat darhol bo'shatiladi: eski tartibdagi izohlar yangi
  /// tartib kelguncha ekranda turib qolsa, tugma bosilgani
  /// bilinmasdi.
  void setSort(CommentSort next) {
    if (_sort == next) return;
    _sort = next;
    _items.clear();
    _replies.clear();
    _page = 0;
    _hasMore = false;
    _loaded = false;
    notifyListeners();
    load(force: true);
  }

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
    // Diskda FAQAT odatiy tartib saqlanadi (`_saveDisk` izohi).
    if (_sort != CommentSort.yangi) return;
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

  /// Bosh ro'yxatni diskka qayta yozadi.
  ///
  /// Izoh o'chirilganda chaqiriladi: aks holda diskdagi eski
  /// nusxa o'chirilgan izohni qaytarib chiqarardi.
  /// Diskda FAQAT odatiy ("Yangilar") tartib saqlanadi: oyna
  /// har doim shu tartibda ochiladi, ya'ni boshqa tartiblarni
  /// saqlash joy egallab, hech qachon ishlatilmasdi.
  void _saveDisk() {
    if (_sort != CommentSort.yangi) return;
    DiskCache.write(_diskKey, _items.map((c) => c.toJson()).toList());
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await http
          .get(Uri.parse(
              '$_base/$animeId/$seasonId?page=0&sort=${_sort.code}'),
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
        if (_sort == CommentSort.yangi) DiskCache.write(_diskKey, rows);
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
          .get(Uri.parse(
              '$_base/$animeId/$seasonId?page=$next&sort=${_sort.code}'),
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
  /// Izoh yozadi.
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
      // ── IZOH BILAN BIRGA JAVOBLARI HAM KETADI ──────────────
      //
      // TALAB (foydalanuvchi): "kimdir izoh yozgan bo'lsa va
      // izohni o'chirsa, izohga berilgan javoblar va bosilgan
      // layklar o'chirib tashlansin".
      //
      // Server o'chirilgan izohning javoblarini ham, ikkalasiga
      // bosilgan layklarni ham o'chiradi. Ekranda esa shu
      // o'zgarish DARHOL ko'rinishi kerak — tarmoq javobini
      // kutib turmasdan.
      _items.removeWhere((c) => c.id == id);
      for (final list in _replies.values) {
        list.removeWhere((c) => c.id == id);
      }
      // O'chirilgan izohga ochib qo'yilgan javoblar ro'yxati ham
      // ma'nosini yo'qotdi.
      _replies.remove(id);
      // ── DISKDAGI NUSXA ─────────────────────────────────────
      //
      // TOPILGAN XATO: o'chirilgan izoh diskda qolib ketardi va
      // ilova qayta ochilganda ro'yxatda YANA chiqardi (tarmoq
      // javobi kelguncha, ya'ni har safar bir necha soniya).
      _saveDisk();
      notifyListeners();
      return null;
    } catch (_) {
      return 'Internet yo\'q';
    }
  }

  // ── LAYK ──────────────────────────────────────────────────

  /// Laykni yoqadi/o'chiradi.
  ///
  /// ── NEGA QAYTA YOZILDI ──────────────────────────────────
  ///
  /// TALAB (foydalanuvchi): "layk bosish tugmasini kattalashtir
  /// va TEZ ishlaydigan qil".
  ///
  /// TOPILGAN XATO: tugma bosilganda so'rov tugagunicha KEYINGI
  /// bosishlar butunlay e'tiborsiz qolardi (`_likeBusy` qaytarib
  /// yuborardi). Sekin internetda bu bir necha soniya — odam
  /// bosadi, hech narsa bo'lmaydi, yana bosadi. Tashqaridan bu
  /// "tugma ishlamayapti" bo'lib ko'rinadi.
  ///
  /// ENDI: HAR BOSISH ekranda darhol ko'rinadi, so'rov ketayotgan
  /// bo'lsa ham. So'rov tugagach server holati ekrandagi holat
  /// bilan solishtiriladi va farq bo'lsa yana bitta so'rov
  /// yuboriladi — ya'ni oxirida ikkovi albatta tenglashadi.
  /// Tarmoqqa esa bosishlar soncha emas, kerakligicha so'rov
  /// ketadi.
  Future<String?> toggleLike(String id) async {
    final c = _find(id);
    if (c == null) return null;
    if (AuthService.instance.sessionToken == null) {
      return 'Layk bosish uchun hisobingizga kiring';
    }

    // 1) Ekranda DARHOL — tarmoq umuman kutilmaydi.
    c.liked = !c.liked;
    c.likes = c.liked ? c.likes + 1 : (c.likes - 1).clamp(0, 1 << 30);
    notifyListeners();

    // So'rov allaqachon ketyapti — quyidagi halqa yangi holatni
    // o'zi yetkazadi, ikkinchi halqa kerak emas.
    if (_likeBusy.contains(id)) return null;

    // Xato bo'lsa SHU holatga qaytariladi: bu server bilgan
    // oxirgi holat (bosishdan oldingisi).
    final wasLiked = !c.liked;
    final wasLikes = c.liked ? c.likes - 1 : c.likes + 1;

    _likeBusy.add(id);
    String? error;
    try {
      // Server ekrandagi holatga yetguncha. Chegara — cheksiz
      // aylanishdan saqlaydi (server kutilmagan javob bersa).
      for (var i = 0; i < 5; i++) {
        final r = await http
            .post(
              Uri.parse('$_base/like'),
              headers: _headers(json: true),
              body: jsonEncode({'id': id}),
            )
            .timeout(const Duration(seconds: 20));
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        if (r.statusCode != 200) {
          error = '${j['error'] ?? 'Layk yuborilmadi'}';
          break;
        }
        final liked = j['liked'] == true;
        final likes = ((j['likes'] as num?) ?? c.likes).toInt();
        // Foydalanuvchi so'rov ketayotganda YANA bosgan bo'lsa,
        // `c.liked` allaqachon boshqa — yana bir marta yuboramiz.
        if (liked == c.liked) {
          c.likes = likes;
          notifyListeners();
          break;
        }
      }
    } catch (_) {
      error = 'Internet yo\'q';
    }
    if (error != null) {
      c.liked = wasLiked;
      c.likes = wasLikes;
      notifyListeners();
    }
    _likeBusy.remove(id);
    return error;
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

// ══════════════════════════════════════════════════════════════
//  BITTA IZOHNING JAVOBLARI — XIZMATGA BOG'LANMASDAN
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): izohlar statistikasida "javoblarni
// statistika oynasining o'zida ochib ko'rish mumkin bo'lsin".
//
// NEGA `CommentsService` ISHLAMAYDI: u BITTA bo'limga bog'langan
// (`animeId`/`seasonId` uning holati) va izohlar oynasi ochilganda
// sozlanadi. Statistika oynasida esa har bir qator BOSHQA
// bo'limning izohi — xizmatni ular uchun qayta-qayta sozlash
// izohlar oynasini buzib qo'yardi.
//
// Shu sabab bu yerda holatsiz oddiy funksiya: so'radi, qaytardi.
// `null` — kelmadi (internet yo'q yoki server javob bermadi).
Future<List<Comment>?> fetchCommentReplies({
  required int animeId,
  required int seasonId,
  required String parentId,
}) async {
  if (animeId <= 0 || parentId.isEmpty) return const [];
  try {
    final token = AuthService.instance.sessionToken;
    final r = await http.get(
      Uri.parse('$kApiBase/api/comments/$animeId/$seasonId/$parentId'),
      headers: {
        if (token != null) 'Authorization': 'Bearer $token',
      },
    ).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    // Javoblar eskisidan yangisiga — suhbat tartibida
    // (`toggleReplies` bilan bir xil).
    return ((j['items'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(Comment.fromJson)
        .toList()
        .reversed
        .toList();
  } catch (_) {
    return null;
  }
}
