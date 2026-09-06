import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
// ═══════════════════════════════════════════════════════════════════
//  PLEYER: RASMIY `video_player` (Android'da ExoPlayer / Media3)
// ═══════════════════════════════════════════════════════════════════
//
// NEGA fvp/mdk-sdk'DAN VOZ KECHILDI (uzoq izlanishdan keyingi qaror):
//
// Avval pleyer `package:fvp/mdk.dart` (mdk-sdk) ustiga QO'LDA
// qurilgan edi. U ishlagan bo'lsa-da, biz uning past-darajali
// hayot-siklini (Player yaratish/o'chirish, native surface'ni
// biriktirish, media almashtirish, EOF/loop) o'zimiz boshqarishga
// majbur edik. Har bir qadamda yangi nosozlik chiqaverdi: sek
// paytida o'chirilgan obyektga murojaat (SIGSEGV), media
// almashtirilganda rasm qotib qolishi, fullscreen'da surface'ning
// uzilib qolishi. Bularning har biri "biz o'zimiz yozgan"
// boshqaruv qatlamining xatosi edi.
//
// `video_player` — Flutter jamoasining RASMIY paketi va Android'da
// u **ExoPlayer (androidx.media3)** ustida ishlaydi. Bu AYNAN
// YouTube va boshqa yirik Android pleyerlari ishlatadigan dvigatel.
// Bizga kerak bo'lgan hamma narsa unda tayyor va millionlab
// ilovalarda sinovdan o'tgan:
//   * ketma-ket, tez-tez sek qilish — ExoPlayer ularni ichkarida
//     birlashtiradi va navbatga to'plamaydi;
//   * media almashtirish, EOF va takrorlash (setLooping);
//   * surface'ning hayot sikli — plagin o'zi to'g'ri boshqaradi;
//   * bufer strategiyasi.
//
// Bundan tashqari `VideoViewType.platformView` bilan chiqish
// **SurfaceView**ga beriladi (video_player_android 2.8.0+) —
// Google'ning Android uchun rasmiy tavsiyasi va Flutter
// teksturasidagi (SurfaceTexture/Impeller) muammolardan xoli yo'l.
//
// ═══════════════════════════════════════════════════════════════════
//  VIDEO QAYERDAN KELADI: IKKI YO'L, IKKITASI HAM ANIQ
// ═══════════════════════════════════════════════════════════════════
//
// ── ILGARI QANDAY EDI VA NEGA MUAMMO BO'LGAN ──────────────────────
//
// Pleyer HAR DOIM telefondagi mahalliy (127.0.0.1) Rust kesh-serveri
// orqali ishlardi. Undan ikkita muammo kelib chiqardi:
//
//   1) ORTIQCHA (VA ERTA) YUKLASH. Mahalliy server pleyer so'ramagan
//      baytlarni ham oldindan tortib olardi: bo'laklar 8 MiB'lik
//      guruhlar bilan olinar, ustiga worker'da "oyna isitish" ham
//      ishga tushardi. Foydalanuvchi videoning bir necha daqiqasini
//      ko'rsa ham, trafik ancha ko'p sarflanardi.
//
//   2) "VIDEO TUGADI" DEB BOSHIDAN BOSHLANISH. Mahalliy server biror
//      bo'lakni ololmasa, javobni yarmida to'xtatib ulanishni
//      yopardi. ExoPlayer uchun esa javobning erta tugashi "FAYL
//      TUGADI" degani: u videoni tugagan deb bilib, yig'ilgan
//      buferni boshidan qayta ko'rsatardi — video esa hali
//      o'rtasida edi.
//
// ── ENDI QANDAY ───────────────────────────────────────────────────
//
//   * Fayl telefonda TO'LIQ bor  ->  MAHALLIY server (127.0.0.1).
//     Internet bor-yo'qligidan qat'i nazar: bitta ham tarmoq
//     so'rovi yuborilmaydi.
//
//   * Fayl to'liq emas + internet bor  ->  TO'G'RIDAN-TO'G'RI
//     worker (`/api/play/...`). Bu oddiy, to'g'ri HTTP video
//     manbasi: `Range` so'rovi o'zgarishsiz bajariladi va javob
//     hech qachon sun'iy kesilmaydi. Qancha bayt olishni endi
//     PLEYERNING O'ZI hal qiladi (buferi to'lishi bilan soketdan
//     o'qishni to'xtatadi) — ortiqcha bayt olinmaydi.
//
//     MUHIM: `/api/play/...` FAQAT Cloudflare keshidan xizmat
//     qiladi va B2'ga UMUMAN chiqmaydi — kesh tekin, B2'ning
//     har bir so'rovi esa pul. B2'ga murojaat butun ijro
//     yo'lida ATIGI BITTA joyda bo'ladi: isitish so'rovi
//     480 MiB'lik oynani keshga ko'chirganda. Shu sabab pleyer
//     ochilishidan oldin ilova o'sha isitishni chaqirib,
//     HAQIQATAN tugashini kutadi ("Video tayyorlanyabdi...").
//
//     ILGARI shu yerda xato bor edi: worker boshqa birov
//     isitayotganini ko'rsa darhol "warming" deb qaytarar,
//     Rust yadrosi esa bunday javobda ham "tayyor" deb
//     belgilardi. Ilova pleyerni ochar, kesh esa bo'sh bo'lgani
//     uchun 503 kelar va ekranda "Videoni yuklab bo'lmadi"
//     chiqardi — onlayn video umuman ochilmasligining sababi
//     aynan shu edi. Endi worker oyna keshda paydo bo'lishini
//     kutadi va yozilganini O'QIB tasdiqlaydi; ilova esa
//     muvaffaqiyatsizlikni ko'rsa isitishni majburan qayta
//     boshlaydi.
//
// ── PLEYER QANCHA BAYT SO'RAYDI ───────────────────────────────
//
// Onlayn ijroda baytlarni PLEYERNING O'ZI (ExoPlayer) so'raydi,
// oradagi hech qanday "bo'laklovchi" qatlam yo'q. ExoPlayer
// bitta `Range: bytes=N-` so'rovini ochadi va buferi to'lishi
// bilan soketdan o'qishni TO'XTATADI (TCP oqim boshqaruvi) —
// ya'ni tarmoqdan aynan buferga sig'adigan bayt keladi.
// Buferning standart sig'imi — 50 SONIYA (ExoPlayer'ning
// `DefaultLoadControl` qiymati), va bufer shu chegaradan
// kamayishi bilan o'qish avtomatik qayta boshlanadi, ya'ni
// faqat BO'SHAGAN JOYNI to'ldiradigancha bayt olinadi.
// Yuklab olish tugmasidagi 1 MiB'lik bo'laklar bunga UMUMAN
// aloqador emas — u boshqa yo'l (`/api/image/...`).
//
//   * Fayl to'liq emas + internet yo'q  ->  ijro etib bo'lmaydi,
//     foydalanuvchiga aniq xabar ko'rsatiladi.
//
// Ya'ni mahalliy kesh-server O'CHIRILMADI, uning VAZIFASI aniqlashdi:
// u endi YUKLAB OLISH tugmasiga xizmat qiladi (va yuklab olingan
// videoni oflayn ko'rsatadi), ijro oqimiga aralashmaydi.
import 'package:video_player/video_player.dart';

import '../services/download_manager.dart';
import '../services/rust_bridge.dart';
import '../services/video_cache_server.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

const String _apiBase = 'https://aniraxuzapp.ogabekraximov650.workers.dev';

class VideoPlayerScreen extends StatefulWidget {
  final Map<String, dynamic> season;
  const VideoPlayerScreen({super.key, required this.season});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabCtrl;

  List<Map<String, dynamic>> _episodes = [];
  List<Map<String, dynamic>> _seasons = [];
  bool _loadingEps = true;
  bool _loadingSeasons = true;

  // ── PLEYER ───────────────────────────────────────────────────
  // Har bir epizod uchun BITTA `VideoPlayerController`. Uni
  // yaratish/o'chirishni endi biz emas, rasmiy plagin boshqaradi —
  // surface, dekoder va bufer hayot sikli ExoPlayer tomonida,
  // sinovdan o'tgan holda kechadi.
  VideoPlayerController? _controller;

  // Foydalanuvchi NIMANI xohlagani: ijro yoki pauza. Sek/buferlash
  // paytida ExoPlayer ichkarida bir lahza to'xtaydi va `isPlaying`
  // false bo'ladi — lekin tugmaning ko'rinishi shu sababli
  // "sakramasligi" kerak. Shu sabab tugma ana shu NIYATNI ko'rsatadi.
  bool _intendedPlaying = true;

  // Progress chizig'i barmoq bilan surilayotgan payt.
  bool _isScrubbing = false;

  Map<String, dynamic>? _currentEp;
  // Hozir ijro etilayotgan videoning ASL (`/api/image/...`) manzili.
  // Kesh, yuklab olish hisobi va o'chirish AYNAN shu manzil bo'yicha
  // ishlaydi. Pleyerga beriladigan manzil esa boshqacha bo'lishi
  // mumkin (mahalliy proksi yoki `/api/play/...`) — `_playEpisode`ga
  // qarang.
  String _currentUrl = '';
  // Ro'yxatda YOYILGAN (sifatlari ko'rsatilgan) qismlar kalitlari.
  final Set<String> _expandedEps = {};

  // ── OFLAYN REJIM ─────────────────────────────────────────────
  // Internet yo'q bo'lganda faqat TO'LIQ yuklab olingan sifatlar va
  // ular tegishli qismlar ko'rsatiladi — chunki qolganlarini ochib
  // ham bo'lmaydi va foydalanuvchini "ishlamayapti" deb chalkashtirish
  // keraksiz.
  bool _offline = false;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  String? _selectedQuality;
  bool _playerLoading = false;

  // Hozirgi video QAYERDAN kelayapti:
  //   true  — telefondagi mahalliy server (fayl to'liq yuklangan);
  //   false — to'g'ridan-to'g'ri worker (internet orqali).
  bool _playViaLocal = false;

  // Worker 480 MiB'lik oynani B2'dan Cloudflare keshiga
  // ko'chirayotgan payt `true`. Shu paytda ekranda aylanma halqa va
  // "Video tayyorlanyabdi..." yozuvi turadi — foydalanuvchi nima
  // kutayotganini bilsin.
  bool _preparing = false;
  int _playToken = 0;
  String? _playerError;

  // ── Ikki marta bosib sek qilishda tarmoqqa yuboriladigan seekTo
  // so'rovini debounce qilish uchun: tez-tez ketma-ket bosilganda
  // faqat OXIRGI holatga BITTA marta sek qilinadi.


  bool _isFullscreen = false;
  bool _showControls = true;
  Timer? _hideTimer;

  DateTime _lastPlayPauseTap = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Ikki marta bosib sek qilish (double-tap seek) ─────────────
  int _leftSeekAccum = 0;
  int _rightSeekAccum = 0;
  bool _showLeftSeek = false;
  bool _showRightSeek = false;
  Timer? _leftSeekHideTimer;
  Timer? _rightSeekHideTimer;

  // ── Video ustidagi tapni qo'lda kuzatish uchun: GestureDetector'ning
  // o'rnatilgan double-tap tanish tizimi ishlatilmaydi (u taplar orasidagi
  // masofani ham cheklaydi, shu sabab ekranning istalgan nuqtasiga ikki
  // marta bosilganda ishonchli ishlamas edi). Buning o'rniga taplar
  // orasidagi VAQT (300ms) tekshiriladi — joyidan qat'iy nazar.
  DateTime? _lastTapTime;
  bool? _lastTapWasLeft;
  Timer? _pendingSingleTapTimer;

