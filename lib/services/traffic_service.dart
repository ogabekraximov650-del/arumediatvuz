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
// Keyin hisob Android yadrosidan olindi
// (`TrafficStats.getUidRxBytes`) va UCHINCHI xato chiqdi: u
// ilovaning UID'i ostidagi HAMMA soketni sanaydi, shu jumladan
// MAHALLIY (`127.0.0.1`) uzatmani ham. Pleyer videoni ilovaning
// o'z kesh-serveridan oladi, ya'ni har bir video ikki marta
// sanalardi va oflayn ko'rilgan video ham trafik qo'shardi.
//
// TALAB (foydalanuvchi): "ilova faqatgina internet yoniq vaqtda
// worker orqali kelgan baytlarni hisoblashi kerak, ilova
// ichidagilarni emas."
//
// Endi hisob AYNAN tarmoqqa chiqadigan ikki joydan olinadi —
// `net_meter.dart` izohiga qarang.
//
// ═══════════════════════════════════════════════════════════════
//  QANDAY ISHLAYDI
// ═══════════════════════════════════════════════════════════════
//
//   1. Ilovaning IKKITA tarmoq hisoblagichi qo'shiladi:
//
//        * Rust yadrosi workerdan tortib olgan VIDEO baytlari
//          (`rust_video_cache_net_bytes`),
//        * ilovaning http klienti qabul qilgan baytlar — API,
//          posterlar, avatarlar (`NetMeter`, net_meter.dart).
//
//      Ikkovi ham AYNAN tarmoqdan kelgan baytni sanaydi.
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
// ILOVA QAYTA ISHGA TUSHSA: ikkala hisoblagich ham noldan
// boshlanadi. Bu holat aniqlanadi (yangi o'lchov eskisidan
// KICHIK) va o'sha o'lchovning o'zi farq sifatida olinadi — ya'ni
// hisob hech qachon manfiy bo'lmaydi va sakrab ketmaydi.

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'auth_service.dart';
import 'net_meter.dart';
import 'rust_bridge.dart';
import 'stats_service.dart';

class TrafficService extends ChangeNotifier with WidgetsBindingObserver {
  TrafficService._();
  static final TrafficService instance = TrafficService._();

  /// Diskdagi yozuv kaliti (Rust yadrosining ro'yxat keshi).
  // ── HISOB NOLDAN BOSHLANADI ──────────────────────────────────
  //
  // TALAB (foydalanuvchi): "Barcha statistikalarni tozalab tashla,
  // mening profilimga tegishlilarini ham — umuman statistika
  // qolmasin".
  //
  // Telefondagi eski yig'indini o'chirishning eng ishonchli yo'li
  // — kalitni ALMASHTIRISH. Yangi kalit ostida hech narsa yo'q,
  // ya'ni hisob o'z-o'zidan noldan boshlanadi va eski blob
  // keyingi saqlashda ustiga yozilib yo'q bo'ladi.
  //
  // Serverdagi raqamlar ham SHU bilan birga nollangan
  // (`worker/src/lib.rs` -> `stats_reset_v3`).
  static const String _key = 'traffic_v3';

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

  bool _started = false;

  /// Har bir toifa uchun oxirgi o'lchov (ilova ishga tushganidan
  /// beri o'sib boradigan hisoblagich).
  final Map<String, int> _lastByKind = {};

  /// ── TOIFALAR BO'YICHA UMUMIY HISOB ─────────────────────────
  ///
  /// TALAB (foydalanuvchi): "trafikda nimaga qancha trafik ketgani
  /// aniq qilib ko'rsatilsin".
  ///
  /// Serverda BITTA umumiy raqam turadi (`users_db.traffic_bytes`)
  /// — u nimaga ketganini bilmaydi. Shu sabab taqsimot shu yerda,
  /// telefonda yig'iladi va diskka yoziladi: hisobot yuborilgach
  /// ham NOLLANMAYDI, ya'ni bu "shu hisob shu telefonda qancha
  /// sarfladi" degan umr bo'yi hisob.
  final Map<String, int> _totals = {};

