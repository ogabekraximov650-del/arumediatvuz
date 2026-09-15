// lib/services/dm_service.dart — SHAXSIY YOZISHMALAR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "balans to'ldirish tugmasi tagiga suhbatlar degan
// tugma qo'sh ... bitta foydalanuvchi boshqa do'stlari bilan
// gaplasha olsin ... bu funksiya obunasi bor vaqtda ishlaydi ...
// yuborilgan xabarga shikoyat qilish, reaksiya bildirish, ovozli,
// rasm va video xabar yuborish, yuborgan xabarini o'chirish".
//
// ── QOIDALAR SERVERDA ───────────────────────────────────────
//
// Obuna sharti, "faqat o'z suhbati" va adminning ko'rish huquqi —
// hammasi SERVERDA hal qilinadi. Bu yerdagi kod shunchaki so'rov
// yuboradi: o'zgartirilgan ilova bilan begona yozishmani ocholmaydi
// yoki obunasiz yozib bo'lmaydi.
//
// ── ADMIN YOZISHMASI BILAN BIR XIL USULLAR ──────────────────
//
// Xabar DARHOL yetib borishi uchun uzoq kutish (`/api/dm/wait`),
// o'chirilgan xabarni sezish uchun `all_ids`, ✓ dan ✓✓ ga o'tish
// uchun `seen_ids` — hammasi `support_service.dart` dagi bilan
// bir xil. U yerda bu yechimlar allaqachon sinovdan o'tgan va
// nima uchun aynan shunday qilinganini o'sha fayldagi izohlar
// tushuntiradi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'disk_cache.dart';

String get _base => '$kApiBase/api/dm';

Map<String, String> _headers({bool json = false}) {
  final t = AuthService.instance.sessionToken;
  return {
    if (t != null) 'Authorization': 'Bearer $t',
    if (json) 'Content-Type': 'application/json',
  };
}

// ══════════════════════════════════════════════════════════════
//  ODAM
// ══════════════════════════════════════════════════════════════

@immutable
class DmPerson {
  final int userId;
  final String firstName;
  final String username;
  final String photoUrl;

  const DmPerson({
    required this.userId,
    required this.firstName,
    required this.username,
    required this.photoUrl,
  });

  String get name {
    final n = firstName.trim();
    if (n.isNotEmpty) return n;
    final u = username.trim();
    return u.isNotEmpty ? '@$u' : 'Foydalanuvchi $userId';
  }

  static DmPerson fromJson(Map<String, dynamic> j) => DmPerson(
        userId: ((j['user_id'] ?? j['id']) as num?)?.toInt() ?? 0,
        firstName: '${j['first_name'] ?? ''}',
        username: '${j['username'] ?? ''}',
        photoUrl: '${j['photo_url'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'first_name': firstName,
        'username': username,
        'photo_url': photoUrl,
      };
}

// ══════════════════════════════════════════════════════════════
//  BITTA XABAR
// ══════════════════════════════════════════════════════════════

@immutable
class DmMessage {
  final String id;

  /// Xabar MENIKIMI (o'ng tarafda turadi).
  final bool mine;

  final int fromId;
  final String body;

  /// Rasm, video yoki ovoz manzili (bo'sh — oddiy matn).
  final String mediaUrl;

  /// `image` | `video` | `voice`.
  final String mediaType;

  /// Ovozli xabar uzunligi (ms).
  final int mediaMs;

  /// Suhbatdosh o'qiganmi (✓ / ✓✓).
  final bool seen;

  final int createdAt;

  /// Serverdan `emoji:son,emoji:son` ko'rinishida keladi.
  final String reactionsRaw;

  /// Men qo'ygan reaksiya (bo'sh — qo'ymaganman).
  final String myReaction;

  /// Hali serverga yetib bormagan (ekranda DARHOL ko'rsatilgan)
  /// nusxa — admin yozishmasidagi bilan bir xil usul.
  final bool pending;

  const DmMessage({
    required this.id,
    required this.mine,
    required this.fromId,
    required this.body,
    required this.createdAt,
    this.mediaUrl = '',
    this.mediaType = '',
    this.mediaMs = 0,
    this.seen = false,
    this.reactionsRaw = '',
    this.myReaction = '',
    this.pending = false,
  });

  bool get hasMedia => mediaUrl.isNotEmpty && mediaType.isNotEmpty;
  bool get isVideo => mediaType == 'video';
  bool get isVoice => mediaType == 'voice';

