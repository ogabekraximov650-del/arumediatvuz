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
import 'disk_cache.dart';

/// Bitta xabar.
@immutable
class ChatMessage {
  final String id;
  final bool fromAdmin;
  final String body;
  final int createdAt;

  /// Rasm yoki video manzili (bo'sh — oddiy matn).
  final String mediaUrl;

  /// `image`, `video` yoki `voice`.
  final String mediaType;

  /// Ovozli xabarning uzunligi (millisekund).
  ///
  /// Yozib olinganda o'lchanadi va xabar bilan birga saqlanadi —
  /// shu sabab uzunlik faylni yuklamasdan turib ko'rinadi.
  final int mediaMs;

  /// Hali serverga yetib bormagan (ekranda DARHOL ko'rsatilgan)
  /// nusxa.
  ///
  /// TALAB (foydalanuvchi): "huddi Telegramdek tez ishlasin".
  /// Telegram yuborilgan xabarni serverni KUTMASDAN ekranga
  /// qo'yadi va yoniga soat belgisini chizadi; javob kelgach
  /// belgi yo'qoladi. Shu yerda ham xuddi shunday.
  final bool pending;

  /// Suhbatdosh xabarni O'QIGANMI.
  ///
  /// TALAB (foydalanuvchi): "yuborilgach Telegramdagidek bitta ✓
  /// tursin va admin o'qiganidan keyingina ✓✓ ikkita bo'lsin".
  final bool seen;

  const ChatMessage({
    required this.id,
    required this.fromAdmin,
    required this.body,
    required this.createdAt,
    this.mediaUrl = '',
    this.mediaType = '',
    this.mediaMs = 0,
    this.pending = false,
    this.seen = false,
  });

  ChatMessage markSeen() => ChatMessage(
        id: id,
        fromAdmin: fromAdmin,
        body: body,
        createdAt: createdAt,
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        mediaMs: mediaMs,
        seen: true,
      );

  bool get hasMedia => mediaUrl.isNotEmpty && mediaType.isNotEmpty;
  bool get isVideo => mediaType == 'video';
  bool get isVoice => mediaType == 'voice';

  /// Rasm yoki video (ya'ni ko'ruvchida ochiladigan narsa).
  /// Ovozli xabar bunga KIRMAYDI — u xabarning o'zida ijro etiladi.
  bool get isViewable => hasMedia && !isVoice;

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        id: '${j['id'] ?? ''}',
        fromAdmin: j['from_admin'] == true,
        body: '${j['body'] ?? ''}',
        createdAt: ((j['created_at'] as num?) ?? 0).toInt(),
        mediaUrl: '${j['media_url'] ?? ''}',
        mediaType: '${j['media_type'] ?? ''}',
        mediaMs: ((j['media_ms'] as num?) ?? 0).toInt(),
        seen: j['seen'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'from_admin': fromAdmin,
        'body': body,
        'created_at': createdAt,
        'media_url': mediaUrl,
        'media_type': mediaType,
        'media_ms': mediaMs,
        'seen': seen,
      };
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
  bool _admin = false;

  /// Nechta o'qilmagan xabar bor.
  int get count => _count;

  /// Nuqta yonsinmi.
  bool get has => _count > 0;

  /// ── SANOQ KIMNIKI ───────────────────────────────────────
  ///
  /// Oddiy odam uchun bu — ADMIN unga yozgan o'qilmagan
  /// xabarlar. Admin uchun esa — BARCHA suhbatlardagi
  /// o'qilmaganlar yig'indisi, ya'ni butunlay boshqa narsa.
  ///
  /// TALAB (foydalanuvchi): "adminga xabar kelganda support chat
  /// va profil tugmasida qizil nuqta chiqmasin, faqat admin
  /// paneli ustida chiqsin".
  ///
  /// Ilgari ikkovi bir xil qaralardi va adminning profil
  /// tugmasida ham, "Admin bilan bog'lanish" qatorida ham nuqta
  /// yonardi — holbuki xabar u yerga emas, ADMIN PANELIGA
  /// kelgan edi. Endi ekranlar shu belgiga qarab ajratadi.
  bool get isAdmin => _admin;