  // Sek gesture qatlami (Listener) uchun: tapni surishdan ajratish —
  // barmoq qo'yilgan nuqta va vaqti. Agar barmoq 14px dan ko'p surilsa
  // yoki 350ms dan uzoq ushlab turilsa, bu tap emas (masalan slayderni
  // tortish) va sek ishga tushmaydi.
  Offset? _tapDownPos;
  DateTime? _tapDownTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabCtrl = TabController(length: 3, vsync: this);
    _watchConnectivity();
    _loadEpisodes();
    _loadSeasons();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connSub?.cancel();
    // Surish o'rtasida ekran yopilsa, to'xtatish osilib qolmasin.
    _releaseDownloadUpdates();
    _epScrollCtrl.dispose();
    DownloadManager.instance.unwatch(this);
    _tabCtrl.dispose();
    _hideTimer?.cancel();
    _leftSeekHideTimer?.cancel();
    _rightSeekHideTimer?.cancel();
    _seekIdleTimer?.cancel();
    _pendingSingleTapTimer?.cancel();
    _healthTimer?.cancel();
    _recoveryStreakResetTimer?.cancel();
    _restoreSystemUI();
    final c = _controller;
    _controller = null;
    c?.removeListener(_onControllerUpdate);
    c?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Ilova fonga ketganda video ijrosini to'xtatamiz — orqa fonda
    // bir nechta video parallel ijro bo'lib qolishining oldini oladi.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _controller?.pause();
    }
  }

  // ── Ma'lumot yuklash ──────────────────────────────────────────
  // MUHIM (oflayn rejim): ro'yxat AVVAL diskdagi keshdan (Rust yadrosi
  // orqali) o'qib darhol ko'rsatiladi — shu sabab internet bo'lmasa
  // ham epizod tugmalari ko'rinib turadi va allaqachon keshlangan
  // videolarni oflayn ko'rish mumkin. Keyin tarmoqdan yangilanadi;
  // tarmoq ishlamasa, keshdagi ro'yxat joyida qoladi (o'chirilmaydi).
  Future<void> _loadEpisodes() async {
    final animeId = widget.season['anime_id']?.toString() ?? '';
    final seasonId = widget.season['season_id']?.toString() ?? '';
    final cacheKey = 'eps_${animeId}_$seasonId';

    final cached = RustCore.instance.getCachedList(cacheKey);
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() {
        _episodes = cached;
        _loadingEps = false;
      });
      _autoOpenFirstEpisode();
    }

    try {
      final res = await http
          .get(Uri.parse('$_apiBase/api/epizods/$animeId/$seasonId'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final fresh =
            (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
        RustCore.instance.saveListCache(cacheKey, fresh);
        if (mounted) {
          setState(() {
            _episodes = fresh;
            _loadingEps = false;
          });
          _syncWatchedUrls();
          _autoOpenFirstEpisode();
        }
        return;
      }
    } catch (_) {
      // Tarmoq yo'q/xato — keshdagi ro'yxat (agar bo'lsa) saqlanib qoladi.
    }
    if (mounted && _loadingEps) setState(() => _loadingEps = false);
  }

  Future<void> _loadSeasons() async {
    final animeId = widget.season['anime_id']?.toString() ?? '';
    final cacheKey = 'seasons_$animeId';

    final cached = RustCore.instance.getCachedList(cacheKey);
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() {
        _seasons = cached;
        _loadingSeasons = false;
      });
    }

    try {
      final res = await http
          .get(Uri.parse('$_apiBase/api/seasons/anime/$animeId'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final fresh =
            (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
        RustCore.instance.saveListCache(cacheKey, fresh);
        if (mounted) {
          setState(() {
            _seasons = fresh;
            _loadingSeasons = false;
          });
        }
        return;
      }
    } catch (_) {
      // Tarmoq yo'q/xato — keshdagi ro'yxat saqlanib qoladi.
    }
    if (mounted && _loadingSeasons) setState(() => _loadingSeasons = false);
  }

  // ── OFLAYN REJIM ─────────────────────────────────────────────

  Future<void> _watchConnectivity() async {
    void apply(List<ConnectivityResult> r) {
      final off = r.every((e) => e == ConnectivityResult.none);
      if (off == _offline) return;
      if (mounted) setState(() => _offline = off);
      // Oflayn'da BARCHA qismlarning holati kerak (qaysi biri to'liq
      // yuklanganini bilish uchun), onlayn'da esa faqat ekrandagilar.
      _syncWatchedUrls();
    }

    try {
      apply(await Connectivity().checkConnectivity());
    } catch (_) {}
    _connSub = Connectivity().onConnectivityChanged.listen(apply);
  }

  /// Shu sifat TO'LIQ yuklab olinganmi.
  bool _isComplete(String url) =>
      url.isNotEmpty && DownloadManager.instance.statOf(url).complete;

  /// Oflayn rejimda ko'rsatiladigan sifatlar: faqat to'liq
  /// yuklanganlari.
  bool _qualityVisible(String url) => !_offline || _isComplete(url);

  // ── Player yordamchilari ───────────────────────────────────────
  String _getUrl(Map<String, dynamic> ep) {
    // Oflayn: faqat TO'LIQ yuklangan sifat o'ynatiladi.
    if (_offline) {
      if (_selectedQuality != null) {
        final u = (ep['url_$_selectedQuality'] as String?) ?? '';
        if (_isComplete(u)) return u;
      }
      for (final k in ['1080p', '720p', '480p', '360p']) {
        final v = (ep['url_$k'] as String?) ?? '';
        if (_isComplete(v)) return v;
      }
      return '';
    }
    if (_selectedQuality != null) {
      final u = (ep['url_$_selectedQuality'] as String?) ?? '';
      if (u.isNotEmpty) return u;
    }
    for (final k in ['url_1080p', 'url_720p', 'url_480p', 'url_360p']) {
      final v = (ep[k] as String?) ?? '';
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  String _qualityLabel(Map<String, dynamic> ep) {
    if (_selectedQuality != null) return _selectedQuality!;
    for (final k in ['1080p', '720p', '480p', '360p']) {
      if (((ep['url_$k'] as String?) ?? '').isNotEmpty) return k;
    }
    return 'HQ';
  }

  List<String> _availableQualities(Map<String, dynamic> ep) {
    final q = <String>[];
    for (final k in ['1080p', '720p', '480p', '360p']) {
      if (((ep['url_$k'] as String?) ?? '').isNotEmpty) q.add(k);
    }
    return q;
  }

  // MUHIM: bir vaqtning o'zida faqat BITTA Player yashaydi va u
  // EKRAN UMRI DAVOMIDA o'chirilmaydi — epizod/sifat almashganda
  // faqat `media` almashtiriladi (_PlayerCtrl izohiga qarang).
  // resumeAt/resumePlaying — sifat almashtirilganda joriy pozitsiya va
  // play/pause holatini saqlab qolish uchun (video boshidan boshlanib
  // qolmasligi kerak). Oddiy epizod tanlashda ikkalasi ham null/true
  // bo'lib, video 0-sekunddan avtomatik boshlanadi.
  Future<void> _playEpisode(
    Map<String, dynamic> ep, {
    Duration? resumeAt,
    bool resumePlaying = true,
    bool isRecovery = false,
  }) async {
    final url = _getUrl(ep);
    if (url.isEmpty) return;

    if (!isRecovery) {
      _recoveryStreakResetTimer?.cancel();
      _recoveryStreak = 0;
    }

    // Har bir ochish o'z "chiptasi" (token) bilan boradi. Foydalanuvchi
    // ochilish tugashini kutmasdan boshqa epizodni bossa, eskisi shu
    // token orqali o'zini bekor qilingan deb biladi va HECH NARSAGA
    // tegmaydi (aynan shu tekshiruvsiz eski ochilish yangisining
    // controllerini o'chirib yuborib, "epizod almashtirganda ekran
    // qora bo'lib qoldi" holatini keltirib chiqarardi).
    final myToken = ++_playToken;
    setState(() {
      _currentEp = ep;
      _currentUrl = url;
      _showControls = true;
      _playerLoading = true;
      _preparing = false;
      _playerError = null;
      _intendedPlaying = resumePlaying;
    });

    // Sek navbatini tozalaymiz — eski epizodga tegishli so'rovlar
    // yangisiga tushib qolmasligi kerak.
    _seekIdleTimer?.cancel();
    _pendingTarget = null;
    _queuedSeek = null;
    _seekBusy = false;
    _healthTimer?.cancel();

    // ── ESKI CONTROLLERNI XAVFSIZ YOPISH ─────────────────────
    // Tartib muhim: avval uni daraxtdan olib tashlaymiz (setState),
    // BIR KADR kutamiz (video vidjeti haqiqatan yo'q bo'lsin), keyin
    // dispose qilamiz. `dispose()` dan keyin controllerga murojaat
    // qilinmaydi — plagin o'zi ham buni e'tiborsiz qoldiradi
    // ("after dispose all further calls are ignored"), ya'ni bu yerda
    // native halokat xavfi YO'Q.
    final old = _controller;
    if (old != null) {
      setState(() => _controller = null);
      await WidgetsBinding.instance.endOfFrame;
      try {
        await old.pause();
      } catch (_) {}
      try {
        await old.dispose();
      } catch (_) {}
    }
    if (!mounted || myToken != _playToken) return;

    // ═══════════════════════════════════════════════════════════
    //  MANBA TANLASH: WORKER'MI YOKI MAHALLIY SERVERMI
    // ═══════════════════════════════════════════════════════════
    //
    // Qoida sodda va qat'iy (ekran boshidagi izohga qarang):
    //
    //   * fayl TELEFONDA TO'LIQ bor -> MAHALLIY server. Internet
    //     bor-yo'qligi ahamiyatsiz: bitta ham tarmoq so'rovi
    //     yuborilmaydi.
    //   * fayl to'liq emas + internet bor -> to'g'ridan-to'g'ri
    //     WORKER (/api/play/...).
    //   * fayl to'liq emas + internet yo'q -> ijro etib bo'lmaydi.
    final complete = _isFullyDownloaded(url);
    Uri? source;
    if (complete) {
      try {
        source = await VideoCacheServer.instance.proxyUri(url);
        _playViaLocal = true;
      } catch (e) {
        // Mahalliy server javob bermadi — quyida worker'ga
        // o'tamiz (internet bo'lsa).
        VideoCacheServer.log('Mahalliy server javob bermadi: $e');
      }
    }
    if (!mounted || myToken != _playToken) return;

    if (source == null) {
      if (_offline) {
        setState(() {
          _playerLoading = false;
          _playerError = complete
              ? 'Videoni ochib bo\'lmadi'
              : 'Bu qism to\'liq yuklab olinmagan — internetga ulaning';
        });
        return;
      }
      source = Uri.parse(_workerPlayUrl(url));
      _playViaLocal = false;
    }
    VideoCacheServer.log(_playViaLocal
        ? 'Manba: MAHALLIY server (fayl to\'liq yuklangan)'
        : 'Manba: WORKER (Cloudflare keshidan oqim)');

    // ── WORKER'DAN IJRO: AVVAL OYNA KESHGA TAYYOR BO'LSIN ─────
    //
    // `/api/play/...` FAQAT Cloudflare keshidan xizmat qiladi va
    // B2'ga UMUMAN chiqmaydi — kesh tekin, B2'ning har bir so'rovi
    // esa pul. B2'ga murojaat butun ijro yo'lida atigi bitta joyda
    // bo'ladi: isitish 480 MiB'lik oynani keshga ko'chirganda.
    // Shu sabab pleyerni ochishdan oldin aynan o'sha isitishni
    // chaqiramiz va HAQIQATAN tugashini kutamiz.
    //
    // Fayl allaqachon to'liq telefonda bo'lsa bu bosqich umuman
    // bo'lmaydi (yuqoridagi mahalliy yo'l).
    var prepared = true;
    if (!_playViaLocal) {
      prepared = await _prepareSource(url, myToken);
      if (!mounted || myToken != _playToken) return;
      // Isitish chiqmadi — MAJBURAN bir marta qayta urinamiz
      // (worker'ning eskirgan kesh yozuvi va o'lib qolgan isitish
      // belgisi e'tiborsiz qoldiriladi).
      if (!prepared) {
        prepared = await _prepareAgain(url, myToken);
        if (!mounted || myToken != _playToken) return;
      }
      if (!prepared) {
        // Pleyerni ochish behuda: 503 keladi. Foydalanuvchiga
        // ANIQ sabab ko'rsatamiz.
        setState(() {
          _playerLoading = false;
          _playerError = 'Video keshga tayyorlanmadi — qayta urinib ko\'ring';
        });
        return;
      }
    }

    var ctrl = await _openController(source, myToken);

    // Mahalliy server kutilmaganda ishlamay qolsa — internet bo'lsa
    // worker orqali qayta urinamiz (video baribir ochilsin).
    if (ctrl == null && _playViaLocal && !_offline) {
      if (!mounted || myToken != _playToken) return;
      VideoCacheServer.log('Zaxira: worker orqali qayta urinilyapti...');
      _playViaLocal = false;
      source = Uri.parse(_workerPlayUrl(url));
      if (await _prepareSource(url, myToken)) {
        if (!mounted || myToken != _playToken) return;
        ctrl = await _openController(source, myToken);
      }
      if (!mounted || myToken != _playToken) return;
    }

    // ── KESH OYNASI ESKIRGAN BO'LISHI MUMKIN ─────────────────
    //
    // Cloudflare katta yozuvlarni (480 MiB'lik oyna) xotira
    // siqilganda o'chirib yuborishi mumkin — o'shanda `/api/play`
    // 503 qaytaradi va video ochilmaydi. Bu holatda oynani
    // MAJBURAN qaytadan isitamiz va bir marta qayta urinamiz.
    // (B2'ga murojaat baribir faqat shu isitishda bo'ladi —
    // qoida buzilmaydi.)
    if (ctrl == null && !_playViaLocal && !_offline) {
      if (!mounted || myToken != _playToken) return;
      VideoCacheServer.log('Kesh oynasi topilmadi — qaytadan isitilmoqda...');
      if (await _prepareAgain(url, myToken)) {
        if (!mounted || myToken != _playToken) return;
        ctrl = await _openController(source, myToken);
      }
    }

    if (!mounted || myToken != _playToken) {
      // Bu ochilish eskirgan — yaratilgan controllerni tashlab
      // yuboramiz, ekrandagisiga TEGMAYMIZ.
      try {
        await ctrl?.dispose();
      } catch (_) {}
      return;
    }

    if (ctrl == null) {
      setState(() {
        _playerLoading = false;
        _playerError = 'Videoni yuklab bo\'lmadi';
      });
      return;
    }

    // ═══════════════════════════════════════════════════════════
    //  NATIVE TAKRORLASH (setLooping) ATAYLAB O'CHIRILGAN
    // ═══════════════════════════════════════════════════════════
    //
    // TUZATILGAN XATO (foydalanuvchi ko'rgan asosiy muammo):
    // "video 15 soniya ishlab, yana boshidan boshlanadi".
    //
    // SABABI: ExoPlayer uchun HTTP javobining erta tugashi (masalan
    // bir lahzalik tarmoq uzilishi sabab mahalliy server ulanishni
    // yopib qo'yishi) "FAYL TUGADI" degani. `setLooping(true)`
    // yoqilganda esa u bu haqda BIZGA UMUMAN XABAR BERMAYDI —
    // videoni jimgina BOSHIDAN qayta boshlaydi. Ya'ni oddiy tarmoq
    // xatosi foydalanuvchiga "video 15 soniyadan keyin qayta
    // boshlandi" bo'lib ko'rinardi.
    //
    // ENDI takrorlashni O'ZIMIZ boshqaramiz (`_onCompleted`):
    //   * video HAQIQATAN oxiriga yetgan bo'lsa — boshidan
    //     boshlanadi (foydalanuvchi uchun xulq o'zgarmadi);
    //   * oxiriga yetmasdan "tugadi" degan xabar kelsa — bu erta
    //     uzilish, ya'ni video AYNAN O'SHA nuqtadan qayta ochiladi.
    try {
      await ctrl.setLooping(false);
    } catch (_) {}
    _lastGoodPosition = resumeAt ?? Duration.zero;
    _handlingCompleted = false;
    _pendingEofAt = null;

    if (resumeAt != null && resumeAt > Duration.zero) {
      try {
        await ctrl.seekTo(resumeAt);
      } catch (_) {}
    }
    if (!mounted || myToken != _playToken) {
      try {
        await ctrl.dispose();
      } catch (_) {}
      return;
    }
    if (resumePlaying) {
      try {
        await ctrl.play();
      } catch (_) {}
    }

    ctrl.addListener(_onControllerUpdate);
    setState(() {
      _controller = ctrl;
      _playerLoading = false;
    });
    // Progress chizig'idagi "yuklab olingan" qism shu videoni kuzata
    // boshlaydi.
    _syncWatchedUrls();
    _startHealthWatchdog();
    _scheduleHide();
  }

  /// ── FAYL TELEFONDA TO'LIQ BORMI ─────────────────────────────
  ///
  /// Pleyer manbani AYNAN shu javobga qarab tanlaydi.
  ///
  /// Ekrandagi hisob (`DownloadManager`) UI oqimini bloklamaslik
  /// uchun diskka chiqmaydi — shu sabab video endigina ochilganda u
  /// hali "0 bayt" deb turishi mumkin. Shu bois bu yerda Rust
  /// yadrosidan ANIQ javob so'raladi: u diskni bir marta
  /// skanerlaydi. Chaqiruv faqat video ochilganda bo'lgani uchun
  /// ro'yxatni surishga hech qanday ta'siri yo'q.
  bool _isFullyDownloaded(String url) {
    if (url.isEmpty) return false;
    if (DownloadManager.instance.statOf(url).complete) return true;
    return RustCore.instance.videoIsComplete(url);
  }

  /// ── OYNANI KESHGA ISITISHNI KUTISH ──────────────────────────
  ///
  /// Worker'ga "480 MiB'lik oynani B2'dan Cloudflare keshiga
  /// ko'chir" degan BITTA so'rov yuboriladi va HAQIQATAN tugashi
  /// kutiladi. Shundan keyin videoning har bir bayti chekkadagi
  /// keshdan keladi — ijro paytida B2'ga UMUMAN chiqilmaydi.
  ///
  /// ── NEGA KUTISH SHART ───────────────────────────────────────
  ///
  /// `/api/play/...` qat'iy qoida bilan ishlaydi: faqat keshdan
  /// xizmat qiladi, kesh bo'sh bo'lsa 503. Bu ataylab shunday —
  /// kesh tekin, B2'ning har bir so'rovi esa pul. Ya'ni pleyerni
  /// kesh tayyor bo'lmasdan ochish behuda.
  ///
  /// ── NIMA TUZATILDI ──────────────────────────────────────────
  ///
  /// Ilgari kutish YOLG'ON edi: worker boshqa birov isitayotganini
  /// ko'rsa darhol `{"status":"warming"}` qaytarardi, Rust yadrosi
  /// esa bunday javobda ham "tayyor" deb belgilardi. Ilova
  /// pleyerni ochar, 503 kelar va ekranda "Videoni yuklab
  /// bo'lmadi" chiqardi — foydalanuvchi ko'rgan asosiy muammo
  /// aynan shu edi.
  ///
  /// Endi:
  ///   * worker "warming" qaytarmaydi — u oyna keshda paydo
  ///     bo'lishini kutadi va yozilganini O'QIB tasdiqlaydi;
  ///   * Rust yadrosi muvaffaqiyatsizlikni ALOHIDA holat sifatida
  ///     qaytaradi (`videoPrepareStatus` == 2);
  ///   * ilova bu holatda isitishni MAJBURAN bir marta qayta
  ///     boshlaydi va faqat shundan keyin ham chiqmasa aniq xabar
  ///     ko'rsatadi.
  ///
  /// Kutish CHEGARALANGAN (`_prepareMax`) — ilova hech qachon
  /// "muzlab" qolmaydi.
  static const Duration _prepareMax = Duration(seconds: 100);

  /// `true` — oyna keshda, pleyerni ochsa bo'ladi.
  Future<bool> _prepareSource(String url, int myToken) async {
    RustCore.instance.videoPrepare(url);
    // Darhol tayyor bo'lsa (oyna allaqachon keshda) — hech qanday
    // yozuv ko'rsatmaymiz.
    if (RustCore.instance.videoPrepareStatus(url) == 1) return true;

    if (mounted && myToken == _playToken) {
      setState(() => _preparing = true);
    }
    final started = DateTime.now();
    try {
      while (mounted && myToken == _playToken) {
        final st = RustCore.instance.videoPrepareStatus(url);
        if (st == 1) return true;
        if (st == 2) {
          VideoCacheServer.log('Isitish muvaffaqiyatsiz tugadi');
          return false;
        }
        if (DateTime.now().difference(started) > _prepareMax) {
          VideoCacheServer.log(
              'Isitish ${_prepareMax.inSeconds} soniyada tugamadi');
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    return false;
  }

  /// Isitishni MAJBURAN qaytadan boshlab, yana kutadi.
  ///
  /// Worker'ning keshdagi eskirgan yozuvi ham, o'lib qolgan
  /// isitishning "belgisi" ham e'tiborsiz qoldiriladi — shusiz
  /// qayta urinish ko'pincha aynan o'sha ishlamaydigan holatni
  /// qaytarardi.
  Future<bool> _prepareAgain(String url, int myToken) async {
    VideoCacheServer.log('Isitish majburan qaytadan boshlanmoqda...');
    RustCore.instance.videoPrepareReset(url);
    return _prepareSource(url, myToken);
  }

  /// Worker'dagi TO'G'RIDAN-TO'G'RI ijro manzili.
  ///
  /// Bazadagi manzil `/api/image/<fayl>` ko'rinishida saqlanadi —
  /// bu bo'laklab keshlaydigan, YUKLAB OLISH uchun mo'ljallangan
  /// yo'l. Pleyer uchun esa `/api/play/<fayl>` ishlatiladi: u
  /// javobni hech qachon kesmaydi (`Range` B2'ga o'zgarishsiz
  /// uzatiladi) va tanani oqim bilan beradi. Aynan shu farq
  /// "video tugadi deb boshidan boshlanishi" muammosini yo'q
  /// qiladi.
  static String _workerPlayUrl(String url) {
    const mark = '/api/image/';
    final i = url.indexOf(mark);
    if (i < 0) return url;
    return '${url.substring(0, i)}/api/play/${url.substring(i + mark.length)}';
  }

  // Bitta manzildan controller ochishga urinadi. Muvaffaqiyatsiz
  // bo'lsa (yoki 25 soniyada javob kelmasa) null qaytaradi.
  Future<VideoPlayerController?> _openController(Uri uri, int myToken) async {
    // ── NEGA platformView (SurfaceView) ──────────────────────
    // Android'da video ikki yo'l bilan ko'rsatilishi mumkin:
    // Flutter teksturasi (standart) yoki alohida SurfaceView
    // (platform view). Google'ning rasmiy tavsiyasi — SurfaceView:
    // u o'z ekran qatlamiga chiziladi, Flutter sahnasiga
    // aralashmaydi, quvvat sarfi kam va SurfaceTexture bilan
    // bog'liq muammolar (Impeller) umuman tegmaydi. YouTube va
    // ExoPlayer asosidagi ilovalar shu yo'ldan boradi.
    final ctrl = VideoPlayerController.networkUrl(
      uri,
      viewType: VideoViewType.platformView,
      videoPlayerOptions: VideoPlayerOptions(
        // Ilova fonga ketganda ExoPlayer ijroni to'xtatadi va
        // qurilma resurslarini bo'shatadi.
        allowBackgroundPlayback: false,
        mixWithOthers: false,
      ),
    );
    try {
      await ctrl.initialize().timeout(const Duration(seconds: 25));
      if (!mounted || myToken != _playToken) {
        try {
          await ctrl.dispose();
        } catch (_) {}
        return null;
      }
      if (!ctrl.value.isInitialized) {
        await ctrl.dispose();
        return null;
      }
      VideoCacheServer.log(
          'Video ochildi: ${ctrl.value.size.width.toInt()}x${ctrl.value.size.height.toInt()}, '
          '${ctrl.value.duration}');
      return ctrl;
    } catch (e) {
      VideoCacheServer.log('Controller ochishda xato: $e');
      try {
        await ctrl.dispose();
      } catch (_) {}
      return null;
    }
  }

  // Controllerdan kelgan har bir yangilanish. Bu yerda faqat
  // XATO holatini kuzatamiz — qolgan yangilanishlarni UI o'zi
  // (ValueListenableBuilder orqali) oladi.
  /// Video "tugadi" xabari kelishidan OLDINGI oxirgi haqiqiy ijro
  /// nuqtasi.
  ///
  /// NEGA KERAK: `video_player` "tugadi" hodisasini olganda
  /// pozitsiyani DARHOL `duration`ga qo'yadi (paketning o'z kodi:
  /// `pause().then((_) => seekTo(value.duration))`). Shu sabab
  /// hodisadan keyin "video haqiqatan oxirigacha ko'rildimi yoki
  /// oqim erta uzildimi" degan savolga `value.position` javob bera
  /// olmaydi — bizga hodisadan OLDINGI qiymat kerak.
  Duration _lastGoodPosition = Duration.zero;
  bool _handlingCompleted = false;

  /// Oqim ERTA uzilgan bo'lsa — qayta ochish kerak bo'lgan nuqta.
  /// `null` = kutayotgan hech narsa yo'q.
  ///
  /// Qayta ochish `_recoverPlayer` ichidagi 6 soniyalik tormoz
  /// sabab darhol boshlanmasligi mumkin. Shunday bo'lsa video
  /// oxirida qotib qolmasligi uchun sog'liq kuzatuvchisi (har
  /// 800 ms) urinishni takrorlaydi.
  Duration? _pendingEofAt;

  void _onControllerUpdate() {
    final c = _controller;
    if (c == null || !mounted) return;
    if (c.value.hasError && !_recovering) {
      VideoCacheServer.log('Pleyer xatosi: ${c.value.errorDescription}');
      _recoverPlayer(c.value.position);
      return;
    }
    final v = c.value;
    if (v.isCompleted) {
      _onCompleted(c);
    } else if (v.isInitialized) {
      _lastGoodPosition = v.position;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  "VIDEO TUGADI" — HAQIQIY OXIRMI YOKI ERTA UZILISHMI?
  // ═══════════════════════════════════════════════════════════════
  //
  // ExoPlayer HTTP javobining tugashini "fayl tugadi" deb biladi.
  // Ya'ni "tugadi" xabari ikki xil holatda keladi:
  //
  //   1) video HAQIQATAN oxirigacha ko'rildi;
  //   2) mahalliy server ulanishni erta yopdi (masalan tarmoq bir
  //      lahzaga uzilib, bo'lak olinmadi) — video esa hali
  //      o'rtasida edi.
  //
  // Ilgari bu ikkalasi FARQLANMASDI: `setLooping(true)` yoqilgani
  // uchun ExoPlayer ikkala holatda ham videoni jimgina BOSHIDAN
  // boshlar edi. Foydalanuvchi ko'rgan "15 soniyadan keyin video
  // qayta boshlanadi" xatosi aynan shu edi.
  //
  // Endi farq ANIQ: oxirgi haqiqiy ijro nuqtasi videoning
  // oxiriga yaqinmi yoki yo'qmi.
  static const Duration _endThreshold = Duration(seconds: 3);

  void _onCompleted(VideoPlayerController c) {
    if (_handlingCompleted || _recovering) return;
    final v = c.value;
    if (!v.isInitialized || v.duration <= Duration.zero) return;
    _handlingCompleted = true;

    final reached = _lastGoodPosition;
    final remaining = v.duration - reached;

    if (remaining <= _endThreshold) {
      // ── HAQIQIY OXIR: takrorlaymiz (avvalgi xulq saqlanadi) ──
      VideoCacheServer.log('Video oxiriga yetdi — boshidan boshlanmoqda');
      _lastGoodPosition = Duration.zero;
      _pendingEofAt = null;
      () async {
        try {
          // `video_player` "tugadi" hodisasida O'ZI ham
          // `pause()` + `seekTo(duration)` qiladi (paket kodi).
          // Bizning `seekTo(0)` undan OLDIN ketib qolmasligi uchun
          // bir lahza kutamiz — aks holda pleyer darhol yana
          // oxiriga sakrab ketardi.
          await Future.delayed(const Duration(milliseconds: 250));
          if (!mounted || _controller != c) return;
          await c.seekTo(Duration.zero);
          if (!mounted || _controller != c) return;
          if (_intendedPlaying) await c.play();
        } catch (_) {
        } finally {
          if (mounted) _handlingCompleted = false;
        }
      }();
      return;
    }

    // ── ERTA UZILISH: video AYNAN SHU nuqtadan qayta ochiladi ──
    // Boshidan boshlanmaydi — foydalanuvchi ko'rgan joyida qoladi.
    VideoCacheServer.log(
        'Oqim erta uzildi (${reached.inSeconds}s / ${v.duration.inSeconds}s) — '
        'shu nuqtadan qayta ochilmoqda');
    _pendingEofAt = reached;
    _recoverPlayer(reached);
  }

  // ── IJRO NUQTASINI YADROGA XABAR QILISH — OLIB TASHLANDI ─────
  //
  // Ilgari pleyer har yarim soniyada Rust yadrosiga "hozir shu
  // joydaman" deb xabar berardi: yadro javob oynasini ("oldinda
  // nechta bo'lak yuklansin") aynan shu nuqtadan hisoblardi.
  //
  // Endi bu xabar KERAK EMAS:
  //   * worker'dan ijro etilganda yadro umuman ishtirok etmaydi —
  //     baytlarni pleyerning o'zi so'raydi;
  //   * mahalliy serverdan ijro etilganda esa fayl ALLAQACHON
  //     to'liq diskda bo'ladi, ya'ni "oldinda nimani yuklash
  //     kerak" degan savolning o'zi yo'q.

  // ── SOG'LIQ KUZATUVCHISI (health watchdog) ────────────────────
  //
  // ExoPlayer o'zi ancha barqaror, shu sabab bu taymer endi faqat
  // ORTIQCHA, oxirgi xavfsizlik chizig'i: agar pleyer ijro qilishi
  // KERAK bo'lsa-yu (isPlaying, buferlanmayapti, sek navbatida emas),
  // lekin pozitsiya bir necha soniya BUTUNLAY qotib qolsa — epizod
  // o'sha nuqtadan qaytadan ochiladi. Odatdagi ishlashda bu hech
  // qachon ishga tushmaydi.
  void _startHealthWatchdog() {
    _healthTimer?.cancel();
    _stuckTicks = 0;
    _lastWatchPosition = null;
    _healthTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (!mounted) return;
      final c = _controller;
      if (c == null) return;
      final VideoPlayerValue v = c.value;
      if (!v.isInitialized || v.duration <= Duration.zero) return;

      // ── ERTA UZILGAN OQIM: QAYTA OCHISHNI TAKRORLASH ─────────
      // `_recoverPlayer` ichidagi 6 soniyalik tormoz sabab birinchi
      // urinish o'tmagan bo'lishi mumkin. Video oxirida qotib
      // qolmasligi uchun shu yerda takrorlanadi.
      final eofAt = _pendingEofAt;
      if (eofAt != null && v.isCompleted && !_recovering) {
        _recoverPlayer(eofAt);
        return;
      }

      // Video oxiriga yaqin joyda takrorlash (loop) ishlaydi va
      // pozitsiya bir lahza "joyida turgandek" ko'rinishi mumkin —
      // bu qotish emas.
      final nearEnd =
          (v.duration - v.position) <= const Duration(milliseconds: 2500);

      // MUHIM: foydalanuvchi hozirgina sek qilgan bo'lsa (yoki sek
      // hali tugamagan bo'lsa), pleyer bir necha soniya "joyida
      // turgandek" ko'rinishi butunlay NORMAL — u yangi joydan
      // ma'lumot yig'ayapti. Buni "qotib qolish" deb hisoblab pleyerni
      // qaytadan ochish — aynan foydalanuvchi tez-tez sek qilganda
      // ilovaning ochilib-yopilib, oxiri o'chib qolishiga olib
      // kelardi. Endi sekdan keyin 5 soniya "tinchlik davri" bor.
      final now = DateTime.now();
      final recentSeek =
          now.difference(_lastSeekRequest) < const Duration(seconds: 5) ||
              now.difference(_lastSeekDone) < const Duration(seconds: 5);

      final shouldBeMoving = v.isPlaying &&
          !v.isBuffering &&
          !_seekBusy &&
          !recentSeek &&
          !_recovering &&
          !nearEnd;
      if (!shouldBeMoving) {
        _stuckTicks = 0;
        _lastWatchPosition = v.position;
        return;
      }
      final last = _lastWatchPosition;
      if (last != null &&
          (v.position - last).abs() < const Duration(milliseconds: 50)) {
        _stuckTicks++;
      } else {
        _stuckTicks = 0;
      }
      _lastWatchPosition = v.position;

      // ~9.6s (12 × 800ms) harakatsiz -> pleyer haqiqatan qotgan,
      // qaytadan ochamiz. Fayl mahalliy diskda tayyor turgani uchun
      // bu tez va internetsiz bo'ladi.
      if (_stuckTicks >= 12) {
        VideoCacheServer.log(
            'Pleyer harakatsiz qotib qoldi (${v.position}) — qaytadan ochilmoqda');
        _stuckTicks = 0;
        _recoverPlayer(v.position);
      }
    });
  }

  // ── PLEYERNI QAYTADAN OCHISH (oxirgi chora) ────────────────────
  //
  // "Foydalanuvchi nima qilsa ham crash bo'lmasin" KAFOLATI shu yerda.
  // Sek yakunlanmasa yoki pleyer qotib qolsa, biz endi kutib
  // o'tirmaymiz: joriy epizodni AYNAN O'SHA POZITSIYADAN qaytadan
  // ochamiz. Foydalanuvchi uchun bu 1-2 soniyalik qayta yuklanish
  // bo'lib ko'rinadi — abadiy qotib qolish emas.
  //
  // Fayl allaqachon mahalliy diskda turgani uchun qayta ochish tez
  // bo'ladi va INTERNETGA UMUMAN chiqilmaydi.
  DateTime _lastRecovery = DateTime.fromMillisecondsSinceEpoch(0);
  bool _recovering = false;

  // ── QAYTA OCHISH SIKLIDAN HIMOYA (circuit breaker) ─────────────
  //
  // Agar biror sabab bilan (masalan hali topilmagan nozik xato) har
  // safar qayta ochilgan pleyer ham tezda "qotib qolgan" deb
  // aniqlansa, 6 soniyalik tormoz o'zi YETARLI EMAS — u faqat
  // qayta-ochishlar tezligini cheklaydi, sonini emas. Natijada ilova
  // SOATLAB (yoki cheksiz) ketma-ket pleyerni ochib-yopib, resurs
  // sarflab, oxir-oqibat qotib/crash bo'lishi mumkin edi. Endi ketma-
  // ket qayta ochishlar soni ANIQ chegaralangan: shu chegaradan
  // o'tilsa, ilova urinishni TO'XTATADI va foydalanuvchiga aniq xato
  // ko'rsatadi — muzlab/tinimsiz qayta yuklanib turishdan yaxshiroq.
  int _recoveryStreak = 0;
  Timer? _recoveryStreakResetTimer;
  static const int _maxRecoveryStreak = 5;

  Future<void> _recoverPlayer(Duration at) async {
    if (_recovering) return;
    final ep = _currentEp;
    if (ep == null || !mounted) return;
    // Cheksiz qayta ochish tsikliga tushib qolmaslik uchun: kamida
    // 6 soniya oraliq.
    final now = DateTime.now();
    if (now.difference(_lastRecovery) < const Duration(seconds: 6)) return;

    _recoveryStreakResetTimer?.cancel();
    _recoveryStreak++;
    if (_recoveryStreak > _maxRecoveryStreak) {
      VideoCacheServer.log(
          'Pleyer ketma-ket $_recoveryStreak marta qayta ochishga urindi — to\'xtatildi');
      // Kuzatuvchi ham to'xtatiladi — aks holda u har 800 ms da
      // qayta-qayta urinishda davom etardi.
      _healthTimer?.cancel();
      if (mounted) {
        setState(() {
          _playerLoading = false;
          _playerError = 'Videoni ijro etib bo\'lmadi (takroriy xato)';
        });
      }
      return;
    }

    _lastRecovery = now;
    _recovering = true;
    _healthTimer?.cancel();
    // MUHIM: `_seekBusy` bu yerda ZO'RLAB tozalanmaydi. Uni tozalash
    // hali tugamagan `_runSeek` bilan yonma-yon IKKINCHI sek yo'lini
    // ochib yuborardi. Har bir `_runSeek` o'z `finally` blokida
    // bayroqni albatta bo'shatadi, shu sabab bu yerda tegish shart
    // emas va xavfli.
    _queuedSeek = null;
    _stuckTicks = 0;
    _lastWatchPosition = null;
    try {
      await _playEpisode(ep, resumeAt: at, resumePlaying: true, isRecovery: true);
      // Muvaffaqiyatli ochilgandan keyin 20 soniya davomida yana qayta
      // ochish kerak bo'lmasa — demak muammo hal bo'lgan, hisoblagich
      // tozalanadi (aks holda uzoq ko'rish seansida vaqti-vaqti bilan
      // yuz beradigan mustaqil, alohida-alohida muammolar yig'ilib,
      // asossiz ravishda chegaraga yetkazib qo'yardi).
      _recoveryStreakResetTimer = Timer(const Duration(seconds: 20), () {
        _recoveryStreak = 0;
      });
    } catch (_) {
    } finally {
      _recovering = false;
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _onTapVideo() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  // Ketma-ket tez-tez bosishda play/pause "qotib qolishi"ning oldini
  // oladi: 280ms ichida takroriy taplarni e'tiborsiz qoldiradi.
  void _togglePlayPause() {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    final now = DateTime.now();
    if (now.difference(_lastPlayPauseTap).inMilliseconds < 280) return;
    _lastPlayPauseTap = now;

    // Kutilayotgan sek bo'lsa — foydalanuvchi "endi ket" demoqda:
    // Kutish vaqtini sarflamasdan darhol bajaramiz.
    if (_pendingTarget != null) {
      _seekIdleTimer?.cancel();
      _seekIdleTimer = null;
      setState(() => _intendedPlaying = true);
      _resumeAfterSeek = true;
      _commitPendingSeek();
      _scheduleHide();
      return;
    }

    if (ctrl.value.isPlaying) {
      setState(() => _intendedPlaying = false);
      ctrl.pause();
    } else {
      setState(() => _intendedPlaying = true);
      ctrl.play();
    }
    _scheduleHide();
  }

  // ══════════════════════════════════════════════════════════════
  //  SEK: "YIG'IB, KEYIN BITTA MARTA" (foydalanuvchi taklifi)
  // ══════════════════════════════════════════════════════════════
  //
  // MUAMMO: har bir sek — dekoder uchun qimmat ish. U kalit kadrni
  // topib, undan boshlab qayta dekod qiladi. Foydalanuvchi tez-tez
  // sek qilsa, bu ishlar ketma-ket kelib, video har safar bir lahza
  // "qotib" ketadi.
  //
  // YECHIM: sek qilinayotgan payt pleyerga UMUMAN tegilmaydi.
  //   1) birinchi sek buyrug'ida video PAUZA qilinadi (dekoder tinch
  //      qoladi, ekrandagi kadr muzlab turadi);
  //   2) keyingi barcha sek buyruqlari faqat MAQSAD NUQTASINI
  //      o'zgartiradi — progress chizig'i va vaqt darhol yangilanadi,
  //      lekin tarmoqqa ham, dekoderga ham hech narsa bormaydi;
  //   3) foydalanuvchi _seekIdle davomida boshqa sek qilmasa —
  //      AYNAN BITTA sek yuboriladi va video o'sha joydan davom
  //      etadi.
  //
  // Tugmadagi ikonka bu davrda o'zgarmaydi (foydalanuvchi niyati
  // saqlanadi), uni o'rab turgan halqa esa aylanib turadi — ya'ni
  // "sek kutilmoqda" degani.
  //
  // KUTISH VAQTI: 0.5 SONIYA (foydalanuvchi talabi; avval 1, undan
  // ham avval 3 soniya edi). Ketma-ket bosilgan taplar odatda
  // 200-400 ms oralig'ida keladi, ya'ni 500 ms ularni yig'ib
  // olishga baribir yetadi — lekin bitta marta sek qilib qo'yib
  // yuborilganda video deyarli darhol ishlab ketadi.
  //
  // MUHIM: shu 500 ms ichida pleyerga (demak worker'ga ham) BITTA
  // ham so'rov yuborilmaydi — video pauzada, `seekTo` esa faqat
  // tinchlik davri tugagach, AYNAN BIR MARTA yuboriladi.
  static const Duration _seekIdle = Duration(milliseconds: 500);

  // ── Ichki holat ──────────────────────────────────────────────
  // Bir vaqtda faqat BITTA `seekTo` uchib turadi; undan keyingilari
  // "keyingi nuqta" sifatida saqlanadi (_runSeek izohiga qarang).
  bool _seekBusy = false;
  Duration? _queuedSeek;
  Timer? _healthTimer;
  DateTime _lastSeekRequest = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSeekDone = DateTime.fromMillisecondsSinceEpoch(0);
  // Sog'liq kuzatuvchisi uchun: pozitsiya o'zgarmay turgan takrorlar.
  int _stuckTicks = 0;
  Duration? _lastWatchPosition;

  // Sek nuqtasini xavfsiz oraliqqa qisadi: [0 .. duration-1s] — video
  // ENG OXIRIGA sek qilinishining oldini oladi (EOF holatiga tushish
  // demukserni keraksiz "tugadi" yo'liga olib boradi).
  static Duration _clampSeekTarget(Duration t, Duration dur) {
    if (t < Duration.zero) return Duration.zero;
    if (dur <= Duration.zero) return t;
    final limit = dur - const Duration(seconds: 1);
    if (limit <= Duration.zero) return Duration.zero;
    return t > limit ? limit : t;
  }

  // Kutilayotgan sek nuqtasi. Null bo'lmasa — UI shu qiymatni
  // ko'rsatadi (pleyerning haqiqiy pozitsiyasini emas).
  Duration? _pendingTarget;
  Timer? _seekIdleTimer;
  // Sek boshlanganda ijro ketayotganmidi — tugagach shunga qaytamiz.
  bool _resumeAfterSeek = false;

  /// Sek uchun boshlang'ich nuqta: kutilayotgan maqsad bo'lsa —
  /// o'sha, aks holda pleyerning joriy pozitsiyasi.
  Duration get _seekBase {
    final p = _pendingTarget;
    if (p != null) return p;
    final c = _controller;
    return c?.value.position ?? Duration.zero;
  }

  /// Nisbiy sek (ekranga ikki marta bosish).
  void _scheduleSeek(int deltaSeconds) {
    _requestSeek(_seekBase + Duration(seconds: deltaSeconds));
  }

  /// Mutlaq sek (progress chizig'i).
  void _scheduleSeekTo(Duration target) => _requestSeek(target);

  void _requestSeek(Duration target) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    // Birinchi sek: ijroni to'xtatamiz va keyin qaytishni eslab
    // qolamiz.
    if (_pendingTarget == null) {
      // MUHIM: bu yerda `ctrl.value.isPlaying` EMAS, foydalanuvchining
      // NIYATI olinadi. Sek qilingan payt pleyer buferlash sabab
      // vaqtincha "to'xtagan" bo'lishi mumkin — o'shanda isPlaying
      // false bo'lib, sekdan keyin video PAUZADA qolib ketardi.
      _resumeAfterSeek = _intendedPlaying;
      if (ctrl.value.isPlaying) {
        ctrl.pause();
      }
    }

    var t = target;
    if (t < Duration.zero) t = Duration.zero;
    t = _clampSeekTarget(t, ctrl.value.duration);

    setState(() => _pendingTarget = t);
    _scheduleHide();

    // Har bir yangi sek kutish taymerini QAYTADAN boshlaydi.
    _seekIdleTimer?.cancel();
    _seekIdleTimer = Timer(_seekIdle, _commitPendingSeek);
  }

  /// Qisqa tinchlikdan keyin: BITTA sek va ijroni davom ettirish.
  Future<void> _commitPendingSeek() async {
    _seekIdleTimer = null;
    final target = _pendingTarget;
    final c = _controller;
    if (target == null || c == null || !mounted) {
      if (mounted) setState(() => _pendingTarget = null);
      return;
    }
    await _runSeek(c, target);
    if (!mounted || _controller != c) return;

    // ── YANGI SEKNI YO'QOTMASLIK ─────────────────────────────
    // `_runSeek` eng ko'pi 1 soniya davom etadi va o'sha payt
    // foydalanuvchi YANA sek qilgan bo'lishi mumkin. Avval bu holatda
    // biz `_pendingTarget`ni SO'ZSIZ tozalab yuborardik — natijada
    // foydalanuvchining eng oxirgi sek'i YO'QOLARDI: video eski
    // nuqtadan davom etar, ekranda esa hech narsa bo'lmagandek
    // tuyulardi ("qotib qoldi" hissi). Endi maqsad o'zgargan bo'lsa,
    // uni tegmasdan qoldiramiz — o'zining 1 soniyalik taymeri bilan
    // bajariladi.
    if (_pendingTarget != target) return;

    setState(() => _pendingTarget = null);
    if (_resumeAfterSeek) {
      _resumeAfterSeek = false;
      try {
        await c.play();
      } catch (_) {}
    }
  }

  // ── SEK: "eng oxirgisi yutadi" ─────────────────────────────
  //
  // Professional pleyerlar (ExoPlayer/Media3 "scrubbing mode",
  // YouTube) progress chizig'i surilayotganda shunday ishlaydi:
  //   * oraliq sek so'rovlari NAVBATGA TO'PLANMAYDI — eskisi
  //     bekor qilinib, faqat eng oxirgi nuqta bajariladi;
  //   * sek kalit kadrga (key frame) qilinadi, shu sabab tez.
  //
  // ExoPlayer buni ichkarida o'zi ham qiladi, lekin biz ustiga bitta
  // yupqa qatlam qo'yamiz: bir vaqtda faqat BITTA `seekTo` uchib
  // turadi, undan keyingilari esa "keyingi nuqta" sifatida saqlanadi.
  // Shu bilan tez-tez surilganda platformaga yuboriladigan chaqiruv
  // soni minimumga tushadi.
  Future<void> _runSeek(VideoPlayerController c, Duration t) async {
    _lastSeekRequest = DateTime.now();
    if (_seekBusy) {
      _queuedSeek = t;
      return;
    }
    _seekBusy = true;
    try {
      var target = t;
      var rounds = 0;
      while (rounds < 32) {
        rounds++;
        if (!mounted || _controller != c) return;
        try {
          // ── NEGA ANIQ 1 SONIYA ────────────────────────────────
          // `seekTo` Future'i pleyer YANGI joydan kadr tayyorlaganda
          // hal bo'ladi. Agar o'sha joydagi bo'lak hali worker'dan
          // yuklanmagan bo'lsa, bu kutish uzoq cho'zilishi mumkin —
          // va o'sha davrda foydalanuvchining KEYINGI sek'lari
          // navbatda turib qolardi (avval 10 soniyagacha!).
          //
          // Endi biz javobni eng ko'pi 1 soniya kutamiz. Kutish
          // tugagach navbatdagi (eng oxirgi) nuqta DARHOL yuboriladi
          // — ya'ni foydalanuvchi qanchalik tez sek qilsa ham,
          // buyruq 1 soniya ichida pleyerga yetib boradi. Pleyer esa
          // fayl tayyor bo'lgunicha o'zi kutadi (bufer aylanasi
          // ko'rinib turadi) — ya'ni "faqat yuklab olinishini kutish"
          // qoladi, bizning navbatimiz emas.
          await c.seekTo(target).timeout(const Duration(seconds: 1));
        } catch (e) {
          VideoCacheServer.log('seekTo kechikdi/xato: $e');
        }
        final next = _queuedSeek;
        _queuedSeek = null;
        if (next == null) break;
        target = next;
      }
    } finally {
      _seekBusy = false;
      _lastSeekDone = DateTime.now();
      final pending = _queuedSeek;
      _queuedSeek = null;
      if (pending != null && mounted && _controller == c) {
        scheduleMicrotask(() => _runSeek(c, pending));
      }
    }
  }

  // Ekranning chap/o'ng yarmiga ikki marta bosilganda 5 sonyaga
  // orqaga/oldinga suradi. Tez-tez bosilsa jamlanadi (+5, +10, +15...)
  // va qo'l tortilgach 2 soniyadan keyin ko'rsatkich avtomatik yo'qoladi.
  void _handleDoubleTapSeek(bool isLeft) {
    if (_currentEp == null) return;
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    // ── KO'RSATKICH HAQIQATNI KO'RSATADI ─────────────────────
    // Avval har bir bosishda ko'rsatkich shunchaki +5 ga oshaverardi:
    // 55 soniyalik videoda "+65s" deb turardi, holbuki video oxiridan
    // nariga sek qilib bo'lmaydi. Endi jamlangan qiymat videoning
    // HAQIQIY chegaralari bilan cheklanadi — ya'ni ekranda ko'ringan
    // son bilan haqiqiy sakrash bir xil bo'ladi.
    final v = ctrl.value;
    final base = _seekBase;
    final dur = v.duration;
    final maxForward = dur > Duration.zero
        ? (_clampSeekTarget(dur, dur) - base).inSeconds
        : 0;
    final maxBack = base.inSeconds;

    setState(() {
      if (isLeft) {
        _leftSeekAccum = (_leftSeekAccum + 5).clamp(0, maxBack < 0 ? 0 : maxBack);
        _showLeftSeek = true;
      } else {
        _rightSeekAccum =
            (_rightSeekAccum + 5).clamp(0, maxForward < 0 ? 0 : maxForward);
        _showRightSeek = true;
      }
    });

    HapticFeedback.lightImpact();
    _scheduleSeek(isLeft ? -5 : 5);
    _scheduleHide();

    if (isLeft) {
      _leftSeekHideTimer?.cancel();
      // Sek qisqa tinchlikdan keyin bajarilgani uchun ko'rsatkich
      // ham shu vaqtgacha turadi (avval 2 soniyada yo'qolib, hali
      // sek bo'lmagan holda foydalanuvchini chalg'itardi).
      _leftSeekHideTimer = Timer(_seekIdle + const Duration(milliseconds: 400), () {
        if (mounted) {
          setState(() {
            _showLeftSeek = false;
            _leftSeekAccum = 0;
          });
        }
      });
    } else {
      _rightSeekHideTimer?.cancel();
      _rightSeekHideTimer = Timer(_seekIdle + const Duration(milliseconds: 400), () {
        if (mounted) {
          setState(() {
            _showRightSeek = false;
            _rightSeekAccum = 0;
          });
        }
      });
    }
  }

  // Video ustidagi tapni tahlil qiladi: play/pause atrofidagi o'lik zonada
  // — faqat kontrollarni ko'rsatish/yashirish; chap/o'ng tomonda 300ms
  // ichida (joyidan qat'iy nazar) ketma-ket tap qilinsa — sek boshlanadi
  // va har keyingi shu tarafdagi tap (yana 300ms ichida bo'lsa) jamlanib
  // boradi. 300ms ichida ikkinchi tap kelmasa, birinchi tap oddiy tap
  // sifatida hisoblanib kontrollarni ko'rsatadi/yashiradi.
  // O'lik zona endi butun balandlik bo'ylab cho'zilgan VERTIKAL YO'LAK
  // emas, balki aynan play/pause tugmasi turgan joydagi DOIRA — shu
  // bilan ekranning chap/o'ng tarafidagi deyarli HAR QANDAY nuqta
  // (jumladan yuqori va pastki markaz) sek uchun ishlaydi, faqat
  // tugmaning o'zi bosilganda sek ishga tushmaydi.
  void _handleVideoTap(
      double dx, double dy, double center, double centerY, double deadRadius) {
    final ddx = dx - center;
    final ddy = dy - centerY;
    if (ddx * ddx + ddy * ddy <= deadRadius * deadRadius) {
      _pendingSingleTapTimer?.cancel();
      _lastTapTime = null;
      // MUHIM: kontrollar KO'RINIB turgan bo'lsa, bu tapni allaqachon
      // play/pause tugmasining o'zi qabul qilgan (gesture qatlami
      // shaffof — tapni yutmaydi). Bu yerda yana _onTapVideo() chaqirsak,
      // play bosilishi bilanoq kontrollar yopilib qolardi. Shu sabab
      // kontrollarni faqat ular YASHIRIN bo'lganda ko'rsatamiz.
      if (!_showControls) _onTapVideo();
      return;
    }

    final isLeft = dx < center;
    final now = DateTime.now();
    if (_lastTapTime != null &&
        _lastTapWasLeft == isLeft &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
      _pendingSingleTapTimer?.cancel();
      _lastTapTime = now;
      _handleDoubleTapSeek(isLeft);
    } else {
      _lastTapTime = now;
      _lastTapWasLeft = isLeft;
      _pendingSingleTapTimer?.cancel();
      _pendingSingleTapTimer = Timer(const Duration(milliseconds: 300), () {
        _lastTapTime = null;
        _onTapVideo();
      });
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ── Fullscreen: alohida sahifaga o'tmaydi — xuddi shu controller
  // joyida (soat mili bo'ylab) landscape rejimga aylanadi ─────────
  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      _restoreSystemUI();
    }
    _scheduleHide();
  }

  void _restoreSystemUI() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _showQualityDialog() {
    final ep = _currentEp;
    if (ep == null) return;
    final have = _availableQualities(ep);
    final ordered =
        ['1080p', '720p', '480p', '360p'].where(have.contains).toList();

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF15151F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sifatni tanlang',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              ...ordered.map((q) {
                final sel = _selectedQuality == q ||
                    (_selectedQuality == null && q == _qualityLabel(ep));
                final size = (ep['size_$q'] as String?) ?? '';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      final ctrl = _controller;
                      final resumeAt = ctrl?.value.position;
                      final resumePlaying = ctrl?.value.isPlaying ?? true;
                      setState(() => _selectedQuality = q);
                      _playEpisode(
                        ep,
                        resumeAt: resumeAt,
                        resumePlaying: resumePlaying,
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: sel
                            ? AppColors.accent
                            : Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(q.toUpperCase(),
                                    style: TextStyle(
                                        color:
                                            sel ? Colors.black : Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15)),
                                if (size.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(size,
                                      style: TextStyle(
                                          color: sel
                                              ? Colors.black87
                                              : Colors.white54,
                                          fontSize: 12)),
                                ],
                              ],
                            ),
                          ),
                          if (sel)
                            const Icon(Icons.check_rounded,
                                color: Colors.black),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> get _playableEps => _episodes
      .where((ep) => ['url_1080p', 'url_720p', 'url_480p', 'url_360p']
          .any((k) => (ep[k] ?? '').toString().isNotEmpty))
      .toList();

  // ── UI ──────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (_isFullscreen) {
          _toggleFullscreen();
          return false;
        }
        return true;
      },
      child: _isFullscreen ? _buildFullscreenPlayer() : _buildNormalScreen(),
    );
  }

  Widget _buildNormalScreen() {
    final name = widget.season['nomi'] ?? '';
    final tavsif = widget.season['tavsif'] ?? '';
    // Video ostidagi "N-qism / N-bo'lim / yil / janr" yorliqlari OLIB
    // TASHLANDI (foydalanuvchi talabi): qism raqami endi pastdagi
    // boshqaruvda ("N-qism" tugmalari orasida) ko'rinadi, yil va janr
    // esa "Ma'lumot" tabida bor. Shu bilan tablar to'g'ridan-to'g'ri
    // videoning tagiga tushdi.

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    GlassTappable(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Glass(
                        borderRadius: 14,
                        blur: 14,
                        padding: EdgeInsets.all(8),
                        child:
                            Icon(Icons.arrow_back_rounded, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _buildInlinePlayer(),
                ),
              ),
              const SizedBox(height: 8),
              // Tartib (foydalanuvchi talabi):
              //   video -> tablar -> [<] N-qism [>] -> qismlar ro'yxati
              //
              // ── BO'YI KICHRAYTIRILDI (foydalanuvchi talabi) ────
              // Avval `Tab` o'zining standart bo'yida (46 dp) edi va
              // atrofida 4 dp to'ldirish bilan butun panel 54 dp joy
              // egallardi. Yozuvlar bir qatorli bo'lgani uchun bu
              // ortiqcha edi — endi `Tab(height: 32)` va 3 dp
              // to'ldirish, ya'ni 38 dp. Qismlar ro'yxatiga 16 dp
              // qo'shimcha joy chiqdi.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Glass(
                  borderRadius: 14,
                  blur: 12,
                  padding: const EdgeInsets.all(3),
                  child: TabBar(
                    controller: _tabCtrl,
                    indicator: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(11)),
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white54,
                    labelPadding: EdgeInsets.zero,
                    labelStyle: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    unselectedLabelStyle: const TextStyle(fontSize: 13),
                    dividerColor: Colors.transparent,
                    tabs: const [
                      Tab(height: 32, text: 'Qismlar'),
                      Tab(height: 32, text: 'Bo\'limlar'),
                      Tab(height: 32, text: 'Ma\'lumot'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // [<]  N-qism  [>] — tablarning TAGIDA, ro'yxat ustida.
              _buildEpisodeNav(),
              const SizedBox(height: 6),
              Expanded(
                // ── NEGA TabBarView EMAS ──────────────────────────
                // TabBarView sahifalarni PageView kabi yonma-yon
                // joylashtiradi va bir tabdan boshqasiga o'tganda
                // ORADAGI tabni ham qurishga majbur bo'ladi — hammasi
                // ~300 ms lik animatsiya ichida. "Qismlar"dan
                // "Ma'lumot"ga o'tishda esa ikkita tab birdan
                // quriladi (biri rasm yuklaydigan ro'yxat) va ilova
                // bir zumga QOTIB qolardi.
                //
                // IndexedStack esa faqat TANLANGAN tabni ko'rsatadi,
                // qolganlari o'z holatini saqlab turadi. Pastdagi
                // `_lazyTab` yordamida tab BIRINCHI MARTA ochilgandagina
                // quriladi — ya'ni hech qachon ortiqcha ish
                // bajarilmaydi.
                //
                // ── SURISH PAYTIDA SO'ROVLAR TO'XTAYDI ────────────
                // Yuklab olish holati Rust yadrosidan SINXRON FFI
                // bilan o'qiladi va bu ish UI oqimida bajariladi.
                // U kadr tayyorlanayotgan paytga to'g'ri kelsa,
                // ro'yxat barmoq ostida "tutilib" ko'rinadi. Shu
                // sabab barmoq ekranda turganda so'rov umuman
                // qilinmaydi; barmoq ko'tarilishi bilan holat darhol
                // yangilanadi.
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n is ScrollStartNotification) {
                      _holdDownloadUpdates();
                    } else if (n is ScrollEndNotification) {
                      _releaseDownloadUpdates();
                    }
                    // `false` — xabar yuqoriga o'tishda davom etadi.
                    return false;
                  },
                  // ── TABLAR ORASIDA SURIB O'TISH (foydalanuvchi talabi) ──
                  //
                  // Pastki qismni chapdan o'ngga (yoki teskarisiga)
                  // surib "Qismlar" <-> "Bo'limlar" <-> "Ma'lumot"
                  // orasida o'tish mumkin.
                  //
                  // NEGA `TabBarView` EMAS: yuqoridagi izohda
                  // tushuntirilganidek, u o'tish paytida ORADAGI
                  // tabni ham qurishga majbur bo'lardi va ilova bir
                  // zumga qotib qolardi. Bu yerda esa faqat surish
                  // HARAKATI ushlanadi, ko'rsatish esa avvalgidek
                  // `IndexedStack` orqali (bitta tab — bitta qurish).
                  //
                  // `translucent` — tapni yutmaydi: ro'yxatdagi
                  // tugmalar va vertikal surish avvalgidek ishlaydi
                  // (vertikal surish gorizontal gesture bilan
                  // to'qnashmaydi, Flutter arena ularni ajratadi).
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: _onTabSwipe,
                    child: AnimatedBuilder(
                      animation: _tabCtrl,
                      builder: (context, _) => IndexedStack(
                        index: _tabCtrl.index,
                        sizing: StackFit.expand,
                        children: [
                          _lazyTab(0, _buildEpisodeTab),
                          _lazyTab(1, _buildSeasonsTab),
                          _lazyTab(2, () => _buildInfoTab(tavsif.toString())),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pastki qismni chapga/o'ngga surganda tabni almashtiradi.
  ///
  /// Chapga surish (`primaryVelocity < 0`) — KEYINGI tab,
  /// o'ngga surish — OLDINGISI. Tasodifiy mayda siljishlar tabni
  /// almashtirib yubormasligi uchun tezlik chegarasi qo'yilgan.
  void _onTabSwipe(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v.abs() < 200) return;
    final next = _tabCtrl.index + (v < 0 ? 1 : -1);
    if (next < 0 || next >= _tabCtrl.length) return;
    _tabCtrl.animateTo(next);
  }

  /// Tab BIRINCHI MARTA ochilgandagina quriladi; keyin esa o'z
  /// holati bilan yashab turadi (qayta ochilganda darhol chiqadi).
  final Set<int> _builtTabs = {0};

  Widget _lazyTab(int index, Widget Function() build) {
    if (_tabCtrl.index == index) _builtTabs.add(index);
    if (!_builtTabs.contains(index)) return const SizedBox.shrink();
    return build();
  }

  Widget _buildFullscreenPlayer() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: _buildPlayerCore(isFullscreen: true),
      ),
    );
  }

  // ── Player core: video + gesture layer + controls. Bir xil widget
  // ham inline, ham fullscreen holatida ishlatiladi — controller hech
  // qachon qayta yaratilmaydi. ─────────────────────────────────────
  Widget _buildInlinePlayer() {
    final width = MediaQuery.of(context).size.width - 32;
    final height = width * 9 / 16;
    return SizedBox(
      width: double.infinity,
      height: height,
      child: _buildPlayerCore(isFullscreen: false),
    );
  }

  Widget _buildPlayerCore({required bool isFullscreen}) {
    final ctrl = _controller;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: ctrl != null && ctrl.value.isInitialized
                ? Center(
                    child: AspectRatio(
                      aspectRatio: ctrl.value.aspectRatio,
                      child: VideoPlayer(ctrl),
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          if (_currentEp == null)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_circle_outline_rounded,
                      color: Colors.white24, size: 52),
                  SizedBox(height: 8),
                  Text('Qismni tanlang',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            ),

          // ── Butun video maydoni ustida BITTA gesture detektor: bitta tap —
          // kontrollarni ko'rsatish/yashirish, ketma-ket ikki (yoki undan
          // ortiq) tap xuddi shu tarafda — sekundga sek qiladi. Taplar
          // ekranning chap/o'ng yarmida QAYERGA bosilishidan qat'iy nazar
          // ishlaydi. GestureDetector'ning o'rnatilgan double-tap tanish
          // tizimi ATAYLAB ishlatilmaydi — u taplar orasidagi masofani ham
          // cheklaydi va shu sabab har xil nuqtalarga bosilganda sek
          // ishonchsiz ishlar edi; buning o'rniga taplar orasidagi VAQT
          // (300ms) qo'lda tekshiriladi. O'lik zona — aynan play/pause
          // tugmasi turgan joydagi DOIRA (tugma radiusi + 10px), butun
          // balandlik bo'ylab cho'zilgan yo'lak EMAS — shu sabab
          // ekranning chap/o'ng tarafidagi deyarli har qanday nuqta
          // (yuqori/pastki markaz ham) sek uchun ishlaydi.
          // (Sek gesture qatlami Stack'ning ENG USTIGA ko'chirildi — pastga
          // qarang. Sabab: kontrollar ko'ringanda pastki panel (slayder
          // qatori) tapni tutib qolib, ekranning pastki qismida sek
          // umuman ishlamas edi.)

          // ── Xato holati: gesture qatlamidan KEYIN joylashtirilgan —
          // aks holda "Qayta urinish" tugmasi tepasidagi translucent
          // gesture qatlami tapni tutib qolib, tugma bosilmay qolar edi.
          if (_currentEp != null && _playerError != null)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded,
                      color: Colors.white38, size: 40),
                  const SizedBox(height: 10),
                  Text(_playerError!,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 14),
                  GestureDetector(
                    onTap: () {
                      final ep = _currentEp;
                      if (ep != null) _playEpisode(ep);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text('Qayta urinish',
                          style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.w700,
                              fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),

          if (_currentEp != null)
            AnimatedOpacity(
              // Yuklanish/tayyorlanish paytida kontrollar MAJBURIY
              // ko'rinadi — aks holda yagona aylanma halqa ham
              // ko'rinmay qolardi.
              opacity: (_showControls || _playerLoading) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: RepaintBoundary(
                    child: _buildControls(isFullscreen: isFullscreen)),
              ),
            ),

          // ── KUTISH HALQASI: KONTROLLARDAN MUSTAQIL ────────────
          //
          // TALAB: "play/pause atrofida aylanadigan progress chizig'i
          // KUTISH VAQTIDA HAR DOIM ko'rinishi kerak — qolgan pleyer
          // tugmalari esa chiqmasin".
          //
          // Muammo shunda ediki, halqa `_buildControls` ichida
          // joylashgan va butun kontrollar paneli bilan birga
          // yashirinardi: 3 soniyadan keyin kontrollar ketishi bilan
          // buferlash/sek aylanasi ham ko'rinmay qolardi va ekran
          // "qotib qolgandek" tuyulardi.
          //
          // Endi kutish holati uchun ALOHIDA qatlam bor: u faqat
          // HALQANI chizadi (ikonkasiz, tugmalarsiz) va faqat
          // kontrollar yashiringan paytda ishlaydi — kontrollar
          // ko'ringanda halqani `_centerButton` o'zi chizadi, ya'ni
          // ikkitasi hech qachon ustma-ust tushmaydi.
          if (_currentEp != null && _playerError == null)
            IgnorePointer(child: Center(child: _busyRingOverlay(isFullscreen))),

          // ── FAQAT BITTA AYLANMA CHIZIQ ────────────────────────
          //
          // Kutish holatining HAMMASI (video ochilishi, sek,
          // progress chizig'ini surish, qayta buferlash) markazdagi
          // play/pause tugmasini o'rab turgan BITTA halqa orqali
          // ko'rsatiladi — `_centerButton` ichidagi aylanma
          // `CircularProgressIndicator`.
          //
          // Bu yerda faqat YOZUV qoladi va u aynan halqaning
          // TAGIDA turadi (halqa diametri 76, ya'ni 60 px pastga
          // surish uni halqa ostiga tushiradi).
          if (_currentEp != null && _preparing)
            Center(
              child: Transform.translate(
                offset: const Offset(0, 60),
                child: const Text(
                  'Video tayyorlanyabdi...',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),


          // ── Sek ko'rsatkichlari — asosiy kontrollardan mustaqil,
          // faqat bosilgan tarafda chiqadi va 2s dan keyin yo'qoladi.
          //
          // O'LCHAMI: markazdagi play/pause tugmasini o'rab turgan
          // AYLANMA HALQA bilan AYNAN TENG (`_playPauseDiameter`).
          // Avval u 1.3 barobar kattaroq edi va portret (fullscreen
          // emas) rejimda ekranning katta qismini to'sib qo'yardi.
          // MUHIM: play/pause tugmasi (markaz) bilan video cheti
          // o'rtasidagi nuqtaga joylashtirilgan — chetga emas.
          if (_showLeftSeek)
            Align(
              alignment: const Alignment(-0.5, 0),
              child: IgnorePointer(
                child: _SeekBadge(
                  seconds: _leftSeekAccum,
                  isLeft: true,
                  diameter: _playPauseDiameter(isFullscreen),
                ),
              ),
            ),
          if (_showRightSeek)
            Align(
              alignment: const Alignment(0.5, 0),
              child: IgnorePointer(
                child: _SeekBadge(
                  seconds: _rightSeekAccum,
                  isLeft: false,
                  diameter: _playPauseDiameter(isFullscreen),
                ),
              ),
            ),

          // ── SEK GESTURE QATLAMI — Stack'ning ENG USTIDA ─────────────
          // MUHIM: bu qatlam `Listener` (GestureDetector emas) va
          // HitTestBehavior.translucent bilan ishlaydi. Bu ikkovi birga
          // shuni anglatadi: qatlam BARCHA taplarni ko'radi, LEKIN ularni
          // yutib qolmaydi — ostidagi tugmalar (play/pause, slayder,
          // sifat, fullscreen) o'z vazifasini avvalgidek bajaraveradi.
          //
          // Avval bu qatlam kontrollardan PASTDA turardi, shu sabab
          // kontrollar ko'ringanda pastki panel (slayder qatori) tapni
          // tutib qolib, ekranning pastki qismida sek umuman ishlamas edi.
          // Endi chap/o'ng tarafning YUQORISI, PASTI, CHETI va O'RTASI —
          // hamma joyi sek uchun ishlaydi; faqat haqiqiy tugmalar turgan
          // tor zonalar (markazdagi play/pause doirasi va pastki
          // boshqaruv paneli) bundan mustasno.
          if (_currentEp != null)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final center = constraints.maxWidth / 2;
                  final centerY = constraints.maxHeight / 2;
                  final deadRadius = _playPauseDiameter(isFullscreen) / 2 + 10;
                  // Kontrollar ko'ringandagina haqiqiy tugmalar bor —
                  // shu paytdagina ular turgan tor zonalar chetlab
                  // o'tiladi. Kontrollar yashiringanda esa ekranning
                  // MUTLAQO hamma joyi (markazdan tashqari) sek qiladi.
                  // Pastki boshqaruv paneli oddiy rejimda kattaroq
                  // (tugmalar qulay bo'lishi uchun) — shu sabab uning
                  // ustidagi "sek qilinmaydigan" zona ham balandroq.
                  final bottomGuard =
                      _showControls ? (isFullscreen ? 78.0 : 86.0) : 0.0;
                  final topGuard = (_showControls && isFullscreen) ? 60.0 : 0.0;
                  return Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) {
                      _tapDownPos = e.localPosition;
                      _tapDownTime = DateTime.now();
                    },
                    onPointerUp: (e) {
                      final downPos = _tapDownPos;
                      final downTime = _tapDownTime;
                      _tapDownPos = null;
                      _tapDownTime = null;
                      if (downPos == null || downTime == null) return;
                      // Surish (masalan slayderni tortish) tap deb
                      // hisoblanmaydi.
                      if ((e.localPosition - downPos).distance > 14) return;
                      if (DateTime.now().difference(downTime) >
                          const Duration(milliseconds: 350)) {
                        return;
                      }
                      final dy = e.localPosition.dy;
                      if (dy > constraints.maxHeight - bottomGuard) return;
                      if (dy < topGuard) return;
                      _handleVideoTap(
                        e.localPosition.dx,
                        dy,
                        center,
                        centerY,
                        deadRadius,
                      );
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControls({required bool isFullscreen}) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.60),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withOpacity(0.85),
          ],
          stops: const [0.0, 0.3, 0.68, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Yuqori qator: orqaga (faqat fullscreen) + sarlavha ──
            if (isFullscreen)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _toggleFullscreen,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.arrow_back_rounded,
                            color: Colors.white, size: 24),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        (_currentEp?['epizod_name'] ??
                                widget.season['nomi'] ??
                                '')
                            .toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),

            const Spacer(),

            // ── O'rta qator: faqat play/pause markazda ──────────────
            // Sek tugmalari olib tashlandi — ularning o'rniga video
            // ustida ikki marta bosish orqali ishlaydigan gesture bor.
            Center(child: _playPauseReactive(size: isFullscreen ? 46 : 40)),

            const Spacer(),

            _bottomBarReactive(isFullscreen: isFullscreen),
          ],
        ),
      ),
    );
  }

  // ── MARKAZIY TUGMA: play/pause + uni O'RAB TURGAN HALQA ─────
  //
  // Halqa ikki vazifani bajaradi:
  //   * odatdagi holatda — ijro qay darajada o'tganini ko'rsatadi
  //     (to'liq aylana = video oxiri);
  //   * pleyer band bo'lganda (buferlash, sek, progress chizig'i
  //     surilayotgan payt) — AYLANADI, ya'ni "kutilmoqda" degani.
  //
  // Muhim tafsilot: band bo'lganda tugmadagi ikonka O'ZGARMAYDI.
  // ExoPlayer sek paytida ichkarida bir lahza to'xtaydi va
  // `isPlaying` false bo'lib qoladi; agar ikonka shunga qarab
  // chizilsa, har bir sekda tugma "play" ga sakrab, ko'zni
  // qamashtirardi. Endi u foydalanuvchining NIYATINI ko'rsatadi.
  /// Kontrollar YASHIRINGAN paytdagi kutish halqasi.
  ///
  /// Kutish deb hisoblanadigan holatlar (foydalanuvchi uchun bularning
  /// hammasi bir xil: "video hozir tayyorlanmoqda"):
  ///   * video endi ochilmoqda (`_playerLoading`, `_preparing`);
  ///   * pleyer buferlamoqda (`isBuffering`);
  ///   * sek kutilmoqda yoki bajarilmoqda;
  ///   * progress chizig'i barmoq bilan surilmoqda.
  Widget _busyRingOverlay(bool isFullscreen) {
    // Kontrollar ko'rinib turibdi — halqani `_centerButton` chizadi.
    if (_showControls || _playerLoading) return const SizedBox.shrink();

    final ctrl = _controller;
    if (ctrl == null) return _spinnerOnly(isFullscreen);

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) {
        final busy = !value.isInitialized ||
            value.isBuffering ||
            _isScrubbing ||
            _seekBusy ||
            _pendingTarget != null;
        if (!busy) return const SizedBox.shrink();
        return _spinnerOnly(isFullscreen);
      },
    );
  }

  /// Faqat aylanma halqa — markazdagi tugma o'lchamida, ikonkasiz.
  Widget _spinnerOnly(bool isFullscreen) => _PlayerRing(
        size: _playPauseDiameter(isFullscreen),
        strokeWidth: 2.6,
        color: AppColors.accent,
        trackColor: Colors.transparent,
        busy: true,
        progress: 0,
      );

  Widget _playPauseReactive({required double size}) {
    final ctrl = _controller;
    if (ctrl == null) {
      return GestureDetector(
        onTap: _togglePlayPause,
        child: _centerButton(playing: false, busy: true, progress: 0),
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) {
        final busy = !value.isInitialized ||
            value.isBuffering ||
            _isScrubbing ||
            _seekBusy ||
            _pendingTarget != null;
        final dur = value.duration.inMilliseconds;
        final shown = _pendingTarget ?? value.position;
        final progress =
            dur > 0 ? (shown.inMilliseconds / dur).clamp(0.0, 1.0) : 0.0;
        return GestureDetector(
          onTap: _togglePlayPause,
          child: _centerButton(
            playing: busy ? _intendedPlaying : value.isPlaying,
            busy: busy,
            progress: progress,
          ),
        );
      },
    );
  }

  Widget _centerButton({
    required bool playing,
    required bool busy,
    required double progress,
  }) {
    const iconSize = 40.0;
    const ringPadding = 6.0;
    final ringSize = iconSize + 12 * 2 + ringPadding * 2;
    return SizedBox(
      width: ringSize,
      height: ringSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _PlayerRing(
            size: ringSize,
            strokeWidth: 2.6,
            color: AppColors.accent,
            trackColor:
                busy ? Colors.transparent : Colors.white.withOpacity(0.22),
            busy: busy,
            progress: progress,
          ),
          _playPauseIcon(playing: playing, size: iconSize),
        ],
      ),
    );
  }

  // Play/pause tugmasining haqiqiy (doira) diametri — ikonka o'lchami
  // + atrofidagi 12px padding ikki tarafdan. Sek gesture'idagi o'lik
  // zona kengligi va sek ko'rsatkichining o'lchami shu qiymatga
  // asoslanadi.
  double _playPauseDiameter(bool isFullscreen) {
    // Ikonka (40) + ichki padding (12×2) + halqa uchun joy (6×2).
    return 40.0 + 12 * 2 + 6 * 2;
  }

  Widget _playPauseIcon({required bool playing, required double size}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.42),
        shape: BoxShape.circle,
      ),
      child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white, size: size),
    );
  }

  /// Progress chizig'idagi OQ chiziq — "qayergacha tayyor".
  ///
  ///   * mahalliy serverdan ijro etilyaptimi — diskdagi ulush
  ///     (bunday holatda fayl to'liq, ya'ni 100%);
  ///   * worker'dan ijro etilyaptimi — pleyerning O'Z buferi.
  ///     Diskda hech narsa saqlanmagani uchun DownloadManager'ning
  ///     hisobi bu yerda 0 bo'lardi va chiziq bo'sh ko'rinardi.
  double _readyRatio(VideoPlayerValue? value) {
    if (_playViaLocal) {
      return DownloadManager.instance.statOf(_currentUrl).ratio;
    }
    if (value == null) return 0;
    final dur = value.duration;
    if (dur <= Duration.zero) return 0;
    var end = Duration.zero;
    for (final r in value.buffered) {
      if (r.end > end) end = r.end;
    }
    return (end.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
  }

  // Faqat slayder/vaqtni eng tor ko'lamda yangilaydi.
  Widget _bottomBarReactive({required bool isFullscreen}) {
    final ctrl = _controller;
    // Progress chizig'idagi OQ (tayyor) qism uchun: mahalliy
    // ijroda DownloadManager hisobi kerak bo'ladi.
    Widget bar(VideoPlayerValue? value) => AnimatedBuilder(
          animation: DownloadManager.instance,
          builder: (context, _) => _bottomBar(value, isFullscreen),
        );
    if (ctrl == null) return bar(null);
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) => bar(value),
    );
  }

  Widget _bottomBar(VideoPlayerValue? value, bool isFullscreen) => _BottomBar(
          // Sek kutilayotgan bo'lsa — chiziq va vaqt O'SHA nuqtani
          // ko'rsatadi (pleyer hali eski joyda muzlab turgan bo'lsa
          // ham). Foydalanuvchi shu bilan qayerga borayotganini
          // darhol ko'radi.
          position: _pendingTarget ?? value?.position ?? Duration.zero,
          duration: value?.duration ?? Duration.zero,
          downloadedRatio: _readyRatio(value),
          fmt: _fmt,
          onSeek: (d) {
            // MUHIM: progress chizig'idan kelgan sek ham DEBOUNCE
            // orqali o'tadi. Avval har bir surish/bosish darhol
            // ctrl.seekTo() chaqirardi — tez-tez bosilganda o'nlab sek
            // buyrug'i pleyerda navbatga to'planib, uni qotirib
            // qo'yardi. Endi ikki marta bosib sek qilish bilan BITTA
            // umumiy navbat ishlatiladi.
            _scheduleSeekTo(d);
            _scheduleHide();
          },
          onQualityTap: _showQualityDialog,
          onFullscreen: _toggleFullscreen,
          isFullscreen: isFullscreen,
          onScrubStart: () {
            _hideTimer?.cancel();
            if (!_isScrubbing) setState(() => _isScrubbing = true);
          },
          onScrubEnd: () {
            if (_isScrubbing) setState(() => _isScrubbing = false);
            _scheduleHide();
          },
        );

  // ── QISMLAR RO'YXATI ────────────────────────────────────────────
  //
  // Tartib TESKARI: eng oxirgi qism ENG YUQORIDA turadi. Sabab oddiy —
  // foydalanuvchi odatda oxirgi chiqqan qismni qidiradi; avval buning
  // uchun ro'yxatning oxirigacha aylantirish kerak edi.
  List<Map<String, dynamic>> get _orderedEps {
    var eps = [..._playableEps];
    // Oflayn: faqat kamida bitta sifati TO'LIQ yuklangan qismlar.
    if (_offline) {
      eps = eps.where(_hasCompleteQuality).toList();
    }
    eps.sort((a, b) => _epNumOf(b).compareTo(_epNumOf(a)));
    return eps;
  }

  static int _epNumOf(Map<String, dynamic> ep) =>
      int.tryParse('${ep['epizod_number'] ?? ''}') ?? 0;

  /// Epizodni ro'yxatda BARQAROR tanib olish uchun kalit (ochilgan
  /// qismlar shu kalit bilan eslab qolinadi).
  static String _epKeyOf(Map<String, dynamic> ep) =>
      '${ep['epizod_id'] ?? ep['epizod_number'] ?? ''}';

  /// Shu epizodda mavjud sifatlar (yuqoridan pastga: 1080p -> 360p).
  List<_QualityInfo> _qualityInfos(Map<String, dynamic> ep) {
    return _availableQualities(ep)
        .map((q) => _QualityInfo(
              label: q,
              url: (ep['url_$q'] ?? '').toString(),
              sizeLabel: (ep['size_$q'] ?? '').toString(),
            ))
        .where((q) => q.url.isNotEmpty && _qualityVisible(q.url))
        .toList();
  }

  /// Qismning BIRORTA sifati to'liq yuklanganmi (oflayn ro'yxat uchun).
  bool _hasCompleteQuality(Map<String, dynamic> ep) {
    for (final q in _availableQualities(ep)) {
      if (_isComplete((ep['url_$q'] ?? '').toString())) return true;
    }
    return false;
  }

  /// Yuklab olish holati REAL VAQTDA faqat EKRANDA KO'RINIB TURGAN
  /// videolar uchun so'raladi: hozir ijro etilayotgani va ochilgan
  /// (yoyilgan) qismlarning sifatlari. Shu bilan keraksiz ish
  /// bajarilmaydi.
  void _syncWatchedUrls() {
    final urls = <String>{};
    final cur = _currentEp;
    if (cur != null) {
      final u = _getUrl(cur);
      if (u.isNotEmpty) urls.add(u);
    }
    for (final ep in _episodes) {
      // Oflayn rejimda HAR BIR qismning holati kerak: qaysi biri
      // to'liq yuklanganini bilmasak, ro'yxatni filtrlab bo'lmaydi.
      // (Bunday paytda so'rash oralig'i ham avtomatik siyraklashadi —
      // DownloadManager'dagi `_interval`ga qarang.)
      final expanded = _expandedEps.contains(_epKeyOf(ep));
      if (!expanded && !_offline) continue;
      for (final q in _availableQualities(ep)) {
        final u = (ep['url_$q'] ?? '').toString();
        if (u.isNotEmpty) urls.add(u);
      }
    }
    DownloadManager.instance.watch(this, urls);
  }

  /// Surish davomida holat so'rovi to'xtatilganmi (ikki marta
  /// to'xtatib qo'ymaslik uchun).
  bool _dlHeld = false;

  void _holdDownloadUpdates() {
    if (_dlHeld) return;
    _dlHeld = true;
    DownloadManager.instance.hold();
  }

  void _releaseDownloadUpdates() {
    if (!_dlHeld) return;
    _dlHeld = false;
    DownloadManager.instance.release();
  }

  // ══════════════════════════════════════════════════════════════
  //  QISMLAR BO'YICHA HARAKAT: [<] N-qism [>]
  // ══════════════════════════════════════════════════════════════

  /// Ro'yxatni surish uchun (tanlangan qismni o'rtaga olib kelish).
  final ScrollController _epScrollCtrl = ScrollController();

  /// Har bir qism qatorining kaliti — qatorni ANIQ o'rtaga joylash
  /// uchun kerak (ochilgan qatorlarning bo'yi har xil bo'lgani sabab
  /// faqat hisob-kitob bilan aniq chiqmaydi).
  final Map<String, GlobalKey> _epTileKeys = {};

  GlobalKey _epTileKey(String epKey) =>
      _epTileKeys.putIfAbsent(epKey, () => GlobalKey());

  /// YOPIQ qatorning taxminiy bo'yi (margin bilan). Surishning
  /// birinchi, taxminiy bosqichi uchun — keyin aniqlashtiriladi.
  static const double _kTileExtent = 60.0;

  /// Ekran ochilishi bilan ENG BIRINCHI qism (eng kichik raqamlisi,
  /// ya'ni "0-qism") pleyerga yuklanadi — lekin IJRO BOSHLANMAYDI.
  /// Kesh-server videoning birinchi bo'lagini oladi va birinchi kadr
  /// ekranda turadi, ya'ni "play" bosilishi bilan video darhol
  /// ketadi.
  ///
  /// Ro'yxat KAMAYISH tartibida saralangan (3, 2, 1, 0) — shu sabab
  /// eng birinchi qism ro'yxatning OXIRIDA turadi.
  void _autoOpenFirstEpisode() {
    if (!mounted || _currentEp != null) return;
    if (_orderedEps.isEmpty) return;
    // MUHIM: birinchi KADRDAN KEYIN ochamiz.
    // `_loadEpisodes` ro'yxatni keshdan o'qiganda bu metod hali
    // `initState` ichida — ya'ni ilk build davomida — chaqirilishi
    // mumkin. `_playEpisode` esa darhol `setState` qiladi va eski
    // controllerni yopish uchun kadr kutadi; buni build o'rtasida
    // qilib bo'lmaydi.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _currentEp != null) return;
      final eps = _orderedEps;
      if (eps.isEmpty) return;
      _playEpisode(eps.last, resumePlaying: false);
      _centerOnEpisode(eps.last);
    });
  }

  /// Joriy qismning ro'yxatdagi o'rni (topilmasa -1).
  int get _currentEpIndex {
    final cur = _currentEp;
    if (cur == null) return -1;
    final key = _epKeyOf(cur);
    final eps = _orderedEps;
    for (var i = 0; i < eps.length; i++) {
      if (_epKeyOf(eps[i]) == key) return i;
    }
    return -1;
  }

  /// `delta`: +1 — KEYINGI qism (raqami kattaroq), -1 — oldingisi.
  ///
  /// Ro'yxat KAMAYISH tartibida saralangan (3-qism, 2-qism, 1-qism...),
  /// shu sabab "keyingi qism" indeksda YUQORIGA siljish demakdir.
  void _stepEpisode(int delta) {
    final eps = _orderedEps;
    if (eps.isEmpty) return;
    final i = _currentEpIndex;
    final target = i < 0 ? 0 : i - delta;
    if (target < 0 || target >= eps.length) return;
    // Ijro holati saqlanadi: video ketayotgan bo'lsa yangi qism ham
    // darhol ijro etiladi, pauzada bo'lsa pauzada ochiladi.
    _playEpisode(eps[target], resumePlaying: _intendedPlaying);
    _centerOnEpisode(eps[target]);
  }

  /// Tanlangan qism qatorini ro'yxatning O'RTASIGA olib keladi.
  void _centerOnEpisode(Map<String, dynamic> ep) {
    final epKey = _epKeyOf(ep);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_epScrollCtrl.hasClients) return;
      final eps = _orderedEps;
      final index = eps.indexWhere((e) => _epKeyOf(e) == epKey);
      if (index < 0) return;

      final pos = _epScrollCtrl.position;
      // 1-bosqich: taxminiy o'ringa suramiz. Yopiq qatorlarning bo'yi
      // bir xil bo'lgani uchun bu odatda aynan to'g'ri chiqadi.
      final want =
          index * _kTileExtent - (pos.viewportDimension - _kTileExtent) / 2;
      final target =
          want.clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
      _epScrollCtrl
          .animateTo(target,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic)
          .whenComplete(() {
        // 2-bosqich: qator endi qurilgan — uni ANIQ o'rtaga joylaymiz
        // (ro'yxatda ochilgan, balandroq qatorlar bo'lsa shu tuzatadi).
        if (!mounted) return;
        final ctx = _epTileKeys[epKey]?.currentContext;
        if (ctx == null) return;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    });
  }

  /// [<] N-qism [>] — qismlar tabining USTIDAGI boshqaruv.
  /// Tugmalarda YOZUV yo'q, faqat ikonka.
  Widget _buildEpisodeNav() {
    final eps = _orderedEps;
    final i = _currentEpIndex;
    // Ro'yxat kamayish tartibida: keyingi qism indeksda yuqorida.
    final hasNext = i > 0;
    final hasPrev = i >= 0 && i < eps.length - 1;
    final label = i >= 0
        ? '${eps[i]['epizod_number'] ?? ''}-qism'
        : (eps.isEmpty ? '—' : 'Qismni tanlang');

    // ── BO'YI KICHRAYTIRILDI (foydalanuvchi talabi) ─────────────
    // Avval tugmalar 76x50 dp, atrofida 7 dp to'ldirish bilan butun
    // qator 64 dp edi. Endi 68x38 dp va 5 dp to'ldirish, ya'ni
    // 48 dp — barmoq bilan tegish uchun baribir qulay (Android'ning
    // tavsiyasi 48x48 dp bo'lib, tugmaning ENI aynan shundan katta),
    // lekin qismlar ro'yxatiga yana 16 dp joy chiqadi.
    Widget btn(IconData icon, bool enabled, VoidCallback onTap) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          width: 68,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(enabled ? 0.10 : 0.035),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: Colors.white.withOpacity(enabled ? 0.20 : 0.06)),
          ),
          child: Icon(icon,
              size: 24,
              color: Colors.white.withOpacity(enabled ? 0.95 : 0.22)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Glass(
        borderRadius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          children: [
            btn(Icons.skip_previous_rounded, hasPrev, () => _stepEpisode(-1)),
            Expanded(
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: i >= 0 ? Colors.white : Colors.white54,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            btn(Icons.skip_next_rounded, hasNext, () => _stepEpisode(1)),
          ],
        ),
      ),
    );
  }

  void _toggleExpanded(String epKey) {
    setState(() {
      if (!_expandedEps.remove(epKey)) _expandedEps.add(epKey);
    });
    _syncWatchedUrls();
  }

  /// O'chirishdan oldin tasdiq so'raydi — bir marta bosish bilan
  /// yuklab olingan video yo'qolib qolmasligi uchun.
  Future<void> _confirmDeleteQuality(_QualityInfo q) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF15151F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Tozalash',
            style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700)),
        content: Text(
          'Rostanham ${q.label} sifatidagi videoni tozalab tashlaysizmi?',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Bekor qilish',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Ha',
                style: TextStyle(
                    color: AppColors.accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    DownloadManager.instance.delete(q.url);

    // ── HOZIR IJRO ETILAYOTGAN SIFAT O'CHIRILGAN BO'LSA ────────
    // Kesh papkasi shu zahoti yo'q qilinadi, ya'ni pleyer o'qib
    // turgan oqim uziladi. Uni o'z holiga tashlab qo'ysak, ekranda
    // "Videoni yuklab bo'lmadi" chiqib qolardi. Shu sabab pleyer
    // AYNAN SHU joydan qaytadan ochiladi — video worker'dan
    // yangidan yuklana boshlaydi.
    final currentEp = _currentEp;
    if (q.url == _currentUrl && currentEp != null) {
      final at = _controller?.value.position ?? Duration.zero;
      // MUHIM: bu yerda `_recoverPlayer` ISHLATILMAYDI. U "xatodan
      // tiklanish" uchun mo'ljallangan va o'zida 6 soniyalik tormoz
      // hamda ketma-ket urinishlar chegarasi bor — foydalanuvchining
      // ATAYLAB bosgan tugmasi esa har doim, darhol ishlashi kerak.
      // Ilgari aynan shu tormoz sabab tozalashdan keyin video
      // qayta ochilmay qolishi mumkin edi.
      _recoveryStreakResetTimer?.cancel();
      _recoveryStreak = 0;
      _lastRecovery = DateTime.fromMillisecondsSinceEpoch(0);
      _playEpisode(currentEp, resumeAt: at, resumePlaying: _intendedPlaying);
    }
  }

  Widget _buildEpisodeTab() {
    if (_loadingEps) {
      return Center(
          child: CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation(AppColors.accent)));
    }
    final eps = _orderedEps;
    if (eps.isEmpty) {
      return Center(
          child: Text('Qismlar topilmadi',
              style: TextStyle(color: Colors.white.withOpacity(0.5))));
    }
    return ListView.builder(
      controller: _epScrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      itemCount: eps.length,
      itemBuilder: (_, i) {
        final ep = eps[i];
        final epKey = _epKeyOf(ep);
        final isCurrent =
            _currentEp != null && _currentEp!['epizod_id'] == ep['epizod_id'];
        return _EpisodeTile(
          // GlobalKey — qatorni aniq o'rtaga joylash uchun
          // (`_centerOnEpisode`ga qarang).
          key: _epTileKey(epKey),
          number: ep['epizod_number']?.toString() ?? '${i + 1}',
          isCurrent: isCurrent,
          // Tugmadagi ikonka foydalanuvchining NIYATINI ko'rsatadi
          // (pleyerdagi markaziy tugma bilan bir xil mantiq).
          isPlaying: isCurrent && _intendedPlaying,
          expanded: _expandedEps.contains(epKey),
          qualities: _qualityInfos(ep),
          // Ijro etilayotgan qism ustiga YANA bir marta bosilsa —
          // video pauza bo'ladi (va yana bosilsa davom etadi).
          onTap: () {
            if (isCurrent) {
              _togglePlayPause();
            } else {
              _playEpisode(ep);
            }
          },
          onToggleExpand: () => _toggleExpanded(epKey),
          onDelete: _confirmDeleteQuality,
        );
      },
    );
  }

  Widget _buildSeasonsTab() {
    if (_loadingSeasons) {
      return Center(
          child: CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation(AppColors.accent)));
    }
    if (_seasons.isEmpty) {
      return Center(
          child: Text('Bo\'limlar topilmadi',
              style: TextStyle(color: Colors.white.withOpacity(0.5))));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      itemCount: _seasons.length,
      itemBuilder: (_, i) {
        final s = _seasons[i];
        final bolimId = s['bolim_id'] ?? s['season_id'] ?? '';
        final nomi = (s['nomi'] ?? '').toString();
        final photoUrl = s['photo_url'] as String?;
        final isCur = s['season_id']?.toString() ==
            widget.season['season_id']?.toString();
        return GlassTappable(
          onTap: () {
            if (!isCur) {
              Navigator.of(context).pushReplacement(PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 300),
                pageBuilder: (_, a, __) => VideoPlayerScreen(season: s),
                transitionsBuilder: (_, a, __, child) =>
                    FadeTransition(opacity: a, child: child),
              ));
            }
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isCur
                  ? AppColors.accent.withOpacity(0.12)
                  : Colors.white.withOpacity(0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: isCur
                      ? AppColors.accent.withOpacity(0.4)
                      : Colors.white12),
            ),
            child: Row(
              children: [
                if (photoUrl != null && photoUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                        imageUrl: photoUrl,
                        width: 50,
                        height: 50,
                        // 50 dp li ikonka — xotiraga 150 px tushadi.
                        memCacheWidth: 150,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                            width: 50,
                            height: 50,
                            color: Colors.white10,
                            child: const Icon(Icons.movie_outlined,
                                color: Colors.white38))),
                  )
                else
                  Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.movie_outlined,
                          color: Colors.white38)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nomi.isNotEmpty ? nomi : '$bolimId-bo\'lim',
                          style: TextStyle(
                              color: isCur ? AppColors.accent : Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                      Text('$bolimId-bo\'lim',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.45),
                              fontSize: 12)),
                    ],
                  ),
                ),
                if (isCur)
                  Icon(Icons.play_arrow_rounded, color: AppColors.accent),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoTab(String tavsif) {
    final studio = (widget.season['studio'] ?? '').toString();
    final tarjimon = (widget.season['tarjimon'] ?? '').toString();
    final holati = (widget.season['holati'] ?? '').toString();
    final turi = (widget.season['turi'] ?? '').toString();
    final yili = (widget.season['yili'] ?? '').toString();
    final janri = (widget.season['janri'] ?? '').toString();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      child: Glass(
        borderRadius: 18,
        blur: 14,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow('Turi', turi),
            _infoRow('Yili', yili),
            _infoRow('Janri', janri),
            _infoRow('Studio', studio),
            _infoRow('Tarjimon', tarjimon),
            _infoRow('Holati', holati),
            if (tavsif.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Tavsif',
                  style: TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              Text(tavsif,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.8),
                      fontSize: 14,
                      height: 1.6)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 90,
              child: Text(label,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.5), fontSize: 13))),
          Expanded(
              child: Text(value,
                  style: const TextStyle(color: Colors.white, fontSize: 13))),
        ],
      ),
    );
  }
}

