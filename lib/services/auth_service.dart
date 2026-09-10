import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'rust_bridge.dart';

const String kApiBase = 'https://aniraxuzapp.ogabekraximov650.workers.dev';

/// Sessiyalar jurnalida ko'rinadigan ilova versiyasi.
/// `pubspec.yaml` dagi `version:` bilan bir xil turishi kerak.
const String kAppVersion = '0.0.9';

/// Ilovaga kirgan foydalanuvchi.
class AppUser {
  /// ILOVADAGI raqam (#1, #2, ...) — Telegram ID emas.
  final int id;
  final int telegramId;
  final String username;
  final String firstName;
  final String lastName;
  final String photoUrl;

  /// Hisobdagi mablag' (Turso'dagi `users_db.balance`).
  final int balance;

  /// Ism va username kiritilganmi. `false` bo'lsa ilova
  /// so'rash oynasini ochadi va uni yopib bo'lmaydi.
  final bool profileDone;

  const AppUser({
    required this.id,
    required this.telegramId,
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.photoUrl,
    this.balance = 0,
    this.profileDone = true,
  });

  String get fullName {
    final n = '$firstName $lastName'.trim();
    if (n.isNotEmpty) return n;
    if (username.isNotEmpty) return '@$username';
    return 'Foydalanuvchi $id';
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
        balance: (j['balance'] as num?)?.toInt() ?? 0,
        // Eski serverdan javob kelsa maydon bo'lmaydi — bunday
        // holatda so'ramaymiz (`true`), aks holda hamma
        // foydalanuvchi to'satdan so'roq oynasiga tushib qolardi.
        profileDone: j['profile_done'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'telegram_id': telegramId,
        'username': username,
        'first_name': firstName,
        'last_name': lastName,
        'photo_url': photoUrl,
        'balance': balance,
        'profile_done': profileDone,
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
      return;
    }

    // ── UZILIB QOLGAN KIRISHNI DAVOM ETTIRISH ─────────────────
    //
    // Ilova Telegramga o'tganda yopilib ketgan bo'lishi mumkin.
    // Foydalanuvchi u yerda START bosgan bo'lsa, sessiya serverda
    // ALLAQACHON ochilgan — faqat ilova buni bilmaydi. Saqlangan
    // token bilan bir marta so'raymiz va hisob o'zi ochiladi.
    //
    // Kutilmaydi: internet sekin bo'lsa ilova ochilishi
    // sekinlashmasin.
    unawaited(resumePendingLogin());
  }

  /// Saqlangan token bo'yicha kirish tugallanganini tekshiradi.
  /// Kirilgan bo'lsa hisob ochiladi va `true` qaytadi.
  Future<bool> resumePendingLogin() async {
    if (isLoggedIn) return false;
    final pending = await pendingLogin();
    if (pending == null) return false;
    return await check(pending.token) == LoginStatus.ok;
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
  ///
  /// AVVAL SAQLANGANI QARALADI. Muddati tugamagan token bo'lsa
  /// serverdan YANGISI SO'RALMAYDI — o'sha qaytariladi. Sabab
  /// `pendingLogin()` izohida.
  Future<TelegramLoginRequest?> start() async {
    final saved = await pendingLogin();
    if (saved != null) return saved;

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
      final expires = (d['expires_in'] as num?)?.toInt() ?? 300;
      await _savePending(token, link, expires);
      return TelegramLoginRequest(token, link, expires);
    } catch (_) {
      return null;
    }
  }

  // ── KUTILAYOTGAN KIRISH (diskda, AES-256-GCM bilan) ──────────
  //
  // MUAMMO. Kirish tokeni faqat XOTIRADA turardi. Foydalanuvchi
  // Telegramga o'tganda xotirasi kam telefonlarda Android ilovani
  // BUTUNLAY yopib qo'yishi mumkin — token yo'qolardi va qaytib
  // kelgan odam kira olmasdi. U qaytadan urinardi, ilova esa HAR
  // SAFAR serverdan YANGI token so'rardi va har bir START serverda
  // YANGI SESSIYA ochardi. Natija: foydalanuvchi bir marta ham
  // kira olmagani holda "Qurilmalar" ro'yxatida 4 ta sessiya.
  //
  // YECHIM. Token diskka AES-256-GCM bilan MUHRLANGAN faylga
  // yoziladi (Rust yadrosi, kalit Android Keystore'dan). Ilova
  // qaytadan ochilganda:
  //   * `restore()` shu tokenni ko'rib holatni tekshiradi — START
  //     bosilgan bo'lsa foydalanuvchi O'ZI kirgan bo'lib chiqadi;
  //   * `start()` esa muddati tugamagan tokenni QAYTA ISHLATADI,
  //     ya'ni ortiqcha sessiya umuman ochilmaydi.
  //
  // Fayl 5 daqiqadan keyin (token muddati) o'zi yaroqsiz bo'ladi.