  /// Oddiy foydalanuvchining o'qilmagan xabari bormi.
  ///
  /// Profil tugmasi va "Admin bilan bog'lanish" qatori SHUNGA
  /// qaraydi.
  bool get hasForUser => _count > 0 && !_admin;

  /// Admin panelidagi nuqta SHUNGA qaraydi.
  bool get hasForAdmin => _count > 0 && _admin;

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
        // Server har javobda "bu admin sanog'imi" deb aytadi
        // (`chat_unread`). Ilova buni O'ZI taxmin qilmaydi.
        final adm = j['admin'] == true;
        if (n != _count || adm != _admin) {
          _count = n;
          _admin = adm;
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

  /// Diskdagi kalit. Admin ko'rinishida — o'sha odamniki.
  String get _diskKey => 'chat_${userId ?? 0}';

  /// Suhbat versiyasining diskdagi kaliti.
  String get _verKey => 'chatver_${userId ?? 0}';

  // ── SUHBAT VERSIYASI ────────────────────────────────────────
  //
  // Serverdagi `chat_threads.chat_ver` — suhbatda BIROR NARSA
  // o'zgarganda bittaga oshadigan son. Uzoq kutish AYNAN shuni
  // kuzatadi (`/api/chat/wait?ver=...`), ilgari esa har tekshiruvda
  // 200 ta xabar qatori o'qilardi.
  //
  // DISKDA ham saqlanadi: ilova qayta ochilganda xabarlar bilan
  // birga versiya ham tiklanadi, ya'ni hech narsa o'zgarmagan
  // bo'lsa BIRINCHI kutish ham darhol qaytmaydi — bekorga so'rov
  // ketmaydi.
  int _ver = 0;

  /// Diskdagi nusxani DARHOL ko'rsatadi (tarmoq kutilmaydi).
  ///
  /// TALAB (foydalanuvchi): "hullas hammasi diskda tursin, tezroq
  /// ishlashi uchun". Suhbat ochilganda eski xabarlar darhol
  /// chiqadi, yangisi esa fon'da keladi.
  void loadFromDisk() {
    if (_items.isNotEmpty) return;
    final rows = DiskCache.read(_diskKey);
    if (rows == null) return;
    _items
      ..clear()
      ..addAll(rows.map(ChatMessage.fromJson));
    _ver = (DiskCache.readOne(_verKey)?['v'] as num?)?.toInt() ?? 0;
    _loaded = true;
    notifyListeners();
  }

  // ── UZOQ KUTISH: XABAR DARHOL KELSIN ────────────────────
  //
  // TALAB (foydalanuvchi): "supportga yuborilgan xabar tez
  // kelmayapti, Telegramnikidek tez ishlaydigan qilib ber".
  //
  // ILGARI: har 10 soniyada butun ro'yxat qaytadan so'ralardi.
  // Xabar eng yomon holatda 10 soniyadan keyin ko'rinardi.
  //
  // ENDI: Telegramning O'Z Bot API'sidagi usul — so'rov
  // yuboriladi va SERVER javobni yangi xabar paydo bo'lgunicha
  // ushlab turadi (`/api/chat/wait`). Xabar kelishi bilan javob
  // qaytadi va faqat YANGILARI olinadi.
  //
  // Natija: xabar ~1 soniyada yetib boradi, so'rovlar soni esa
  // KAMAYADI (daqiqasiga 6 ta emas, ~3 ta).

  bool _watching = false;

  /// Oxirgi ko'rilgan xabar vaqti — kutish shundan boshlanadi.
  int get _lastAt => _items.isEmpty ? 0 : _items.last.createdAt;

  /// Nechta xabar o'qilgan. Server shu son o'zgarganda ham
  /// javob qaytaradi — ✓ dan ✓✓ ga o'tish shu orqali ko'rinadi.
  int get _seenCount => _items.where((m) => m.seen).length;

  /// Ekrandagi HAQIQIY xabarlar soni (yuborilayotgan vaqtinchalik
  /// nusxalar hisobga olinmaydi — ular serverda hali yo'q).
  ///
  /// Server shu son o'zgarganda ham javob qaytaradi. Aynan shu
  /// narsa admin O'CHIRGAN xabarni sezishga imkon beradi:
  /// o'chirilganda yangi xabar paydo bo'lmaydi va eng oxirgi vaqt
  /// ham ortmaydi — faqat SON kamayadi.
  int get _liveCount => _items.where((m) => !m.pending).length;

  /// Ekrandagi eng ESKI xabar vaqti.
  ///
  /// Uzun yozishmada o'rtadagi xabar o'chirilsa SON o'zgarmaydi
  /// (o'rniga bittasi pastdan ko'tariladi) — lekin eng eski
  /// xabar vaqti o'zgaradi. Server shu ikkovini ham tekshiradi.
  int get _oldestAt {
    var oldest = 0;
    for (final m in _items) {
      if (m.pending) continue;
      if (oldest == 0 || m.createdAt < oldest) oldest = m.createdAt;
    }
    return oldest;
  }

  void startPolling() {
    if (_watching) return;
    _watching = true;
    unawaited(_watchLoop());
  }

  void stopPolling() {
    _watching = false;
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _watchLoop() async {
    while (_watching) {
      if (AuthService.instance.sessionToken == null) {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }
      try {
        // `ver` — ASOSIY belgi (server bitta qator o'qiydi).
        // Qolgan sonlar ESKI serverlar uchun qoldirilgan: yangi
        // worker `ver` ni ko'rsa ularga qaramaydi.
        final uri = Uri.parse('$_base/wait?ver=$_ver'
            '&since=$_lastAt&seen=$_seenCount'
            '&count=$_liveCount&oldest=$_oldestAt'
            '${userId != null ? '&user_id=$userId' : ''}');
        final r = await http
            .get(uri, headers: _headers())
            // Server ~19 soniya ushlaydi; 35 — zaxira bilan.
            .timeout(const Duration(seconds: 35));
        if (!_watching) return;
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          // Versiya YUKLASHDAN OLDIN olinadi, lekin KEYIN yoziladi:
          // yuklash davomida yana o'zgarish bo'lsa, keyingi kutish
          // uni darhol sezadi (o'zgarish yo'qolib qolmaydi).
          final ver = (j['ver'] as num?)?.toInt();
          if (j['new'] == true) {
            await load(force: true);
          }
          if (ver != null && ver != _ver) {
            _ver = ver;
            DiskCache.write(_verKey, [{'v': ver}]);
          }
          // Javob darhol qaytsa ham (yangi xabar bor edi),
          // keyingi kutish shu zahoti boshlanadi.
          continue;
        }
        // Xato javob — bir oz kutib qaytadan.
        await Future<void>.delayed(const Duration(seconds: 3));
      } catch (_) {
        // Internet uzildi yoki so'rov muddati tugadi — bu
        // KUTILGAN holat, shunchaki qaytadan uriniladi.
        if (!_watching) return;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  @override
  void dispose() {
    _watching = false;
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
    // ── FAQAT YANGILARINI OLAMIZ ──────────────────────────
    //
    // Ro'yxat allaqachon bo'lsa serverga "shu vaqtdan keyingisi"
    // deb aytiladi. Javob odatda BO'SH ro'yxat bo'ladi — bir
    // necha o'nlab bayt. Ilgari har safar 200 ta xabar qaytadan
    // tashilardi.
    final since = _loaded ? _lastAt : 0;
    try {
      final uri = Uri.parse(since > 0 ? '$_url?since=$since' : _url);
      final r = await http
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final raw = ((j['items'] as List?) ?? [])
            .cast<Map<String, dynamic>>();
        final rows = raw.map(ChatMessage.fromJson).toList();

        // ── ESKI XABARLARNING "O'QILDI" BELGISI ───────────
        //
        // `since` bilan faqat YANGI xabarlar keladi, "o'qildi"
        // belgisi esa ESKI xabarlarga qo'yiladi. Server shu
        // sabab o'qilganlarning RAQAMLARINI ham yuboradi.
        final seenIds =
            ((j['seen_ids'] as List?) ?? []).map((e) => '$e').toSet();
        if (seenIds.isNotEmpty) {
          for (var i = 0; i < _items.length; i++) {
            final m = _items[i];
            if (!m.seen && seenIds.contains(m.id)) {
              _items[i] = m.markSeen();
            }
          }
        }

        // ── ADMIN O'CHIRGAN XABARLAR ──────────────────────
        //
        // TOPILGAN XATO (foydalanuvchi): "Support chatda admin
        // o'chirgan yozishmalar foydalanuvchi chatidan o'chib
        // ketmayabdi".
        //
        // SABABI: `since` bilan faqat YANGI xabarlar kelardi.
        // O'chirish esa yangi xabar tug'dirmaydi — ya'ni ilova
        // uni sezmasdi va xabar ekranda ham, diskdagi nusxada
        // ham qolib ketardi.
        //
        // ENDI: server suhbatda HOZIR turgan barcha xabarlarning
        // raqamlarini yuboradi. Shu ro'yxatda yo'q xabar —
        // o'chirilgan xabar, u darhol olib tashlanadi. Yuborilish
        // arafasidagi vaqtinchalik nusxalarga tegilmaydi: ular
        // serverda hali yo'q, lekin o'chirilgan ham emas.
        var removed = false;
        if (j['all_ids'] is List) {
          final live = (j['all_ids'] as List).map((e) => '$e').toSet();
          final before = _items.length;
          _items.removeWhere((m) => !m.pending && !live.contains(m.id));
          removed = _items.length != before;
        }

        if (since > 0) {
          // Qo'shimcha xabarlar — oxiriga qo'shiladi.
          // Takrorlanmasin: sekin tarmoqda bitta javob ikki
          // marta kelishi mumkin.
          final have = _items.map((m) => m.id).toSet();
          final fresh = rows.where((m) => !have.contains(m.id)).toList();
          if (fresh.isNotEmpty) {
            // Yuborayotgan paytda qo'yilgan vaqtinchalik nusxa
            // bo'lsa — u serverdan kelgani bilan almashadi.
            _items.removeWhere((m) => m.pending);
            _items.addAll(fresh);
          }
          // Diskdagi nusxa yangi xabar kelganda HAM, xabar
          // o'chirilganda HAM qayta yoziladi — aks holda ilova
          // keyingi safar ochilganda o'chirilgan xabar diskdan
          // qaytib chiqardi.
          if (fresh.isNotEmpty || removed) {
            _saveDisk();
          }
        } else if (removed ||
            rows.length != _items.length ||
            (rows.isNotEmpty &&
                _items.isNotEmpty &&
                rows.last.id != _items.last.id)) {
          _items
            ..clear()
            ..addAll(rows);
          DiskCache.write(_diskKey, raw);
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

  /// Ro'yxatni diskka yozadi (vaqtinchalik nusxalarsiz).
  void _saveDisk() {
    DiskCache.write(
      _diskKey,
      _items.where((m) => !m.pending).map((m) => m.toJson()).toList(),
    );
  }

  /// ADMIN: xabarni o'chiradi va ro'yxatdan darhol olib tashlaydi.
  Future<String?> removeMessage(String id) async {
    final err = await deleteChatMessage(id);
    if (err != null) return err;
    _items.removeWhere((m) => m.id == id);
    notifyListeners();
    return null;
  }

  /// ADMIN: TANLANGAN xabarlarni birdaniga o'chiradi.
  ///
  /// TALAB (foydalanuvchi): "xabarni bittalab emas, ustiga bosib
  /// turadi — xabar tanlandi, keyin qolganlarini qo'lda tanlab
  /// o'chirsa bo'ladigan qil; va hammasini bittada tanlab
  /// o'chiradigan tugma qo'sh".
  ///
  /// Hammasi BITTA so'rovda ketadi: 200 ta xabar uchun 200 ta
  /// so'rov yuborish sekin bo'lardi va yarmida uzilib qolsa
  /// yozishma yarim o'chgan holatda qolardi.
  Future<String?> removeMessages(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return null;
    final err = await deleteChatMessages(list);
    if (err != null) return err;
    final gone = list.toSet();
    _items.removeWhere((m) => gone.contains(m.id));
    notifyListeners();
    return null;
  }

  /// Xabar yuboradi. Xato bo'lsa matn qaytadi.
  ///
  /// `mediaFile` — B2'ga allaqachon yuklangan faylning NOMI,
  /// `mediaType` esa `image` yoki `video`.
  Future<String?> send(
    String body, {
    String mediaFile = '',
    String mediaType = '',
    int mediaMs = 0,
  }) async {
    final text = body.trim();
    if (text.isEmpty && mediaFile.isEmpty) return null;

    // ── XABAR EKRANDA DARHOL PAYDO BO'LADI ────────────────
    //
    // Serverning javobi kutilmaydi: xabar vaqtinchalik nusxa
    // bo'lib ro'yxatga qo'yiladi va yonida soat belgisi turadi.
    // Javob kelgach nusxa serverdan kelgani bilan almashadi.
    // Telegram ham aynan shunday qiladi — shu sabab u "bir
    // zumda yuboradi" bo'lib tuyuladi.
    //
    // Fayl bor bo'lsa vaqtinchalik nusxa QO'YILMAYDI: u paytda
    // yuklash progressi allaqachon ko'rinib turadi.
    final tempId = 'tmp${DateTime.now().microsecondsSinceEpoch}';
    if (mediaFile.isEmpty) {
      _items.add(ChatMessage(
        id: tempId,
        // Admin boshqa odamning suhbatida yozsa — admindan.
        fromAdmin: isAdminView,
        body: text,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        pending: true,
      ));
      _loaded = true;
      notifyListeners();
    }

    try {
      final r = await http
          .post(
            Uri.parse(_base),
            headers: _headers(json: true),
            body: jsonEncode({
              'body': text,
              if (userId != null) 'user_id': userId,
              if (mediaFile.isNotEmpty) 'media_file': mediaFile,
              if (mediaType.isNotEmpty) 'media_type': mediaType,
              if (mediaMs > 0) 'media_ms': mediaMs,
            }),
          )
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 && r.statusCode != 201) {
        _items.removeWhere((m) => m.id == tempId);
        notifyListeners();
        return '${j['error'] ?? 'Yuborilmadi'}';
      }
      _items.removeWhere((m) => m.id == tempId);
      final saved = ChatMessage.fromJson(j);
      if (!_items.any((m) => m.id == saved.id)) _items.add(saved);
      _loaded = true;
      _saveDisk();
      notifyListeners();
      return null;
    } catch (_) {
      _items.removeWhere((m) => m.id == tempId);
      notifyListeners();
      return 'Internet yo\'q — qaytadan urinib ko\'ring';
    }
  }
}

// ══════════════════════════════════════════════════════════════
//  ADMIN: BARCHA SUHBATLAR
// ══════════════════════════════════════════════════════════════

/// ADMIN: bitta xabarni butunlay o'chiradi.
///
/// TALAB (foydalanuvchi): "admin panelda kelgan xabarni va chatni
/// butunlay o'chirib tashlashi mumkin bo'lsin".
Future<String?> deleteChatMessage(String id) async {
  try {
    final r = await http
        .delete(Uri.parse('$_base/message/$id'), headers: _headers())
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return '${j['error'] ?? 'O\'chirilmadi'}';
    }
    return null;
  } catch (_) {
    return 'Internet yo\'q';
  }
}

/// ADMIN: bir nechta xabarni BITTA so'rovda o'chiradi.
Future<String?> deleteChatMessages(List<String> ids) async {
  if (ids.isEmpty) return null;
  try {
    final r = await http
        .post(
          Uri.parse('$_base/messages/delete'),
          headers: _headers(json: true),
          body: jsonEncode({'ids': ids}),
        )
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return '${j['error'] ?? 'O\'chirilmadi'}';
    }
    return null;
  } catch (_) {
    return 'Internet yo\'q';
  }
}

/// ADMIN: butun yozishmani o'chiradi.
Future<String?> deleteChatThread(int userId) async {
  try {
    final r = await http
        .delete(Uri.parse('$_base/thread/$userId'), headers: _headers())
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return '${j['error'] ?? 'O\'chirilmadi'}';
    }
    return null;
  } catch (_) {
    return 'Internet yo\'q';
  }
}


