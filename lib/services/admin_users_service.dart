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
import 'disk_cache.dart';

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

  /// ── BLOK MUDDATI VA SABABI ──────────────────────────────
  ///
  /// TALAB (foydalanuvchi): "bloklaganda muddatsiz va muddatli
  /// bloklash tizimini qo'sh va bloklanish sababini ham yozsa
  /// bo'ladigan qil".
  ///
  /// `banUntil` = 0 va `banned` = true — MUDDATSIZ.
  final int banUntil;
  final String banReason;

  final int createdAt;
  final int lastLoginAt;

  /// Obuna qachon tugaydi (0 — obuna yo'q).
  final int subUntil;

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
    this.banUntil = 0,
    this.banReason = '',
    this.subUntil = 0,
  });

  /// Blok muddatsizmi.
  bool get banForever => banned && banUntil <= 0;

  /// Blok muddati tugashiga qancha qolgan (`null` — muddatsiz
  /// yoki bloklanmagan).
  Duration? get banLeft {
    if (!banned || banUntil <= 0) return null;
    final ms = banUntil - DateTime.now().millisecondsSinceEpoch;
    return ms <= 0 ? Duration.zero : Duration(milliseconds: ms);
  }

  /// Obunadan necha kun qolgan (0 — obuna yo'q yoki tugagan).
  int get subDaysLeft {
    final ms = subUntil - DateTime.now().millisecondsSinceEpoch;
    if (ms <= 0) return 0;
    // Boshlangan kun ham sanaladi: 1.2 kun qolgan bo'lsa
    // "2 kun" deyilgani "1 kun" deyilganidan to'g'riroq.
    return (ms / 86400000).ceil();
  }

  bool get hasSub => subDaysLeft > 0;

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
        banUntil: ((j['ban_until'] as num?) ?? 0).toInt(),
        banReason: '${j['ban_reason'] ?? ''}',
        createdAt: ((j['created_at'] as num?) ?? 0).toInt(),
        lastLoginAt: ((j['last_login_at'] as num?) ?? 0).toInt(),
        subUntil: ((j['sub_until'] as num?) ?? 0).toInt(),
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
    _items.clear();
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

  /// Diskdagi kalit. Har bir ro'yxat turi alohida saqlanadi —
  /// izlash natijasi esa SAQLANMAYDI (u vaqtinchalik).
  String get _diskKey => 'admin_users_${_sort.code}';

  /// Diskdagi nusxani DARHOL ko'rsatadi (tarmoq kutilmaydi).
  ///
  /// TALAB (foydalanuvchi): "admin panelidagi ma'lumotlar ham
  /// diskda saqlansin, keyingi safar sekin ochilmasligi uchun".
  void loadFromDisk() {
    if (_query.isNotEmpty) return;
    final rows = DiskCache.read(_diskKey);
    if (rows == null) return;
    _items
      ..clear()
      ..addAll(rows.map(AdminUser.fromJson));
    notifyListeners();
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_items.isNotEmpty && !force) return;
    _loading = true;
    _page = 0;
    _error = null;
    // Yangi ro'yxat turiga o'tilgan bo'lsa — uning diskdagi
    // nusxasi darhol chiqadi.
    loadFromDisk();
    notifyListeners();
    final rows = await _fetch(0);
    if (rows.isNotEmpty || _error == null) {
      _items
        ..clear()
        ..addAll(rows);
    }
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
        final raw =
            ((j['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        // Faqat BIRINCHI sahifa va izlashsiz holat saqlanadi:
        // ekran ochilganda kerak bo'ladigan narsa aynan shu.
        if (page == 0 && _query.isEmpty) DiskCache.write(_diskKey, raw);
        return raw.map(AdminUser.fromJson).toList();
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
    String reason = '',
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
              // Bloklash sababi (boshqa amallarda bo'sh).
              if (reason.isNotEmpty) 'reason': reason,
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
          banUntil: j.containsKey('banned')
              ? ((j['ban_until'] as num?) ?? 0).toInt()
              : old.banUntil,
          banReason: j.containsKey('banned')
              ? '${j['ban_reason'] ?? ''}'
              : old.banReason,
          createdAt: old.createdAt,
          lastLoginAt: old.lastLoginAt,
          subUntil: j.containsKey('subscription_until')
              ? ((j['subscription_until'] as num?) ?? 0).toInt()
              : old.subUntil,
        );
        notifyListeners();
      }
      return null;
    } catch (_) {
      return 'Internet yo\'q';
    }
  }
}

// ══════════════════════════════════════════════════════════════
//  B2'DAGI YETIM FAYLLARNI TOZALASH
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "B2'da qolib ketgan eski fayllarni
// tozalab tashla, ya'ni animega tegishli bo'lmagan fayllarni".
//
// Yetim fayl — bazada unga ISHORA QILADIGAN birorta qator
// qolmagan fayl. U hech qachon ochilmaydi, lekin ombor uchun pul
// yeb turadi.
//
// Server bir chaqiruvda cheklangan sonda o'chiradi va davomi
// uchun kursor qaytaradi — shu sabab bu yerda TUGAGUNCHA
// takrorlanadi.

class B2CleanResult {
  final int checked;
  final int deleted;
  final int freed;
  final String? error;

  const B2CleanResult({
    this.checked = 0,
    this.deleted = 0,
    this.freed = 0,
    this.error,
  });
}

Future<B2CleanResult> b2Cleanup({
  bool dry = false,
  void Function(int deleted)? onStep,
}) async {
  var checked = 0;
  var deleted = 0;
  var freed = 0;
  var start = '';
  try {
    // Cheksiz aylanishdan himoya: 200 qadam ham yetib ortadi.
    for (var step = 0; step < 200; step++) {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/admin/b2-cleanup'),
            headers: _headers(json: true),
            body: jsonEncode({'dry': dry, 'start': start}),
          )
          .timeout(const Duration(seconds: 60));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return B2CleanResult(
          checked: checked,
          deleted: deleted,
          freed: freed,
          error: '${j['error'] ?? 'Tozalanmadi (${r.statusCode})'}',
        );
      }
      checked += ((j['checked'] as num?) ?? 0).toInt();
      deleted += ((j['deleted'] as num?) ?? 0).toInt();
      freed += ((j['freed'] as num?) ?? 0).toInt();
      onStep?.call(deleted);
      if (j['done'] == true) break;
      final next = '${j['next'] ?? ''}';
      // Kursor siljimasa — to'xtaymiz (aks holda cheksiz aylanish).
      if (next.isEmpty || next == start) break;
      start = next;
    }
    return B2CleanResult(checked: checked, deleted: deleted, freed: freed);
  } catch (_) {
    return B2CleanResult(
      checked: checked,
      deleted: deleted,
      freed: freed,
      error: 'Internet yo\'q',
    );
  }
}