  static const _pendingFile = 'pending_login.bin';
  static const _pendingLabel = 'pending_login_v1';

  String? get _pendingPath {
    final dir = RustCore.instance.dataDirPath;
    return dir == null ? null : '$dir/$_pendingFile';
  }

  Future<void> _savePending(String token, String link, int expiresIn) async {
    final path = _pendingPath;
    if (path == null) return;
    RustCore.instance.secureSave(
      path,
      _pendingLabel,
      jsonEncode({
        'token': token,
        'deep_link': link,
        'expires_at': DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
      }),
    );
  }

  /// Saqlangan, muddati TUGAMAGAN kirish urinishi (bo'lmasa `null`).
  /// Muddati tugagan bo'lsa fayl yo'l-yo'lakay o'chiriladi.
  Future<TelegramLoginRequest?> pendingLogin() async {
    final path = _pendingPath;
    if (path == null) return null;
    final raw = RustCore.instance.secureLoad(path, _pendingLabel);
    if (raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      final token = (d['token'] ?? '').toString();
      final link = (d['deep_link'] ?? '').toString();
      final endsAt = (d['expires_at'] as num?)?.toInt() ?? 0;
      final leftMs = endsAt - DateTime.now().millisecondsSinceEpoch;
      // 10 soniyadan kam qolgan bo'lsa yangisini olgan ma'qul.
      if (token.isEmpty || link.isEmpty || leftMs < 10000) {
        clearPending();
        return null;
      }
      return TelegramLoginRequest(token, link, leftMs ~/ 1000);
    } catch (_) {
      clearPending();
      return null;
    }
  }

  /// Kutilayotgan kirishni o'chiradi (kirilgach yoki muddati tugagach).
  void clearPending() {
    final path = _pendingPath;
    if (path != null) RustCore.instance.secureClear(path);
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
          // Kirildi — saqlangan token endi keraksiz.
          clearPending();
          return LoginStatus.ok;
        case 'expired':
          clearPending();
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

  // ── ISM VA USERNAME (yangi hisob uchun) ──────────────────────

  /// USERNAME QOIDALARI — worker'dagi `username_problem` bilan
  /// AYNAN bir xil. Ikki joyda tekshirilishi ataylab: bu yerdagisi
  /// tezkor javob uchun (har bir harfda), serverdagisi esa
  /// ishonch uchun (ilovani chetlab o'tib bo'lmasin).
  ///
  /// Qaytaradi: xato matni yoki `null`.
  static String? usernameProblem(String u) {
    if (u.length < 3) return 'Username kamida 3 ta belgidan iborat bo\'lsin';
    if (u.length > 15) return 'Username eng ko\'pi 15 ta belgi bo\'lishi mumkin';
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(u)) {
      return 'Faqat harf, raqam va pastki chiziq (_) ishlatiladi';
    }
    return null;
  }

