// lib/services/support_service.dart — ADMIN BILAN YOZISHMA.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "profil sahifasiga admin bilan bog'lanadigan chat
// qo'sh; admin paneliga barcha chatlar bo'limi; Telegram chatidek
// ishlasin — xabar o'qilmagan bo'lsa profil sahifasida nuqta yonib
// tursin; admin panelida yangi xabar yuqorida tursin va profil
// rasmi bilan ko'rinsin".
//
// ── NUQTA QANDAY YONADI ─────────────────────────────────────
//
// `UnreadBadge` — kichkina alohida xizmat. U FAQAT SONNI so'raydi
// (`/api/chat/unread`), xabarlarning o'zini emas. Javob bir necha
// o'nlab bayt, ya'ni uni tez-tez so'rash arzon.
//
// So'rov qachon ketadi:
//   * ilova ochilganda bir marta;
//   * profil sahifasi ochiq turganda har 30 soniyada;
//   * chat yopilganda (o'qilgan xabarlar hisobdan chiqsin).
//
// Ya'ni ilova fon'da turganda HECH QANDAY so'rov ketmaydi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// Bitta xabar.
@immutable
class ChatMessage {
  final String id;
  final bool fromAdmin;
  final String body;
  final int createdAt;

  const ChatMessage({
    required this.id,
    required this.fromAdmin,
    required this.body,
    required this.createdAt,
  });

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        id: '${j['id'] ?? ''}',
        fromAdmin: j['from_admin'] == true,
        body: '${j['body'] ?? ''}',
        createdAt: ((j['created_at'] as num?) ?? 0).toInt(),
      );
}

/// Admin ro'yxatidagi bitta suhbat.
@immutable
class ChatThread {
  final int userId;
  final String firstName;
  final String username;
  final String photoUrl;
  final String lastBody;
  final int lastAt;
  final bool lastFromAdmin;
  final int unread;

  const ChatThread({
    required this.userId,
    required this.firstName,
    required this.username,
    required this.photoUrl,
    required this.lastBody,
    required this.lastAt,
    required this.lastFromAdmin,
    required this.unread,
  });

  String get name {
    final n = firstName.trim();
    if (n.isNotEmpty) return n;
    final u = username.trim();
    return u.isNotEmpty ? '@$u' : 'Foydalanuvchi $userId';
  }

  static ChatThread fromJson(Map<String, dynamic> j) => ChatThread(
        userId: ((j['user_id'] as num?) ?? 0).toInt(),
        firstName: '${j['first_name'] ?? ''}',
        username: '${j['username'] ?? ''}',
        photoUrl: '${j['photo_url'] ?? ''}',
        lastBody: '${j['last_body'] ?? ''}',
        lastAt: ((j['last_at'] as num?) ?? 0).toInt(),
        lastFromAdmin: j['last_from_admin'] == true,
        unread: ((j['unread'] as num?) ?? 0).toInt(),
      );
}

Map<String, String> _headers({bool json = false}) {
  final t = AuthService.instance.sessionToken;
  return {
    if (t != null) 'Authorization': 'Bearer $t',
    if (json) 'Content-Type': 'application/json',
  };
}

String get _base => '$kApiBase/api/chat';

// ══════════════════════════════════════════════════════════════
//  O'QILMAGAN XABARLAR BELGISI
// ══════════════════════════════════════════════════════════════

class UnreadBadge extends ChangeNotifier {
  UnreadBadge._();
  static final UnreadBadge instance = UnreadBadge._();

  int _count = 0;
  bool _busy = false;

  /// Nechta o'qilmagan xabar bor.
  int get count => _count;

  /// Nuqta yonsinmi.
  bool get has => _count > 0;

  /// Hisob almashganda.
  void clear() {
    if (_count == 0) return;
    _count = 0;
    notifyListeners();
  }

  /// Xabarlar o'qildi — nuqta darhol o'chsin (serverni kutmasdan).
  void markRead() {
    if (_count == 0) return;
    _count = 0;
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
      // Jim: nuqta eski holicha qoladi.
    }
    _busy = false;
  }
}

// ══════════════════════════════════════════════════════════════
//  BITTA SUHBAT
// ══════════════════════════════════════════════════════════════