// ── Widgetlar ──────────────────────────────────────────────────────

// VAQTINCHALIK: mahalliy kesh-server (VideoCacheServer) diagnostika
// jurnalining so'nggi qatorlarini to'g'ridan-to'g'ri video ustida
// ko'rsatadi — muammoni adb/logcat'siz, qurilmaning o'zida ko'rish
// uchun. Muammo aniqlangach bu widget va uni chaqirgan joy olib
// tashlanishi mumkin.
// ── QISM TUGMASI VA UNING SIFATLAR RO'YXATI ────────────────────────
//
// Tugmaning o'ng chetida BITTA tugma bor va uning ichida uchta ikonka
// turadi: uchburchak (yoyish/yig'ish), yuklab olish va chiqitdon.
// Unga bosilganda uchburchak yuqoriga qaraydi va tugmaning bo'yi
// cho'zilib, pastida shu qismning BARCHA sifatlari chiqadi. Har bir
// sifat o'z holati (foiz, hajm, progress chizig'i) va o'z
// tugmalari (yuklab olish / tozalash) bilan.

/// Bitta sifat haqidagi ma'lumot: yorlig'i, manzili va (bazadagi)
/// hajmi. Hajm bazada matn sifatida saqlanadi ("240MB" kabi) va u
/// faqat HALI hech narsa yuklanmagan, ya'ni haqiqiy hajm noma'lum
/// bo'lgan holatda ko'rsatiladi.
class _QualityInfo {
  final String label;
  final String url;
  final String sizeLabel;
  const _QualityInfo({
    required this.label,
    required this.url,
    required this.sizeLabel,
  });
}