  /// Username band emasmi — server bazasidan so'raydi.
  ///
  /// `null` — javob olinmadi (internet yo'q yoki server jim).
  /// Bunday holatda ilova "band" ham, "bo'sh" ham demasligi kerak.
  Future<bool?> usernameAvailable(String u) async {
    final s = _session;
    if (s == null || s.isEmpty) return null;
    try {
      final r = await http.get(
        Uri.parse('$kApiBase/api/auth/username-check?u=${Uri.encodeQueryComponent(u)}'),
        headers: {'Authorization': 'Bearer $s'},
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (d['valid'] != true) return false;
      return d['available'] == true;
    } catch (_) {
      return null;
    }
  }

  /// Ism va username'ni saqlaydi.
  /// Qaytaradi: xato matni yoki muvaffaqiyatda `null`.
  Future<String?> saveProfile(String firstName, String username) async {
    final s = _session;
    if (s == null || s.isEmpty) return 'Avval hisobga kiring';
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/auth/profile'),
            headers: {
              'Authorization': 'Bearer $s',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'first_name': firstName.trim(),
              'username': username.trim(),
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (r.statusCode == 200) {
        await _save(
            s,
            AppUser.fromJson((jsonDecode(r.body) as Map<String, dynamic>)['user']
                as Map<String, dynamic>));
        return null;
      }
      try {
        return ((jsonDecode(r.body) as Map<String, dynamic>)['error'] ?? '')
                .toString()
                .isEmpty
            ? 'Saqlab bo\'lmadi'
            : (jsonDecode(r.body) as Map<String, dynamic>)['error'].toString();
      } catch (_) {
        return 'Saqlab bo\'lmadi';
      }
    } catch (_) {
      return 'Tarmoq xatosi — qaytadan urinib ko\'ring';
    }
  }

  /// HISOBNI BUTUNLAY O'CHIRISH. Serverda foydalanuvchi, uning
  /// barcha sessiyalari va profil rasmi o'chiriladi; qurilmadan
  /// esa sessiya tozalanadi.
  ///
  /// Qaytaradi: xato matni yoki muvaffaqiyatda `null`.
  Future<String?> deleteAccount() async {
    final s = _session;
    if (s == null || s.isEmpty) return 'Avval hisobga kiring';
    try {
      final r = await http.post(
        Uri.parse('$kApiBase/api/auth/delete-account'),
        headers: {'Authorization': 'Bearer $s'},
      ).timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return 'O\'chirib bo\'lmadi';
      await _clear();
      return null;
    } catch (_) {
      return 'Tarmoq xatosi — qaytadan urinib ko\'ring';
    }
  }

  // ── PROFIL RASMI ─────────────────────────────────────────────

  /// Foydalanuvchi tanlagan rasmni profil rasmi qilib qo'yadi.
  ///
  /// Yo'l anime rasmlari bilan BIR XIL: fayl B2'ga to'g'ridan-to'g'ri
  /// yuklanadi (`/api/upload-token` bergan bir martalik manzil bilan),
  /// keyin workerga faqat FAYL NOMI aytiladi. Ya'ni rasm baytlari
  /// worker orqali o'tmaydi.
  ///
  /// Eski rasmni B2'dan o'chirishni WORKER bajaradi — u eski fayl
  /// nomini bazadan biladi va yangisini saqlagandan KEYIN o'chiradi.
  ///
  /// Fayl nomi qolipi `avatar_<id>_<vaqt>.jpg` bo'lishi SHART:
  /// worker aynan shu qolipni tekshiradi (birov o'z profiliga
  /// begona faylni bog'lab, uni o'chirtira olmasligi uchun).
  ///
  /// Qaytaradi: xato matni yoki muvaffaqiyatda `null`.
  Future<String?> updateAvatar(List<int> jpegBytes) async {
    final s = _session;
    final u = _user;
    if (s == null || s.isEmpty || u == null) return 'Avval hisobga kiring';

    try {
      final tokenRes = await http
          .post(Uri.parse('$kApiBase/api/upload-token'))
          .timeout(const Duration(seconds: 20));
      if (tokenRes.statusCode != 200) return 'Yuklash manzili olinmadi';
      final td = jsonDecode(tokenRes.body) as Map<String, dynamic>;
      final uploadUrl = (td['uploadUrl'] ?? '').toString();
      final authToken = (td['authorizationToken'] ?? '').toString();
      if (uploadUrl.isEmpty || authToken.isEmpty) {
        return 'Yuklash manzili olinmadi';
      }

      final fileName =
          'avatar_${u.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final up = await http
          .post(
            Uri.parse(uploadUrl),
            headers: {
              'Authorization': authToken,
              'X-Bz-File-Name': fileName,
              'Content-Type': 'image/jpeg',
              'X-Bz-Content-Sha1': 'do_not_verify',
            },
            body: jpegBytes,
          )
          .timeout(const Duration(seconds: 60));
      if (up.statusCode != 200) return 'Rasm yuklanmadi';

      final save = await http
          .post(
            Uri.parse('$kApiBase/api/auth/avatar'),
            headers: {
              'Authorization': 'Bearer $s',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'file': fileName}),
          )
          .timeout(const Duration(seconds: 20));
      if (save.statusCode != 200) return 'Rasm saqlanmadi';

      final nu = AppUser.fromJson(
          (jsonDecode(save.body) as Map<String, dynamic>)['user']
              as Map<String, dynamic>);
      await _save(s, nu);
      return null;
    } catch (_) {
      return 'Tarmoq xatosi — qaytadan urinib ko\'ring';
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
