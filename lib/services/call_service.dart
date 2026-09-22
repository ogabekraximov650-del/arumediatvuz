// lib/services/call_service.dart — AUDIO QO'NG'IROQ.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "ilovaga huddi telegramdagidek real vaqt rejimida
// kechikishlarsiz, huddi qo'ng'iroq qilgandek gaplashsa bo'ladigan
// qil" va "faqat adminlar bilan jonli suhbat".
//
// ── QANDAY ISHLAYDI ───────────────────────────────────────────
//
// WebRTC — Telegram, WhatsApp va Discord qo'ng'iroqlari ostidagi
// o'sha texnologiya. Ikki telefon TO'G'RIDAN-TO'G'RI ulanadi va
// ovoz server orqali o'tmaydi.
//
// Server faqat IKKI ishni bajaradi:
//
//   1. POCHTACHI. Telefonlar bir-biriga "men shu manzildaman,
//      shu kodeklarni bilaman" deb xat yuborishi kerak — buni
//      WebSocket orqali worker uzatadi (`realtime.rs`). Xatning
//      MAZMUNI serverga qorong'i va shunday bo'lishi ham kerak.
//
//   2. KO'PRIK (TURN). Mobil operatorlarda to'g'ridan-to'g'ri
//      ulanish ko'pincha imkonsiz (abonentlar bitta umumiy IP
//      ortida). Shunday hollarda oqim TURN orqali o'tadi —
//      kalitini worker beradi (`/api/call/ice`).
//
// ── NEGA SFU EMAS ─────────────────────────────────────────────
//
// Cloudflare'ning Serverless SFU'si KO'P ODAMLI suhbat uchun.
// Bu yerda esa suhbat ikki kishilik (foydalanuvchi ↔ admin), va
// ikki kishi uchun to'g'ridan-to'g'ri ulanish HAR DOIM yaxshiroq:
// kechikish kamroq, trafik puli esa umuman yo'q (oqim server
// orqali o'tmaydi).
//
// SFU guruh qo'ng'irog'i qo'shilganda kerak bo'ladi — sirlari
// (`REALTIME_SFU_*`) shu sabab allaqachon joyida turibdi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'auth_service.dart';
import 'call_sounds.dart';
import 'realtime_service.dart';

/// Qo'ng'iroq qaysi bosqichda.
enum CallState {
  /// Qo'ng'iroq yo'q.
  idle,

  /// Biz chaqiryapmiz, javob kutilmoqda.
  outgoing,

  /// Bizni chaqirishyapti.
  incoming,

  /// Qabul qilindi, ulanish qurilmoqda.
  connecting,

  /// Gaplashyapmiz.
  active,
}

extension CallStateLabel on CallState {
  /// Qo'ng'iroq oynasidagi holat matni.
  String get label => switch (this) {
        CallState.idle => '',
        CallState.outgoing => 'Kutilmoqda',
        CallState.incoming => 'Chaqirmoqda',
        CallState.connecting => 'Ulanmoqda',
        CallState.active => '',
      };
}

/// Qo'ng'iroq qanday tugadi — yozishmada shu ko'rinadi.
enum CallEnding { cancelled, declined, missed, finished, failed }

class CallService extends ChangeNotifier {
  CallService._();
  static final CallService instance = CallService._();

  // ── HOLAT ───────────────────────────────────────────────────

  CallState _state = CallState.idle;
  CallState get state => _state;
  bool get busy => _state != CallState.idle;

  /// Shu qo'ng'iroqning raqami. Ikki tomon ham bir xil raqamni
  /// ishlatadi.
  ///
  /// NEGA KERAK: eski qo'ng'iroqning kechikkan signali yangisini
  /// buzib qo'ymasligi uchun. Raqami mos kelmagan har qanday
  /// signal tashlab yuboriladi.
  String _callId = '';

  /// Suhbatdoshning ismi, `@useri` va rasmi — qo'ng'iroq oynasi
  /// va kelayotgan qo'ng'iroq banneri uchun.
  String peerName = '';
  String peerUsername = '';
  String peerAvatar = '';

  /// Biz chaqirdikmi (`true`) yoki bizni chaqirishdimi.
  bool _outgoing = false;
  bool get isOutgoing => _outgoing;

  bool _micOn = true;
  bool get micOn => _micOn;

  bool _speakerOn = false;
  bool get speakerOn => _speakerOn;

  /// Suhbat boshlangan vaqt — oynadagi soat shundan hisoblanadi.
  DateTime? _startedAt;
  DateTime? get startedAt => _startedAt;

