// lib/services/realtime_service.dart — SERVER BILAN DOIMIY ULANISH.
//
// ═══════════════════════════════════════════════════════════════
//  NIMA UCHUN
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi):
//   * "foydalanuvchi onlayn yoki oflayn o'tirganini aniq ko'rsatib
//      turishning iloji bormi, huddi telegramdagidek";
//   * "xabar yoki chaqiruv kelganda ilovani qaysi joyida
//      o'tirgan bo'lsam ham yuqoridan bildirishnoma chiqishi
//      kerak";
//   * admin bilan audio qo'ng'iroq.
//
// Uchalasiga ham BITTA narsa kerak: serverning O'ZI ilovaga xabar
// bera olishi. Oddiy `GET` so'rovida bu bo'lmaydi — ilova so'raydi,
// server javob beradi, tamom. Shu sabab bu yerda WebSocket.
//
// ── NIMA UZATILADI ────────────────────────────────────────────
//
//   presence — suhbatdosh onlayn bo'ldi yoki uzildi;
//   typing   — "xabar yozmoqda" / "ovozli xabar yozmoqda";
//   chat     — yangi xabar, tahrirlandi, o'chirildi, qadaldi;
//   call     — qo'ng'iroq signallari (SDP va ICE).
//
// ── UZOQ KUTISH (`chat_wait`) O'CHIRILMADI ────────────────────
//
// U ishonchli ZAXIRA bo'lib qoladi. Ulanish uzilgan bo'lsa yoki
// tarmoq WebSocket'ni bloklasa (ba'zi korporativ Wi-Fi'lar
// shunday qiladi), xabar baribir yetib boradi — bir necha soniya
// kechikib. Ya'ni bu fayl tezlikni beradi, ishonchlilikni emas.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// Serverdan kelgan bitta xabar.
@immutable
class RtEvent {
  /// `presence`, `typing`, `chat`, `call`.
  final String type;
  final Map<String, dynamic> data;

  const RtEvent(this.type, this.data);

  @override
  String toString() => 'RtEvent($type, $data)';
}

/// Suhbatdoshning holati.
@immutable
class PeerPresence {
  final bool online;

  /// Oxirgi marta qachon onlayn bo'lgani (ms). 0 — noma'lum.
  final int lastSeen;

  const PeerPresence({this.online = false, this.lastSeen = 0});

  /// Sarlavhada ko'rsatiladigan matn: `Onlayn`, `yaqinda onlayn
  /// edi`, `5 daqiqa oldin` va hokazo.
  ///
  /// Telegram ham aynan shu tartibda yozadi: aniq daqiqa faqat
  /// yaqin vaqt uchun, undan nariga "yaqinda" yoki sana.
  String get label {
    if (online) return 'Onlayn';
    if (lastSeen <= 0) return 'oxirgi ko\'rinish noma\'lum';
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - lastSeen;
    if (diff < 60 * 1000) return 'hozirgina onlayn edi';
    if (diff < 60 * 60 * 1000) {
      return '${diff ~/ 60000} daqiqa oldin onlayn edi';
    }
    if (diff < 24 * 60 * 60 * 1000) {
      return '${diff ~/ 3600000} soat oldin onlayn edi';
    }
    final d = DateTime.fromMillisecondsSinceEpoch(lastSeen);
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd.$mm.${d.year} da onlayn edi';
  }
}

/// Suhbatdosh nima qilyapti.
enum PeerActivity {
  none,
  typing,
  recordingVoice,
  sending,
}

extension PeerActivityLabel on PeerActivity {
  /// Sarlavhada holat o'rniga chiqadigan matn.
  String? get label => switch (this) {
        PeerActivity.none => null,
        PeerActivity.typing => 'Xabar yozmoqda',
        PeerActivity.recordingVoice => 'Ovozli xabar yozmoqda',
        PeerActivity.sending => 'Yubormoqda',
      };
}

/// Doimiy ulanish.
///
/// Bitta suhbatga bitta ulanish. Admin boshqa odamning suhbatini
/// ochsa, avvalgisi yopilib yangisi ochiladi.
class RealtimeService extends ChangeNotifier {
  RealtimeService._();
  static final RealtimeService instance = RealtimeService._();

  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _retry;
  Timer? _activityOff;

  /// Qaysi suhbatga ulanganmiz (`null` — o'z suhbatiga).
  int? _threadUser;