  /// Ko'ruvchida ochiladigan narsa (ovoz bunga kirmaydi — u
  /// xabarning o'zida ijro etiladi).
  bool get isViewable => hasMedia && !isVoice;

  /// `emoji -> soni`. Server matn qilib yuboradi, chunki uni
  /// SQL'da yig'ish har xabar uchun alohida so'rovdan arzon.
  Map<String, int> get reactions {
    final out = <String, int>{};
    for (final part in reactionsRaw.split(',')) {
      final i = part.lastIndexOf(':');
      if (i <= 0) continue;
      final e = part.substring(0, i).trim();
      final n = int.tryParse(part.substring(i + 1).trim()) ?? 0;
      if (e.isNotEmpty && n > 0) out[e] = n;
    }
    return out;
  }

  DmMessage copyWith({bool? seen, String? myReaction, String? reactionsRaw}) =>
      DmMessage(
        id: id,
        mine: mine,
        fromId: fromId,
        body: body,
        createdAt: createdAt,
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        mediaMs: mediaMs,
        seen: seen ?? this.seen,
        reactionsRaw: reactionsRaw ?? this.reactionsRaw,
        myReaction: myReaction ?? this.myReaction,
      );

  static DmMessage fromJson(Map<String, dynamic> j) => DmMessage(
        id: '${j['id'] ?? ''}',
        mine: j['mine'] == true,
        fromId: ((j['from_id'] as num?) ?? 0).toInt(),
        body: '${j['body'] ?? ''}',
        mediaUrl: '${j['media_url'] ?? ''}',
        mediaType: '${j['media_type'] ?? ''}',
        mediaMs: ((j['media_ms'] as num?) ?? 0).toInt(),
        seen: j['seen'] == true,
        createdAt: ((j['created_at'] as num?) ?? 0).toInt(),
        reactionsRaw: '${j['reactions'] ?? ''}',
        myReaction: '${j['my_reaction'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'mine': mine,
        'from_id': fromId,
        'body': body,
        'media_url': mediaUrl,
        'media_type': mediaType,
        'media_ms': mediaMs,
        'seen': seen,
        'created_at': createdAt,
        'reactions': reactionsRaw,
        'my_reaction': myReaction,
      };
}

// ══════════════════════════════════════════════════════════════
//  SUHBAT QATORI (ro'yxat uchun)
// ══════════════════════════════════════════════════════════════

@immutable
class DmThread {
  final DmPerson other;
  final String lastBody;
  final int lastAt;
  final bool lastMine;
  final int unread;

  const DmThread({
    required this.other,
    required this.lastBody,
    required this.lastAt,
    required this.lastMine,
    required this.unread,
  });

  static DmThread fromJson(Map<String, dynamic> j) => DmThread(
        other: DmPerson.fromJson(j),
        lastBody: '${j['last_body'] ?? ''}',
        lastAt: ((j['last_at'] as num?) ?? 0).toInt(),
        lastMine: j['last_mine'] == true,
        unread: ((j['unread'] as num?) ?? 0).toInt(),
      );

  Map<String, dynamic> toJson() => {
        ...other.toJson(),
        'last_body': lastBody,
        'last_at': lastAt,
        'last_mine': lastMine,
        'unread': unread,
      };
}

// ══════════════════════════════════════════════════════════════
//  QIZIL NUQTA
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "suhbatlardan kimdir foydalanuvchiga
// xabar yuborsa qizil nuqta yonib tursin, huddi support
// chatdagidek".
//
// `UnreadBadge` dan AYRIM: u admin bilan yozishmaniki, bu esa
// do'stlar bilan. Ikkovi bir joyda sanalsa, qaysi nuqta qaysi
// yozishmaniki ekani bilinmasdi.

class DmBadge extends ChangeNotifier {
  DmBadge._();
  static final DmBadge instance = DmBadge._();

  int _count = 0;
  bool _busy = false;

  int get count => _count;
  bool get has => _count > 0;

  void clear() {
    if (_count == 0) return;
    _count = 0;
    notifyListeners();
  }

  /// Suhbat ochildi — nuqta darhol o'chsin (serverni kutmasdan).
  void markRead(int n) {
    if (n <= 0 || _count == 0) return;
    _count = (_count - n).clamp(0, 1 << 30);
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_busy) return;
    if (AuthService.instance.sessionToken == null) {
      clear();
      return;
    }
    _busy = true;
    try {
      final r = await http
          .get(Uri.parse('$_base/unread'), headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final n = ((j['unread'] as num?) ?? 0).toInt();
        if (n != _count) {
          _count = n;
          notifyListeners();
        }
      }
    } catch (_) {
      // Internet yo'q — nuqta eski holicha qoladi.
    }
    _busy = false;
  }
}

