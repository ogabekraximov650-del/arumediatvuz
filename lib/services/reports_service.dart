// lib/services/reports_service.dart — SHIKOYATLAR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "izohning o'ng chetiga 3ta nuqta qo'y va
// nuqtani bosganda 'shikoyat qilish' degan yozuv bo'lsin; ustiga
// bosganda pastdan shikoyat yozish oynasi chiqsin. Admin panelida
// esa shikoyatlar bo'limida shikoyat qayerdan kelgani, shikoyat
// qilingan izoh va shikoyat qiluvchining xabari tursin; tagida
// Tekshirish, Xabar yuborish va Tozalash tugmalari bo'ladi".
//
// ── HAR BIR QOIDA SERVERDA ──────────────────────────────────
//
// Bu yerdagi kod shunchaki so'rov yuboradi. Kim shikoyat qila
// oladi, bir izohga necha marta va soatiga nechta — hammasini
// SERVER hal qiladi (`report_add`). Ya'ni o'zgartirilgan ilova
// bilan ham chegaradan o'tib bo'lmaydi.
//
// Ro'yxat DISKKA saqlanmaydi: u faqat adminga ko'rinadi, tez-tez
// o'zgaradi va ichida boshqa odamlarning shikoyatlari bor —
// telefonda yotib qolishining ma'nosi yo'q.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

String get _base => '$kApiBase/api';

Map<String, String> _headers({bool json = false}) {
  final t = AuthService.instance.sessionToken;
  return {
    if (t != null) 'Authorization': 'Bearer $t',
    if (json) 'Content-Type': 'application/json',
  };
}

/// Shikoyat matnining eng kam uzunligi.
///
/// Serverdagi `REPORT_MIN` bilan bir xil. Bu yerda ham
/// tekshiriladi — shunda "juda qisqa" degan javob uchun bekorga
/// tarmoqqa chiqilmaydi.
const int kReportMinLength = 10;

/// Shikoyat matnining eng ko'p uzunligi (serverdagi `REPORT_MAX`).
const int kReportMaxLength = 2000;

/// Izohga shikoyat yuboradi. Xato bo'lsa matn qaytadi.
Future<String?> sendCommentReport({
  required String commentId,
  required String reason,
}) =>
    _sendReport(kind: 'comment', targetId: commentId, reason: reason);

/// Shaxsiy yozishmadagi xabarga shikoyat yuboradi.
///
/// TALAB (foydalanuvchi): shaxsiy chatda ham "yuborilgan xabarga
/// shikoyat qilish" bo'lsin.
Future<String?> sendDmReport({
  required String messageId,
  required String reason,
}) =>
    _sendReport(kind: 'dm', targetId: messageId, reason: reason);