  /// Ataylab uzildikmi (qayta ulanishga urinmaslik uchun).
  bool _closed = true;

  /// Necha marta qayta ulanishga urindik — kutish shunga qarab
  /// uzayadi.
  int _attempt = 0;

  PeerPresence _presence = const PeerPresence();
  PeerPresence get presence => _presence;

  PeerActivity _activity = PeerActivity.none;
  PeerActivity get activity => _activity;

  /// Sarlavhada ko'rsatiladigan matn.
  ///
  /// Nima qilayotgani (yozmoqda, ovoz yozmoqda) holatdan USTUN
  /// turadi — Telegram ham shunday.
  String get statusLine => _activity.label ?? _presence.label;

  bool get connected => _ws != null;

  /// Barcha voqealar shu oqimdan chiqadi.
  final _events = StreamController<RtEvent>.broadcast();
  Stream<RtEvent> get events => _events.stream;

  /// Faqat qo'ng'iroq signallari (qulaylik uchun alohida).
  Stream<Map<String, dynamic>> get callEvents =>
      _events.stream.where((e) => e.type == 'call').map((e) => e.data);

  /// Faqat yozishma voqealari.
  Stream<Map<String, dynamic>> get chatEvents =>
      _events.stream.where((e) => e.type == 'chat').map((e) => e.data);

  // ── ULANISH ─────────────────────────────────────────────────

  /// Ulanadi. `threadUser` — ADMIN uchun: qaysi odamning suhbati.
  ///
  /// Bir xil suhbatga qayta chaqirilsa hech narsa qilmaydi, ya'ni
  /// uni ekran har ochilganda bemalol chaqirish mumkin.
  Future<void> connect({int? threadUser}) async {
    if (AuthService.instance.sessionToken == null) return;
    if (_ws != null && _threadUser == threadUser) return;

    await disconnect();
    _threadUser = threadUser;
    _closed = false;
    await _open();
  }