  /// ── OVOZ TEBRANISHI ───────────────────────────────────────
  ///
  /// TALAB (foydalanuvchi): "gapirayotganda iloji bo'lsa ovoz
  /// tebranishini ham ko'rsatadigan narsa qo'sha olasanmi".
  ///
  /// 0.0 dan 1.0 gacha. WebRTC bu qiymatni O'ZI hisoblaydi va
  /// statistikada beradi — qo'shimcha hisob-kitob kerak emas.
  double _peerLevel = 0;
  double get peerLevel => _peerLevel;

  double _myLevel = 0;
  double get myLevel => _myLevel;

  // ── ICHKI ───────────────────────────────────────────────────

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  StreamSubscription<Map<String, dynamic>>? _signals;
  Timer? _levels;
  Timer? _timeout;

  /// Qabul qilinmagan qo'ng'iroqning taklifi (SDP).
  ///
  /// Kelayotgan qo'ng'iroq DARHOL qabul qilinmaydi — foydalanuvchi
  /// yashil tugmani bosishi kerak. Shu sabab taklif shu yerda
  /// kutib turadi.
  Map<String, dynamic>? _pendingOffer;

  /// ── ERTA KELGAN ICE ───────────────────────────────────────
  ///
  /// TOPILGAN MUAMMO: ICE nomzodlari SDP dan OLDIN kelib qolishi
  /// mumkin (tarmoqda tartib kafolatlanmagan). O'shanda
  /// `addCandidate` xato beradi va ulanish qurilmay qoladi.
  ///
  /// Shu sabab ular shu ro'yxatda kutadi va SDP o'rnatilgach
  /// birdaniga qo'shiladi.
  final List<RTCIceCandidate> _earlyIce = [];
  bool _remoteReady = false;

  /// Qo'ng'iroq tugaganda chaqiriladi — chat ekrani shu orqali
  /// yozishmaga yozuv qo'yadi.
  void Function(CallEnding how, Duration length)? onEnded;

  /// Kelayotgan qo'ng'iroq paydo bo'lganda chaqiriladi — banner
  /// shu orqali ko'rsatiladi.
  VoidCallback? onIncoming;

  // ── ULANISHNI TINGLASH ──────────────────────────────────────

  /// Signallarni tinglashni boshlaydi.
  ///
  /// Chat ekrani ochilganda chaqiriladi. Bir necha marta
  /// chaqirilsa ham bitta obuna bo'lib qoladi.
  void listen() {
    _signals ??= RealtimeService.instance.callEvents.listen(_onSignal);
  }

  void stopListening() {
    _signals?.cancel();
    _signals = null;
  }

  // ── CHAQIRISH ───────────────────────────────────────────────

  /// Qo'ng'iroq qiladi.
  ///
  /// Xato matni qaytsa — qo'ng'iroq boshlanmadi.
  Future<String?> start({
    required String name,
    String username = '',
    String avatar = '',
  }) async {
    if (busy) return 'Qo\'ng\'iroq allaqachon ketyapti';
    if (!RealtimeService.instance.connected) {
      return 'Ulanish yo\'q — internetni tekshiring';
    }

    peerName = name;
    peerUsername = username;
    peerAvatar = avatar;
    _outgoing = true;
    _callId = 'c${DateTime.now().microsecondsSinceEpoch}';
    _set(CallState.outgoing);
    CallSounds.instance.play(AppSound.outgoing);

    final err = await _buildConnection();
    if (err != null) {
      await _finish(CallEnding.failed);
      return err;
    }

    try {
      final offer = await _pc!.createOffer({
        // Faqat ovoz. Video keyinroq qo'shiladi — o'shanda shu
        // ikki qator o'zgaradi, qolgani o'z holicha qoladi.
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _pc!.setLocalDescription(offer);
      _signal({
        'action': 'offer',
        'call_id': _callId,
        'sdp': offer.sdp,
        'sdp_type': offer.type,
      });
    } catch (e) {
      debugPrint('CallService.start: $e');
      await _finish(CallEnding.failed);
      return 'Qo\'ng\'iroq boshlanmadi';
    }

    // ── JAVOBSIZ QO'NG'IROQ ───────────────────────────────────
    //
    // Suhbatdosh telefonini ko'rmasligi mumkin. 45 soniyadan
    // keyin qo'ng'iroq o'zi tugaydi — aks holda ohang abadiy
    // chalinib turardi.
    _timeout = Timer(const Duration(seconds: 45), () {
      if (_state == CallState.outgoing) hangUp(ending: CallEnding.missed);
    });
    return null;
  }

  // ── QABUL QILISH VA RAD ETISH ───────────────────────────────

  /// Kelayotgan qo'ng'iroqni qabul qiladi.
  Future<void> accept() async {
    final offer = _pendingOffer;
    if (_state != CallState.incoming || offer == null) return;
    _pendingOffer = null;
    _timeout?.cancel();
    await CallSounds.instance.stopRing();
    _set(CallState.connecting);

    final err = await _buildConnection();
    if (err != null) {
      await _finish(CallEnding.failed);
      return;
    }

    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(
        '${offer['sdp']}',
        '${offer['sdp_type'] ?? 'offer'}',
      ));
      _remoteReady = true;
      await _flushEarlyIce();

      final answer = await _pc!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _pc!.setLocalDescription(answer);
      _signal({
        'action': 'answer',
        'call_id': _callId,
        'sdp': answer.sdp,
        'sdp_type': answer.type,
      });
    } catch (e) {
      debugPrint('CallService.accept: $e');
      await _finish(CallEnding.failed);
    }
  }