/// Baytni "120" / "1.4" ko'rinishidagi MB soniga aylantiradi.
String _mb(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb >= 10 ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1);
}

class _EpisodeTile extends StatelessWidget {
  final String number;
  final bool isCurrent;
  final bool isPlaying;
  final bool expanded;
  final List<_QualityInfo> qualities;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;
  final Future<void> Function(_QualityInfo) onDelete;

  const _EpisodeTile({
    super.key,
    required this.number,
    required this.isCurrent,
    required this.isPlaying,
    required this.expanded,
    required this.qualities,
    required this.onTap,
    required this.onToggleExpand,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isCurrent
            ? AppColors.accent.withOpacity(0.14)
            : Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isCurrent
                ? AppColors.accent.withOpacity(0.5)
                : Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: Padding(
                    // Bo'yi biroz kichraytirildi (vertikal 12 -> 8).
                    padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? AppColors.accent.withOpacity(0.28)
                                : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            isPlaying && isCurrent
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color:
                                isCurrent ? AppColors.accent : Colors.white54,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('$number-qism',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: isCurrent
                                      ? AppColors.accent
                                      : Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggleExpand,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
                  child: Container(
                    // Uch ikonkali tugma KATTALASHTIRILDI — barmoq
                    // bilan tegish qulay bo'lsin (foydalanuvchi talabi).
                    padding: const EdgeInsets.symmetric(
                        horizontal: 11, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                            expanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            color: Colors.white,
                            size: 23),
                        const SizedBox(width: 8),
                        const Icon(Icons.download_rounded,
                            color: Colors.white70, size: 21),
                        const SizedBox(width: 8),
                        const Icon(Icons.delete_outline_rounded,
                            color: Colors.white70, size: 21),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (expanded)
            ...qualities.map((q) => _QualityRow(
                  info: q,
                  onDelete: () => onDelete(q),
                )),
        ],
      ),
    );
  }
}

/// Bitta sifat qatori: "1080p / 50% / 120 / 240MB", tagida progress
/// chizig'i, o'ng tarafda yuklab olish va tozalash tugmalari.
///
/// Progress REAL VAQTDA yangilanadi: DownloadManager Rust yadrosidagi
/// hisobni 500 ms da bir marta o'qib turadi va o'zgargan bo'lsagina
/// xabar beradi. Video shunchaki KO'RILAYOTGANDA ham foiz o'sib
/// boraveradi — chunki ko'rish paytida ham aynan shu bo'laklar diskka
/// yozilyapti.
class _QualityRow extends StatelessWidget {
  final _QualityInfo info;
  final VoidCallback onDelete;

