// lib/services/download_manager.dart
//
// ── VIDEO YUKLAB OLISH: REAL VAQTDAGI HOLAT ─────────────────────────
//
// Bu qatlam Rust yadrosidagi kesh-serverning HISOBINI o'qiydi va uni
// ekranga uzatadi. Muhim tafsilot: yuklab olish ham, video ko'rish ham
// AYNAN BIR XIL bo'lak fayllariga yozadi — shu sabab hisob bitta:
// foydalanuvchi videoni oddiy ko'rsa ham, foiz ko'rsatkichi o'sib
// boradi; keyin "yuklab olish"ni bossa, faqat YETISHMAYOTGAN bo'laklar
// olinadi.
//
// Nima uchun so'rab turish (polling) tanlandi: Rust tomonidagi hisob
// bir nechta native ish oqimida yangilanadi. Ularning har biridan
// Dart'ga hodisa yuborish (NativeApi.postCObject) murakkab va nozik
// bo'lardi; hisobni o'qish esa ARZON — u xotiradagi bitta HashMap'dan
// olinadi, diskka ham, tarmoqqa ham chiqmaydi. Shu sabab so'rab turish
// eng sodda va eng ishonchli yo'l.
//
// ── SILLIQLIK UCHUN UCHTA QOIDA ────────────────────────────────────
//
// So'rov SINXRON FFI chaqiruvi bo'lgani uchun u Flutter'ning UI
// oqimida bajariladi — ya'ni kadr tayyorlashni kechiktirishi mumkin.
// Shu sabab:
//
//   1. Rust tomoni bu chaqiruvda DISKKA UMUMAN CHIQMAYDI. Kerak
//      bo'lganda diskni skanerlash fon oqimiga topshiriladi
//      (video_cache.rs -> `stat_snapshot_fast`). Ilgari aynan shu
//      skanerlash UI oqimida bajarilardi: 166 MB video = 166 ta fayl,
//      bir necha sifat bilan mingga yaqin syscall — natijada qismlar
//      ro'yxatini surganda kadrlar tashlanardi.
//   2. Ro'yxat SURILAYOTGAN paytda so'rov umuman qilinmaydi
//      (`hold()` / `release()`). Barmoq ko'tarilishi bilan holat
//      darhol yangilanadi.
//   3. Oraliq holatga qarab moslashadi: yuklash ketayotganda tez
//      (500 ms), tinch turganda siyrak.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'rust_bridge.dart';
import 'video_cache_server.dart';

/// Bitta video (aniq bir sifat) uchun yuklab olish holati.
@immutable
class VideoCacheStat {
  /// Faylning to'liq hajmi (bayt). 0 — hali noma'lum (hech qachon
  /// ochilmagan va yuklab olinmagan).
  final int total;

  /// Diskda tayyor turgan hajm (bayt).
  final int downloaded;

  /// Hozir fon'da yuklab olinyaptimi (navbatda turgani ham shunga
  /// kiradi).
  final bool downloading;

  /// Tarmoq uzilib, qayta urinish kutilyaptimi. Yuklash TO'XTAGANI
  /// YO'Q — Rust yadrosi o'zi qayta uradi va to'xtagan bo'lagidan
  /// davom etadi.
  final bool retrying;

  /// NAVBATDA turibdi — hali boshlanmagan (`downloading` ham `true`).
  ///
  /// TALAB (foydalanuvchi): "bir vaqtda eng ko'pi 3 ta sifat
  /// yuklansin, qolganlari navbatda tursin". Navbat Rust yadrosida
  /// (`pick_task`), bu yerda faqat ekranda "navbatda" deb
  /// ko'rsatish uchun.
  final bool queued;

