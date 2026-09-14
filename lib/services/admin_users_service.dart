// lib/services/admin_users_service.dart — FOYDALANUVCHILARNI BOSHQARISH.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "admin paneliga foydalanuvchilarni boshqaradigan
// bo'lim qo'sh: oxirgi ro'yxatdan o'tgan va oxirgi onlayn bo'lgan
// vaqti bo'yicha ikkita ro'yxat, yuqorida ID yoki username bilan
// izlash, balansni qo'lda to'ldirish, bloklash va yana kerakli
// narsalar".
//
// ── HAR BIR AMAL SERVERDA TEKSHIRILADI ──────────────────────
//
// Bu yerdagi kod shunchaki so'rov yuboradi. Kim admin ekanini va
// amalga ruxsat bor-yo'qligini SERVER hal qiladi (`admin_only`).
// Ya'ni ilovani o'zgartirish bilan birovning balansini
// o'zgartirib bo'lmaydi.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// Ro'yxat qaysi vaqt bo'yicha terilgan.
enum UserSort {
  /// Oxirgi ro'yxatdan o'tganlar.
  registered('new', 'Yangi qo\'shilgan'),

  /// Oxirgi onlayn bo'lganlar.
  online('online', 'Oxirgi onlayn');

  final String code;
  final String label;
  const UserSort(this.code, this.label);
}

/// Ro'yxatdagi bitta foydalanuvchi.
@immutable
class AdminUser {
  final int id;
  final String username;
  final String firstName;
  final String lastName;
  final String photoUrl;
  final int telegramId;
  final int balance;
  final bool banned;
  final int createdAt;
  final int lastLoginAt;

  const AdminUser({
    required this.id,
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.photoUrl,
    required this.telegramId,
    required this.balance,
    required this.banned,
    required this.createdAt,
    required this.lastLoginAt,
  });

  String get name {
    final n = '$firstName $lastName'.trim();
    if (n.isNotEmpty) return n;
    if (username.isNotEmpty) return '@$username';
    return 'Foydalanuvchi $id';
  }

  static AdminUser fromJson(Map<String, dynamic> j) => AdminUser(
        id: ((j['id'] as num?) ?? 0).toInt(),
        username: '${j['username'] ?? ''}',
        firstName: '${j['first_name'] ?? ''}',
        lastName: '${j['last_name'] ?? ''}',
        photoUrl: '${j['photo_url'] ?? ''}',
        telegramId: ((j['telegram_id'] as num?) ?? 0).toInt(),
        balance: ((j['balance'] as num?) ?? 0).toInt(),
        banned: j['banned'] == true,
        createdAt: ((j['created_at'] as num?) ?? 0).toInt(),
        lastLoginAt: ((j['last_login_at'] as num?) ?? 0).toInt(),
      );
}

Map<String, String> _headers({bool json = false}) {
  final t = AuthService.instance.sessionToken;
  return {
    if (t != null) 'Authorization': 'Bearer $t',
    if (json) 'Content-Type': 'application/json',
  };
}

class AdminUsersController extends ChangeNotifier {
  final List<AdminUser> _items = [];
  List<AdminUser> get items => List.unmodifiable(_items);

  UserSort _sort = UserSort.registered;
  String _query = '';
  int _page = 0;
  int _total = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  UserSort get sort => _sort;
  String get query => _query;
  int get total => _total;
  bool get isLoading => _loading && _items.isEmpty;
  bool get isLoadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String? get error => _error;

  /// Ro'yxat turini almashtiradi va qaytadan yuklaydi.
  void setSort(UserSort s) {
    if (_sort == s) return;
    _sort = s;
    load(force: true);
  }

  /// Izlash matni o'zgardi.
  ///
  /// Chaqiruvchi buni KECHIKTIRIB chaqiradi (har harfda emas) —
  /// aks holda yozayotgan paytda o'nlab so'rov ketardi.
  void setQuery(String q) {
    final t = q.trim();
    if (_query == t) return;
    _query = t;
    load(force: true);
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_items.isNotEmpty && !force) return;
    _loading = true;
    _page = 0;
    _error = null;
    notifyListeners();
    final rows = await _fetch(0);
    _items
      ..clear()
      ..addAll(rows);
    _loading = false;
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;
    _loadingMore = true;
    notifyListeners();
    final next = _page + 1;
    final rows = await _fetch(next);
    // Takrorlanmasin: sekin tarmoqda bir sahifa ikki marta
    // kelishi mumkin.
    final have = _items.map((u) => u.id).toSet();
    _items.addAll(rows.where((u) => !have.contains(u.id)));
    _page = next;
    _loadingMore = false;
    notifyListeners();
  }

  Future<List<AdminUser>> _fetch(int page) async {
    try {
      final uri = Uri.parse(
          '$kApiBase/api/admin/users?sort=${_sort.code}&page=$page'
          '&q=${Uri.encodeQueryComponent(_query)}');
      final r =
          await http.get(uri, headers: _headers()).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _total = ((j['total'] as num?) ?? 0).toInt();
        _hasMore = j['has_more'] == true;
        _error = null;
        return ((j['items'] as List?) ?? [])
            .map((e) => AdminUser.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      if (r.statusCode == 403) {
        _error = 'Bu bo\'lim faqat admin uchun';
      } else {
        _error = 'Yuklanmadi (${r.statusCode})';
      }
    } catch (_) {
      _error = 'Internet yo\'q';
    }
    _hasMore = false;
    return const [];
  }

  /// Bitta foydalanuvchi ustida amal bajaradi va ro'yxatni
  /// yangilaydi. Xato bo'lsa matn qaytadi.
  Future<String?> act(
    int userId,
    String action, {
    int amount = 0,
    int days = 0,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/admin/user/$userId'),
            headers: _headers(json: true),
            body: jsonEncode({
              'action': action,
              if (amount != 0) 'amount': amount,
              'days': days,
            }),
          )
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return '${j['error'] ?? 'Bajarilmadi'}';
      }
      // Ro'yxatdagi qator YANGI qiymat bilan almashtiriladi —
      // butun ro'yxatni qayta so'rashning hojati yo'q.
      final i = _items.indexWhere((u) => u.id == userId);
      if (i >= 0) {
        final old = _items[i];
        _items[i] = AdminUser(
          id: old.id,
          username: old.username,
          firstName: old.firstName,
          lastName: old.lastName,
          photoUrl: old.photoUrl,
          telegramId: old.telegramId,
          balance: ((j['balance'] as num?) ?? old.balance).toInt(),
          banned: j.containsKey('banned') ? j['banned'] == true : old.banned,
          createdAt: old.createdAt,
          lastLoginAt: old.lastLoginAt,
        );
        notifyListeners();
      }
      return null;
    } catch (_) {
      return 'Internet yo\'q';
    }
  }
}