  const _QualityRow({required this.info, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        final st = DownloadManager.instance.statOf(info.url);
        final totalLabel = st.total > 0
            ? '${_mb(st.total)}MB'
            : (info.sizeLabel.isNotEmpty ? info.sizeLabel : '—');
        final line =
            '${info.label} / ${st.percent}% / ${_mb(st.downloaded)} / $totalLabel'
            '${st.retrying ? ' · qayta urinilmoqda' : ''}';
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(line,
                        style: TextStyle(
                            color: st.complete
                                ? Colors.white
                                : Colors.white.withOpacity(0.72),
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 5),
                    // Chiziq o'ng chetga YETMAYDI — o'ng tarafda
                    // tugmalar turadi.
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: st.ratio,
                          minHeight: 4,
                          backgroundColor: Colors.white.withOpacity(0.10),
                          valueColor: AlwaysStoppedAnimation(
                              st.complete ? Colors.white : AppColors.accent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // TO'LIQ yuklangan sifatda yuklab olish tugmasi
              // KO'RSATILMAYDI — olinadigan narsa qolmagan.
              if (!st.complete)
                _MiniIconButton(
                  // Yuklanayotganda pleyerdagidek IKKI CHIZIQ (pauza)
                  // ko'rinadi; yana bosilsa yuklash to'xtaydi va ikonka
                  // avvalgi holatiga qaytadi.
                  icon: st.downloading
                      ? Icons.pause_rounded
                      : Icons.download_rounded,
                  highlighted: st.downloading,
                  onTap: () {
                    if (st.downloading) {
                      DownloadManager.instance.pause(info.url);
                    } else {
                      DownloadManager.instance.download(info.url);
                    }
                  },
                ),
              const SizedBox(width: 2),
              _MiniIconButton(
                  icon: Icons.delete_outline_rounded, onTap: onDelete),
            ],
          ),
        );
      },
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool highlighted;