  // ── TEZLIK (bayt/soniya) VA FAOL OQIMLAR SONI ──────────────────
  //
  // NEGA KERAK: "yuklab olish sekinlashdi" degan gapni tekshirib
  // bo'lmasdi — ekranda faqat foiz ko'rinardi. Endi tezlik ham
  // ko'rinadi, ya'ni muammo taxmin emas, RAQAM bo'ladi. Ikkala son
  // ham Rust yadrosidagi xotira hisobidan keladi (diskka ham,
  // tarmoqqa ham chiqilmaydi).
  final int speed;

  /// Hozir shu video uchun nechta yuklash oqimi ishlayapti.
  /// (Diagnostika uchun: tezlik oqimlar soniga proporsional.)
  final int streams;

  const VideoCacheStat({
    this.total = 0,
    this.downloaded = 0,
    this.downloading = false,
    this.retrying = false,
    this.queued = false,
    this.speed = 0,
    this.streams = 0,
  });

  static const empty = VideoCacheStat();

  double get ratio =>
      total > 0 ? (downloaded / total).clamp(0.0, 1.0) : 0.0;

  int get percent => (ratio * 100).round();

  bool get complete => total > 0 && downloaded >= total;

  /// Ekran uchun tayyor matn: "3.4 MB/s". Tezlik nol bo'lsa
  /// (yuklash ketmayapti yoki hozircha bayt kelmadi) — bo'sh satr.
  String get speedLabel {
    if (speed <= 0) return '';
    final mb = speed / (1024 * 1024);
    if (mb >= 10) return '${mb.toStringAsFixed(0)} MB/s';
    if (mb >= 1) return '${mb.toStringAsFixed(1)} MB/s';
    return '${(speed / 1024).toStringAsFixed(0)} KB/s';
  }

  @override
  bool operator ==(Object other) =>
      other is VideoCacheStat &&
      other.total == total &&
      other.downloaded == downloaded &&
      other.downloading == downloading &&
      other.retrying == retrying &&
      other.queued == queued &&
      other.speed == speed &&
      other.streams == streams;

  @override
  int get hashCode =>
      Object.hash(
          total, downloaded, downloading, retrying, queued, speed, streams);
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  /// Ekran (yoki boshqa "egasi") -> u kuzatayotgan URL'lar.
  final Map<Object, Set<String>> _watchers = {};

  /// Foydalanuvchi yuklab olishni boshlagan URL'lar. Ular ekran
  /// yopilsa ham kuzatilaveradi — yuklash fon'da davom etadi.
  final Set<String> _active = {};

  final Map<String, VideoCacheStat> _stats = {};

  Timer? _timer;

  // ── TARMOQ QAYTGANDA YUKLASH DARHOL DAVOM ETSIN ──────────────
  //
  // TUZATILGAN XATO (foydalanuvchi: "yuklab olish barqaror emas"):
  // internet uzilganda Rust yadrosi qayta urinishlar orasini
  // asta-sekin uzaytiradi — 2, 4, 8, 16, 32 va nihoyat 60 soniya.
  // Bu tarmoq HAQIQATAN yo'q bo'lganda to'g'ri (behuda urinish
  // batareyani yeydi). Lekin internet QAYTGANDA ham yuklash yana
  // bir daqiqagacha kutib turardi — foydalanuvchi buni "yuklash
  // to'xtab qoldi" deb ko'rardi.
  //
  // Endi ulanish qaytishi bilan barcha faol yuklashlar UYG'OTILADI:
  // `videoDownload` qayta yuborilganda Rust tomonida kutish
  // hisoblagichi nolga tushadi va ish DARHOL davom etadi.
  // Yangi yuklash boshlanmaydi — vazifa o'sha-o'sha, faqat
  // kutish bekor qilinadi.
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _online = true;

  void _ensureConnectivityWatch() {
    if (_connSub != null) return;
    try {
      _connSub = Connectivity().onConnectivityChanged.listen((r) {
        final online =
            r.isNotEmpty && !r.every((e) => e == ConnectivityResult.none);
        final wasOffline = !_online;
        _online = online;
        if (online && wasOffline) _resumeActive();
      });
    } catch (_) {
      // Tarmoq holatini kuzatib bo'lmadi — yuklash avvalgidek
      // (Rust tomonidagi qayta urinish bilan) ishlayveradi.
    }
  }