  /// Kelayotgan qo'ng'iroqni rad etadi.
  Future<void> decline() async {
    if (_state != CallState.incoming) return;
    _signal({'action': 'decline', 'call_id': _callId});
    await _finish(CallEnding.declined);
  }

  /// Qo'ng'iroqni tugatadi (ikkala tomon uchun ham).
  Future<void> hangUp({CallEnding ending = CallEnding.finished}) async {
    if (!busy) return;
    _signal({'action': 'end', 'call_id': _callId});
    await _finish(ending);
  }

  // ── BOSHQARUV TUGMALARI ─────────────────────────────────────

  /// Mikrofonni o'chiradi yoki yoqadi.
  ///
  /// Oqim UZILMAYDI — faqat trek o'chiriladi. Shu sabab qayta
  /// yoqish bir zumda bo'ladi va ulanish qurilmaydi.
  void toggleMic() {
    _micOn = !_micOn;
    for (final t in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = _micOn;
    }
    if (!_micOn) _myLevel = 0;
    notifyListeners();
  }

  /// Karnayni yoqadi yoki o'chiradi.
  Future<void> toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    try {
      await Helper.setSpeakerphoneOn(_speakerOn);
    } catch (e) {
      debugPrint('CallService.toggleSpeaker: $e');
    }
    notifyListeners();
  }

  // ── SIGNALLAR ───────────────────────────────────────────────

  void _signal(Map<String, dynamic> m) =>
      RealtimeService.instance.sendCall(m);

  Future<void> _onSignal(Map<String, dynamic> m) async {
    final action = '${m['action'] ?? ''}';
    final id = '${m['call_id'] ?? ''}';

    // ── YANGI QO'NG'IROQ ──────────────────────────────────────
    if (action == 'offer') {
      if (busy) {
        // Band — suhbatdosh kutib qolmasin.
        _signal({'action': 'decline', 'call_id': id, 'busy': true});
        return;
      }
      _callId = id;
      _outgoing = false;
      _pendingOffer = m;
      peerName = '${m['from_name'] ?? ''}';
      peerUsername = '${m['from_username'] ?? ''}';
      peerAvatar = '${m['from_avatar'] ?? ''}';
      _set(CallState.incoming);
      CallSounds.instance.play(AppSound.incoming, duck: true);
      onIncoming?.call();

      // Javobsiz qolsa o'zi tugaydi.
      _timeout = Timer(const Duration(seconds: 45), () {
        if (_state == CallState.incoming) _finish(CallEnding.missed);
      });
      return;
    }

    // Qolgan hamma signal SHU qo'ng'iroqqa tegishli bo'lishi
    // kerak — eski qo'ng'iroqning kechikkan signali yangisini
    // buzmasin.
    if (id.isEmpty || id != _callId) return;

    switch (action) {
      case 'answer':
        if (_pc == null) return;
        try {
          await _pc!.setRemoteDescription(RTCSessionDescription(
            '${m['sdp']}',
            '${m['sdp_type'] ?? 'answer'}',
          ));
          _remoteReady = true;
          await _flushEarlyIce();
          _timeout?.cancel();
          _set(CallState.connecting);
        } catch (e) {
          debugPrint('CallService answer: $e');
          await _finish(CallEnding.failed);
        }

      case 'ice':
        final c = RTCIceCandidate(
          '${m['candidate'] ?? ''}',
          m['sdp_mid'] as String?,
          (m['sdp_mline_index'] as num?)?.toInt(),
        );
        if (_pc == null || !_remoteReady) {
          // Hali erta — navbatda kutsin.
          _earlyIce.add(c);
        } else {
          try {
            await _pc!.addCandidate(c);
          } catch (e) {
            debugPrint('CallService ice: $e');
          }
        }

      case 'decline':
        await _finish(CallEnding.declined);

      case 'end':
        await _finish(
          _state == CallState.outgoing ? CallEnding.cancelled : CallEnding.finished,
        );
    }
  }

  Future<void> _flushEarlyIce() async {
    if (_pc == null) return;
    for (final c in _earlyIce) {
      try {
        await _pc!.addCandidate(c);
      } catch (e) {
        debugPrint('CallService flushIce: $e');
      }
    }
    _earlyIce.clear();
  }

  // ── ULANISHNI QURISH ────────────────────────────────────────

  /// `RTCPeerConnection` yasaydi va mikrofonni ulaydi.
  ///
  /// Xato matni qaytsa — qo'ng'iroq boshlanmaydi.
  Future<String?> _buildConnection() async {
    try {
      final config = {
        'iceServers': await _iceServers(),
        // ── NEGA `unified-plan` ───────────────────────────────
        //
        // Eski `plan-b` rejimi WebRTC'dan olib tashlangan va
        // yangi brauzerlar bilan mos kelmaydi. Ataylab ochiq
        // yozilgan: kutubxonaning odatiy qiymati o'zgarsa ham
        // bu yer o'z holicha qoladi.
        'sdpSemantics': 'unified-plan',
      };
      _pc = await createPeerConnection(config);

      // ── MIKROFON ──────────────────────────────────────────
      //
      // `echoCancellation` va qolganlari — WebRTC'ning o'z ovoz
      // ishlovi. Ularsiz karnaydan chiqqan ovoz mikrofonga
      // qaytib, suhbatdosh o'z ovozini aks-sado bo'lib eshitardi.
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      for (final t in _localStream!.getTracks()) {
        await _pc!.addTrack(t, _localStream!);
      }

      _pc!.onIceCandidate = (c) {
        if (c.candidate == null) return;
        _signal({
          'action': 'ice',
          'call_id': _callId,
          'candidate': c.candidate,
          'sdp_mid': c.sdpMid,
          'sdp_mline_index': c.sdpMLineIndex,
        });
      };

      _pc!.onConnectionState = (s) {
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            if (_state != CallState.active) {
              _timeout?.cancel();
              CallSounds.instance.stopRing();
              CallSounds.instance.play(AppSound.connected);
              _startedAt = DateTime.now();
              _set(CallState.active);
              _watchLevels();
              // ── EKRAN O'CHMASIN ──────────────────────────
              //
              // Suhbat paytida ekran o'chsa Android ilovani
              // uxlatishga urinadi va ovoz uzilib-uzilib
              // qoladi. Qo'ng'iroq tugashi bilan qaytariladi.
              _keepAwake(true);
            }
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            // ── NEGA `disconnected` EMAS ──────────────────────
            //
            // `disconnected` — vaqtinchalik holat: tarmoq bir zum
            // uzilganda ham chiqadi va o'zi tiklanadi. Unga qarab
            // qo'ng'iroqni yopish har lift'da suhbatni uzardi.
            // `failed` esa qaytmaydigan holat.
            _finish(CallEnding.failed);
          default:
            break;
        }
      };

      return null;
    } catch (e) {
      debugPrint('CallService._buildConnection: $e');
      // Eng ko'p uchraydigan sabab — mikrofonga ruxsat berilmagan.
      return 'Mikrofonga ruxsat berilmadi';
    }
  }

  /// STUN/TURN ro'yxatini worker'dan oladi.
  ///
  /// Maxfiy kalit ILOVADA YO'Q: worker har safar qisqa muddatli
  /// hisob ma'lumoti yasab beradi (`call_ice` izohiga qarang).
  Future<List<Map<String, dynamic>>> _iceServers() async {
    const fallback = [
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ];
    try {
      final t = AuthService.instance.sessionToken;
      final r = await http.get(
        Uri.parse('$kApiBase/api/call/ice'),
        headers: {if (t != null) 'Authorization': 'Bearer $t'},
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return fallback;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final list = j['iceServers'];
      // Cloudflare javobni ikki xil shaklda berishi mumkin:
      // ro'yxat yoki bitta obyekt. Ikkalasi ham qabul qilinadi.
      if (list is List) {
        return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
      }
      if (list is Map) return [list.cast<String, dynamic>()];
      return fallback;
    } catch (e) {
      debugPrint('CallService._iceServers: $e');
      return fallback;
    }
  }

  // ── OVOZ TEBRANISHI ─────────────────────────────────────────

  /// Ovoz darajasini kuzatadi.
  ///
  /// ── NEGA 200 ms ───────────────────────────────────────────
  ///
  /// WebRTC statistikasi taxminan shu oraliqda yangilanadi —
  /// tez-tez so'rash yangi qiymat bermaydi, faqat protsessorni
  /// yeydi. Animatsiyaning silliqligi esa boshqa yo'l bilan
  /// hal qilinadi: qiymat sakrab emas, asta siljib boradi
  /// (pastdagi aralashtirish).
  void _watchLevels() {
    _levels?.cancel();
    _levels = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      final pc = _pc;
      if (pc == null) return;
      try {
        final reports = await pc.getStats();
        var peer = 0.0;
        var mine = 0.0;
        for (final r in reports) {
          final v = r.values;
          final lvl = (v['audioLevel'] as num?)?.toDouble();
          if (lvl == null) continue;
          // Kelayotgan ovoz — suhbatdoshniki, chiqayotgani —
          // bizniki.
          if (r.type == 'inbound-rtp' || r.type == 'remote-outbound-rtp') {
            if (lvl > peer) peer = lvl;
          } else if (r.type == 'media-source' || r.type == 'outbound-rtp') {
            if (lvl > mine) mine = lvl;
          }
        }
        // ── SILLIQLASH ────────────────────────────────────────
        //
        // Xom qiymat sakraydi va halqa "titrab" ko'rinadi. Shu
        // sabab yangi qiymat eskisiga ARALASHTIRILADI: ko'tarilish
        // tez (gapirish darhol ko'rinsin), pasayish sekin
        // (halqa yumshoq so'nsin).
        _peerLevel = _blend(_peerLevel, peer);
        _myLevel = _micOn ? _blend(_myLevel, mine) : 0;
        notifyListeners();
      } catch (_) {
        // Statistika olinmadi — tebranish ko'rsatilmaydi, lekin
        // suhbat davom etaveradi.
      }
    });
  }

  /// Ekranni uyg'oq ushlab turadi (yoki qo'yib yuboradi).
  ///
  /// Xatolar yutiladi: bu qulaylik, qo'ng'iroqning sharti emas.
  static void _keepAwake(bool on) {
    try {
      WakelockPlus.toggle(enable: on);
    } catch (e) {
      debugPrint('CallService._keepAwake: $e');
    }
  }

  static double _blend(double old, double now) {
    final k = now > old ? 0.6 : 0.25;
    return (old + (now - old) * k).clamp(0.0, 1.0);
  }

  // ── TUGATISH ────────────────────────────────────────────────

  void _set(CallState s) {
    _state = s;
    notifyListeners();
  }

  /// Hammasini tozalaydi.
  ///
  /// Bu yerdagi tartib MUHIM: avval oqim to'xtatiladi, keyin
  /// ulanish yopiladi. Teskarisi qilinsa Android'da mikrofon
  /// band bo'lib qolishi mumkin va keyingi qo'ng'iroq ochilmasdi.
  Future<void> _finish(CallEnding how) async {
    if (_state == CallState.idle) return;
    final length = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);

    _timeout?.cancel();
    _levels?.cancel();
    _timeout = null;
    _levels = null;
    _earlyIce.clear();
    _remoteReady = false;
    _pendingOffer = null;

    await CallSounds.instance.stopRing();

    try {
      for (final t in _localStream?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _localStream?.dispose();
    } catch (e) {
      debugPrint('CallService._finish(stream): $e');
    }
    _localStream = null;

    try {
      await _pc?.close();
    } catch (e) {
      debugPrint('CallService._finish(pc): $e');
    }
    _pc = null;

    // Karnay odatdagi holatiga qaytariladi — aks holda keyingi
    // video shu rejimda ochilardi.
    if (_speakerOn) {
      try {
        await Helper.setSpeakerphoneOn(false);
      } catch (_) {}
    }

    _keepAwake(false);
    _state = CallState.idle;
    _startedAt = null;
    _micOn = true;
    _speakerOn = false;
    _peerLevel = 0;
    _myLevel = 0;
    _callId = '';
    notifyListeners();

    // Tugash ohangi faqat HAQIQIY suhbatdan keyin — rad etilgan
    // qo'ng'iroqdan keyin u ortiqcha shovqin bo'lardi.
    if (how == CallEnding.finished && length > Duration.zero) {
      CallSounds.instance.play(AppSound.ended);
    }
    onEnded?.call(how, length);
  }
}