  const _MiniIconButton({
    required this.icon,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 5),
        // Barmoq bilan aniq tegish uchun kattaroq (34 -> 44).
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: highlighted
              ? AppColors.accent.withOpacity(0.22)
              : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon,
            size: 23,
            color: highlighted ? AppColors.accent : Colors.white70),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  AYLANMA HALQA (play/pause tugmasi atrofidagi chiziq)
// ══════════════════════════════════════════════════════════════
//
// Ikki vazifasi bor:
//   * `busy == false` — ijro qay darajada o'tganini ko'rsatadi
//     (to'liq aylana = video oxiri);
//   * `busy == true`  — GOOGLE USLUBIDA aylanadi: yoy avval
//     uzayadi va boshi tez yuguradi, keyin qisqaradi va sekinlashadi.
//
// NEGA O'Z VIDJETIMIZ (Flutter'ning `CircularProgressIndicator`
// o'rniga): standart vidjetdagi aylanish juda tekis va sust
// ko'rinardi. Bu yerdagi mantiq Material'ning asl g'oyasini
// takrorlaydi, lekin qarama-qarshiligi kuchaytirilgan:
//
//   * yoyning BOSHI davrning birinchi yarmida tez harakatlanadi
//     (yoy uzayadi);
//   * DUMI ikkinchi yarmida uni quvib yetadi (yoy qisqaradi va
//     harakat sekinlashadi);
//   * bir davrda ikkalasi birgalikda ANIQ BITTA to'liq aylana
//     bosib o'tadi — shu sabab davrlar orasida sakrash bo'lmaydi.
class _PlayerRing extends StatefulWidget {
  final double size;
  final double strokeWidth;
  final Color color;
  final Color trackColor;
  final bool busy;
  final double progress;