class ChatThreadsController extends ChangeNotifier {
  final List<ChatThread> _items = [];
  List<ChatThread> get items => List.unmodifiable(_items);

  bool _loading = false;
  bool _loaded = false;
  String? _error;

  bool get isLoading => _loading && _items.isEmpty;
  bool get hasData => _loaded;
  String? get error => _error;

  /// ADMIN: butun yozishmani o'chiradi va ro'yxatdan oladi.
  Future<String?> removeThread(int userId) async {
    final err = await deleteChatThread(userId);
    if (err != null) return err;
    _items.removeWhere((t) => t.userId == userId);
    // Diskdagi nusxa ham yangilansin — aks holda o'chirilgan
    // suhbat keyingi ochilishda qaytib chiqardi.
    DiskCache.write(_diskKey, _items.map((t) => {
          'user_id': t.userId,
          'first_name': t.firstName,
          'username': t.username,
          'photo_url': t.photoUrl,
          'last_body': t.lastBody,
          'last_at': t.lastAt,
          'last_from_admin': t.lastFromAdmin,
          'unread': t.unread,
        }).toList());
    notifyListeners();
    return null;
  }

  static const String _diskKey = 'chat_threads';
  static const String _verKey = 'chat_threads_ver';

  /// Ro'yxatning umumiy versiyasi (`ChatController._ver` izohiga
  /// qarang). Diskda ham saqlanadi.
  int _ver = 0;

