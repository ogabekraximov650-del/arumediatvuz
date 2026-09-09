import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

const String kApiBase = 'https://aniraxuzapp.ogabekraximov650.workers.dev';

/// Sessiyalar jurnalida ko'rinadigan ilova versiyasi.
/// `pubspec.yaml` dagi `version:` bilan bir xil turishi kerak.
const String kAppVersion = '0.0.5';

/// Ilovaga kirgan foydalanuvchi.
class AppUser {
  /// ILOVADAGI raqam (#1, #2, ...) — Telegram ID emas.
  final int id;
  final int telegramId;
  final String username;
  final String firstName;
  final String lastName;
  final String photoUrl;

  const AppUser({
    required this.id,
    required this.telegramId,
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.photoUrl,
  });

  String get fullName {
    final n = '$firstName $lastName'.trim();
    if (n.isNotEmpty) return n;
    if (username.isNotEmpty) return '@$username';
    return 'Foydalanuvchi #$id';
  }

  /// Avatar yuklanmasa ko'rsatiladigan bosh harflar.
  String get initials {
    final a = firstName.trim();
    final b = lastName.trim();
    if (a.isNotEmpty && b.isNotEmpty) return '${a[0]}${b[0]}'.toUpperCase();
    if (a.isNotEmpty) return a[0].toUpperCase();
    if (username.isNotEmpty) return username[0].toUpperCase();
    return '#';
  }

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: (j['id'] as num?)?.toInt() ?? 0,
        telegramId: (j['telegram_id'] as num?)?.toInt() ?? 0,
        username: (j['username'] ?? '').toString(),
        firstName: (j['first_name'] ?? '').toString(),
        lastName: (j['last_name'] ?? '').toString(),
        photoUrl: (j['photo_url'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'telegram_id': telegramId,
        'username': username,
        'first_name': firstName,
        'last_name': lastName,
        'photo_url': photoUrl,
      };
}

/// `/api/auth/telegram/start` javobi.
class TelegramLoginRequest {
  final String token;
  final String deepLink;
  final int expiresIn;
  const TelegramLoginRequest(this.token, this.deepLink, this.expiresIn);
}

/// Kirish holati — `LoginWaitScreen` shu qiymatlarga qarab
/// ekranda nima ko'rsatishini hal qiladi.
enum LoginStatus { pending, ok, expired, error }

/// ═══════════════════════════════════════════════════════════════
///  TELEGRAM ORQALI KIRISH
/// ═══════════════════════════════════════════════════════════════
///
/// Bot tokeni bu yerda YO'Q va bo'lishi ham mumkin emas: APK'ni
/// har kim ochib ichidagi satrlarni o'qiy oladi. Ilova faqat
/// worker bilan gaplashadi, botga esa worker o'zi murojaat qiladi.
///
/// Sessiya tokeni `flutter_secure_storage` da — Android'da u
/// Keystore bilan himoyalangan EncryptedSharedPreferences.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _sessionKey = 'fulutter_session_v1';
  static const _userKey = 'fulutter_user_v1';

  String? _session;
  AppUser? _user;
  bool _restored = false;

  AppUser? get user => _user;
  bool get isLoggedIn => _user != null;

  /// Ilova ishga tushganda saqlangan hisob o'qib bo'lindimi.
  /// Toki `false` ekan, profil sahifasi hech narsa ko'rsatmaydi —
  /// aks holda kirgan foydalanuvchiga bir zumga "kirish" ekrani
  /// miltillab ketardi.
  bool get restored => _restored;

  // ── Ishga tushish ────────────────────────────────────────────

  /// `main()` da bir marta chaqiriladi.
  ///
  /// Saqlangan hisob DARHOL ko'rsatiladi (tarmoqni kutmasdan), so'ng
  /// fon'da server bilan tekshiriladi. Shu sabab internetsiz ham
  /// profil ochiq turadi.
  Future<void> restore() async {
    try {
      _session = await _storage.read(key: _sessionKey);
      final cached = await _storage.read(key: _userKey);
      if (cached != null && cached.isNotEmpty) {
        _user = AppUser.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      }
    } catch (_) {
      // Xavfsiz ombor ishlamadi — mehmon sifatida davom etamiz.
      _session = null;
      _user = null;
    }
    _restored = true;
    notifyListeners();

    if (_session != null && _session!.isNotEmpty) {
      // Javobni kutmaymiz: ilova ochilishi sekinlashmasin.
      unawaited(refresh());
    }
  }