  const _PlayerRing({
    required this.size,
    required this.strokeWidth,
    required this.color,
    required this.trackColor,
    required this.busy,
    required this.progress,
  });

  @override
  State<_PlayerRing> createState() => _PlayerRingState();
}

class _PlayerRingState extends State<_PlayerRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.busy) _spin.repeat();
  }

  @override
  void didUpdateWidget(covariant _PlayerRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Kutish tugagach animatsiya to'xtaydi — bekorga kadr
    // chizilmaydi (batareya tejaladi).
    if (widget.busy && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.busy && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _spin,
          builder: (_, __) => CustomPaint(
            painter: _PlayerRingPainter(
              t: _spin.value,
              busy: widget.busy,
              progress: widget.progress,
              color: widget.color,
              trackColor: widget.trackColor,
              strokeWidth: widget.strokeWidth,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerRingPainter extends CustomPainter {
  final double t;
  final bool busy;
  final double progress;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  const _PlayerRingPainter({
    required this.t,
    required this.busy,
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  // Yoyning eng qisqa uzunligi (aylana ulushi) — u hech qachon
  // butunlay yo'qolib ketmasligi kerak.
  static const double _minArc = 0.06;

  // Yoyning o'sish zaxirasi. `_minArc + _maxArc` = eng uzun yoy
  // (0.78 aylana ~ 280°). Qolgan `1 - _maxArc` esa har bir davrda
  // qo'shiladigan doimiy burilish — shu sabab bir davrda yoy ANIQ
  // bitta to'liq aylana bosadi va davrlar uzluksiz ulanadi.
  static const double _maxArc = 0.72;

  /// `t` ning [begin, end] oralig'idagi yumshatilgan (0..1) qiymati.
  static double _seg(double t, double begin, double end) {
    final v = ((t - begin) / (end - begin)).clamp(0.0, 1.0);
    return Curves.easeInOutCubic.transform(v);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = (math.min(size.width, size.height) - strokeWidth) / 2;
    if (r <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: r);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;

    if (!busy) {
      if (trackColor.alpha != 0) {
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = trackColor,
        );
      }
      final p = progress.clamp(0.0, 1.0);
      if (p > 0) {
        canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * p, false, arc);
      }
      return;
    }

    // Boshi — davrning birinchi yarmida yuguradi (yoy uzayadi).
    final head = _seg(t, 0.0, 0.55);
    // Dumi — ikkinchi yarmida quvib yetadi (yoy qisqaradi).
    final tail = _seg(t, 0.45, 1.0);

    final sweep = (_minArc + (head - tail).clamp(0.0, 1.0) * _maxArc) * 2 * math.pi;
    final start =
        (tail * _maxArc + t * (1 - _maxArc)) * 2 * math.pi - math.pi / 2;
    canvas.drawArc(rect, start, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_PlayerRingPainter old) =>
      old.t != t ||
      old.busy != busy ||
      old.progress != progress ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth;
}

class _SeekBadge extends StatefulWidget {
  final int seconds;
  final bool isLeft;
  final double diameter;
  const _SeekBadge(
      {required this.seconds, required this.isLeft, required this.diameter});

  @override
  State<_SeekBadge> createState() => _SeekBadgeState();
}

class _SeekBadgeState extends State<_SeekBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon =
        widget.isLeft ? Icons.arrow_left_rounded : Icons.arrow_right_rounded;
    final chevrons = _buildChevrons(icon);
    final text = Text('${widget.seconds}s',
        style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            // Doira endi markaziy halqa bilan teng (kichikroq), shu
            // sabab ichidagi belgilar nisbatan biroz kattalashtirildi
            // — aks holda ular yo'qolib ketardi.
            fontSize: widget.diameter * 0.15));

    return Container(
      width: widget.diameter,
      height: widget.diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        shape: BoxShape.circle,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          chevrons,
          SizedBox(height: widget.diameter * 0.07),
          text,
        ],
      ),
    );
  }

  // Uchburchaklar chapda chapga, o'ngda o'ngga qaragan bo'ladi va bir
  // xil tezlikda ketma-ket yonib-o'chadi (foydalanuvchiga sek
  // ketayotganini bildirish uchun).
  Widget _buildChevrons(IconData icon) {
    final order = widget.isLeft ? [2, 1, 0] : [0, 1, 2];
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final idx = order[i];
            final start = idx * 0.15;
            final t = ((_ctrl.value - start) % 1.0 + 1.0) % 1.0;
            final opacity = t < 0.5
                ? (0.3 + 0.7 * (t / 0.5))
                : (1.0 - 0.7 * ((t - 0.5) / 0.5));
            return Opacity(
              opacity: opacity.clamp(0.3, 1.0),
              child:
                  Icon(icon, color: Colors.white, size: widget.diameter * 0.21),
            );
          }),
        );
      },
    );
  }
}