  /// Toifalar bo'yicha umumiy hisob (o'zgartirib bo'lmaydi).
  Map<String, int> get totals => Map.unmodifiable(_totals);

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
    // Xizmat ilova bilan birga yashaydi — taymer to'xtatilmaydi,
    // shu sabab uni ushlab turadigan maydon ham kerak emas.
    Timer.periodic(_sampleEvery, (_) => _tick());
  }

  void _tick() {
    unawaited(_sample());
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
    }
  }

  // ── O'lchov ──────────────────────────────────────────────────

  /// Hisobot yuborishdan oldin oxirgi baytlar ham qo'shilsin.
  Future<void> sampleNow() => _sample(save: true);

  Future<void> _sample({bool save = false}) async {
    // Hali ishga tushmagan bo'lsa o'lchov nuqtasi yo'q — bir
    // o'lchovlik farq butun hisoblagichga teng bo'lib ketardi.
    if (!_started) return;
    final now = _readCounters();
    var delta = 0;
    now.forEach((kind, value) {
      final last = _lastByKind[kind] ?? 0;
      // Ilova qayta ishga tushganda hisoblagich nolga tushadi —
      // o'shanda yangi qiymatning O'ZI farq bo'ladi.
      final d = value >= last ? value - last : value;
      _lastByKind[kind] = value;
      if (d <= 0) return;
      delta += d;
      _totals[kind] = (_totals[kind] ?? 0) + d;
    });
    if (delta > 0) _pending += delta;
    // Diskka: vaqti kelganda YOKI yig'indi sezilarli o'sganda.
    // Ilova to'satdan yopilsa ham ko'pi bilan shuncha bayt
    // hisobdan chiqib ketadi.
    final grew = _pending - _savedPending >= _saveAfterBytes;
    final due = DateTime.now().difference(_savedAt) >= _saveEvery;
    if (save || due || grew) _save();
    if (delta > 0) notifyListeners();
  }

  /// ── FAQAT TARMOQDAN KELGAN BAYTLAR ────────────────────────
  ///
  /// TALAB (foydalanuvchi): "ilova faqatgina internet yoniq
  /// vaqtda worker orqali kelgan baytlarni hisoblashi kerak,
  /// ilova ichidagilarni emas".
  ///
  /// Ikkita manba qo'shiladi va ikkovi ham AYNAN tarmoqdan
  /// kelgan baytni sanaydi:
  ///
  ///   * `videoCacheNetBytes` — Rust yadrosi workerdan tortib
  ///     olgan video baytlari. Diskdagi bo'lakdan o'qilgani
  ///     (ya'ni oflayn ko'rish) bunga KIRMAYDI;
  ///   * `NetMeter.bytes` — ilovaning http klienti qabul qilgan
  ///     baytlar: API javoblari, posterlar, avatarlar. Keshdan
  ///     olingan rasm tarmoqqa chiqmaydi, ya'ni sanalmaydi.
  ///
  /// Mahalliy `127.0.0.1` uzatmasi (pleyer <- kesh-serveri) hech
  /// qaysi hisobga kirmaydi — aynan shu "ilova ichidagi trafik"
  /// edi va aynan shu xato tuzatildi.
  ///
  /// Ikkala son ham ILOVA ishga tushganidan beri o'sadi va qayta
  /// ishga tushganda nolga tushadi — `_sample` dagi farq qoidasi
  /// buni o'zi hal qiladi.
  Map<String, int> _readCounters() {
    final out = <String, int>{
      TrafficKind.image: NetMeter.instance.of(TrafficKind.image),
      TrafficKind.api: NetMeter.instance.of(TrafficKind.api),
    };
    try {
      out[TrafficKind.video] = RustCore.instance.videoCacheNetBytes;
    } catch (_) {
      // Yadro hali yuklanmagan — keyingi o'lchovda qo'shiladi.
    }
    return out;
  }

  // ── Hisobot ──────────────────────────────────────────────────

  /// Vaqti kelmagan bo'lsa ham yig'indini DARHOL yuboradi.
  ///
  /// ── YUBORISHNI ENDI `SyncQueue` BAJARADI ──────────────────
  ///
  /// TALAB (foydalanuvchi): "barcha yozish so'rovlari qurilmaning
  /// o'zida qilinadi va bitta paket bo'lib yuboriladi".
  ///
  /// Shu sabab bu xizmat endi HECH QAYERGA murojaat qilmaydi. U
  /// faqat sanaydi va diskka yozadi; yig'indini `SyncQueue`
  /// paketning ichida olib ketadi va muvaffaqiyat bo'lsa shu
  /// yerdagi `markReported` ni chaqiradi.
  ///
  /// Ilgari bu yerda alohida `POST /api/traffic` bor edi — endi u
  /// yo'q, ya'ni kunlik so'rovlar sonidan yana bittasi tejaladi.

  /// Paket muvaffaqiyatli ketdi: AYNAN yuborilgani ayiriladi.
  ///
  /// Kutish davomida qo'shilgan yangi baytlar hisobda qoladi.
  void markReported(int sent) {
    if (sent <= 0) return;
    final left = _pending - sent;
    _pending = left > 0 ? left : 0;
    _reportedAt = DateTime.now().millisecondsSinceEpoch;
    _uid = AuthService.instance.user?.id ?? _uid;
    _save();
    // Profil sahifasidagi "Trafik" darhol yangilansin.
    notifyListeners();
    unawaited(MyStatsService.instance.load(force: true));
  }

  /// Hisob almashgan — eski yig'indi begona odamga yozilmasin.
  ///
  /// `SyncQueue` paketni yuborishdan oldin chaqiradi.
  void dropIfForeignAccount() {
    final me = AuthService.instance.user?.id ?? 0;
    if (me <= 0) return;
    if (_uid != 0 && _uid != me) {
      _pending = 0;
      _reportedAt = DateTime.now().millisecondsSinceEpoch;
      _save();
    }
    _uid = me;
  }

  // ── Disk ─────────────────────────────────────────────────────

  void _load() {
    try {
      // Eski (nollanishdan oldingi) yozuv endi kerak emas.
      RustCore.instance.saveListCache('traffic', const []);
      final rows = RustCore.instance.getCachedList(_key);
      if (rows == null || rows.isEmpty) return;
      final m = rows.first;
      _pending = (m['pending'] as num?)?.toInt() ?? 0;
      _reportedAt = (m['reported_at'] as num?)?.toInt() ?? 0;
      _uid = (m['uid'] as num?)?.toInt() ?? 0;
      _totals.clear();
      final saved = m['totals'];
      if (saved is Map) {
        saved.forEach((k, v) {
          final n = (v as num?)?.toInt() ?? 0;
          if (n > 0) _totals['$k'] = n;
        });
      }
    } catch (_) {}
  }

  void _save() {
    _savedAt = DateTime.now();
    _savedPending = _pending;
    try {
      RustCore.instance.saveListCache(_key, [
        {
          'pending': _pending,
          'reported_at': _reportedAt,
          'uid': _uid,
          // Toifalar bo'yicha umumiy hisob. `last` (o'lchov
          // nuqtasi) SAQLANMAYDI: u ilova ishga tushganda
          // baribir noldan boshlanadi.
          'totals': _totals,
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
    _totals.clear();
    _lastByKind.clear();
    _load();
    // O'lchov nuqtasi HOZIRGI qiymat: almashish paytidagi baytlar
    // allaqachon eski hisobga yozilgan.
    _lastByKind.addAll(_readCounters());
    _save();
    notifyListeners();
  }
}