// ══════════════════════════════════════════════════════════════
//  SUHBATLAR RO'YXATI
// ══════════════════════════════════════════════════════════════

class DmThreadsController extends ChangeNotifier {
  final List<DmThread> _items = [];
  List<DmThread> get items => List.unmodifiable(_items);

  bool _loading = false;
  bool _loaded = false;
  String? _error;

  bool get isLoading => _loading && _items.isEmpty;
  bool get hasData => _loaded;
  String? get error => _error;

  static const _diskKey = 'dm_threads';

  /// Diskdagi nusxani DARHOL ko'rsatadi (tarmoq kutilmaydi).
  void loadFromDisk() {
    if (_items.isNotEmpty) return;
    final rows = DiskCache.read(_diskKey);
    if (rows == null) return;
    _items
      ..clear()
      ..addAll(rows.map(DmThread.fromJson));
    _loaded = true;
    notifyListeners();
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    if (AuthService.instance.sessionToken == null) {
      _error = 'Avval hisobingizga kiring';
      notifyListeners();
      return;
    }
    _loading = true;
    if (!_loaded) notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$_base/threads'), headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final raw = ((j['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _items
          ..clear()
          ..addAll(raw.map(DmThread.fromJson));
        DiskCache.write(_diskKey, raw);
        _loaded = true;
        _error = null;
      } else {
        _error = 'Yuklanmadi (${r.statusCode})';
      }
    } catch (_) {
      if (!_loaded) _error = 'Internet yo\'q';
    }
    _loading = false;
    notifyListeners();
  }

  /// Suhbatni ro'yxatdan olib tashlaydi (xabarlar o'chirilganda
  /// server ham uni o'chiradi).
  void drop(int userId) {
    final before = _items.length;
    _items.removeWhere((t) => t.other.userId == userId);
    if (_items.length != before) notifyListeners();
  }

  // ── UZOQ KUTISH ───────────────────────────────────────────
  //
  // Yangi xabar ro'yxatda DARHOL ko'rinsin. Usul admin
  // yozishmasidagi bilan bir xil (`support_service.dart`).

  bool _watching = false;

  int get _lastAt =>
      _items.isEmpty ? 0 : _items.map((t) => t.lastAt).reduce((a, b) => a > b ? a : b);

  void startWatching() {
    if (_watching) return;
    _watching = true;
    unawaited(_watchLoop());
  }

  void stopWatching() => _watching = false;

  Future<void> _watchLoop() async {
    while (_watching) {
      if (AuthService.instance.sessionToken == null) {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }
      try {
        final r = await http
            .get(
              Uri.parse('$_base/wait?since=$_lastAt&count=${_items.length}'),
              headers: _headers(),
            )
            // Server ~19 soniya ushlaydi; 35 — zaxira bilan.
            .timeout(const Duration(seconds: 35));
        if (!_watching) return;
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          if (j['new'] == true) {
            await load(force: true);
            unawaited(DmBadge.instance.refresh());
          }
          continue;
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      } catch (_) {
        if (!_watching) return;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  @override
  void dispose() {
    _watching = false;
    super.dispose();
  }
}

/// Username bo'yicha odam qidiradi.
///
/// TALAB (foydalanuvchi): "tepada username bilan izlash uchun
/// lupa bo'lsin (ism bilan izlab bo'lmaydi)".
Future<List<DmPerson>> searchByUsername(String q) async {
  final text = q.trim().replaceAll('@', '');
  if (text.length < 2) return const [];
  try {
    final r = await http
        .get(
          Uri.parse('$_base/search?q=${Uri.encodeQueryComponent(text)}'),
          headers: _headers(),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return const [];
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return ((j['items'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map(DmPerson.fromJson)
        .toList();
  } catch (_) {
    return const [];
  }
}

// ══════════════════════════════════════════════════════════════
//  BITTA SUHBAT
// ══════════════════════════════════════════════════════════════

class DmController extends ChangeNotifier {
  /// Suhbatdoshning raqami.
  final int otherId;

  DmController({required this.otherId});

  final List<DmMessage> _items = [];
  List<DmMessage> get items => List.unmodifiable(_items);

  bool _loading = false;
  bool _loaded = false;
  String? _error;

  bool get isLoading => _loading && _items.isEmpty;
  bool get hasData => _loaded;
  String? get error => _error;

  String get _diskKey => 'dm_$otherId';

  /// Diskdagi nusxani DARHOL ko'rsatadi.
  void loadFromDisk() {
    if (_items.isNotEmpty) return;
    final rows = DiskCache.read(_diskKey);
    if (rows == null) return;
    _items
      ..clear()
      ..addAll(rows.map(DmMessage.fromJson));
    _loaded = true;
    notifyListeners();
  }

  void _saveDisk() {
    DiskCache.write(
      _diskKey,
      _items.where((m) => !m.pending).map((m) => m.toJson()).toList(),
    );
  }

  // ── UZOQ KUTISH ───────────────────────────────────────────

  bool _watching = false;

  int get _lastAt => _items.isEmpty ? 0 : _items.last.createdAt;
  int get _seenCount => _items.where((m) => m.seen).length;
  int get _liveCount => _items.where((m) => !m.pending).length;

  void startPolling() {
    if (_watching) return;
    _watching = true;
    unawaited(_watchLoop());
  }

  void stopPolling() => _watching = false;

  Future<void> _watchLoop() async {
    while (_watching) {
      if (AuthService.instance.sessionToken == null) {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }
      try {
        final r = await http
            .get(
              Uri.parse('$_base/wait?user_id=$otherId&since=$_lastAt'
                  '&seen=$_seenCount&count=$_liveCount'),
              headers: _headers(),
            )
            .timeout(const Duration(seconds: 35));
        if (!_watching) return;
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          if (j['new'] == true) await load(force: true);
          continue;
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      } catch (_) {
        if (!_watching) return;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  @override
  void dispose() {
    _watching = false;
    super.dispose();
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    if (AuthService.instance.sessionToken == null) {
      _error = 'Avval hisobingizga kiring';
      notifyListeners();
      return;
    }
    _loading = true;
    if (!_loaded) notifyListeners();
    // Ro'yxat allaqachon bo'lsa faqat YANGILARI so'raladi.
    final since = _loaded ? _lastAt : 0;
    try {
      final uri = Uri.parse(
          '$_base/thread/$otherId${since > 0 ? '?since=$since' : ''}');
      final r =
          await http.get(uri, headers: _headers()).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final raw = ((j['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        final rows = raw.map(DmMessage.fromJson).toList();

        // ── "O'QILDI" BELGISI ──────────────────────────────
        //
        // `since` bilan faqat yangi xabarlar keladi, belgi esa
        // ESKI xabarlarga qo'yiladi — shu sabab server
        // o'qilganlarning raqamlarini ham yuboradi.
        final seenIds =
            ((j['seen_ids'] as List?) ?? []).map((e) => '$e').toSet();
        if (seenIds.isNotEmpty) {
          for (var i = 0; i < _items.length; i++) {
            final m = _items[i];
            if (!m.seen && seenIds.contains(m.id)) {
              _items[i] = m.copyWith(seen: true);
            }
          }
        }

        // ── O'CHIRILGAN XABARLAR ───────────────────────────
        //
        // O'chirish yangi xabar tug'dirmaydi, ya'ni `since`
        // bilan sezilmasdi. Server suhbatda HOZIR turgan
        // raqamlarni yuboradi va ro'yxat shunga qarab
        // tozalanadi.
        var removed = false;
        if (j['all_ids'] is List) {
          final live = (j['all_ids'] as List).map((e) => '$e').toSet();
          final before = _items.length;
          _items.removeWhere((m) => !m.pending && !live.contains(m.id));
          removed = _items.length != before;
        }

        if (since > 0) {
          final have = _items.map((m) => m.id).toSet();
          final fresh = rows.where((m) => !have.contains(m.id)).toList();
          if (fresh.isNotEmpty) {
            _items.removeWhere((m) => m.pending);
            _items.addAll(fresh);
          }
          // Reaksiyalar eski xabarlarda ham o'zgargan bo'lishi
          // mumkin — kelganlari ustiga yoziladi.
          _mergeReactions(rows);
          if (fresh.isNotEmpty || removed) _saveDisk();
        } else {
          _items
            ..clear()
            ..addAll(rows);
          DiskCache.write(_diskKey, raw);
        }
        _loaded = true;
        _error = null;
      } else {
        _error = 'Yuklanmadi (${r.statusCode})';
      }
    } catch (_) {
      if (!_loaded) _error = 'Internet yo\'q';
    }
    _loading = false;
    notifyListeners();
  }

  /// Serverdan kelgan reaksiyalarni mavjud xabarlarga ko'chiradi.
  void _mergeReactions(List<DmMessage> rows) {
    if (rows.isEmpty) return;
    final byId = {for (final r in rows) r.id: r};
    for (var i = 0; i < _items.length; i++) {
      final fresh = byId[_items[i].id];
      if (fresh == null) continue;
      _items[i] = _items[i].copyWith(
        reactionsRaw: fresh.reactionsRaw,
        myReaction: fresh.myReaction,
      );
    }
  }

  /// Xabar yuboradi.
  ///
  /// Xabar ekranda DARHOL ko'rinadi (serverni kutmasdan) —
  /// Telegramdagidek. Javob kelgach vaqtinchalik nusxa
  /// haqiqiysi bilan almashadi.
  Future<String?> send({
    String body = '',
    String mediaFile = '',
    String mediaType = '',
    int mediaMs = 0,
  }) async {
    final text = body.trim();
    if (text.isEmpty && mediaFile.isEmpty) return null;

    final temp = DmMessage(
      id: 'tmp${DateTime.now().microsecondsSinceEpoch}',
      mine: true,
      fromId: AuthService.instance.user?.id ?? 0,
      body: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      pending: true,
    );
    // Media bo'lsa vaqtinchalik nusxa ko'rsatilmaydi: manzil
    // hali yo'q va bo'sh puffak chiqardi.
    if (mediaFile.isEmpty) {
      _items.add(temp);
      notifyListeners();
    }

    try {
      final r = await http
          .post(
            Uri.parse(_base),
            headers: _headers(json: true),
            body: jsonEncode({
              'to': otherId,
              'body': text,
              if (mediaFile.isNotEmpty) 'media_file': mediaFile,
              if (mediaType.isNotEmpty) 'media_type': mediaType,
              if (mediaMs > 0) 'media_ms': mediaMs,
            }),
          )
          .timeout(const Duration(seconds: 25));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 && r.statusCode != 201) {
        _items.removeWhere((m) => m.id == temp.id);
        notifyListeners();
        return '${j['error'] ?? 'Yuborilmadi'}';
      }
      _items.removeWhere((m) => m.id == temp.id);
      _items.add(DmMessage.fromJson(j));
      _saveDisk();
      notifyListeners();
      return null;
    } catch (_) {
      _items.removeWhere((m) => m.id == temp.id);
      notifyListeners();
      return 'Internet yo\'q';
    }
  }

  /// Reaksiya qo'yadi yoki olib tashlaydi.
  ///
  /// Ekranda DARHOL o'zgaradi; server rad etsa eski holat
  /// qaytariladi.
  Future<String?> react(String msgId, String emoji) async {
    final i = _items.indexWhere((m) => m.id == msgId);
    if (i < 0) return null;
    final old = _items[i];
    // Xuddi shunisi turgan bo'lsa — olib tashlanadi.
    final next = old.myReaction == emoji ? '' : emoji;
    _items[i] = old.copyWith(myReaction: next);
    notifyListeners();

    try {
      final r = await http
          .post(
            Uri.parse('$_base/react'),
            headers: _headers(json: true),
            body: jsonEncode({'id': msgId, 'emoji': next}),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        _items[i] = old;
        notifyListeners();
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return '${j['error'] ?? 'Reaksiya qo\'yilmadi'}';
      }
      // Sonlar serverdan keladi — keyingi yuklashda aniqlanadi.
      unawaited(load(force: true));
      return null;
    } catch (_) {
      _items[i] = old;
      notifyListeners();
      return 'Internet yo\'q';
    }
  }

  /// O'z xabarini o'chiradi.
  Future<String?> remove(String msgId) async {
    final i = _items.indexWhere((m) => m.id == msgId);
    if (i < 0) return null;
    final saved = _items[i];
    _items.removeAt(i);
    _saveDisk();
    notifyListeners();
    try {
      final r = await http
          .delete(Uri.parse('$_base/message/$msgId'), headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) return null;
      // Server rad etdi — xabar joyiga qaytadi.
      _items.insert(i, saved);
      _saveDisk();
      notifyListeners();
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return '${j['error'] ?? 'O\'chirilmadi'}';
    } catch (_) {
      _items.insert(i, saved);
      _saveDisk();
      notifyListeners();
      return 'Internet yo\'q';
    }
  }
}

// ══════════════════════════════════════════════════════════════
//  ADMIN: BARCHA SHAXSIY SUHBATLAR
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "barcha shaxsiy chatlar admin panelida
// ko'rinishi kerak, ya'ni ikkala profil rasmi bitta ro'yxatda
// turadi va ustiga bossa ikkalasini yuborgan xabarlari chiqadi.
// Bu biroz noto'g'ri lekin xavfsizlik va nomaqbul hatti
// harakatlarni oldini olish uchun zarur".
//
// Admin faqat O'QIY oladi — boshqaning nomidan yozolmaydi.
// Tekshiruv serverda (`admin_dm_threads`, `admin_dm_open`).

@immutable
class AdminDmThread {
  final String dmId;
  final DmPerson a;
  final DmPerson b;
  final String lastBody;
  final int lastAt;
  final int msgCount;

  const AdminDmThread({
    required this.dmId,
    required this.a,
    required this.b,
    required this.lastBody,
    required this.lastAt,
    required this.msgCount,
  });

  static AdminDmThread fromJson(Map<String, dynamic> j) => AdminDmThread(
        dmId: '${j['dm_id'] ?? ''}',
        a: DmPerson.fromJson(
            (j['a'] as Map?)?.cast<String, dynamic>() ?? const {}),
        b: DmPerson.fromJson(
            (j['b'] as Map?)?.cast<String, dynamic>() ?? const {}),
        lastBody: '${j['last_body'] ?? ''}',
        lastAt: ((j['last_at'] as num?) ?? 0).toInt(),
        msgCount: ((j['msg_count'] as num?) ?? 0).toInt(),
      );
}

class AdminDmController extends ChangeNotifier {
  final List<AdminDmThread> _items = [];
  List<AdminDmThread> get items => List.unmodifiable(_items);

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _loaded = false;
  int _page = 0;
  int _total = 0;
  String? _error;

  bool get isLoading => _loading && _items.isEmpty;
  bool get isLoadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  int get total => _total;
  String? get error => _error;

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$kApiBase/api/admin/dm/threads?page=0'),
              headers: _headers())
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _items
          ..clear()
          ..addAll(_parse(j['items']));
        _page = 0;
        _hasMore = j['has_more'] == true;
        _total = ((j['total'] as num?) ?? _items.length).toInt();
        _loaded = true;
      } else {
        _error = 'Yuklanmadi (${r.statusCode})';
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
          .get(Uri.parse('$kApiBase/api/admin/dm/threads?page=$next'),
              headers: _headers())
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        // Takrorlanmasin: sekin tarmoqda bir sahifa ikki marta
        // kelishi mumkin.
        final have = _items.map((e) => e.dmId).toSet();
        _items.addAll(_parse(j['items']).where((e) => !have.contains(e.dmId)));
        _page = next;
        _hasMore = j['has_more'] == true;
      }
    } catch (_) {
      // Jim: keyingi urinishda yana so'raladi.
    }
    _loadingMore = false;
    notifyListeners();
  }

  List<AdminDmThread> _parse(dynamic raw) => ((raw as List?) ?? [])
      .cast<Map<String, dynamic>>()
      .map(AdminDmThread.fromJson)
      .toList();
}

/// ADMIN: bitta suhbatning xabarlari.
///
/// `mine` bu yerda ma'nosiz (admin ikkovidan biri emas), shu
/// sabab har xabarda `fromId` bo'yicha kim yozgani aniqlanadi.
Future<List<DmMessage>> adminDmMessages(String dmId) async {
  try {
    final r = await http
        .get(Uri.parse('$kApiBase/api/admin/dm/$dmId'), headers: _headers())
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) return const [];
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return ((j['items'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map(DmMessage.fromJson)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// ADMIN: nomaqbul xabarni o'chiradi.
///
/// Server `dm_del_message` da adminni o'tkazadi — nomaqbul
/// xabarni olib tashlash shikoyat tizimining bir qismi.
Future<String?> adminDeleteDmMessage(String msgId) async {
  try {
    final r = await http
        .delete(Uri.parse('$_base/message/$msgId'), headers: _headers())
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return '${j['error'] ?? 'O\'chirilmadi'}';
  } catch (_) {
    return 'Internet yo\'q';
  }
}
