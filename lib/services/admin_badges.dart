// lib/services/admin_badges.dart — ADMIN PANELIDAGI YANGILIKLAR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "admin paneliga yangilik kelsa, ya'ni shikoyat,
// support, yangi foydalanuvchi va boshqa narsalar kelganda admin
// paneli tugmasida qizil nuqta yonib tursin va o'sha yangi narsa
// ustida ham yonib tursin".
//
// ── "YANGI" NIMA DEGANI ─────────────────────────────────────
//
// Har bo'lim uchun alohida: admin O'SHA BO'LIMNI oxirgi marta
// ochgan vaqtidan keyin paydo bo'lgan narsa.
//
// Vaqt DISKDA saqlanadi, bazada emas: aks holda har bo'lim
// ochilganda yana bitta yozish so'rovi ketardi. Server esa
// shunchaki "shu vaqtdan keyin nechta bor" deb sanaydi.
//
// Yozishmalar bundan farq qiladi — u yerda "o'qilmagan"
// tushunchasi allaqachon bazada bor (`chat_threads.unread_admin`),
// ya'ni vaqt kerak emas va nuqta yozishma ochilgach o'zi so'nadi.
//
// ── SO'ROVLAR SONI ──────────────────────────────────────────
//
// Uchala son BITTA kichik so'rovda keladi (`/api/admin/badges`).
// U faqat admin uchun va faqat profil sahifasi yoki admin paneli
// ochiq turganda so'raladi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'disk_cache.dart';

class AdminBadges extends ChangeNotifier {
  AdminBadges._();
  static final AdminBadges instance = AdminBadges._();

  /// Diskdagi kalit: qaysi bo'lim qachon ko'rilgan.
  static const _seenKey = 'admin_badges_seen';

  int _reports = 0;
  int _chat = 0;
  int _users = 0;
  bool _busy = false;

  /// Yangi shikoyatlar soni.
  int get reports => _reports;

  /// O'qilmagan xabarlar soni (barcha yozishmalar bo'yicha).
  int get chat => _chat;

  /// Yangi ro'yxatdan o'tganlar soni.
  int get users => _users;

  /// Admin paneli tugmasida nuqta yonsinmi.
  bool get any => _reports > 0 || _chat > 0 || _users > 0;

  /// Hisob almashdi — hamma narsa nolga tushadi.
  void clear() {
    if (!any) return;
    _reports = 0;
    _chat = 0;
    _users = 0;
    notifyListeners();
  }

  Map<String, dynamic> get _seen =>
      DiskCache.readOne(_seenKey) ?? <String, dynamic>{};

  int _seenAt(String section) =>
      ((_seen[section] as num?) ?? 0).toInt();

  /// Bo'lim ochildi — undagi nuqta so'nadi.
  ///
  /// `at` — SERVER vaqti (`refresh` javobidan). Telefon soati
  /// noto'g'ri bo'lsa ham hisob buzilmaydi.
  void markSeen(String section, {int? at}) {
    final map = Map<String, dynamic>.from(_seen);
    map[section] = at ?? _lastServerNow;
    DiskCache.writeOne(_seenKey, map);
    // Ekrandagi son ham darhol nolga tushadi — admin bo'limni
    // ochgan zahoti nuqta so'nsin, keyingi so'rov kutilmasin.
    switch (section) {
      case 'reports':
        _reports = 0;
      case 'users':
        _users = 0;
    }
    notifyListeners();
  }

  /// Serverning oxirgi aytgan vaqti.
  int _lastServerNow = 0;

  Future<void> refresh() async {
    if (_busy) return;
    if (AuthService.instance.sessionToken == null) {
      clear();
      return;
    }
    _busy = true;
    try {
      final r = await http
          .get(
            Uri.parse('$kApiBase/api/admin/badges'
                '?since_reports=${_seenAt('reports')}'
                '&since_users=${_seenAt('users')}'),
            headers: {
              'Authorization': 'Bearer ${AuthService.instance.sessionToken}',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final rep = ((j['reports'] as num?) ?? 0).toInt();
        final ch = ((j['chat'] as num?) ?? 0).toInt();
        final us = ((j['users'] as num?) ?? 0).toInt();
        _lastServerNow = ((j['now'] as num?) ?? 0).toInt();
        if (rep != _reports || ch != _chat || us != _users) {
          _reports = rep;
          _chat = ch;
          _users = us;
          notifyListeners();
        }
      }
      // 403 — bu odam admin emas. Jim o'tiladi: nuqta shunchaki
      // yonmaydi va ekranda hech qanday xato ko'rinmaydi.
    } catch (_) {
      // Internet yo'q — sonlar eski holicha qoladi.
    }
    _busy = false;
  }
}