class ChatController extends ChangeNotifier {
  /// Admin boshqa odamning suhbatini ochsa — o'sha odamning raqami.
  /// `null` — o'z suhbatim.
  final int? userId;

  ChatController({this.userId});

  bool get isAdminView => userId != null;

  final List<ChatMessage> _items = [];
  List<ChatMessage> get items => List.unmodifiable(_items);

  bool _loading = false;
  bool _loaded = false;
  String? _error;
  Timer? _poll;

  bool get isLoading => _loading && _items.isEmpty;
  bool get hasData => _loaded;
  String? get error => _error;

  String get _url =>
      userId == null ? _base : '$_base/thread/$userId';

  /// Suhbat ochiq turganda yangi xabarlar o'zi kelib tursin.
  ///
  /// 10 soniya — Telegram'dagidek "jonli" tuyuladi, lekin so'rovlar
  /// soni ham oqilona: suhbat ochiq turgan vaqtgina ishlaydi va
  /// ekran yopilishi bilan to'xtaydi.
  void startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => load(force: true));
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    _poll?.cancel();
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
    try {
      final r = await http
          .get(Uri.parse(_url), headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final rows = ((j['items'] as List?) ?? [])
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        // Ro'yxat FAQAT haqiqatan o'zgarganda almashtiriladi —
        // aks holda har 10 soniyada ekran bekorga qayta chizilardi.
        if (rows.length != _items.length ||
            (rows.isNotEmpty &&
                _items.isNotEmpty &&
                rows.last.id != _items.last.id)) {
          _items
            ..clear()
            ..addAll(rows);
        }
        _loaded = true;
        _error = null;
        // Server bu so'rovda xabarlarni O'QILDI deb belgiladi.
        UnreadBadge.instance.markRead();
      } else {
        _error = 'Yuklanmadi (${r.statusCode})';
      }
    } catch (_) {
      if (!_loaded) _error = 'Internet yo\'q';
    }
    _loading = false;
    notifyListeners();
  }

  /// Xabar yuboradi. Xato bo'lsa matn qaytadi.
  Future<String?> send(String body) async {
    final text = body.trim();
    if (text.isEmpty) return null;
    try {
      final r = await http
          .post(
            Uri.parse(_base),
            headers: _headers(json: true),
            body: jsonEncode({
              'body': text,
              if (userId != null) 'user_id': userId,
            }),
          )
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 && r.statusCode != 201) {
        return '${j['error'] ?? 'Yuborilmadi'}';
      }
      _items.add(ChatMessage.fromJson(j));
      _loaded = true;
      notifyListeners();
      return null;
    } catch (_) {
      return 'Internet yo\'q — qaytadan urinib ko\'ring';
    }
  }
}

// ══════════════════════════════════════════════════════════════
//  ADMIN: BARCHA SUHBATLAR
// ══════════════════════════════════════════════════════════════

class ChatThreadsController extends ChangeNotifier {
  final List<ChatThread> _items = [];
  List<ChatThread> get items => List.unmodifiable(_items);

  bool _loading = false;
  bool _loaded = false;
  String? _error;

  bool get isLoading => _loading && _items.isEmpty;
  bool get hasData => _loaded;
  String? get error => _error;

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    _loading = true;
    if (!_loaded) notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$_base/threads'), headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _items
          ..clear()
          ..addAll(((j['items'] as List?) ?? [])
              .map((e) => ChatThread.fromJson(e as Map<String, dynamic>)));
        _loaded = true;
        _error = null;
      } else if (r.statusCode == 403) {
        _error = 'Bu bo\'lim faqat admin uchun';
      } else {
        _error = 'Yuklanmadi (${r.statusCode})';
      }
    } catch (_) {
      _error = 'Internet yo\'q';
    }
    _loading = false;
    notifyListeners();
  }
}

/// Telegram'dagidek qisqa vaqt: bugun — soat, aks holda sana.
String chatTime(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${two(d.hour)}:${two(d.minute)}';
  }
  if (d.year == now.year) return '${two(d.day)}.${two(d.month)}';
  return '${two(d.day)}.${two(d.month)}.${d.year}';
}