  /// Faol yuklashlarni uyg'otadi (kutishni bekor qiladi).
  void _resumeActive() {
    if (_active.isEmpty) return;
    for (final url in _active) {
      RustCore.instance.videoDownload(url);
    }
    _poll();
  }

  VideoCacheStat statOf(String url) => _stats[url] ?? VideoCacheStat.empty;

  /// Ekran ko'rsatayotgan URL'lar ro'yxatini yangilaydi. Ro'yxat
  /// o'zgarmagan bo'lsa hech narsa qilinmaydi (keraksiz qayta
  /// chizishlarning oldini oladi).
  void watch(Object owner, Set<String> urls) {
    final current = _watchers[owner];
    if (current != null &&
        current.length == urls.length &&
        current.containsAll(urls)) {
      return;
    }
    _watchers[owner] = urls;
    _sync();
  }

  void unwatch(Object owner) {
    if (_watchers.remove(owner) != null) _sync();
  }

  Set<String> get _tracked => {
        for (final s in _watchers.values) ...s,
        ..._active,
      };

  /// ── SILLIQLIK: RO'YXAT SURILAYOTGANDA SO'ROV QILINMAYDI ────────
  ///
  /// `_poll()` Rust yadrosiga SINXRON FFI chaqiruv qiladi va javobni
  /// JSON'dan o'giradi — ikkalasi ham Flutter'ning UI oqimida
  /// bajariladi. Bu ish o'z-o'zidan arzon, lekin u AYNAN kadr
  /// tayyorlanayotgan paytga to'g'ri kelsa, o'sha kadr kechikadi va
  /// barmoq ostidagi ro'yxat "tutilib" ketadi.
  ///
  /// Shu sabab surish davomida so'rov butunlay to'xtatiladi. Barmoq
  /// ko'tarilishi bilan holat DARHOL bir marta yangilanadi — ya'ni
  /// foydalanuvchi hech qanday ma'lumotni yo'qotmaydi, faqat surish
  /// paytidagi bir necha yuzinchi soniya kechikadi.
  int _holds = 0;

  /// Surish boshlandi — so'rovlar to'xtaydi.
  void hold() => _holds++;

  /// Surish tugadi — holat darhol yangilanadi.
  void release() {
    if (_holds == 0) return;
    _holds--;
    if (_holds == 0) _poll();
  }

  /// Biror videoning yuklab olinishi HOZIR ketyaptimi.
  bool get _anyDownloading => _stats.values.any((s) => s.downloading);

  /// So'rab turish oralig'i.
  ///
  /// Yuklab olish ketayotganda tez — foiz silliq o'ssin. Hech narsa
  /// yuklanmayotgan bo'lsa esa holat faqat foydalanuvchi tugma
  /// bosgandagina o'zgaradi (va u holda `_sync()` darhol chaqiriladi),
  /// shu sabab tez-tez so'rash keraksiz UI ishi bo'lardi. Oflayn
  /// rejimda bir vaqtda o'nlab qismning holati so'raladi — u yerda
  /// oraliq yana ham siyrak.
  Duration get _interval {
    if (_anyDownloading) return const Duration(milliseconds: 500);
    return _tracked.length <= 16
        ? const Duration(seconds: 2)
        : const Duration(seconds: 5);
  }

  void _sync() {
    if (_tracked.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _timerInterval = null;
      return;
    }
    _poll();
    _rearm();
  }

  /// Taymerni kerakli oraliqqa moslaydi (oraliq o'zgargan bo'lsa).
  void _rearm() {
    final want = _interval;
    if (_timer == null || _timerInterval != want) {
      _timer?.cancel();
      _timerInterval = want;
      _timer = Timer.periodic(want, (_) => _poll());
    }
  }

