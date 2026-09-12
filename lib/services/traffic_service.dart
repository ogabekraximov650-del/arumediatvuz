// lib/services/traffic_service.dart — TRAFIKNI ILOVA SANAYDI.
//
// ═══════════════════════════════════════════════════════════════
//  NEGA BU YERDA (TOPILGAN XATO)
// ═══════════════════════════════════════════════════════════════
//
// Ilgari trafikni WORKER sanardi: javob tanasini sanovchi quvurdan
// o'tkazardi. Ikki muammo chiqdi:
//
//   1) HISOB NOTO'G'RI edi. Pleyer `Range: bytes=0-` deb butun
//      qolgan faylni so'raydi, bir necha megabayt bufer yig'ib
//      ulanishni uzadi va keyingi joydan qayta so'raydi — natijada
//      166 MB lik video "1,14 GB" bo'lib ko'rinardi.
//   2) IJRO BUZILDI. O'ralgan oqim ba'zan uzilib, pleyerda
//      "yuklanmadi" xatosi chiqardi.
//
// Endi worker javobga UMUMAN tegmaydi, hisobni esa ilova yuritadi.
//
// ═══════════════════════════════════════════════════════════════
//  QANDAY ISHLAYDI
// ═══════════════════════════════════════════════════════════════
//
//   1. Android yadrosining hisoblagichi o'qiladi
//      (`TrafficStats.getUidRxBytes` — MainActivity.kt dagi
//      "aru/net" kanali). Bu — shu ilova HAQIQATAN qabul qilgan
//      bayt: pleyer oqimi, yuklab olish, rasm, API — hammasi.
//      Mahalliy 127.0.0.1 uzatmasi bunga kirmaydi.
//   2. Ikki o'lchov orasidagi FARQ yig'indiga qo'shiladi va
//      diskka (shifrlangan holda) yoziladi — ilova yopilsa ham
//      yo'qolmaydi.
//   3. SUTKADA BIR MARTA yig'indi bitta so'rov bilan workerga
//      yuboriladi (`POST /api/traffic`). Worker uni umumiy
//      statistikaga va o'sha odamning shaxsiy hisobiga qo'shadi.
//   4. Javob kelgach ilova yuborilgan miqdorni ayiradi va
//      qaytadan sanay boshlaydi.
//
// Trafik raqami real vaqtda kerak emas, shu sabab kuniga bitta
// so'rov yetarli — bu ham arzon, ham aniq.
//
// TELEFON O'CHIB YOQILSA: tizim hisoblagichi nolga tushadi. Bu
// holat aniqlanadi (yangi o'lchov eskisidan KICHIK) va o'sha
// o'lchovning o'zi farq sifatida olinadi — ya'ni hisob hech
// qachon manfiy bo'lmaydi va sakrab ketmaydi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'rust_bridge.dart';
import 'stats_service.dart';

class TrafficService extends ChangeNotifier with WidgetsBindingObserver {
  TrafficService._();
  static final TrafficService instance = TrafficService._();

  static const MethodChannel _channel = MethodChannel('aru/net');

  /// Diskdagi yozuv kaliti (Rust yadrosining ro'yxat keshi).
  static const String _key = 'traffic';

  /// Hisobot oralig'i — foydalanuvchi talabi bo'yicha 24 soat.
  static const Duration _reportEvery = Duration(hours: 24);

  /// Yadro hisoblagichini shuncha vaqtda bir marta o'qiymiz.
  /// Arzon chaqiruv (bitta tizim fayli), lekin tez-tez qilishning
  /// ma'nosi yo'q.
  static const Duration _sampleEvery = Duration(seconds: 30);

  /// Diskka shuncha vaqtda bir martadan ko'p yozilmaydi (ilova
  /// fon'ga o'tganda va yopilishidan oldin baribir yoziladi).
  static const Duration _saveEvery = Duration(minutes: 5);

  /// Yig'indi shuncha o'sgan bo'lsa — vaqtini kutmasdan yoziladi.
  /// Yozuv juda kichik (bir necha o'nlab bayt), shu sabab arzon.
  static const int _saveAfterBytes = 8 * 1024 * 1024;

  Timer? _timer;
  bool _started = false;

  /// Oxirgi o'qilgan tizim hisoblagichi (qurilma yoqilganidan beri).
  int _lastSample = 0;

  /// Hali workerga yuborilmagan bayt.
  int _pending = 0;

  /// Oxirgi muvaffaqiyatli hisobot vaqti (Unix ms).
  int _reportedAt = 0;

  /// Yig'indi KIMGA tegishli ekani. Hisob almashgan bo'lsa
  /// (chiqib, boshqasi bilan kirilgan), eski yig'indi begona
  /// hisobga yozilmasligi kerak — u tashlab yuboriladi.
  int _uid = 0;