  // ── UZOQ KUTISH ───────────────────────────────────────────
  //
  // Admin suhbatlar ro'yxatini ochib turganda yangi xabar
  // DARHOL yuqorida paydo bo'lsin. Usul xuddi suhbat ichidagidek
  // (`ChatController._watchLoop` izohiga qarang), farqi faqat
  // nimani kuzatishida: bu yerda BARCHA suhbatlarning eng
  // oxirgi vaqti (`all=1`).
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
        // `ver` — suhbatlar ro'yxatining umumiy versiyasi (server
        // tomonda `SUM(chat_ver) + COUNT(*)`). Ilgari bu yerda
        // faqat `since` yuborilardi va server har tekshiruvda
        // butun ro'yxatni sanardi.
        final r = await http
            .get(Uri.parse('$_base/wait?all=1&ver=$_ver&since=$_lastAt'),
                headers: _headers())
            .timeout(const Duration(seconds: 35));
        if (!_watching) return;
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          final ver = (j['ver'] as num?)?.toInt();
          if (j['new'] == true) {
            await load(force: true);
            await UnreadBadge.instance.refresh();
          }
          if (ver != null && ver != _ver) {
            _ver = ver;
            DiskCache.write(_verKey, [{'v': ver}]);
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

  /// Diskdagi nusxani DARHOL ko'rsatadi.
  void loadFromDisk() {
    if (_items.isNotEmpty) return;
    final rows = DiskCache.read(_diskKey);
    if (rows == null) return;
    _items
      ..clear()
      ..addAll(rows.map(ChatThread.fromJson));
    _ver = (DiskCache.readOne(_verKey)?['v'] as num?)?.toInt() ?? 0;
    _loaded = true;
    notifyListeners();
  }

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
        final rows =
            ((j['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _items
          ..clear()
          ..addAll(rows.map(ChatThread.fromJson));
        _loaded = true;
        _error = null;
        DiskCache.write(_diskKey, rows);
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

/// To'liq vaqt: `14:32 · 12.09.2026`.
///
/// TALAB (foydalanuvchi): "adminga xabar yuborganda yoki izoh
/// yozganda vaqti ham ko'rsatilsin". Qisqa ko'rinish (`chatTime`)
/// ro'yxat uchun, bu esa xabarning O'ZI ostida turadi.
String fullTime(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)} · '
      '${two(d.day)}.${two(d.month)}.${d.year}';
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