  Duration? _timerInterval;

  void _poll() {
    // Ro'yxat surilayotgan bo'lsa — UI oqimini band qilmaymiz.
    if (_holds > 0) return;
    final urls = _tracked.toList();
    if (urls.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _timerInterval = null;
      return;
    }
    final raw = RustCore.instance.videoStats(urls);
    var changed = false;
    for (final entry in raw.entries) {
      final v = entry.value;
      final stat = VideoCacheStat(
        total: (v['total'] as num?)?.toInt() ?? 0,
        downloaded: (v['downloaded'] as num?)?.toInt() ?? 0,
        downloading: v['downloading'] == true,
        retrying: v['retrying'] == true,
        queued: v['queued'] == true,
        speed: (v['speed'] as num?)?.toInt() ?? 0,
        streams: (v['streams'] as num?)?.toInt() ?? 0,
      );
      if (_stats[entry.key] != stat) {
        _stats[entry.key] = stat;
        changed = true;
      }
      // Yuklab olish tugagan (yoki to'xtagan) bo'lsa, uni doimiy
      // kuzatuvdan chiqaramiz — aks holda ilova ishlagan davomida
      // ro'yxat cheksiz o'sib borardi.
      if (!stat.downloading && _active.contains(entry.key)) {
        _active.remove(entry.key);
      }
    }
    if (changed) notifyListeners();
    // Yuklash boshlangan/tugagan bo'lsa oraliq o'zgaradi.
    _rearm();
  }

  /// Yuklab olishni boshlaydi. Videoning bir qismi allaqachon keshda
  /// bo'lsa (masalan ko'rilgani sabab), FAQAT yetishmayotgan bo'laklar
  /// olinadi.
  void download(String url) {
    if (url.isEmpty) return;
    _ensureConnectivityWatch();
    // Odatiy holat: kesh-server ilova ochilishida allaqachon ishga
    // tushgan — yuklash shu zahoti boshlanadi.
    RustCore.instance.videoDownload(url);
    // Kutilmagan holatda (server hali tayyor emas) uni tayyorlab,
    // buyruqni QAYTA yuboramiz — shu sabab tugma hech qachon
    // "ishlamay qolmaydi". Buyruq takrorlansa ham yangi yuklash
    // boshlanmaydi: Rust tomonida vazifa bitta va o'zgarmaydi.
    VideoCacheServer.instance.ensureStarted().then((_) {
      RustCore.instance.videoDownload(url);
      _poll();
    });
    _active.add(url);
    // Tugmaning ko'rinishi darhol o'zgarishi uchun holatni "yuklanyapti"
    // deb belgilab qo'yamiz — keyingi so'rovda Rust'dan kelgan haqiqiy
    // qiymat uni almashtiradi.
    final cur = _stats[url] ?? VideoCacheStat.empty;
    _stats[url] = VideoCacheStat(
      total: cur.total,
      downloaded: cur.downloaded,
      downloading: true,
    );
    notifyListeners();
    _sync();
  }

  /// Yuklab olishni pauza qiladi — olingan qism joyida qoladi va
  /// keyinroq xuddi shu joydan davom etadi.
  void pause(String url) {
    if (url.isEmpty) return;
    RustCore.instance.videoPause(url);
    _active.remove(url);
    final cur = _stats[url] ?? VideoCacheStat.empty;
    _stats[url] = VideoCacheStat(
      total: cur.total,
      downloaded: cur.downloaded,
      downloading: false,
    );
    notifyListeners();
  }

  /// Shu sifatdagi videoni keshdan butunlay o'chiradi.
  void delete(String url) {
    if (url.isEmpty) return;
    RustCore.instance.videoDelete(url);
    _active.remove(url);
    final cur = _stats[url] ?? VideoCacheStat.empty;
    _stats[url] = VideoCacheStat(total: cur.total, downloaded: 0);
    notifyListeners();
  }
}