  Future<void> _open() async {
    if (_closed) return;
    final token = AuthService.instance.sessionToken;
    if (token == null) return;

    // `https` → `wss`. Manzil har doim bitta joydan olinadi
    // (`kApiBase`), ya'ni domen o'zgarsa bu yer ham o'zi
    // moslashadi.
    final base = kApiBase.replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final q = _threadUser != null ? '?user_id=$_threadUser' : '';

    try {
      // ── NEGA TOKEN SARLAVHADA ─────────────────────────────
      //
      // Manzilga qo'yilgan token proksilar va jurnalliklarga
      // tushib qolishi mumkin. Dart'ning `WebSocket.connect`
      // usuli sarlavha berishga ruxsat beradi, shu sabab u har
      // doimgidek `Authorization` da ketadi.
      final ws = await WebSocket.connect(
        '$base/api/rt$q',
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));

      if (_closed) {
        await ws.close();
        return;
      }
      _ws = ws;
      _attempt = 0;
      notifyListeners();

      _sub = ws.listen(
        _onData,
        onDone: _onDropped,
        onError: (_) => _onDropped(),
        cancelOnError: true,
      );

      // ── TIRIK USHLAB TURISH ───────────────────────────────
      //
      // Mobil operatorlar jim turgan ulanishni ~1-2 daqiqada
      // uzadi. Bu "p" ga server tomonidagi runtime O'ZI javob
      // beradi — Durable Object umuman uyg'onmaydi, ya'ni bu
      // ping bepul (`realtime.rs` dagi auto-response izohi).
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 45), (_) {
        try {
          _ws?.add('p');
        } catch (_) {
          _onDropped();
        }
      });
    } catch (_) {
      _onDropped();
    }
  }

  void _onDropped() {
    _ping?.cancel();
    _sub?.cancel();
    _sub = null;
    _ws = null;
    // Ulanish uzildi — suhbatdosh haqidagi ma'lumot endi
    // ishonchsiz. Uni "oflayn" deb ko'rsatish XATO bo'lardi:
    // uzilgan BIZ bo'lishimiz mumkin. Shu sabab faqat "nima
    // qilayotgani" tozalanadi.
    _setActivity(PeerActivity.none);
    notifyListeners();
    if (_closed) return;

    // ── ORTIB BORUVCHI KUTISH ─────────────────────────────────
    //
    // Internet uzilganda har soniyada urinish batareyani yeydi va
    // serverga behuda yuk beradi. Shu sabab kutish 1, 2, 4, 8...
    // soniyaga o'sadi va 30 soniyada to'xtaydi.
    _attempt = (_attempt + 1).clamp(1, 6);
    final wait = Duration(seconds: (1 << (_attempt - 1)).clamp(1, 30));
    _retry?.cancel();
    _retry = Timer(wait, _open);
  }

  Future<void> disconnect() async {
    _closed = true;
    _retry?.cancel();
    _ping?.cancel();
    _activityOff?.cancel();
    await _sub?.cancel();
    _sub = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _threadUser = null;
    _presence = const PeerPresence();
    _activity = PeerActivity.none;
    notifyListeners();
  }

  // ── KELGAN XABAR ────────────────────────────────────────────

  void _onData(dynamic raw) {
    if (raw is! String) return;
    // Tirik ushlab turuvchi javob — e'tiborsiz.
    if (raw == 'P') return;
    Map<String, dynamic> j;
    try {
      final v = jsonDecode(raw);
      if (v is! Map<String, dynamic>) return;
      j = v;
    } catch (_) {
      return;
    }

    switch ('${j['t'] ?? ''}') {
      case 'presence':
        _presence = PeerPresence(
          online: j['online'] == true,
          lastSeen: ((j['last_seen'] as num?) ?? 0).toInt(),
        );
        // Suhbatdosh uzilgan bo'lsa "yozmoqda" ham to'xtaydi.
        if (!_presence.online) _activity = PeerActivity.none;
        notifyListeners();
        _events.add(RtEvent('presence', j));

      case 'typing':
        final on = j['on'] != false;
        _setActivity(!on
            ? PeerActivity.none
            : switch ('${j['kind'] ?? 'text'}') {
                'voice' => PeerActivity.recordingVoice,
                'sending' => PeerActivity.sending,
                _ => PeerActivity.typing,
              });
        _events.add(RtEvent('typing', j));

      case 'chat':
        _events.add(RtEvent('chat', j));

      case 'call':
        _events.add(RtEvent('call', j));
    }
  }

  /// "Nima qilyapti" ni qo'yadi va uni o'z-o'zidan so'ndiradi.
  ///
  /// NEGA O'ZI SO'NADI: "yozishni to'xtatdim" xabari yo'qolishi
  /// mumkin (ilova yopildi, tarmoq uzildi). Bunda sarlavhada
  /// "Xabar yozmoqda" abadiy qotib qolardi. Shu sabab u har
  /// holda 6 soniyada o'zi o'chadi.
  void _setActivity(PeerActivity a) {
    _activityOff?.cancel();
    if (_activity != a) {
      _activity = a;
      notifyListeners();
    }
    if (a != PeerActivity.none) {
      _activityOff = Timer(const Duration(seconds: 6), () {
        if (_activity != PeerActivity.none) {
          _activity = PeerActivity.none;
          notifyListeners();
        }
      });
    }
  }

  // ── YUBORISH ────────────────────────────────────────────────

  /// Xom xabar yuboradi. Ulanish yo'q bo'lsa jimgina tashlanadi:
  /// bu yerdan ketadigan hamma narsa O'TKINCHI, ya'ni yo'qolsa
  /// hech narsa buzilmaydi.
  void _send(Map<String, dynamic> m) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(jsonEncode(m));
    } catch (_) {
      _onDropped();
    }
  }

  /// "Men yozyapman" (yoki ovoz yozyapman) deb bildiradi.
  ///
  /// Tez-tez chaqirilmasin — har harfda emas, bir necha soniyada
  /// bir marta. Buni chaqiruvchi ekran hal qiladi.
  void sendTyping({String kind = 'text', bool on = true}) =>
      _send({'t': 'typing', 'kind': kind, 'on': on});

  /// Qo'ng'iroq signalini suhbatdoshga uzatadi.
  ///
  /// Mazmuni serverga qorong'i: u shunchaki pochtachi.
  void sendCall(Map<String, dynamic> payload) =>
      _send({'t': 'call', ...payload});

  /// Holatni qaytadan so'raydi (ilova fondan qaytganda).
  void resync() => _send({'t': 'sync'});

  @override
  void dispose() {
    disconnect();
    _events.close();
    super.dispose();
  }
}