Future<String?> _sendReport({
  required String kind,
  required String targetId,
  required String reason,
}) async {
  if (AuthService.instance.sessionToken == null) {
    return 'Shikoyat yuborish uchun hisobingizga kiring';
  }
  final text = reason.trim();
  if (text.length < kReportMinLength) {
    return 'Iltimos, shikoyat sababini batafsilroq yozing';
  }
  try {
    final r = await http
        .post(
          Uri.parse('$_base/reports'),
          headers: _headers(json: true),
          body: jsonEncode({
            'kind': kind,
            'target_id': targetId,
            'reason': text,
          }),
        )
        .timeout(const Duration(seconds: 25));
    if (r.statusCode == 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return '${j['error'] ?? 'Shikoyat yuborilmadi'}';
  } catch (_) {
    return 'Internet yo\'q — qaytadan urinib ko\'ring';
  }
}

/// ADMIN: shikoyat qilingan izohni o'chiradi.
///
/// "Tekshirish" oynasidan chaqiriladi. Server `comments_delete`
/// da adminni alohida qarab chiqadi (o'sha yerdagi izohga
/// qarang) — ya'ni ruxsat SHU YERDA emas, serverda hal bo'ladi.
///
/// Izoh o'chganda unga kelgan shikoyatlar ham serverda
/// o'chiriladi, ya'ni ro'yxatni alohida tozalash shart emas.
Future<String?> deleteReportedComment(String commentId) async {
  try {
    final r = await http
        .delete(Uri.parse('$_base/comments/$commentId'), headers: _headers())
        .timeout(const Duration(seconds: 25));
    if (r.statusCode == 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return '${j['error'] ?? 'O\'chirilmadi'}';
  } catch (_) {
    return 'Internet yo\'q';
  }
}

// ══════════════════════════════════════════════════════════════
//  ADMIN TOMONI
// ══════════════════════════════════════════════════════════════

/// Shikoyatga aloqador odam (shikoyat qiluvchi yoki izoh muallifi).
@immutable
class ReportPerson {
  final int id;
  final String firstName;
  final String username;
  final String photoUrl;

  const ReportPerson({
    required this.id,
    required this.firstName,
    required this.username,
    required this.photoUrl,
  });

  /// Ekranda ko'rinadigan nom.
  String get name {
    final n = firstName.trim();
    if (n.isNotEmpty) return n;
    final u = username.trim();
    return u.isNotEmpty ? '@$u' : 'Foydalanuvchi';
  }

  static ReportPerson fromJson(Map<String, dynamic> j) => ReportPerson(
        id: ((j['id'] as num?) ?? 0).toInt(),
        firstName: '${j['first_name'] ?? ''}',
        username: '${j['username'] ?? ''}',
        photoUrl: '${j['photo_url'] ?? ''}',
      );
}

/// Bitta shikoyat.
@immutable
class AdminReport {
  final String id;

  /// Hozircha faqat `comment`.
  final String kind;

  /// Shikoyat qilingan izohning raqami.
  final String targetId;

  /// Izohning SHIKOYAT KELGAN PAYTDAGI matni.
  ///
  /// Izoh keyin o'chirilgan bo'lsa ham admin nimadan shikoyat
  /// qilinganini ko'radi.
  final String targetBody;

  /// Izoh hali ham turibdimi.
  final bool targetAlive;

  final int animeId;
  final int seasonId;

  /// Shikoyat qiluvchining xabari.
  final String reason;
  final int createdAt;

  final ReportPerson author;
  final ReportPerson reporter;

  const AdminReport({
    required this.id,
    required this.kind,
    required this.targetId,
    required this.targetBody,
    required this.targetAlive,
    required this.animeId,
    required this.seasonId,
    required this.reason,
    required this.createdAt,
    required this.author,
    required this.reporter,
  });

  /// "Shikoyat qayerdan kelgan" (foydalanuvchi talabi).
  String get sourceLabel => switch (kind) {
        'comment' => 'Izohdan',
        'dm' => 'Shaxsiy yozishmadan',
        _ => kind,
      };

  static AdminReport fromJson(Map<String, dynamic> j) => AdminReport(
        id: '${j['id'] ?? ''}',
        kind: '${j['kind'] ?? 'comment'}',
        targetId: '${j['target_id'] ?? ''}',
        targetBody: '${j['target_body'] ?? ''}',
        targetAlive: j['target_alive'] == true,
        animeId: ((j['anime_id'] as num?) ?? 0).toInt(),
        seasonId: ((j['season_id'] as num?) ?? 0).toInt(),
        reason: '${j['reason'] ?? ''}',
        createdAt: ((j['created_at'] as num?) ?? 0).toInt(),
        author: ReportPerson.fromJson(
            (j['target_user'] as Map?)?.cast<String, dynamic>() ?? {}),
        reporter: ReportPerson.fromJson(
            (j['reporter'] as Map?)?.cast<String, dynamic>() ?? {}),
      );
}

/// Admin panelidagi shikoyatlar ro'yxati.
class AdminReportsController extends ChangeNotifier {
  final List<AdminReport> _items = [];
  List<AdminReport> get items => List.unmodifiable(_items);

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _loaded = false;
  int _page = 0;
  int _total = 0;
  String? _error;

  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  bool get hasData => _loaded;
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
          .get(Uri.parse('$_base/admin/reports?page=0'), headers: _headers())
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
          .get(Uri.parse('$_base/admin/reports?page=$next'),
              headers: _headers())
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        // Takrorlanmasin: sekin tarmoqda bir sahifa ikki marta
        // kelishi mumkin.
        final have = _items.map((e) => e.id).toSet();
        _items.addAll(_parse(j['items']).where((e) => !have.contains(e.id)));
        _page = next;
        _hasMore = j['has_more'] == true;
      }
    } catch (_) {
      // Jim: keyingi urinishda yana so'raladi.
    }
    _loadingMore = false;
    notifyListeners();
  }

  List<AdminReport> _parse(dynamic raw) => ((raw as List?) ?? [])
      .cast<Map<String, dynamic>>()
      .map(AdminReport.fromJson)
      .toList();

  /// "Tozalash" — shikoyatni bazadan o'chiradi.
  ///
  /// Ro'yxatdan DARHOL olib tashlanadi: tarmoq javobi kelguncha
  /// qator ekranda turib qolsa, admin uni ikkinchi marta
  /// bosardi.
  Future<String?> remove(String id) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return null;
    final saved = _items[idx];
    _items.removeAt(idx);
    if (_total > 0) _total -= 1;
    notifyListeners();
    try {
      final r = await http
          .delete(Uri.parse('$_base/admin/report/$id'), headers: _headers())
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) return null;
      // Server rad etdi — qator joyiga qaytadi.
      _items.insert(idx, saved);
      _total += 1;
      notifyListeners();
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return '${j['error'] ?? 'Tozalanmadi'}';
    } catch (_) {
      _items.insert(idx, saved);
      _total += 1;
      notifyListeners();
      return 'Internet yo\'q';
    }
  }
}