  DateTime _savedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Oxirgi saqlashdagi yig'indi (qancha o'sganini bilish uchun).
  int _savedPending = 0;
  bool _reporting = false;

  /// Hozircha yuborilmagan bayt (diagnostika/ekran uchun).
  int get pendingBytes => _pending;

  // ── Ishga tushirish ──────────────────────────────────────────

  /// `main()` da bir marta chaqiriladi.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _load();
    WidgetsBinding.instance.addObserver(this);
    // Birinchi o'lchov — shu paytdan boshlab sanaymiz.
    await _sample(save: true);
    _timer = Timer.periodic(_sampleEvery, (_) => _tick());
  }

  void _tick() {
    unawaited(_sample());
    unawaited(maybeReport());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Ilova fon'ga o'tayotganda o'lchov olinadi va DARHOL
    // saqlanadi: tizim ilovani yopib qo'ysa ham hisob yo'qolmaydi.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_sample(save: true));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_sample());
      unawaited(maybeReport());
    }
  }

  // ── O'lchov ──────────────────────────────────────────────────

  /// Hisobot yuborishdan oldin oxirgi baytlar ham qo'shilsin.
  Future<void> sampleNow() => _sample(save: true);

  Future<void> _sample({bool save = false}) async {
    // Hali ishga tushmagan bo'lsa o'lchov nuqtasi yo'q — bir
    // o'lchovlik farq butun hisoblagichga teng bo'lib ketardi.
    if (!_started) return;
    final now = await _readCounter();
    if (now < 0) return; // qurilma qo'llab-quvvatlamaydi
    // Telefon o'chib yonganda hisoblagich nolga tushadi — o'shanda
    // yangi qiymatning O'ZI farq bo'ladi.
    final delta = now >= _lastSample ? now - _lastSample : now;
    _lastSample = now;
    if (delta > 0) _pending += delta;
    // Diskka: vaqti kelganda YOKI yig'indi sezilarli o'sganda.
    // Ilova to'satdan yopilsa ham ko'pi bilan shuncha bayt
    // hisobdan chiqib ketadi.
    final grew = _pending - _savedPending >= _saveAfterBytes;
    final due = DateTime.now().difference(_savedAt) >= _saveEvery;
    if (save || due || grew) _save();
    if (delta > 0) notifyListeners();
  }

  /// Qurilma hisoblagichi qo'llab-quvvatlanmaydi (bir marta
  /// aniqlanadi va o'zgarmaydi).
  bool _kernelCounterMissing = false;

  /// ── QABUL QILINGAN BARCHA BAYTLAR ──────────────────────────
  ///
  /// TALAB (foydalanuvchi): "ilova qabul qilgan HAR QANDAY baytni
  /// hisoblashi kerak — video, rasm, database ma'lumotlari va
  /// hokazo".
  ///
  /// Aynan shuning uchun raqam ilovaning O'Z hisoblagichlaridan
  /// emas, TIZIM YADROSIDAN olinadi:
  /// `TrafficStats.getUidRxBytes(Process.myUid())` — shu ilovaning
  /// UID'i ostida ochilgan HAMMA soket bo'yicha qabul qilingan
  /// bayt. Ya'ni:
  ///
  ///   * pleyer oqimi (ExoPlayer),
  ///   * yuklab olish (Rust yadrosi),
  ///   * posterlar va avatarlar (`/api/image/...`),
  ///   * har qanday API so'rovi (tarix, statistika, kirish),
  ///   * hatto Telegram havolasi tekshiruvi
  ///
  /// — hammasi bir joyda, TCP va UDP bilan birga. Sarlavhalar va
  /// qayta yuborilgan paketlar ham kiradi, ya'ni raqam operator
  /// hisoblaydigan trafikka eng yaqin.
  ///
  /// Mahalliy `127.0.0.1` uzatmasi bunga KIRMAYDI — diskdan o'qib
  /// pleyerga berilgan video trafik sifatida sanalmaydi.
  ///
  /// ── ZAXIRA YO'L ────────────────────────────────────────────
  ///
  /// Juda eski yoki g'alati qurilmada yadro hisoblagichi `-1`
  /// qaytarishi mumkin. Bunday holda hech bo'lmaganda video
  /// trafigi sanaladi (Rust yadrosining o'z hisobi). U ilova
  /// ishga tushganda noldan boshlanadi — quyidagi farq qoidasi
  /// buni o'zi hal qiladi.
  Future<int> _readCounter() async {
    if (!_kernelCounterMissing) {
      try {
        final v = await _channel.invokeMethod<int>('rx');
        if (v != null && v >= 0) return v;
      } catch (_) {
        // Kanal yo'q (masalan Android bo'lmagan tizim).
      }
      _kernelCounterMissing = true;
    }
    try {
      return RustCore.instance.videoCacheNetBytes;
    } catch (_) {
      return -1;
    }
  }

  // ── Hisobot ──────────────────────────────────────────────────

  /// Vaqti kelmagan bo'lsa ham yig'indini DARHOL yuboradi.
  ///
  /// Faqat bitta joyda ishlatiladi — hisobdan chiqishdan oldin.
  /// Aks holda o'sha paytgacha yig'ilgan trafik tashlab
  /// yuborilardi (chiqishda hamma narsa tozalanadi).
  Future<void> reportNow() => maybeReport(force: true);

  /// Vaqti kelgan bo'lsa yig'indini workerga yuboradi.
  ///
  /// Shart: hisobga kirilgan, yig'indi noldan katta va oxirgi
  /// hisobotdan 24 soat o'tgan (`force` bo'lsa vaqt shart emas).
  Future<void> maybeReport({bool force = false}) async {
    if (_reporting) return;
    if (_pending <= 0) return;
    final token = AuthService.instance.sessionToken;
    if (token == null) return;
    final me = AuthService.instance.user?.id ?? 0;
    if (me <= 0) return;
    // Hisob almashgan — eski yig'indi begona odamga yozilmaydi.
    if (_uid != 0 && _uid != me) {
      _pending = 0;
      _uid = me;
      _reportedAt = DateTime.now().millisecondsSinceEpoch;
      _save();
      return;
    }
    _uid = me;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      // Birinchi marta: sanoq boshlangan paytdan 24 soat o'tsin.
      if (_reportedAt == 0) {
        _reportedAt = now;
        _save();
        return;
      }
      if (now - _reportedAt < _reportEvery.inMilliseconds) return;
    }

    _reporting = true;
    final sending = _pending;
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/traffic'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'bytes': sending}),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        // AYNAN yuborilgani ayiriladi: kutish davomida yangi
        // baytlar qo'shilgan bo'lsa, ular hisobda qoladi.
        final left = _pending - sending;
        _pending = left > 0 ? left : 0;
        _reportedAt = DateTime.now().millisecondsSinceEpoch;
        _save();
        // Profil sahifasidagi "Trafik" darhol yangilansin.
        notifyListeners();
        unawaited(MyStatsService.instance.load(force: true));
      }
    } catch (_) {
      // Tarmoq yo'q — keyingi safar qayta urinamiz, hisob joyida.
    } finally {
      _reporting = false;
    }
  }

  // ── Disk ─────────────────────────────────────────────────────

  void _load() {
    try {
      final rows = RustCore.instance.getCachedList(_key);
      if (rows == null || rows.isEmpty) return;
      final m = rows.first;
      _pending = (m['pending'] as num?)?.toInt() ?? 0;
      _lastSample = (m['last'] as num?)?.toInt() ?? 0;
      _reportedAt = (m['reported_at'] as num?)?.toInt() ?? 0;
      _uid = (m['uid'] as num?)?.toInt() ?? 0;
    } catch (_) {}
  }

  void _save() {
    _savedAt = DateTime.now();
    _savedPending = _pending;
    try {
      RustCore.instance.saveListCache(_key, [
        {
          'pending': _pending,
          'last': _lastSample,
          'reported_at': _reportedAt,
          'uid': _uid,
        }
      ]);
    } catch (_) {}
  }

  // ── HISOB ALMASHGANDA ────────────────────────────────────────
  //
  // Trafik hisobi ham hisobga TEGISHLI ma'lumot, ya'ni u ham
  // `accountid_<id>` papkasida yotadi. Almashish ikki bosqichda
  // bo'ladi:
  //
  //   1. `detach()` — oxirgi baytlar sanaladi va ESKI papkaga
  //      yoziladi (papka hali almashmagan);
  //   2. `attach()` — YANGI papkadagi yozuv o'qiladi va o'lchov
  //      nuqtasi hozirgi qiymatga tenglanadi, ya'ni oldingi
  //      hisobning trafigi yangisiga qo'shilib ketmaydi.
  //
  // Hech narsa O'CHIRILMAYDI: eski hisobga qaytilsa, uning
  // yig'indisi o'z papkasida turgan bo'ladi.

  /// Eski hisobning hisobini yakunlab, diskka yozadi.
  Future<void> detach() async {
    await _sample(save: true);
  }

  /// Yangi hisobning yozuvini o'qiydi va sanoqni shu paytdan
  /// boshlaydi.
  Future<void> attach() async {
    _pending = 0;
    _uid = 0;
    _reportedAt = 0;
    _lastSample = 0;
    _load();
    final now = await _readCounter();
    // O'lchov nuqtasi HOZIRGI qiymat: almashish paytidagi baytlar
    // allaqachon eski hisobga yozilgan.
    _lastSample = now < 0 ? 0 : now;
    _save();
    notifyListeners();
  }
}
