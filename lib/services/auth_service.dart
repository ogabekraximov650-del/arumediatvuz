import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'app_build.dart';
import 'account_data.dart';
import 'rust_bridge.dart';
import 'sync_queue.dart';

const String kApiBase = 'https://arumediatv.uzcom.workers.dev';

/// Ism eng ko'pi shuncha belgidan iborat bo'lishi mumkin.
/// `TextField` ning `maxLength` i ham, tekshiruv ham shu qiymatga
/// tayanadi — ikki joyda ikki xil son turmasin.
const int kNameMaxLength = 20;

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

  /// Admin panelini ko'radimi.
  ///
  /// Qiymatni SERVER beradi (Telegram raqamiga qarab). Ilova uni
  /// o'zi hisoblamaydi va o'zgartira olmaydi: bu yerdagi belgi
  /// faqat TUGMANI ko'rsatadi/yashiradi, haqiqiy to'siq esa har
  /// bir so'rovda serverda qo'yiladi.
  final bool isAdmin;

  /// Ism va username to'ldirilganmi.
  ///
  /// Yangi hisobga nomni server O'ZI qo'yadi (`User 7` /
  /// `user_7`), ya'ni bu belgi endi hamma hisobda `true`.
  /// Maydon eski serverlar bilan moslik uchun qoldirilgan —
  /// unga qarab hech qanday oyna ochilmaydi.
  final bool profileDone;

  /// ── MAXFIYLIK ──────────────────────────────────────────────
  ///
  /// Statistikamni (ID, nechta anime ko'rgani, tomosha vaqti)
  /// boshqalar ko'rsinmi.
  ///
  /// TALAB (foydalanuvchi): "foydalanuvchi boshqa profilni
  /// ko'rishi mumkin bo'lsin, faqat to'liq emas — faqatgina
  /// profil surati, nomi va usernameni ko'rishga ruxsat
  /// berilsin ... bu narsalarni boshqalar ko'rishi uchun
  /// foydalanuvchi sozlamalar panelidan ruxsat berib chiqishi
  /// kerak".
  ///
  /// ── ENDI TESKARI (foydalanuvchi talabi) ────────────────────
  ///
  /// "Barcha accountda statistika OCHIQ turadi va foydalanuvchi
  /// qo'lda statistikalarni sozlamalardan yashirib chiqishi kerak
  /// va qaysi statistika yashirilgani bazada ham saqlanishi
  /// kerak."
  ///
  /// Shu sabab bitta "ko'rsatish" tugmasi o'rniga YASHIRILGANLAR
  /// RO'YXATI: bo'sh ro'yxat — hammasi ochiq. Nomlar
  /// `StatKind.key` bilan bir xil ("episodes", "comments" ...).
  final List<String> hiddenStats;

  const AppUser({
    required this.id,
    required this.telegramId,
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.photoUrl,
    this.balance = 0,
    this.profileDone = true,
    this.isAdmin = false,
    this.hiddenStats = const [],
  });

  /// Shu statistika yashirilganmi.
  bool isHidden(String key) => hiddenStats.contains(key);

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
        // Eski serverdan javob kelsa maydon bo'lmaydi — `true`.
        profileDone: j['profile_done'] as bool? ?? true,
        // Maydon yo'q bo'lsa — admin EMAS (xavfsiz tomon).
        isAdmin: j['is_admin'] as bool? ?? false,
        // Maydon yo'q bo'lsa — hech nima yashirilmagan (ochiq).
        hiddenStats: ((j['hidden_stats'] as List?) ?? const [])
            .map((e) => '$e')
            .toList(),
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
        'is_admin': isAdmin,
        'hidden_stats': hiddenStats,
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

  /// Joriy sessiya tokeni — boshqa xizmatlar (masalan tomosha
  /// tarixi) server bilan gaplashishi uchun.
  ///
  /// Token bu yerdan FAQAT o'qiladi: uni saqlash, yangilash va
  /// o'chirish mas'uliyati shu klassda qoladi.
  String? get sessionToken {
    final s = _session;
    return (s == null || s.isEmpty) ? null : s;
  }

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
      // Hisob papkasi (`accountid_<id>`) BOSHQA HAMMA NARSADAN
      // OLDIN tanlanadi — tomosha tarixi va qolgan keshlar aynan
      // shu papkadan o'qilishi kerak.
      RustCore.instance.setAccount(_user?.id ?? 0);
      RustCore.instance.setUserId(_user?.id ?? 0);
      // Papka haqiqatan SHU odamniki ekanini tekshiramiz
      // (`AccountData.guardOwner` izohiga qarang).
      AccountData.guardOwner(_user?.id ?? 0, _user?.telegramId ?? 0);
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
          // ── TOPILGAN XATO: TARTIB MUHIM ──────────────────
          //
          // Foydalanuvchi: "chiqib ketib qayta kirmoqchi bo'lsam
          // Telegramni ochish tugmasi chiqmasdan accountga qaytib
          // kirib ketyapti".
          //
          // Sabab: kutilayotgan kirish tokeni HISOB PAPKASIDA
          // saqlanadi (`_pendingPath` -> `dataDirPath`). `_save`
          // esa papkani `accountid_0` dan `accountid_<id>` ga
          // almashtiradi. Ya'ni `clearPending()` `_save` dan
          // KEYIN chaqirilganda YANGI papkadagi (mavjud bo'lmagan)
          // faylni o'chirardi — asl token mehmon papkasida
          // qolaverardi.
          //
          // Chiqilgandan keyin ilova yana mehmon papkasiga
          // tushadi, o'sha eski tokenni topadi va o'zini o'zi
          // qaytadan kirgizib yuborardi.
          //
          // Endi token papka almashishidan OLDIN o'chiriladi.
          clearPending();
          await _save(
              session,
              AppUser.fromJson(d['user'] as Map<String, dynamic>));
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

  // ═══════════════════════════════════════════════════════════
  //  HISOBDAN CHIQISH — AVVAL MA'LUMOTLAR SAQLANADI
  // ═══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "foydalanuvchi hisobidan chiqqanda
  // telefondagi ma'lumotlar Turso'ga yozilishi kerak; nima
  // bo'layotgani va progress chizig'i ko'rsatilsin, chiziq 100%
  // ga yetganda 'ma'lumotlar sinxronlandi, sizni ilovamizda kutib
  // qolamiz' degan xabar chiqsin".
  //
  // Endi hamma yozuv navbatda turadi (`SyncQueue`), shu sabab
  // chiqishdan oldin AYNAN o'sha navbat yuboriladi.
  //
  // ── INTERNET YO'Q BO'LSA ────────────────────────────────────
  //
  // Chiqish BLOKLANMAYDI. Navbat diskda, hisob papkasida qoladi
  // va o'sha hisobga qaytilganda yuboriladi — ya'ni hech narsa
  // yo'qolmaydi. Chaqiruvchi `SyncResult.offline` ni ko'rib
  // foydalanuvchiga shuni aytadi va "baribir chiqish" imkonini
  // beradi.

  /// Navbatni yuboradi, LEKIN hisobdan chiqarmaydi.
  ///
  /// Chiqish oynasi avval shuni chaqiradi, natijani ko'rsatadi va
  /// keyin `logout()` ni chaqiradi.
  Future<SyncResult> syncBeforeLogout({
    void Function(String step, double progress)? onStep,
  }) async {
    try {
      return await SyncQueue.instance.flush(force: true, onStep: onStep);
    } catch (_) {
      onStep?.call('Internet yo\'q', 1.0);
      return SyncResult.offline;
    }
  }

  /// Qurilmadan hisobni olib tashlaydi.
  ///
  /// Ma'lumotlar `syncBeforeLogout` da yuborilgan bo'lishi kerak.
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

  /// ISM QOIDALARI.
  ///
  /// TALAB: ismga emoji ham, istalgan belgi ham qo'yish mumkin;
  /// uzunligi esa eng ko'pi 20 ta belgi.
  ///
  /// NEGA `characters` ISHLATILADI: `String.length` Dart'da
  /// UTF-16 birliklarini sanaydi, ya'ni bitta emoji 2 ta (ba'zan
  /// 7 ta) bo'lib hisoblanadi. Foydalanuvchi esa ko'zi bilan
  /// BITTA belgini ko'radi. `characters` aynan ko'zga ko'ringan
  /// belgilarni sanaydi — `TextField` ning `maxLength` i ham
  /// xuddi shu tarzda sanaydi, ya'ni ikkovi bir xil ishlaydi va
  /// "yozib bo'ldim, lekin xato chiqyapti" holati bo'lmaydi.
  ///
  /// Qaytaradi: xato matni yoki `null`.
  static String? nameProblem(String s) {
    final n = s.trim();
    if (n.isEmpty) return 'Ism bo\'sh bo\'lmasin';
    if (n.characters.length > kNameMaxLength) {
      return 'Ism eng ko\'pi $kNameMaxLength ta belgi bo\'lishi mumkin';
    }
    return null;
  }

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

  // ═══════════════════════════════════════════════════════════
  //  HISOBNI BUTUNLAY O'CHIRISH
  // ═══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "hisob o'chirilganda foydalanuvchiga
  // tegishli va Turso'dagi statistikaga ta'sir qilmaydigan
  // ma'lumotlar tozalab tashlansin; tozalanish jarayoni va
  // progress chizig'i ko'rsatilsin".
  //
  // ── SERVERDA ────────────────────────────────────────────────
  //
  // O'chadi: hisob, sessiyalar, kirish kodlari, tomosha tarixi,
  // sevimlilar va BAHOLAR; bo'limning `fav_count` va reyting
  // hisoblagichlari tuzatiladi (worker bajaradi).
  //
  // Qoladi: statistika chelaklari va qism/bo'limning
  // `views_total` / `watch_ms_total` — bular TARIXIY jamlanma,
  // bir odam ketgani bilan o'tmish o'zgarmasligi kerak.
  //
  // Baho ham o'chadi, chunki aks holda bir odam hisobini bir
  // necha marta o'chirib, har safar yangi hisobdan baho berib
  // reytingni soxtalashtira olardi (foydalanuvchi topgan xato).
  //
  // ── NAVBAT YUBORILMAYDI ─────────────────────────────────────
  //
  // Yuborilmagan yozuvlarni avval yozib, keyin o'chirishning
  // ma'nosi yo'q — ular bir soniyadan keyin baribir o'chadi.
  // Shu sabab navbat shunchaki tashlab yuboriladi.
  //
  /// Qaytaradi: xato matni yoki muvaffaqiyatda `null`.
  Future<String?> deleteAccount({
    void Function(String step, double progress)? onStep,
  }) async {
    final s = _session;
    if (s == null || s.isEmpty) return 'Avval hisobga kiring';
    onStep?.call('Server ma\'lumotlari o\'chirilmoqda', 0.15);
    try {
      final r = await http.post(
        Uri.parse('$kApiBase/api/auth/delete-account'),
        headers: {'Authorization': 'Bearer $s'},
      ).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        // Server nima deganini KO'RSATAMIZ — "o'chirib bo'lmadi"
        // degan quruq xabar bilan sababni topib bo'lmasdi.
        try {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          final msg = (j['error'] ?? '').toString();
          if (msg.isNotEmpty) return msg;
        } catch (_) {}
        return 'O\'chirib bo\'lmadi (${r.statusCode})';
      }
    } catch (_) {
      return 'Tarmoq xatosi — qaytadan urinib ko\'ring';
    }

    // Telefondagi nusxalar — server tasdiqlagandan KEYIN.
    // Tartib muhim: papka almashishidan oldin tozalanadi, aks
    // holda mehmon papkasi o'chib ketardi.
    try {
      await AccountData.wipeDevice(
        onStep: (step, p) => onStep?.call(step, 0.25 + p * 0.7),
      );
    } catch (_) {}

    await _clear();
    onStep?.call('Tayyor', 1.0);
    return null;
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
    final switched = _user?.id != u.id;
    _session = session;
    _user = u;
    // Boshqa hisobga o'tilgan bo'lsa — papka ham almashadi
    // (`AccountData` izohiga qarang). Hech narsa o'chirilmaydi.
    if (switched) {
      await AccountData.switchTo(u.id, telegramId: u.telegramId);
    } else {
      RustCore.instance.setUserId(u.id);
    }
    try {
      await _storage.write(key: _sessionKey, value: session);
      await _storage.write(key: _userKey, value: jsonEncode(u.toJson()));
    } catch (_) {
      // Saqlanmasa ham joriy seans ishlayveradi.
    }
    notifyListeners();
  }

  /// Qurilmadan hisobni olib tashlaydi.
  ///
  /// Chiqish ham, hisobni o'chirish ham SHU YERGA keladi.
  ///
  /// TALAB (foydalanuvchi): "chiqish yoki hisobni o'chirishda endi
  /// HECH NARSA TOZALANMASIN". Shu sabab bu yerda faqat SESSIYA
  /// olib tashlanadi va ilova mehmon papkasiga (`accountid_0`)
  /// o'tadi. Hisobning o'z papkasi (tomosha tarixi, qayerda
  /// to'xtagani, sevimlilar, trafik hisobi) joyida qoladi va
  /// o'sha hisobga qaytilsa hammasi o'z holicha ochiladi.
  /// Yuklab olingan videolar va posterlar esa umuman
  /// hisobga bog'liq emas — ular bitta joyda turadi.
  Future<void> _clear() async {
    // Kutilayotgan kirish tokeni — hisob papkasida. Papka
    // almashishidan OLDIN ham, KEYIN ham tozalanadi: qaysi
    // papkada qolgan bo'lsa ham yo'qolsin, aks holda ilova
    // o'zini o'zi qaytadan kirgizib yuborardi.
    clearPending();
    _session = null;
    _user = null;
    try {
      await _storage.delete(key: _sessionKey);
      await _storage.delete(key: _userKey);
    } catch (_) {}
    notifyListeners();
    await AccountData.switchTo(0);
    clearPending();
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

// ══════════════════════════════════════════════════════════════
//  MAXFIYLIK SOZLAMASI
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "foydalanuvchi boshqa profilni ko'rishi
// mumkin bo'lsin, faqat to'liq emas — faqatgina profil surati,
// nomi va usernameni ko'rishga ruxsat berilsin. ID, balans va
// qolgan statistikalar ko'rinmasin. Bu narsalarni boshqalar
// ko'rishi uchun foydalanuvchi sozlamalar panelidan ruxsat berib
// chiqishi kerak".
//
// Haqiqiy to'siq SERVERDA: ruxsat berilmagan bo'lsa statistika
// javobga UMUMAN qo'shilmaydi (`public_profile` izohiga qarang).
// Bu yerdagi kod shunchaki sozlamani yuboradi.

extension AuthPrivacy on AuthService {
  /// Qaysi statistikalar yashirilishini saqlaydi.
  ///
  /// Ro'yxat TO'LIQ yuboriladi va eskisining o'rnini bosadi —
  /// "qaysi biri o'zgardi" deb yuborish ikki qurilmada bir vaqtda
  /// o'zgartirilganda chalkashardi.
  ///
  /// Xato bo'lsa matn qaytadi va ekrandagi tugma eski holatiga
  /// qaytariladi (chaqiruvchi shunga qarab ish tutadi).
  Future<String?> setHiddenStats(List<String> keys) async {
    final t = sessionToken;
    if (t == null) return 'Avval hisobingizga kiring';
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/me/privacy'),
            headers: {
              'Authorization': 'Bearer $t',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'hidden_stats': keys}),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        return '${j['error'] ?? 'Saqlanmadi'}';
      }
      // Saqlangan nusxa ham yangilanadi — ilova qayta ochilganda
      // tugmalar to'g'ri holatda turadi.
      await refresh();
      return null;
    } catch (_) {
      return 'Internet yo\'q';
    }
  }
}