// ── PLEYERNING PASTKI PANELI ────────────────────────────────────
//
// Panel endi ekranning IKKALA CHETIGACHA to'lib turadi: progress
// chizig'i chap chetdan boshlanadi, vaqt / HQ / fullscreen esa o'ng
// chetga surilgan. Butun qator biroz pastga tushirilgan.
//
// Progress chizig'i endi Material Slider EMAS, o'zimiz chizadigan
// chiziq. Sabab: Slider bir vaqtda faqat IKKI rangni (o'tilgan /
// o'tilmagan) ko'rsata oladi, bizga esa UCHTA qatlam kerak:
//   * ACCENT  — ijro etilgan qism;
//   * OQ      — diskka yuklab olingan qism (real vaqtda o'sib boradi);
//   * SHAFFOF — hali yuklanmagan qism.
//
// Barmoq bilan surish mantig'i o'zgarmadi: surish davomida pleyerga
// UMUMAN tegilmaydi (faqat chiziqning ko'rinishi yangilanadi), sek
// esa barmoq uzilganda BITTA marta yuboriladi.
class _BottomBar extends StatefulWidget {
  final Duration position;
  final Duration duration;

  /// Diskka yuklab olingan ulush (0..1) — oq qismning uzunligi.
  final double downloadedRatio;

  final String Function(Duration) fmt;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onQualityTap;
  final VoidCallback onFullscreen;
  final bool isFullscreen;
  // Barmoq chiziqqa qo'yilganda/uzilganda xabar beradi — markaziy
  // tugmaning halqasi shu paytda aylanadi.
  final VoidCallback onScrubStart;
  final VoidCallback onScrubEnd;

  const _BottomBar({
    required this.position,
    required this.duration,
    required this.downloadedRatio,
    required this.fmt,
    required this.onSeek,
    required this.onQualityTap,
    required this.onFullscreen,
    required this.isFullscreen,
    required this.onScrubStart,
    required this.onScrubEnd,
  });

  @override
  State<_BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends State<_BottomBar> {
  double? _dragValue;

  void _commit(double v) {
    if (widget.duration.inMilliseconds > 0) {
      widget.onSeek(Duration(
          milliseconds: (v * widget.duration.inMilliseconds).round()));
    }
    setState(() => _dragValue = null);
    widget.onScrubEnd();
  }

  @override
  Widget build(BuildContext context) {
    final liveRatio = widget.duration.inMilliseconds > 0
        ? (widget.position.inMilliseconds / widget.duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;
    final ratio = _dragValue ?? liveRatio;
    final shownPosition =
        _dragValue != null && widget.duration.inMilliseconds > 0
            ? Duration(
                milliseconds:
                    (_dragValue! * widget.duration.inMilliseconds).round())
            : widget.position;

    // ── O'LCHAMLAR ────────────────────────────────────────────
    // Oddiy (fullscreen bo'lmagan) rejimda pleyer oynasi kichik
    // bo'lgani uchun boshqaruv elementlari ham kichik chiqardi va
    // ularni barmoq bilan bosish noqulay edi. Endi oddiy rejimda
    // ular KATTAROQ: chiziq qalinroq, tugma va yozuvlar yirikroq,
    // pastki qism to'liqroq ko'rinadi. Fullscreen'da esa ekran
    // allaqachon keng — u yerda o'lchamlar biroz jamroq.
    final compact = !widget.isFullscreen;
    final trackHeight = compact ? 4.0 : 3.0;
    final thumbRadius = compact ? 8.0 : 6.0;
    final timeFont = compact ? 14.0 : 12.0;
    final iconSize = compact ? 31.0 : 25.0;
    final hqFont = compact ? 13.0 : 11.0;

    return Padding(
      // Panel IKKALA CHETGACHA to'ladi va biroz pastroqda turadi
      // (foydalanuvchi talabi). Chap chetda progress chizig'i
      // boshlanadi, o'ng chetda esa vaqt / HQ / fullscreen turadi.
      padding: EdgeInsets.fromLTRB(0, 0, compact ? 6 : 4, compact ? 4 : 2),
      child: Row(
        children: [
          Expanded(
            child: _VideoProgressBar(
              played: ratio,
              downloaded: widget.downloadedRatio,
              trackHeight: trackHeight,
              thumbRadius: thumbRadius,
              onDragStart: () {
                setState(() => _dragValue = ratio);
                widget.onScrubStart();
              },
              onDragUpdate: (v) => setState(() => _dragValue = v),
              onDragEnd: _commit,
              onTapSeek: _commit,
            ),
          ),
          SizedBox(width: compact ? 8 : 6),
          // Vaqt: joriy pozitsiya ham, UMUMIY davomiylik ham TO'LIQ OQ.
          Text(
            '${widget.fmt(shownPosition)}/${widget.fmt(widget.duration)}',
            style: TextStyle(
                color: Colors.white,
                fontSize: timeFont,
                fontWeight: FontWeight.w600),
          ),
          SizedBox(width: compact ? 10 : 8),
          GestureDetector(
            onTap: widget.onQualityTap,
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 10 : 7, vertical: compact ? 6 : 3),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: Colors.white30)),
              child: Text('HQ',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: hqFont,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          SizedBox(width: compact ? 6 : 4),
          GestureDetector(
            onTap: widget.onFullscreen,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 4 : 3, vertical: compact ? 6 : 2),
              child: Icon(
                  widget.isFullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  color: Colors.white,
                  // Yana kattalashtirildi (foydalanuvchi talabi).
                  size: iconSize),
            ),
          ),
        ],
      ),
    );
  }
}

/// Uch qatlamli progress chizig'i (shaffof / oq / accent) + tutqich.
class _VideoProgressBar extends StatefulWidget {
  /// Ijro etilgan ulush (0..1).
  final double played;

  /// Diskka yuklab olingan ulush (0..1).
  final double downloaded;

  /// Chiziq qalinligi va tutqich radiusi — oddiy rejimda kattaroq,
  /// fullscreen'da jamroq (chaqiruvchi hal qiladi).
  final double trackHeight;
  final double thumbRadius;

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;
  final ValueChanged<double> onTapSeek;

  const _VideoProgressBar({
    required this.played,
    required this.downloaded,
    required this.trackHeight,
    required this.thumbRadius,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTapSeek,
  });

  @override
  State<_VideoProgressBar> createState() => _VideoProgressBarState();
}

class _VideoProgressBarState extends State<_VideoProgressBar> {
  /// Barmoq oxirgi marta turgan nuqta (0..1). `onHorizontalDragEnd`
  /// pozitsiya bermaydi, shu sabab uni surish davomida eslab boramiz.
  double _last = 0;

  @override
  Widget build(BuildContext context) {
    final played = widget.played;
    final thumb = widget.thumbRadius * 2;
    final track = widget.trackHeight;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        double ratioAt(double dx) => w <= 0 ? 0.0 : (dx / w).clamp(0.0, 1.0);

        Widget layer(double value, Color color) => Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: (w * value.clamp(0.0, 1.0)),
                child: Container(
                  height: track,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(track / 2),
                  ),
                ),
              ),
            );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => widget.onTapSeek(ratioAt(d.localPosition.dx)),
          onHorizontalDragStart: (d) {
            _last = ratioAt(d.localPosition.dx);
            widget.onDragStart();
            widget.onDragUpdate(_last);
          },
          onHorizontalDragUpdate: (d) {
            _last = ratioAt(d.localPosition.dx);
            widget.onDragUpdate(_last);
          },
          onHorizontalDragEnd: (_) => widget.onDragEnd(_last),
          onHorizontalDragCancel: () => widget.onDragEnd(_last),
          child: SizedBox(
            // Barmoq bilan qulay tegish uchun chiziqdan ancha baland.
            height: thumb + 16,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Yuklanmagan qism ATAYLAB shaffof qoldirilgan.
                layer(1.0, Colors.transparent),
                // Diskda tayyor turgan qism — real vaqtda o'sib boradi.
                layer(widget.downloaded, Colors.white.withOpacity(0.85)),
                // Ijro etilgan qism.
                layer(played, AppColors.accent),
                Positioned(
                  left: (w * played.clamp(0.0, 1.0) - thumb / 2)
                      .clamp(0.0, w > thumb ? w - thumb : 0.0),
                  child: Container(
                    width: thumb,
                    height: thumb,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