  /// Sessiya hali kuchdami? Faqat 401 kelganda hisobdan chiqariladi
  /// — tarmoq xatosi yoki server nosozligi hisobni yo'qotmasligi
  /// kerak.
  Future<void> refresh() async {
    final s = _session;
    if (s == null || s.isEmpty) return;
    try {
      final r = await http.get(
        Uri.parse('$kApiBase/api/auth/me'),
        headers: {'Authorization': 'Bearer $s'},
      ).timeout(const Duration(seconds: 15));

      if (r.statusCode == 200) {
        final u = AppUser.fromJson(
            (jsonDecode(r.body) as Map<String, dynamic>)['user']
                as Map<String, dynamic>);
        await _save(s, u);
      } else if (r.statusCode == 401) {
        // Sessiya bekor qilingan — masalan 5-qurilma kirgani uchun
        // bu qurilma chegaradan chiqarilgan.
        await _clear();
      }
    } catch (_) {
      // Tarmoq yo'q — hisobga tegmaymiz.
    }
  }

  // ── Kirish ───────────────────────────────────────────────────

  /// 1-qadam: serverdan bir martalik token va Telegram havolasini
  /// oladi.
  Future<TelegramLoginRequest?> start() async {
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/auth/telegram/start'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(await deviceInfo()),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 && r.statusCode != 201) return null;
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      final token = (d['token'] ?? '').toString();
      final link = (d['deep_link'] ?? '').toString();
      if (token.isEmpty || link.isEmpty) return null;
      return TelegramLoginRequest(
          token, link, (d['expires_in'] as num?)?.toInt() ?? 300);
    } catch (_) {
      return null;
    }
  }

  /// 2-qadam: foydalanuvchi Telegramda START bosdimi?
  Future<LoginStatus> check(String token) async {
    try {
      final r = await http
          .get(Uri.parse('$kApiBase/api/auth/telegram/status?token=$token'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return LoginStatus.error;
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      switch ((d['status'] ?? '').toString()) {
        case 'ok':
          final session = (d['session'] ?? '').toString();
          if (session.isEmpty) return LoginStatus.error;
          await _save(
              session,
              AppUser.fromJson(d['user'] as Map<String, dynamic>));
          return LoginStatus.ok;
        case 'expired':
          return LoginStatus.expired;
        default:
          return LoginStatus.pending;
      }
    } catch (_) {
      // Tarmoq uzildi — "hali kutilmoqda" deb hisoblaymiz va
      // keyingi urinishda qayta so'raladi.
      return LoginStatus.pending;
    }
  }

  Future<void> logout() async {
    final s = _session;
    if (s != null && s.isNotEmpty) {
      try {
        await http.post(
          Uri.parse('$kApiBase/api/auth/logout'),
          headers: {'Authorization': 'Bearer $s'},
        ).timeout(const Duration(seconds: 15));
      } catch (_) {
        // Server javob bermasa ham qurilmadan chiqamiz.
      }
    }
    await _clear();
  }

  // ── Sessiyalar jurnali ───────────────────────────────────────

  /// Hisobga kirgan qurilmalar ro'yxati (eng ko'pi 4 ta).
  Future<List<Map<String, dynamic>>?> sessions() async {
    final s = _session;
    if (s == null || s.isEmpty) return null;
    try {
      final r = await http.get(
        Uri.parse('$kApiBase/api/auth/sessions'),
        headers: {'Authorization': 'Bearer $s'},
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      return (d['sessions'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Boshqa qurilmani hisobdan chiqarish.
  Future<bool> revoke(int sessionId) async {
    final s = _session;
    if (s == null || s.isEmpty) return false;
    try {
      final r = await http.delete(
        Uri.parse('$kApiBase/api/auth/sessions/$sessionId'),
        headers: {'Authorization': 'Bearer $s'},
      ).timeout(const Duration(seconds: 15));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Ichki ────────────────────────────────────────────────────

  Future<void> _save(String session, AppUser u) async {
    _session = session;
    _user = u;
    try {
      await _storage.write(key: _sessionKey, value: session);
      await _storage.write(key: _userKey, value: jsonEncode(u.toJson()));
    } catch (_) {
      // Saqlanmasa ham joriy seans ishlayveradi.
    }
    notifyListeners();
  }

  Future<void> _clear() async {
    _session = null;
    _user = null;
    try {
      await _storage.delete(key: _sessionKey);
      await _storage.delete(key: _userKey);
    } catch (_) {}
    notifyListeners();
  }

  /// Sessiyalar jurnalidagi "qaysi qurilma" ustuni uchun.
  static Future<Map<String, String>> deviceInfo() async {
    var device = 'Noma\'lum qurilma';
    var platform = Platform.operatingSystem;
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        device = '${a.brand} ${a.model}'.trim();
        platform = 'Android ${a.version.release}';
      } else if (Platform.isIOS) {
        final i = await plugin.iosInfo;
        device = i.utsname.machine;
        platform = '${i.systemName} ${i.systemVersion}';
      }
    } catch (_) {
      platform = Platform.operatingSystemVersion;
    }
    return {
      'device': device,
      'platform': platform,
      'app_version': kAppVersion,
    };
  }
}
