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
import '../services/video_gate.dart';
import '../services/image_cache.dart';

import '../services/app_settings.dart';
import '../services/billing_service.dart';
import '../services/comments_service.dart';
import '../services/download_manager.dart';
import '../services/app_http.dart';
import '../services/rust_bridge.dart';
import '../services/screen_guard.dart';
import '../services/video_cache_server.dart';
import '../services/format.dart';
import '../services/intro_times.dart';
import '../services/season_info.dart';
import '../services/watch_history.dart';
import '../services/watch_progress.dart';
import '../theme/app_background.dart';
import 'billing_screen.dart';
import '../widgets/glass.dart';
import '../widgets/comments_tab.dart';

const String _apiBase = 'https://arumediatv.uzcom.workers.dev';

class VideoPlayerScreen extends StatefulWidget {
  final Map<String, dynamic> season;

  /// Qaysi qism ochilsin (tarixdan kelinganda) — qismning
  /// O'ZGARMAS IDsi. `null` — ilova o'zi tanlaydi: shu bo'limning
  /// OXIRGI ko'rilgan qismi, u ham bo'lmasa eng birinchi qism.
  ///
  /// Raqam EMAS, ID: admin qism raqamini o'zgartirsa ham tarixdagi
  /// kadr aynan o'sha qismni ochishi kerak (foydalanuvchi talabi).
  final int? startEpizodId;

  /// Qaysi joydan boshlansin (tarixdan kelinganda). `null` —
  /// telefonda eslab qolingan nuqta ishlatiladi.
  final Duration? startAt;

  const VideoPlayerScreen({
    super.key,
    required this.season,
    this.startEpizodId,
    this.startAt,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        // ── SKRINSHOT VA EKRAN YOZUVI TAQIQLANADI ────────────
        //
        // TALAB (foydalanuvchi): "ilovada video pleyerda ...
        // screenshot olish va ekranni yozib olish taqiqlansin".
        //
        // Aralashma ekran ochilganda himoyani yoqadi, yopilganda
        // o'chiradi (`screen_guard.dart` izohiga qarang).
        ScreenGuarded<VideoPlayerScreen> {
  late final TabController _tabCtrl;

  /// Oynalar QO'LDA suriladi (tarix oynalaridek). `TabBar` va bu
  /// sahifa bir-birini kuzatib boradi.
  late final PageController _tabPages;

  /// Bo'lim ma'lumoti: ko'rishlar, tomosha vaqti, sevimlilar,
  /// reyting va shu odamning O'Z bahosi. BITTA so'rov bilan
  /// olinadi (`GET /api/season/:a/:s`).
  SeasonInfo? _info;

  /// Tomosha vaqtini o'lchash uchun oldingi kadrdagi nuqta.
  ///
  /// Faqat IJRO ketayotganda va tezlik 1x bo'lganda hisoblanadi;
  /// sek (sakrash) katta farq berganda e'tiborsiz qoldiriladi.
  Duration? _watchTickPos;

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

  /// Pleyerga HAQIQATAN berilgan manzil: mahalliy proksi
  /// (`127.0.0.1/v?u=...`) yoki worker oqimi (`/api/play/...`).
  ///
  /// Suzuvchi oynalar (ilova ichidagi ham, ilovalar ustidagi ham)
  /// AYNAN shuni olishi kerak. `_currentUrl` xom manzil — u
  /// `/api/image/` ga ishora qiladi va undan ijro etilsa
  /// Cloudflare keshi chetlab o'tilib, har so'rov B2'ga tushardi
  /// (pul). Batafsil — `_workerPlayUrl` izohi.
  String _currentSource = '';
  // Ro'yxatda YOYILGAN (sifatlari ko'rsatilgan) qismlar kalitlari.
  final Set<String> _expandedEps = {};

  // ── OFLAYN REJIM ─────────────────────────────────────────────
  // Internet yo'q bo'lganda faqat TO'LIQ yuklab olingan sifatlar va
  // ular tegishli qismlar ko'rsatiladi — chunki qolganlarini ochib
  // ham bo'lmaydi va foydalanuvchini "ishlamayapti" deb chalkashtirish
  // keraksiz.
  bool _offline = false;

  /// Internet bor-yo'qligi hali tekshirilmagan bo'lsa `false`.
  ///
  /// MUHIM: qism AVTOMATIK ochilishidan oldin buni bilish shart —
  /// oflaynda pleyer umuman ochilmasligi kerak (foydalanuvchi
  /// talabi), aks holda ekranda xato yozuvi chiqib qolardi.
  bool _connectivityKnown = false;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  String? _selectedQuality;

  /// Foydalanuvchi shu seansda sifatni QO'LDA tanladimi.
  ///
  /// Tanlagan bo'lsa — tarixdagi "oxirgi ko'rilgan sifat" endi
  /// ustidan yozmaydi: odam nima tanlasa o'sha qoladi.
  bool _qualityChosenByUser = false;
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

  // ═══════════════════════════════════════════════════════════
  //  TANBAL (LAZY) OYNA KESHLASH — PLEYER TOMONI
  // ═══════════════════════════════════════════════════════════
  //
  // Katta fayl (masalan 1.5 GB) 480 MiB'lik OYNALARGA bo'linadi va
  // keshga FAQAT KERAK BO'LGANI olinadi:
  //
  //   * video ochilganda — faqat #0 oyna (0-480 MiB). Foydalanuvchi
  //     shu bittasini kutadi, boshqa hech narsa manbadan o'qilmaydi;
  //   * ijro davomida pleyer #0 oynaning OXIRIGA YAQINLASHGANDA
  //     ilova #1 oynani (480-960 MiB) FON'DA keshga oldiradi —
  //     foydalanuvchi u yerga yetib borgunicha tayyor bo'ladi va
  //     hech qanday kutish sezilmaydi;
  //   * foydalanuvchi hali keshlanmagan joyga SEK qilsa, ilova
  //     avval o'sha oynani keshlatadi va faqat KEYIN sek qiladi.
  //
  // ── NEGA AYNAN SHUNDAY ────────────────────────────────────
  //
  // Pleyer keshda YO'Q joyni so'rasa, server "hali tayyor emas"
  // (503) deb javob beradi. ExoPlayer uchun bu QAYTARIB
  // BO'LMAYDIGAN xato: pleyerni butunlay qaytadan ochishga
  // to'g'ri keladi va SHU PAYT YIG'ILGAN BUTUN BUFER YO'QOLADI.
  // Foydalanuvchi buni aynan "sek qilsam bufer tozalanadi va
  // video qaytadan sekin ochiladi" deb ko'rgan edi.
  //
  // Endi ilova pleyerdan OLDINDA yuradi: kerakli oyna har doim
  // pleyer so'rashidan avval tayyor bo'ladi. Ya'ni 503 umuman
  // yuz bermaydi — demak bufer ham hech qachon tozalanmaydi.

  /// Faylning umumiy hajmi (bayt). 0 — hali noma'lum.
  int _totalBytes = 0;

  /// Bitta oynadagi baytlar soni (Rust yadrosidan olinadi).
  int _windowBytes = 480 * 1024 * 1024;

  /// Oldindan keshlash chegarasi: bufer uchi oyna oxiriga shu
  /// masofadan yaqinlashsa, keyingi oyna FON'DA tayyorlanadi.
  ///
  /// 64 MiB — 1.5 GB / 90 daqiqalik faylda bu ~4 daqiqalik zaxira,
  /// ya'ni keyingi oyna foydalanuvchi u yerga yetguncha allaqachon
  /// tayyor bo'ladi.
  static const int _prefetchMarginBytes = 64 * 1024 * 1024;

  /// Oyna tayyor bo'lishini eng ko'pi shuncha kutamiz.
  static const Duration _windowWaitMax = Duration(seconds: 120);

  /// Keyingi oynani oldindan tayyorlab turuvchi taymer.
  Timer? _windowTimer;

  /// Hozir oyna keshga olinishi kutilyaptimi (ekranda yozuv
  /// ko'rsatiladi). Pleyerga bu paytda TEGILMAYDI — bufer
  /// joyida qoladi.
  bool _windowWaiting = false;

  /// Ayni paytda nechta kutish ketyapti. Foydalanuvchi kutish
  /// davomida yana sek qilsa, ikkita kutish yonma-yon ketishi
  /// mumkin — sanoqsiz bo'lsa, birinchisi tugagach ekrandagi
  /// yozuv ikkinchisi hali kutayotgan bo'lsa ham yo'qolib qolardi.
  int _windowWaiters = 0;

  /// Qisqa muddatli xabar (masalan "bu joy hali tayyor emas").
  String? _notice;
  Timer? _noticeTimer;

  // ── Ikki marta bosib sek qilishda tarmoqqa yuboriladigan seekTo
  // so'rovini debounce qilish uchun: tez-tez ketma-ket bosilganda
  // faqat OXIRGI holatga BITTA marta sek qilinadi.


  bool _isFullscreen = false;
  bool _showControls = true;
  Timer? _hideTimer;
  double _playbackSpeed = 1.0;
  bool _speedPanelOpen = false;
  bool _qualityPanelOpen = false;
  bool _episodeListOpen = false;
  bool _isLocked = false;
  bool _settingsPanelOpen = false;

  // ── UXLASH VAQTI (Sleep Timer) ──────────────────────────────
  //
  // Tanlangan muddat (daqiqa). 0 — o'chirilgan.
  int _sleepMinutes = 0;
  // Qolgan vaqt (soniya). Sanoq `_sleepTickTimer` da yuritiladi.
  int _sleepSecondsLeft = 0;
  Timer? _sleepTickTimer;
  bool _sleepPanelOpen = false;
  bool _sleepCustomInput = false;
  String _sleepCustomValue = '';

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
    // Kadr yasovchilar SHU PAYTDA tarmoqqa chiqmasin: ijro
    // birinchi o'rinda (`video_gate.dart` izohiga qarang).
    VideoGate.enter();
    // Pleyer sozlamalari (intro avtomatik o'tkazilsinmi) —
    // diskdan, tarmoqsiz.
    AppSettings.instance.load();
    WidgetsBinding.instance.addObserver(this);
    // Tartib (foydalanuvchi talabi): Ma'lumot | Qismlar | Bo'limlar,
    // va ochilganda MA'LUMOT oynasi turadi.
    _tabCtrl = TabController(length: 4, vsync: this);
    _tabPages = PageController();

    // Holat serverdan bir marta yangilanadi: odam boshqa
    // qurilmada obuna olgan bo'lsa shu yerda darhol bilinadi.
    unawaited(BillingService.instance.load(force: true));
    if (BillingService.instance.active) {
      _startLoading();
    } else {
      // Obuna SHU EKRANDA turib olinishi mumkin ("Obuna olish"
      // tugmasi). O'sha payt yuklashni boshlash kerak — aks holda
      // pleyer ochiladi-yu, qismlar ro'yxati bo'sh qolardi.
      BillingService.instance.addListener(_onBillingChanged);
    }
  }

  /// Qismlar, bo'limlar va bo'lim ma'lumoti — BIR MARTA.
  bool _loadingStarted = false;

  void _startLoading() {
    if (_loadingStarted) return;
    _loadingStarted = true;
    _watchConnectivity();
    _loadEpisodes();
    _loadSeasons();
    _loadSeasonInfo();
  }

  void _onBillingChanged() {
    if (!mounted || !BillingService.instance.active) return;
    BillingService.instance.removeListener(_onBillingChanged);
    // Xabar KADR CHIZILAYOTGAN paytda kelishi mumkin. Yuklash esa
    // `setState` chaqiradi — shu sabab kadr tugagach boshlanadi.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startLoading();
    });
  }


  // ══════════════════════════════════════════════════════════
  //  OYNALAR ORASIDA O'TISH
  // ══════════════════════════════════════════════════════════
  //
  // TOPILGAN XATO (foydalanuvchi: "Ma'lumot oynasidan Bo'limlar
  // oynasiga bittada o'tib bo'lmayapti").
  //
  // SABAB: `animateToPage` uzoq oynaga o'tishda ORADAGI oynadan
  // sirg'alib o'tadi va o'sha payt `onPageChanged(1)` ishlaydi.
  // U esa tab tugmasini ORQAGA, 1-oynaga qaytarardi. Natijada
  // bosilgan tugma bilan ko'rinayotgan oyna bir-biriga zid bo'lib
  // qolar va o'tish "ishlamagandek" tuyulardi.
  //
  // Endi ikki narsa qilinadi:
  //   * qo'shni bo'lmagan oynaga `jumpTo` bilan TO'G'RIDAN o'tiladi
  //     (oradagi oyna umuman ko'rsatilmaydi — tezroq ham);
  //   * o'tish davomida `onPageChanged` tab tugmasiga TEGMAYDI.
  bool _tabJumping = false;

  void _goToTab(int i) {
    if (!_tabPages.hasClients) return;
    final cur = (_tabPages.page ?? _tabPages.initialPage.toDouble()).round();
    if (cur == i) return;

    // ── TUGMA BOSILGANDA SUZISH YO'Q ──────────────────────────
    //
    // TOPILGAN XATO (foydalanuvchi: "pleyer tagidagi oynalarga
    // qo'lda bosib va surib o'tkazishda sekin va qotish
    // bo'lyapti").
    //
    // Suzish davomida PageView oradagi oynani ham chizishi kerak,
    // ya'ni bitta o'tishda IKKI-UCH oynaning ro'yxati bir vaqtda
    // ekranda bo'ladi. Qismlar va bo'limlar ro'yxatida rasm bor —
    // kuchsiz telefonda bu aniq kadr tashlashga olib keladi.
    //
    // `jumpToPage` esa DARHOL o'tadi: oradagi oyna umuman
    // chizilmaydi va chizadigan ish qolmaydi. Tugma bosilganda
    // sahifa shu zahoti almashadi — bu "qotish" emas, tezlik.
    _tabJumping = true;
    _tabPages.jumpToPage(i);
    _tabJumping = false;
  }

  /// Izohlar — pleyer ochilganda BIR MARTA yaratiladi.
  ///
  /// NEGA `initState` DA, `build` DA EMAS: `build` har kadrda
  /// ishlaydi va u yerda nazoratchini almashtirish (eskisini
  /// `dispose` qilib yangisini yasash) oynani O'CHIRILGAN
  /// nazoratchiga bog'lab qo'yishi mumkin edi.
  ///
  /// Bo'lim bu ekran ichida almashmaydi — boshqa bo'lim tanlansa
  /// YANGI pleyer ochiladi (`_buildSeasonsTab`), ya'ni nazoratchi
  /// ham yangisi bo'ladi.
  bool _commentsMade = false;
  late final CommentsController _comments = () {
    _commentsMade = true;
    return CommentsController(
      animeId: _seasonNum('anime_id'),
      seasonId: _seasonNum('season_id'),
    );
  }();

  // ── IZOHLAR BUTUN EKRANGA ────────────────────────────────
  //
  // TALAB (foydalanuvchi): "foydalanuvchi izohlarni yuqoriga
  // sursa, ya'ni pastdagi izohlarni o'qish uchun, izoh oynasi
  // butun ekranga kattalashsin".
  //
  // Izohlarga pleyer ostidan atigi bir necha qator joy tegadi.
  // Ro'yxat surilishi bilan tepadagi hamma narsa (sarlavha,
  // video, tablar, qism o'tkazish) YIG'ILADI.
  //
  // MUHIM: yig'ilgan qism daraxtdan OLIB TASHLANMAYDI, balki
  // bo'yi nolga tushiriladi (`AnimatedAlign(heightFactor: 0)` va
  // `ClipRect`). Olib tashlansa pleyer qayta qurilib, ko'rilayotgan
  // video to'xtab qolardi — ovozi ham uzilardi.
  bool _commentsExpanded = false;

  void _setCommentsExpanded(bool v) {
    if (_commentsExpanded == v) return;
    setState(() => _commentsExpanded = v);
  }

  Widget _buildCommentsTab() => CommentsTab(
        controller: _comments,
        expanded: _commentsExpanded,
        onExpanded: _setCommentsExpanded,
      );

  @override
  void dispose() {
    VideoGate.leave();
    BillingService.instance.removeListener(_onBillingChanged);
    // `late final` — Izohlar oynasi umuman ochilmagan bo'lsa
    // nazoratchi yaratilmagan ham bo'ladi.
    if (_commentsMade) _comments.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // Tarixga BITTA so'rov aynan shu yerda ketadi. Javob
    // kutilmaydi: ekran allaqachon yopilyapti, yozuv esa
    // yuborilmasa navbatga tushadi va keyin o'zi yuboriladi.
    unawaited(WatchHistory.instance.flush());
    _connSub?.cancel();
    // Surish o'rtasida ekran yopilsa, to'xtatish osilib qolmasin.
    _releaseDownloadUpdates();
    _epScrollCtrl.dispose();
    _epListCtrl?.dispose();
    _thinBarTimer?.cancel();
    DownloadManager.instance.unwatch(this);
    _tabPages.dispose();
    _tabCtrl.dispose();
    _hideTimer?.cancel();
    _sleepTickTimer?.cancel();
    _leftSeekHideTimer?.cancel();
    _rightSeekHideTimer?.cancel();
    _seekIdleTimer?.cancel();
    _pendingSingleTapTimer?.cancel();
    _healthTimer?.cancel();
    _windowTimer?.cancel();
    _noticeTimer?.cancel();
    _recoveryStreakResetTimer?.cancel();
    _restoreSystemUI();
    final c = _controller;
    _controller = null;
    c?.removeListener(_onControllerUpdate);
    c?.dispose();
    super.dispose();
  }

  /// Ilovani biz PAUZA qilganmizmi (foydalanuvchi emas).
  ///
  /// Shu bayroq bo'lmasa, fon'dan qaytganda foydalanuvchi ATAYLAB
  /// pauza qilib qo'ygan video ham o'z-o'zidan ijro bo'lib
  /// ketardi.
  bool _pausedByLifecycle = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ── BILDIRISHNOMA PARDASI PAUZA QILMAYDI ─────────────────
    //
    // TOPILGAN XATO (foydalanuvchi: "telefonning yuqoridagi
    // internet va boshqa narsalarni yoqib o'chiradigan oynasini
    // tushirsa video pauza bo'lyapti, agar ko'tarsa yana play
    // bo'lib ketsin").
    //
    // Sabab: bu yerda `inactive` ham `paused` bilan bir qatorda
    // turardi. Android pardani tushirganda `inactive` yuboradi —
    // ilova esa FONGA KETMAYDI, video ko'rinib turaveradi.
    // Xuddi shu holat qo'ng'iroq oynasi va tizim dialoglarida ham
    // bo'ladi.
    //
    // Endi:
    //   * `inactive`          -> tegilmaydi (parda, dialog);
    //   * `paused`/`hidden`   -> pauza qilinadi va ESLAB QOLINADI;
    //   * `resumed`           -> biz pauza qilgan bo'lsak qaytadi.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      final c = _controller;
      if (c != null && c.value.isPlaying) {
        _pausedByLifecycle = true;
        c.pause();
      }
      // Ilova fonda o'chib ketishi mumkin — tarix yozuvi
      // yo'qolmasin.
      unawaited(WatchHistory.instance.flush());
    } else if (state == AppLifecycleState.resumed) {
      if (!_pausedByLifecycle) return;
      _pausedByLifecycle = false;
      // Foydalanuvchi shu orada pauzani o'zi bosgan bo'lsa
      // tegilmaydi.
      if (!_intendedPlaying) return;
      _controller?.play();
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
      _autoOpenEpisode();
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
          _adoptFreshEpisode();
          _syncWatchedUrls();
          _autoOpenEpisode();
        }
        return;
      }
    } catch (_) {
      // Tarmoq yo'q/xato — keshdagi ro'yxat (agar bo'lsa) saqlanib qoladi.
    }
    if (mounted && _loadingEps) setState(() => _loadingEps = false);
  }

  /// ── OCHILGAN QISM YANGI RO'YXATDAN QAYTA OLINADI ───────────
  ///
  /// TOPILGAN XATO (foydalanuvchi: "pleyerda intro chiqmayapti").
  ///
  /// Pleyer qismlar ro'yxatini AVVAL diskdagi keshdan o'qiydi va
  /// darhol qism ochadi. Keyin serverdan yangi ro'yxat keladi va
  /// `_episodes` almashtiriladi — LEKIN `_currentEp` eski (kesh)
  /// obyekt bo'lib qolardi.
  ///
  /// Ya'ni admin qismga endi qo'shgan intro vaqtlari ochiq qismda
  /// KO'RINMASDI: ular faqat yangi ro'yxatda bor edi, pleyer esa
  /// eskisiga qarab turardi. Xuddi shu narsa yangi qo'shilgan
  /// sifat yoki o'zgargan nom uchun ham amal qilardi.
  ///
  /// Shu sabab yangi ro'yxat kelganda ochiq qism AYNAN o'sha
  /// qismning yangi qatori bilan almashtiriladi (`epizod_id`
  /// bo'yicha) va intro oraliqlari qaytadan o'qiladi.
  void _adoptFreshEpisode() {
    final cur = _currentEp;
    if (cur == null) return;
    final id = _epIdOf(cur);
    if (id <= 0) return;
    for (final e in _episodes) {
      if (_epIdOf(e) != id) continue;
      _currentEp = e;
      _introRanges = introRangesOf(e);
      // Hozir qaysi oraliqdaligi endi boshqacha bo'lishi mumkin.
      _introIndex = -1;
      _introTries.clear();
      return;
    }
  }

  /// Bo'lim ma'lumoti — BITTA so'rov.
  Future<void> _loadSeasonInfo() async {
    final aid = int.tryParse(widget.season['anime_id']?.toString() ?? '') ?? 0;
    final sid = int.tryParse(widget.season['season_id']?.toString() ?? '') ?? 0;
    if (aid <= 0) return;
    // ── AVVAL DISKDAGI NUSXA ────────────────────────────────
    //
    // TOPILGAN XATO: oflaynda "Ma'lumot" oynasi bo'sh turardi.
    // Endi diskdagi nusxa DARHOL ko'rsatiladi (tarmoq kutilmaydi),
    // internet bo'lsa esa bir necha soniyadan keyin yangisi
    // ustidan yoziladi.
    final cached = SeasonService.fromDisk(aid, sid);
    if (cached != null && mounted) setState(() => _info = cached);

    final info = await SeasonService.load(aid, sid);
    if (!mounted || info == null) return;
    setState(() => _info = info);
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
      final firstTime = !_connectivityKnown;
      _connectivityKnown = true;
      if (off == _offline) {
        // Birinchi tekshiruv: ro'yxat allaqachon kelgan bo'lishi
        // mumkin, ya'ni avtomatik ochish shu yerda boshlanadi.
        if (firstTime) _autoOpenEpisode();
        return;
      }
      if (mounted) setState(() => _offline = off);
      // Oflayn'da BARCHA qismlarning holati kerak (qaysi biri to'liq
      // yuklanganini bilish uchun), onlayn'da esa faqat ekrandagilar.
      _syncWatchedUrls();
      if (firstTime) {
        _autoOpenEpisode();
      }
      if (off) {
        _onNetworkLost();
      } else {
        _onNetworkBack();
      }
    }

    try {
      apply(await Connectivity().checkConnectivity());
    } catch (_) {
      // Tekshiruv ishlamadi — ONLAYN deb hisoblaymiz va qismni
      // ochaveramiz. Aks holda qism avtomatik ochilishi butunlay
      // to'xtab qolardi: `_autoOpenEpisode` ulanish holati
      // ma'lum bo'lishini kutadi, holat esa endi hech qachon
      // kelmasdi.
      _connectivityKnown = true;
      _autoOpenEpisode();
    }
    _connSub = Connectivity().onConnectivityChanged.listen(apply);
  }

  // ═══════════════════════════════════════════════════════════
  //  INTERNET UZILDI / QAYTDI
  // ═══════════════════════════════════════════════════════════
  //
  // TUZATILGAN XATO (foydalanuvchi ko'rgan): onlayn ko'rayotganda
  // internet uzilsa pleyer xatoga chiqar, ilova uni bir necha marta
  // qaytadan ochishga urinar va "Videoni ijro etib bo'lmadi
  // (takroriy xato)" deb BUTUNLAY taslim bo'lardi. Internet qaytsa
  // ham hech narsa bo'lmasdi — foydalanuvchi ilovani yopib qayta
  // ochishga majbur edi.
  //
  // Endi:
  //   * internet uzilganda pleyer O'LDIRILMAYDI, faqat ekranda
  //     xabar chiqadi va joriy nuqta eslab qolinadi;
  //   * internet QAYTGANDA video AYNAN O'SHA nuqtadan avtomatik
  //     davom etadi;
  //   * "taslim bo'lish" hisoblagichi nolga tushadi — internetning
  //     yo'qligi pleyerning nosozligi EMAS.

  // ═══════════════════════════════════════════════════════════
  //  MANBA KUZATUVCHISI: MAHALLIY <-> WORKER
  // ═══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi):
  //   * video ko'rilayotganda fayl TO'LIQ yuklab olinsa — AYNAN
  //     o'sha joydan mahalliy server orqali davom etsin;
  //   * mahalliy ko'rish paytida fayl O'CHIRILSA — kelib qolgan
  //     joydan tezda workerga ulanib, onlayn davom etsin.
  //
  // Ilgari manba FAQAT BIR MARTA, video ochilganda tanlanar va
  // keyin o'zgarmasdi. Shu sabab yuklab olish tugasa ham video
  // worker orqali ketaverar, internet uzilganda esa xatoga chiqib
  // boshidan boshlanardi.
  //
  // Tekshiruv ARZON: avval xotiradagi hisob (ishora) ko'riladi va
  // faqat u O'ZGARGANDA diskdan aniq javob so'raladi.

  /// Ayni paytda manba almashtirilyaptimi.
  bool _switchingSource = false;

  /// Oxirgi ko'rilgan "to'liq yuklangan" ishorasi.
  bool? _lastCompleteHint;

  void _checkSourceSwitch() {
    final ep = _currentEp;
    final c = _controller;
    if (ep == null ||
        c == null ||
        _switchingSource ||
        _recovering ||
        _handlingError ||
        _windowWaiting) {
      return;
    }
    if (!c.value.isInitialized) return;
    final url = _currentUrl;
    if (url.isEmpty) return;

    final hint = DownloadManager.instance.statOf(url).complete;
    if (hint == _lastCompleteHint) return;
    _lastCompleteHint = hint;
    if (hint == _playViaLocal) return;

    // Ishora o'zgardi — endi DISKDAN aniq javob (bu qimmatroq, shu
    // sabab faqat shu yerda chaqiriladi).
    final real = _isFullyDownloaded(url);
    if (real == _playViaLocal) return;

    _switchingSource = true;
    final at = c.value.position;
    VideoCacheServer.log(real
        ? 'Fayl to\'liq yuklandi — mahalliy serverga o\'tilmoqda (${at.inSeconds}s)'
        : 'Fayl o\'chirildi — workerga o\'tilmoqda (${at.inSeconds}s)');
    _showNotice(real
        ? 'Yuklab olindi — endi telefondan ko\'rsatilmoqda'
        : 'Fayl o\'chirildi — onlayn davom etilmoqda');
    _playEpisode(ep,
            resumeAt: at,
            resumePlaying: _intendedPlaying,
            isRecovery: true)
        .whenComplete(() => _switchingSource = false);
  }

  void _onNetworkLost() {
    // Mahalliy (to'liq yuklab olingan) ijroga internetning aloqasi
    // yo'q — u tarmoqqa umuman chiqmaydi.
    if (_playViaLocal || _currentEp == null) return;
    _showNotice('Internet yo\'q — ulanish qaytishi kutilmoqda');
  }

  void _onNetworkBack() {
    final ep = _currentEp;
    if (ep == null || _playViaLocal) return;
    // Internet yo'qligi sabab yig'ilgan "takroriy xato" hisobi
    // bekor qilinadi.
    _recoveryStreakResetTimer?.cancel();
    _recoveryStreak = 0;
    _lastRecovery = DateTime.fromMillisecondsSinceEpoch(0);

    final c = _controller;
    final broken = _playerError != null || c == null || c.value.hasError;
    if (!broken) {
      // Pleyer sog'lom — hech narsaga tegmaymiz (bufer joyida).
      return;
    }
    final at = _lastGoodPosition;
    VideoCacheServer.log(
        'Internet qaytdi — video ${at.inSeconds}s dan davom ettirilmoqda');
    if (mounted) {
      setState(() {
        _playerError = null;
        _playerLoading = true;
      });
    }
    _playEpisode(ep, resumeAt: at, resumePlaying: true, isRecovery: true);
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

  /// ── OXIRGI KO'RILGAN SIFATDAN DAVOM ETISH ─────────────────
  ///
  /// TALAB (foydalanuvchi): "jurnalga oxirgi marta foydalanuvchi
  /// qaysi sifatni ko'rgani ham yozib qo'yilsin va keyingi safar
  /// internetni yoqib videoni ko'rganida aynan o'sha sifatdan
  /// davom etishi kerak".
  ///
  /// Sifat tomosha tarixida (`last_quality`) saqlanadi, ya'ni u
  /// ilova qayta o'rnatilganda ham, boshqa telefonda ham o'sha
  /// odam uchun bir xil bo'ladi.
  ///
  /// Foydalanuvchi shu seansda sifatni qo'lda tanlagan bo'lsa
  /// TEGILMAYDI — uning tanlovi ustunroq.
  void _restoreQuality(Map<String, dynamic> ep) {
    if (_qualityChosenByUser) return;
    final animeId = int.tryParse(widget.season['anime_id']?.toString() ?? '');
    final seasonId = int.tryParse(widget.season['season_id']?.toString() ?? '');
    if (animeId == null || seasonId == null) return;
    final saved =
        WatchHistory.instance.qualityOf(animeId, seasonId, _epIdOf(ep));
    if (saved.isEmpty || saved == _selectedQuality) return;
    // Shu qismda o'sha sifat bormi (bo'lmasa tegmaymiz).
    final url = (ep['url_$saved'] ?? '').toString();
    if (url.isEmpty) return;
    // Oflaynda faqat to'liq yuklangan sifat ochiladi.
    if (_offline && !_isComplete(url)) return;
    _selectedQuality = saved;
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
    _restoreQuality(ep);
    final url = _getUrl(ep);
    if (url.isEmpty) return;

    // ── QAYERDA TO'XTAGAN BO'LSA — O'SHA JOYDAN ──────────────
    // Sifat almashtirilganda yoki pleyer qayta ochilganda nuqta
    // chaqiruvchidan keladi; oddiy ochilishda esa eslab qolingan
    // nuqta ishlatiladi (`WatchProgress`).
    final startAt =
        resumeAt ?? (isRecovery ? null : WatchProgress.instance.positionOf(url));

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

    // ── TOMOSHA TARIXI ────────────────────────────────────────
    //
    // Bu yerda serverga HECH NARSA yuborilmaydi — faqat "hozir shu
    // qism ochildi" deb xotirada belgilanadi. Serverga bitta so'rov
    // pleyerdan chiqilganda (yoki qism almashganda) ketadi:
    // `WatchHistory.flush()`.
    //
    // Nom va rasmlar ham beriladi: ular tarix ro'yxatini DARHOL
    // (internetsiz ham) to'g'ri ko'rsatish uchun kerak.
    WatchHistory.instance.startEpisode(
      animeId: int.tryParse(widget.season['anime_id']?.toString() ?? '') ?? 0,
      seasonId: int.tryParse(widget.season['season_id']?.toString() ?? '') ?? 0,
      bolimId: int.tryParse(widget.season['bolim_id']?.toString() ?? '') ?? 0,
      epizodId: _epIdOf(ep),
      epizodNumber: _epNumOf(ep),
      // Oxirgi ko'rilgan sifat — keyingi safar shundan davom etadi.
      quality: _qualityOfUrl(ep, url),
      seasonName: (widget.season['nomi'] ?? '').toString(),
      animeName: (widget.season['anime_name'] ?? '').toString(),
      seasonPhoto: (widget.season['photo_url'] ?? '').toString(),
      videoUrl: url,
    );

    // Yangi qism — intro oraliqlari qaytadan o'qiladi.
    //
    // MUHIM: urinishlar hisobi ham TOZALANADI. Ilgari u qolib
    // ketardi va avto o'tkazish faqat BIRINCHI qismda ishlardi
    // (`_introTries` izohiga qarang).
    _introIndex = -1;
    _introTries.clear();
    _lastIntroSkip = DateTime.fromMillisecondsSinceEpoch(0);
    _introRanges = introRangesOf(ep);

    setState(() {
      _currentEp = ep;
      _currentUrl = url;
      _showControls = true;
      _playerLoading = true;
      _preparing = false;
      _playerError = null;
      _intendedPlaying = resumePlaying;
      _introVisible = false;
    });
    _syncThinBar();

    // Sek navbatini tozalaymiz — eski epizodga tegishli so'rovlar
    // yangisiga tushib qolmasligi kerak.
    _seekIdleTimer?.cancel();
    _pendingTarget = null;
    _queuedSeek = null;
    _seekBusy = false;
    _healthTimer?.cancel();
    _windowTimer?.cancel();
    _watchTickPos = null;
    _windowWaiters = 0;
    _windowWaiting = false;
    _lastCompleteHint = null;

    // ── ESKI CONTROLLERNI XAVFSIZ YOPISH ─────────────────────
    // Tartib muhim: avval uni daraxtdan olib tashlaymiz (setState),
    // BIR KADR kutamiz (video vidjeti haqiqatan yo'q bo'lsin), keyin
    // dispose qilamiz. `dispose()` dan keyin controllerga murojaat
    // qilinmaydi — plagin o'zi ham buni e'tiborsiz qoldiradi
    // ("after dispose all further calls are ignored"), ya'ni bu yerda
    // native halokat xavfi YO'Q.
    final old = _controller;
    if (old != null) {
      // Eski qismning "qayerda to'xtagan" nuqtasi yo'qolmasin.
      if (old.value.isInitialized && _lastPlayedUrl.isNotEmpty) {
        WatchProgress.instance
            .save(_lastPlayedUrl, old.value.position, old.value.duration);
        WatchProgress.instance.flush();
      }
      setState(() => _controller = null);
      await WidgetsBinding.instance.endOfFrame;
      // ── YOPISH KUTILMAYDI ─────────────────────────────────
      // Eski pleyerni yopish (ExoPlayer + platform view) bir necha
      // yuz millisekund olishi mumkin. Uni KUTIB o'tirish yangi
      // videoning ochilishini shuncha kechiktirardi. U allaqachon
      // ekrandan olib tashlangan, shu sabab yopilishini fon'da
      // qoldiramiz.
      () async {
        try {
          await old.pause();
        } catch (_) {}
        try {
          await old.dispose();
        } catch (_) {}
      }();
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
    _currentSource = source.toString();
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
    if (!_playViaLocal && RustCore.instance.videoWindowSeen(url, 0)) {
      // ── TEZ YO'L: BO'LAK AVVAL KESHDA KO'RILGAN ─────────────
      //
      // TUZATILGAN XATO (foydalanuvchi: "video keshda bo'lsa ham
      // sekin ochilyapti"): ilova HAR SAFAR isitish so'rovini
      // yuborib, javobini KUTARDI — hatto kesh allaqachon tayyor
      // bo'lganda ham. O'lchandi: bunday "bo'sh" so'rov
      // data-markazdan 0.26-0.63 s, telefonda mobil tarmoqda esa
      // 1-3 s. `/api/play` ning o'zi atigi 0.3 s.
      //
      // Endi bo'lak avval keshda ko'rilgan bo'lsa (diskdagi belgi)
      // pleyer DARHOL ochiladi, isitish esa fon'da ishga tushadi
      // (kesh o'chgan bo'lsa keyingi safar tayyor bo'lsin).
      //
      // Kesh kutilmaganda o'chirilgan bo'lsa pleyer xatoga chiqadi
      // va odatdagi tiklanish yo'li (`_handleFatalError`) oynani
      // isitib, AYNAN O'SHA joydan qayta ochadi.
      RustCore.instance.videoPrepare(url);
      VideoCacheServer.log('Tez yo\'l: bo\'lak keshda ko\'rilgan — kutilmaydi');
    } else if (!_playViaLocal) {
      prepared = await _prepareSource(url, myToken);
      if (!mounted || myToken != _playToken) return;
      // Isitish ANIQ yiqilgan bo'lsa — MAJBURAN bir marta qayta
      // urinamiz (worker'ning eskirgan kesh yozuvi va o'lib qolgan
      // isitish belgisi e'tiborsiz qoldiriladi).
      //
      // Kutish muddati tugagan bo'lsa esa MAJBURLAMAYMIZ: isitish
      // odatda hali DAVOM ETAYOTGAN bo'ladi va uni qaytadan
      // boshlash manbadan 480 MiB'ni ikkinchi marta o'qishga
      // majbur qilardi (bekorga xarajat). Bunday holatda ekranda
      // "Qayta urinish" tugmasi ko'rsatiladi — qaror foydalanuvchida
      // qoladi va u kutgan sari isitish baribir davom etaveradi.
      if (!prepared && _prepareFailedHard) {
        prepared = await _prepareAgain(url, myToken);
        if (!mounted || myToken != _playToken) return;
      }
      if (!prepared) {
        // Pleyerni ochish behuda: 503 keladi. Foydalanuvchiga
        // ANIQ sabab ko'rsatamiz.
        setState(() {
          _playerLoading = false;
          _playerError = _prepareFailedHard
              ? 'Video keshga tayyorlanmadi — qayta urinib ko\'ring'
              : 'Video hali tayyorlanmoqda — biroz kutib, qayta urinib ko\'ring';
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
    if (ctrl == null && !_playViaLocal && !_offline && _openTimedOut) {
      // Tarmoq shunchaki sekin — isitmasdan yana bir marta ochamiz.
      if (!mounted || myToken != _playToken) return;
      VideoCacheServer.log('Ochilish vaqti tugadi — qayta urinilmoqda...');
      ctrl = await _openController(source, myToken);
    }
    if (ctrl == null && !_playViaLocal && !_offline && !_openTimedOut) {
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
    _lastGoodPosition = startAt ?? Duration.zero;
    _handlingCompleted = false;
    _pendingEofAt = null;

    if (startAt != null && startAt > Duration.zero) {
      // ── TANBAL KESHLASH: DAVOM ETTIRILADIGAN JOY TAYYORMI ──
      //
      // Sifat almashtirilganda (yoki pleyer qayta ochilganda) video
      // 0-sekunddan emas, o'sha joydan boshlanadi. O'sha joy esa
      // videoning IKKINCHI yoki UCHINCHI bo'lagida bo'lishi mumkin —
      // u hali keshda bo'lmasa pleyer darhol xatoga chiqardi.
      // Shu sabab avval o'sha bo'lak tayyorlanadi.
      _refreshTotalBytes();
      await _ensureWindowFor(startAt, ctrl.value.duration);
      if (!mounted || myToken != _playToken) {
        try {
          await ctrl.dispose();
        } catch (_) {}
        return;
      }
      try {
        await ctrl.seekTo(startAt);
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
    // Oxirgi tekshiruv: kutish davomida ekran yopilgan yoki
    // foydalanuvchi boshqa qismni bosgan bo'lishi mumkin. Bunday
    // holatda yangi controller ekranga QO'YILMAYDI va darhol
    // yopiladi — aks holda u xotirada osilib qolardi.
    if (!mounted || myToken != _playToken) {
      try {
        await ctrl.dispose();
      } catch (_) {}
      return;
    }

    ctrl.addListener(_onControllerUpdate);
    setState(() {
      _controller = ctrl;
      _playerLoading = false;
    });
    // Progress chizig'idagi "yuklab olingan" qism shu videoni kuzata
    // boshlaydi.
    _lastPlayedUrl = _currentUrl;
    _syncWatchedUrls();
    _startHealthWatchdog();
    // Hajm endi ma'lum (isitish javobidan meta.json'ga yozilgan) —
    // shu bilan oyna chegaralari hisoblanadi va keyingi oyna
    // oldindan tayyorlanadi.
    _refreshTotalBytes();
    _startWindowPrefetch();
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
    // ── FAQAT DISK — XOTIRADAGI HISOBGA ISHONMAYMIZ ──────────
    //
    // TUZATILGAN XATO (foydalanuvchi ko'rgan): ilgari bu yerda
    // avval ekrandagi hisob (`DownloadManager.statOf`) so'ralardi.
    // U esa har 0.5-5 soniyada yangilanadi, ya'ni videoni
    // O'CHIRGANDAN keyin ham bir necha soniya "to'liq" deb turardi.
    // Pleyer shunga ishonib MAHALLIY serverga borar, u yerda fayl
    // yo'q bo'lgani uchun butun video QAYTADAN yuklab olinardi —
    // foydalanuvchi "yuklab olishni bosmasam ham o'zi yuklab
    // olyapti" deb ko'rgan holat aynan shu edi.
    //
    // Endi javob YAGONA ishonchli manbadan — diskni skanerlashdan
    // olinadi. Chaqiruv faqat video ochilganda bo'lgani uchun
    // ro'yxatning silliqligiga ta'siri yo'q.
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
  ///
  /// 100 -> 150 soniya: server boshqa birov isitayotganini ko'rsa
  /// uni 110 soniyagacha kutadi. Ilova undan OLDIN taslim bo'lsa,
  /// keyingi urinish isitishni MAJBURAN qaytadan boshlar va o'sha
  /// 480 MiB manbadan IKKINCHI marta o'qilardi — bu esa bekorga
  /// xarajat. Endi ilova serverdan biroz uzoqroq kutadi.
  static const Duration _prepareMax = Duration(seconds: 150);

  /// Oxirgi tayyorlash ANIQ muvaffaqiyatsizlik bilan tugadimi
  /// (kutish muddati tugagani emas).
  ///
  /// MUHIM: majburan qayta isitish (`_prepareAgain`) manbadan
  /// 480 MiB'ni QAYTA o'qishga majbur qiladi. Shu sabab u FAQAT
  /// isitish haqiqatan yiqilganda chaqiriladi. Kutish muddati
  /// tugaganda esa isitish odatda hali DAVOM ETAYOTGAN bo'ladi —
  /// uni majburan qayta boshlash sof isrof bo'lardi.
  bool _prepareFailedHard = false;

  /// `true` — oyna keshda, pleyerni ochsa bo'ladi.
  Future<bool> _prepareSource(String url, int myToken) async {
    _prepareFailedHard = false;
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
          _prepareFailedHard = true;
          return false;
        }
        if (DateTime.now().difference(started) > _prepareMax) {
          VideoCacheServer.log(
              'Isitish ${_prepareMax.inSeconds} soniyada tugamadi');
          return false;
        }
        // 200 -> 60 ms: isitish tugagan lahzani tezroq ilg'aymiz.
        // Chaqiruv mahalliy (FFI), tarmoqqa chiqmaydi — arzon.
        await Future.delayed(const Duration(milliseconds: 60));
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
  /// `/api/image/<fayl>` -> `/api/play/<fayl>?t=<token>`.
  ///
  /// ── NEGA TOKEN ──────────────────────────────────────────
  ///
  /// Bu manzilni ExoPlayer'ning O'ZI ochadi
  /// (`VideoPlayerController.networkUrl`) va unga sarlavha
  /// qo'shib bo'lmaydi. Worker esa endi hamma yo'lni tekshiradi,
  /// ya'ni tokensiz so'rov 403 oladi va video ochilmaydi.
  ///
  /// Token AYNAN shu faylga bog'langan va 6 soat yashaydi — bitta
  /// ijro seansiga yetadi, lekin manzil abadiy ochiq qolmaydi.
  /// Oddiy so'rov imzosi bu yerda yaramaydi: u 2 daqiqada o'ladi,
  /// ExoPlayer esa butun ijro davomida oraliq so'rovlar yuboradi.
  ///
  /// Cloudflare keshiga ta'sir qilmaydi — worker kesh kalitini
  /// fayl nomidan quradi, so'rov qismidan emas.
  static String _workerPlayUrl(String url) {
    const mark = '/api/image/';
    final i = url.indexOf(mark);
    if (i < 0) return url;
    final name = url.substring(i + mark.length);
    // Token `nativeMediaUrl` da qo'shiladi — bitta joyda, ya'ni
    // yangi manzil qo'shilganda unutilmaydi.
    return nativeMediaUrl('${url.substring(0, i)}/api/play/$name');
  }

  // ═══════════════════════════════════════════════════════════
  //  OYNA HISOBI VA OLDINDAN TAYYORLASH
  // ═══════════════════════════════════════════════════════════

  /// Berilgan ijro nuqtasi faylning taxminan nechanchi baytiga
  /// to'g'ri keladi.
  ///
  /// Hisob oddiy nisbat bilan qilinadi (`bayt = hajm * poz / davomiylik`).
  /// Video o'zgaruvchan bitreytda bo'lsa bu ANIQ emas — lekin bizga
  /// aniqlik kerak emas: chegara 64 MiB zaxira bilan olinadi, ya'ni
  /// xato bir necha o'n megabaytga yetsa ham keyingi oyna baribir
  /// vaqtida tayyorlanadi.
  int _byteAt(Duration pos, Duration dur) {
    if (_totalBytes <= 0 || dur <= Duration.zero) return 0;
    final ms = dur.inMilliseconds;
    if (ms <= 0) return 0;
    var r = pos.inMilliseconds / ms;
    if (r < 0) r = 0;
    if (r > 1) r = 1;
    return (_totalBytes * r).floor();
  }

  /// Ijro nuqtasi qaysi oynada.
  int _windowAt(Duration pos, Duration dur) {
    if (_windowBytes <= 0) return 0;
    return _byteAt(pos, dur) ~/ _windowBytes;
  }

  /// Fayl bitta oynaga sig'adimi (u holda tanbal keshlashning o'zi
  /// kerak emas — hamma narsa allaqachon tayyor).
  bool get _singleWindow =>
      _playViaLocal || _totalBytes <= 0 || _totalBytes <= _windowBytes;

  /// Hajmni yadrodan yangilaydi (isitish javobidan meta.json'ga
  /// yozilgan bo'ladi — tarmoqqa chiqilmaydi).
  void _refreshTotalBytes() {
    if (_currentUrl.isEmpty) return;
    try {
      _windowBytes = RustCore.instance.videoWindowSize;
      final t = RustCore.instance.videoTotalBytes(_currentUrl);
      if (t > 0) _totalBytes = t;
    } catch (_) {}
  }

  /// ── KEYINGI OYNANI OLDINDAN TAYYORLASH ────────────────────
  ///
  /// Har 2 soniyada pleyerning BUFER UCHIGA qaraydi (ijro
  /// nuqtasiga emas — bufer har doim oldinda va aynan u
  /// serverdan bayt so'raydi). Bufer uchi oyna chegarasiga
  /// yaqinlashsa, keyingi oyna fon'da keshga olinadi.
  ///
  /// Chaqiruv juda arzon: Rust tomonida bitta HashMap tekshiruvi.
  /// Oyna allaqachon tayyor yoki tayyorlanayotgan bo'lsa manbaga
  /// BITTA HAM so'rov ketmaydi.
  void _startWindowPrefetch() {
    _windowTimer?.cancel();
    // Mahalliy (to'liq yuklab olingan) faylda oyna tushunchasining
    // o'zi yo'q — tarmoqqa umuman chiqilmaydi.
    if (_playViaLocal) return;
    _windowTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _playViaLocal) return;
      // Barmoq ekranda (oynalar surilmoqda) — UI oqimini band
      // qilmaymiz. Bir-ikki soniya kechikish sezilmaydi, kadr
      // tashlash esa darhol ko'rinadi.
      if (_gestureBusy) return;
      // Hajm hali noma'lum bo'lsa (isitish javobi kechikkan bo'lishi
      // mumkin) — uni qayta so'raymiz. Hajmsiz oyna chegarasini
      // hisoblab bo'lmaydi.
      if (_totalBytes <= 0) {
        _refreshTotalBytes();
        return;
      }
      if (_singleWindow) return;
      final c = _controller;
      if (c == null) return;
      final v = c.value;
      if (!v.isInitialized || v.duration <= Duration.zero) return;

      // Bufer uchi — pleyer serverdan qayergacha o'qib qo'ygani.
      var ahead = v.position;
      for (final r in v.buffered) {
        if (r.end > ahead) ahead = r.end;
      }
      final aheadBytes = _byteAt(ahead, v.duration);
      final w = aheadBytes ~/ _windowBytes;
      final boundary = (w + 1) * _windowBytes;
      if (boundary >= _totalBytes) return; // oxirgi oyna — davomi yo'q
      if (boundary - aheadBytes > _prefetchMarginBytes) return;
      if (RustCore.instance.videoWindowStatus(_currentUrl, w + 1) == 1) {
        return;
      }
      VideoCacheServer.log(
          'Keyingi bo\'lak oldindan tayyorlanmoqda: #${w + 1}');
      RustCore.instance.videoWarmWindow(_currentUrl, w + 1);
    });
  }

  /// ── SEK QILINADIGAN JOY TAYYORMI ──────────────────────────
  ///
  /// Foydalanuvchi hali keshlanmagan joyga sek qilsa, avval
  /// O'SHA oyna keshga olinadi va faqat keyin sek bajariladi.
  /// Shu sabab pleyer "keshda yo'q" xatosini HECH QACHON
  /// ko'rmaydi — bufer ham, ijro ham buzilmaydi.
  ///
  /// `true` — sek qilsa bo'ladi.
  Future<bool> _ensureWindowFor(Duration target, Duration dur) async {
    // Hajm noma'lum bo'lsa oyna raqamini hisoblab bo'lmaydi — avval
    // uni yadrodan so'raymiz (tarmoqqa chiqilmaydi).
    if (!_playViaLocal && _totalBytes <= 0) _refreshTotalBytes();
    if (_singleWindow) return true;
    final url = _currentUrl;
    if (url.isEmpty) return true;
    final w = _windowAt(target, dur);
    if (RustCore.instance.videoWindowStatus(url, w) == 1) return true;
    // Internet yo'q — kutishning ma'nosi yo'q (2 daqiqa bekorga
    // aylanma halqa ko'rsatilardi).
    if (_offline) return false;

    VideoCacheServer.log('Sek: #$w bo\'lak hali keshda yo\'q — olinmoqda');
    RustCore.instance.videoWarmWindow(url, w);
    _windowWaiters++;
    if (mounted && !_windowWaiting) setState(() => _windowWaiting = true);
    final started = DateTime.now();
    var lastRetry = started;
    try {
      while (mounted && _currentUrl == url) {
        final st = RustCore.instance.videoWindowStatus(url, w);
        if (st == 1) return true;
        final now = DateTime.now();
        if (now.difference(started) > _windowWaitMax) break;
        // Muvaffaqiyatsiz tugagan bo'lsa vaqti-vaqti bilan qayta
        // urinamiz (Rust tomonining o'z tanaffusi bor, ya'ni
        // manbaga so'rovlar bo'roni ketmaydi).
        if (st == 2 && now.difference(lastRetry).inSeconds >= 5) {
          lastRetry = now;
          RustCore.instance.videoWarmWindow(url, w);
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      if (_windowWaiters > 0) _windowWaiters--;
      if (mounted && _windowWaiters == 0 && _windowWaiting) {
        setState(() => _windowWaiting = false);
      }
    }
    return RustCore.instance.videoWindowStatus(url, w) == 1;
  }

  /// Ekranda 3 soniya turadigan qisqa xabar.
  void _showNotice(String text) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _notice = null);
    });
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
    // ── TRAFIK ENDI SARLAVHA BILAN SANALMAYDI ────────────────
    //
    // Ilgari bu yerda `X-U` sarlavhasi qo'yilar, worker esa javob
    // tanasini sanovchi quvurdan o'tkazardi. Hisob noto'g'ri
    // chiqdi va ba'zan ijro "yuklanmadi" xatosiga yiqildi. Endi
    // so'rov TOZA ketadi, trafikni esa ilovaning o'zi sanaydi
    // (`lib/services/traffic_service.dart`).
    final ctrl = VideoPlayerController.networkUrl(
      uri,
      viewType: VideoViewType.platformView,
      videoPlayerOptions: VideoPlayerOptions(
        // ── NEGA `true`, GARCHI FONDA IJRO KERAK BO'LMASA HAM ──
        //
        // `false` bo'lganda plagin ijroni ilovaning hayot-sikliga
        // qarab O'ZI to'xtatadi. Bu tizim PiP oynasini buzardi:
        // PiP'da Android ilovani "paused" deb belgilaydi (oyna
        // ko'rinib tursa ham), plagin esa videoni to'xtatib
        // qo'yardi — kichik oyna qotgan kadr bo'lib qolardi.
        //
        // Endi to'xtatishni ILOVANING O'ZI boshqaradi
        // (`didChangeAppLifecycleState`): u haqiqatan fonga
        // ketganda to'xtatadi, PiP'da esa tegmaydi. Ya'ni fonda
        // ijro baribir bo'lmaydi — nazorat bir joyga yig'ildi.
        allowBackgroundPlayback: true,
        mixWithOthers: false,
      ),
    );
    _openTimedOut = false;
    try {
      // ── 40 SONIYA (ilgari 25) ─────────────────────────────
      //
      // TOPILGAN XATO (foydalanuvchi: "pleyer sekin ochilyapti va
      // ba'zida ochilmay qolyapti"). Sekin mobil tarmoqda
      // ExoPlayer'ga birinchi kadrlarni yig'ish uchun 25 soniya
      // yetmasdi: deyarli tayyor pleyer yopib tashlanar, keyin esa
      // kesh oynasi MAJBURAN qaytadan isitilardi (150 soniyagacha)
      // — video umuman ochilmay qolardi. Yozishmadagi video ham
      // 40 soniya kutadi.
      await ctrl.initialize().timeout(const Duration(seconds: 40));
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
      _openTimedOut = e is TimeoutException;
      try {
        await ctrl.dispose();
      } catch (_) {}
      return null;
    }
  }

  /// Oxirgi ochilish XATO bilan emas, VAQT tugagani bilan
  /// yiqildimi. Bunday holatda kesh oynasi joyida — uni qaytadan
  /// isitish (manbadan 480 MiB) behuda va juda uzoq.
  bool _openTimedOut = false;

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
      _handleFatalError(c.value.position);
      return;
    }
    final v = c.value;
    if (v.isCompleted) {
      _onCompleted(c);
    } else if (v.isInitialized) {
      _lastGoodPosition = v.position;
      _updateIntro(v.position);
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
      // ── HAQIQIY OXIR: SHUNCHAKI PAUZA ────────────────────────
      //
      // TALAB (foydalanuvchi): "video tugagach qayta boshlanmasin,
      // shunchaki pauza bo'lsin".
      //
      // Ilgari bu yerda `seekTo(0)` + `play()` turardi va video
      // o'z-o'zidan boshidan ketardi. Endi pleyer oxirida turadi,
      // "play" bosilsa `_togglePlayPause` uni boshidan boshlaydi
      // (o'sha yerdagi qoida).
      VideoCacheServer.log('Video oxiriga yetdi — pauza');
      _pendingEofAt = null;
      _lastGoodPosition = v.duration;
      if (mounted) setState(() => _intendedPlaying = false);
      () async {
        try {
          if (!mounted || _controller != c) return;
          await c.pause();
          // ── AVTO QISM O'TKAZISH ──────────────────────────────
          //
          // TALAB (foydalanuvchi): "3ta nuqtaga `avto qism
          // o'tkazish` nomli tugma qo'sh — tugmani bosganda video
          // tugashi bilan avtomatik ravishda keyingi qismga
          // o'tadi".
          //
          // Faqat HAQIQIY oxirda ishlaydi: erta uzilish yuqoridagi
          // ikkinchi tarmoqqa tushadi va u yerda video o'sha
          // nuqtadan qayta ochiladi, keyingi qismga o'tmaydi.
          //
          // `_intendedPlaying` ATAYLAB `true` qilinadi: odam
          // videoni ko'rib tugatdi, ya'ni keyingisi ham ijro
          // bo'lishi kerak. Yuqorida u `false` ga tushirilgan
          // (pauza uchun), shu sabab shu yerda qaytariladi.
          if (AppSettings.instance.autoNextEpisode && _hasNextEpisode) {
            VideoCacheServer.log('Avto o\'tkazish: keyingi qism');
            if (mounted) {
              setState(() => _intendedPlaying = true);
              _stepEpisode(1);
            }
          }
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
    _handleFatalError(reached);
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
      // Surish davomida o'tkazib yuboriladi (yuqoridagi izoh).
      if (_gestureBusy) return;
      final c = _controller;
      if (c == null) return;
      final VideoPlayerValue v = c.value;
      if (!v.isInitialized || v.duration <= Duration.zero) return;

      // ── MANBA O'ZGARDIMI (yuklab olindi / o'chirildi) ──────
      if (DateTime.now().difference(_lastSourceCheck).inMilliseconds >= 2000) {
        _lastSourceCheck = DateTime.now();
        _checkSourceSwitch();
      }

      // ── QAYERDA TO'XTAGANINI ESLAB QOLISH ──────────────────
      // HAR SONIYA — foydalanuvchi talabi. Bu faqat telefon
      // xotirasiga yoziladi, serverga UMUMAN yuborilmaydi, shu
      // sabab ijroga sezilarli ta'siri yo'q (bir necha kilobaytlik
      // JSON).
      if (DateTime.now().difference(_lastProgressSave).inMilliseconds >= 1000) {
        _lastProgressSave = DateTime.now();
        WatchProgress.instance.save(_currentUrl, v.position, v.duration);
        // Tarix uchun ham eslab qo'yiladi — bu ham faqat XOTIRAGA,
        // serverga emas.
        WatchHistory.instance.note(v.position, v.duration);
        // To'xtagan joydagi kadr KO'RISH DAVOMIDA tayyorlanadi
        // (45 soniyada bir marta, fon'da) — shunda tarix oynasi
        // ochilganda rasm allaqachon joyida turadi.
        // Izohi: `WatchHistory.prewarmThumb`.
        if (v.isPlaying) WatchHistory.instance.prewarmThumb();
      }

      // ── TOMOSHA VAQTI ────────────────────────────────────
      //
      // TALAB (foydalanuvchi): "videoni 1x tezlikda ko'rganda
      // hisoblansin" va vaqt qism uzunligidan oshmasin.
      //
      // Shu sabab bu yerda SOAT emas, videoning O'Z nuqtasi
      // o'lchanadi: pauza, buferlash va sek umuman qo'shilmaydi.
      // Sakrash katta farq beradi — u ham tashlab yuboriladi.
      final prev = _watchTickPos;
      _watchTickPos = v.position;
      if (prev != null &&
          v.isPlaying &&
          (v.playbackSpeed - 1.0).abs() < 0.01) {
        final step = v.position.inMilliseconds - prev.inMilliseconds;
        if (step > 0 && step <= 2000) {
          WatchHistory.instance.addWatched(step);
        }
      }

      // ── ERTA UZILGAN OQIM: QAYTA OCHISHNI TAKRORLASH ─────────
      // `_recoverPlayer` ichidagi 6 soniyalik tormoz sabab birinchi
      // urinish o'tmagan bo'lishi mumkin. Video oxirida qotib
      // qolmasligi uchun shu yerda takrorlanadi.
      final eofAt = _pendingEofAt;
      if (eofAt != null && v.isCompleted && !_recovering) {
        _handleFatalError(eofAt);
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
          // Bo'lak keshga olinishini kutayotgan bo'lsak, pozitsiya
          // qimirlamasligi BUTUNLAY NORMAL — bu qotish emas.
          !_windowWaiting &&
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
      // ── IKKI BOSQICHLI TIKLANISH ───────────────────────────
      //
      // 1) ~4.8 s harakatsiz -> YENGIL TURTKI. Bufer saqlanadi,
      //    foydalanuvchi deyarli hech narsa sezmaydi. Qotishlarning
      //    katta qismi shu bilan tugaydi.
      // 2) turtkidan keyin ham ~6.4 s harakatsiz -> pleyer
      //    haqiqatan qotgan, faqat SHUNDA qaytadan ochamiz.
      //
      // Ilgari BIRINCHI belgidayoq pleyer qaytadan ochilardi va
      // yig'ilgan butun bufer yo'qolardi — foydalanuvchi ko'rgan
      // "video qaytadan sekin ochiladi" holati aynan shu edi.
      final sinceNudge = now.difference(_lastNudge);
      if (_stuckTicks >= 6 && sinceNudge > const Duration(seconds: 10)) {
        _stuckTicks = 0;
        _nudgePlayer(c, v.position);
        return;
      }
      if (_stuckTicks >= 14) {
        VideoCacheServer.log(
            'Pleyer harakatsiz qotib qoldi (${v.position}) — qaytadan ochilmoqda');
        _stuckTicks = 0;
        _handleFatalError(v.position);
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

  // ═══════════════════════════════════════════════════════════
  //  XATO: AVVAL SABABNI YO'QOT, KEYIN QAYTA OCH
  // ═══════════════════════════════════════════════════════════
  //
  // Pleyer xatosining eng ehtimolli sababi — o'sha joydagi bo'lak
  // hali keshda yo'q. Ilgari ilova darhol pleyerni qaytadan ochardi;
  // bo'lak esa baribir keshda bo'lmagani uchun xato TAKRORLANARDI —
  // va bir necha urinishdan keyin "Videoni ijro etib bo'lmadi
  // (takroriy xato)" chiqardi.
  //
  // Endi avval AYNAN O'SHA bo'lak keshga olinadi va faqat shundan
  // keyin pleyer qayta ochiladi. Ya'ni qayta ochish bir marta
  // bo'ladi va muvaffaqiyatli tugaydi.
  /// Ayni paytda xato ustida ishlanyaptimi.
  ///
  /// MUHIM: pleyer xato holatida HAR BIR yangilanishda xabar
  /// beradi. Bu bayroqsiz `_handleFatalError` o'nlab marta
  /// yonma-yon ishga tushib, o'nlab kutish sikli ochilib ketardi.
  /// (`_recoverPlayer`ning o'z bayrog'i bu yerda yetarli emas —
  /// unga yetguncha KUTISH bor.)
  bool _handlingError = false;

  Future<void> _handleFatalError(Duration at) async {
    if (_recovering || _handlingError) return;
    _handlingError = true;
    try {
      await _handleFatalErrorInner(at);
    } finally {
      _handlingError = false;
    }
  }

  Future<void> _handleFatalErrorInner(Duration at) async {
    final c = _controller;
    final dur = c?.value.duration ?? Duration.zero;
    if (!_singleWindow && dur > Duration.zero) {
      final ok = await _ensureWindowFor(at, dur);
      if (!mounted) return;
      if (!ok) {
        VideoCacheServer.log('Xatodan keyin bo\'lak tayyorlanmadi');
      }
    }
    if (!mounted) return;
    await _recoverPlayer(at);
  }

  // ── YENGIL TURTKI (nudge) ────────────────────────────────────
  //
  // Pleyer qotib qolganday ko'rinsa, uni DARHOL qaytadan ochish
  // eng qimmat yo'l: butun bufer yo'qoladi va video 1-2 soniya
  // qora bo'lib turadi.
  //
  // Amalda "qotish"larning katta qismi shunchaki dekoderning bir
  // lahzalik tiqilishi bo'lib, `seekTo(joriy joy)` + `play()` bilan
  // O'ZI ochiladi — bufer esa BUTUNLAY saqlanadi. Shu sabab endi
  // avval shu yengil turtki sinaladi, pleyerni qaytadan ochish esa
  // faqat turtki ham yordam bermaganda bo'ladi.
  DateTime _lastNudge = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _nudgePlayer(VideoPlayerController c, Duration at) async {
    _lastNudge = DateTime.now();
    VideoCacheServer.log('Yengil turtki: ${at.inSeconds}s');
    try {
      await c.seekTo(at).timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (!mounted || _controller != c) return;
    if (_intendedPlaying) {
      try {
        await c.play();
      } catch (_) {}
    }
  }

  /// Kontrollar yashiringanda pastda qoladigan INGICHKA chiziq
  /// yoqilganmi.
  ///
  /// `!_showControls` dan farqi: bu bayroq kontrollar so'nish
  /// animatsiyasini TUGATGANDAN keyin yoqiladi, ya'ni ikkita
  /// chiziq hech qachon bir vaqtda ko'rinmaydi.
  bool _thinBarOn = false;
  Timer? _thinBarTimer;

  /// `_showControls` o'zgargan HAR SAFAR chaqiriladi.
  void _syncThinBar() {
    _thinBarTimer?.cancel();
    if (_showControls) {
      // Kontrollar chiqdi — ingichka chiziq DARHOL o'chadi
      // (asosiy progress chizig'i uning o'rnini oladi).
      if (_thinBarOn && mounted) setState(() => _thinBarOn = false);
      return;
    }
    // Kontrollar so'nishi uchun 200 ms kerak (`AnimatedOpacity`),
    // ustiga kichik zaxira.
    _thinBarTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted || _showControls) return;
      setState(() => _thinBarOn = true);
    });
  }

  /// Boshqaruv ko'rinib turadigan vaqt.
  ///
  /// TALAB (foydalanuvchi): "pleyerdagi tugmalarni bosganda
  /// juda tez yashirilyapti — bosgandan keyin ham 5 soniya
  /// tursin". Ilgari 3 soniya edi.
  ///
  /// Taymer HAR BOSISHDA qaytadan boshlanadi (`_scheduleHide`
  /// tugma ishlovchilarining oxirida chaqiriladi), ya'ni ketma-ket
  /// bosilsa boshqaruv yo'qolmaydi.
  static const Duration _controlsHideDelay = Duration(seconds: 5);

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlsHideDelay, () {
      if (!mounted) return;
      setState(() => _showControls = false);
      _syncThinBar();
    });
  }

  void _onTapVideo() {
    setState(() => _showControls = !_showControls);
    _syncThinBar();
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
      // ── OXIRIDA TURGAN BO'LSA — BOSHIDAN ────────────────────
      //
      // Video tugagach endi qayta boshlanmaydi, oxirida pauza
      // bo'lib turadi (foydalanuvchi talabi). Shu holatda "play"
      // bosilsa `play()` ning o'zi hech narsa qilmaydi — avval
      // boshiga qaytariladi.
      final v = ctrl.value;
      final atEnd = v.duration > Duration.zero &&
          v.duration - v.position <= _endThreshold;
      if (atEnd) {
        unawaited(() async {
          try {
            await ctrl.seekTo(Duration.zero);
            if (!mounted || _controller != ctrl) return;
            await ctrl.play();
          } catch (_) {}
        }());
      } else {
        ctrl.play();
      }
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
  // ── SEK KUTISHI: 200 ms (foydalanuvchi talabi) ─────────────
  //
  // Bu tanaffusning yagona vazifasi — ketma-ket buyruqlarni bitta
  // sek qilib yig'ish. Progress chizig'ini surganda yig'iladigan
  // narsa yo'q, shu sabab u AYNAN 200 ms bilan ishlaydi: barmoq
  // uzilishi bilan video deyarli darhol sakraydi.
  static const Duration _seekIdle = Duration(milliseconds: 200);

  // ── IKKI MARTA BOSISH UCHUN BIROZ UZUNROQ ─────────────────
  //
  // Ketma-ket tap deb hisoblanadigan oraliq 300 ms
  // (`_handleVideoTap`). Agar sek shu oraliqdan TEZROQ yuborilsa,
  // u ikki tap ORASIDA ketib qolardi: "+10" o'rniga ikkita alohida
  // "+5" bo'lar va ekrandagi son haqiqiy sakrashga mos kelmasdi.
  //
  // Shu sabab FAQAT tap yo'li uchun tanaffus 320 ms. Progress
  // chizig'i esa yuqoridagi 200 ms bilan ishlaydi.
  static const Duration _seekIdleTap = Duration(milliseconds: 320);

  // ── Ichki holat ──────────────────────────────────────────────
  // Bir vaqtda faqat BITTA `seekTo` uchib turadi; undan keyingilari
  // "keyingi nuqta" sifatida saqlanadi (_runSeek izohiga qarang).
  bool _seekBusy = false;
  Duration? _queuedSeek;
  Timer? _healthTimer;
  DateTime _lastSeekRequest = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSeekDone = DateTime.fromMillisecondsSinceEpoch(0);
  /// "Qayerda to'xtagan" nuqtasi oxirgi marta qachon saqlangan.
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// Manba (mahalliy/worker) oxirgi marta qachon tekshirilgan.
  DateTime _lastSourceCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// Oldingi qismning manzili — epizod almashganda uning nuqtasini
  /// saqlab qolish uchun.
  String _lastPlayedUrl = '';

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

  /// Nisbiy sek (ekranga ikki marta bosish) — jamlash uchun
  /// biroz uzunroq tanaffus.
  void _scheduleSeek(int deltaSeconds) {
    _requestSeek(_seekBase + Duration(seconds: deltaSeconds),
        idle: _seekIdleTap);
  }

  /// Mutlaq sek (progress chizig'i) — eng qisqa tanaffus.
  void _scheduleSeekTo(Duration target) => _requestSeek(target);

  /// Maqsad pleyerning ALLAQACHON YIG'GAN buferi ichidami.
  ///
  /// TOPILGAN MUAMMO (foydalanuvchi): "sek qilganda bufer
  /// tozalanib ketyapti va kutish vaqti ko'payyapti — hattoki
  /// yig'ilgan buferning yarmigacha sek qilsam ham".
  ///
  /// Sabablardan biri BIZNING tomonda edi: har bir sek, hatto
  /// bufer ICHIDAGISI ham, avval 200 ms "tinchlik" kutardi, keyin
  /// `_ensureWindowFor` orqali kesh oynasi holatini so'rardi.
  /// Bufer ichidagi nuqta uchun bularning IKKALASI ham keraksiz:
  /// ma'lumot allaqachon pleyerning o'zida.
  ///
  /// Endi bunday sek DARHOL va to'g'ridan-to'g'ri bajariladi.
  bool _targetInBuffer(VideoPlayerController c, Duration t) {
    final v = c.value;
    if (!v.isInitialized) return false;
    for (final r in v.buffered) {
      if (t >= r.start && t <= r.end) return true;
    }
    return false;
  }

  void _requestSeek(Duration target, {Duration? idle}) {
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
      // ── IJRO ENDI TO'XTATILMAYDI ──────────────────────────
      //
      // Avval har bir sek buyrug'ida video MAJBURAN pauza
      // qilinardi va 0.5 soniyalik tanaffusdan keyin qaytadan
      // ishga tushardi. Foydalanuvchi buni "sek qilsam video
      // to'xtab qoladi va sekin ishlaydi" deb ko'rardi.
      //
      // ExoPlayer sekni ijro davomida ham bemalol bajaradi —
      // YouTube ham aynan shunday ishlaydi: siz +5s bosganingizda
      // video to'xtamaydi. Shu sabab bu yerda pleyerga tegilmaydi.
    }

    var t = target;
    if (t < Duration.zero) t = Duration.zero;
    t = _clampSeekTarget(t, ctrl.value.duration);

    setState(() => _pendingTarget = t);
    _scheduleHide();

    // Har bir yangi sek kutish taymerini QAYTADAN boshlaydi.
    _seekIdleTimer?.cancel();
    // Bufer ichidagi nuqtaga sek — yig'iladigan narsa yo'q, tanaffus
    // ham kerak emas (yuqoridagi `_targetInBuffer` izohiga qarang).
    final wait = _targetInBuffer(ctrl, t) ? Duration.zero : (idle ?? _seekIdle);
    _seekIdleTimer = Timer(wait, _commitPendingSeek);
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

    // ── SEK QILINADIGAN JOY KESHDA BORMI ────────────────────
    //
    // Yo'q bo'lsa — AVVAL o'sha bo'lak keshga olinadi va faqat
    // keyin sek bajariladi. Pleyerga bu paytda umuman tegilmaydi,
    // ya'ni yig'ilgan bufer joyida qoladi.
    final wasPlaying = _intendedPlaying;
    // Maqsad pleyerning o'z buferida bo'lsa — kesh oynasini umuman
    // tekshirmaymiz: ma'lumot allaqachon qo'lda, kutishning ma'nosi
    // yo'q (va "tayyorlanmoqda" halqasi ham chiqmaydi).
    final inBuffer = _targetInBuffer(c, target);
    if (!inBuffer && !await _ensureWindowFor(target, c.value.duration)) {
      // Tayyorlab bo'lmadi (masalan internet uzildi). Sekni BEKOR
      // qilamiz — pleyerni buzib, buferni yo'qotishdan ko'ra
      // foydalanuvchini o'z joyida qoldirgan yaxshiroq.
      if (!mounted || _controller != c) return;
      setState(() => _pendingTarget = null);
      _showNotice('Bu joy hali tayyor emas — birozdan keyin urinib ko\'ring');
      if (wasPlaying) {
        try {
          await c.play();
        } catch (_) {}
      }
      return;
    }
    if (!mounted || _controller != c) return;

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
      _leftSeekHideTimer = Timer(_seekIdleTap + const Duration(milliseconds: 400), () {
        if (mounted) {
          setState(() {
            _showLeftSeek = false;
            _leftSeekAccum = 0;
          });
        }
      });
    } else {
      _rightSeekHideTimer?.cancel();
      _rightSeekHideTimer = Timer(_seekIdleTap + const Duration(milliseconds: 400), () {
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

  // ══════════════════════════════════════════════════════════
  //  OPENINGNI O'TKAZIB YUBORISH
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): qism qo'shishda `1:23  2:12` deb
  // yozilsa, video 1:23 ga kelganda ekranning O'RTA CHAP chetida
  // "O'tkazib yuborish" tugmasi chiqsin; bosilsa video 2:12 ga
  // sakrab o'tsin.
  //
  // Bazada 5 ta juftlik bor (`intro_1 ... intro_10`, SONIYADA) —
  // o'tkaziladigan joyi ko'p animelar uchun.
  //
  // Ko'rinish qoidasi (foydalanuvchi aniq aytgan):
  //
  //   * vaqti kelganda chiqadi va 5 SONIYADAN keyin o'zi
  //     yashirinadi — ekranni to'sib turmaydi;
  //   * video ustiga bosilsa pleyer tugmalari bilan BIRGA qayta
  //     chiqadi;
  //   * tugma SHAFFOF (video ko'rinib tursin).

  /// Hozir qaysi intro oralig'idamiz (-1 — hech qaysi).
  int _introIndex = -1;

  /// Tugma ayni damda ekrandami.
  bool _introVisible = false;

  /// Har bir oraliq uchun AVTOMATIK o'tkazish necha marta
  /// urinilgani (`oraliq -> urinishlar soni`).
  ///
  /// ── TOPILGAN XATO: AVTO O'TKAZISH ISHLAMAY QOLARDI ────────
  ///
  /// Foydalanuvchi: "avto intro o'tkazish ishlamayabdi".
  ///
  /// Ilgari bu yerda oddiy `Set<int> _introDone` turardi va unga
  /// urinish BOSHLANISHIDA yozib qo'yilardi. Ikkita og'ir oqibati
  /// bor edi:
  ///
  ///   1. TO'PLAM QISM ALMASHGANDA TOZALANMASDI. Birinchi qismda
  ///      intro o'tkazilgach, to'plamda `0` qolardi — keyingi
  ///      qismning HAM birinchi oralig'i "allaqachon o'tkazilgan"
  ///      hisoblanib, avto o'tkazish boshqa umuman ishlamasdi.
  ///      Ya'ni sozlama faqat bitta qismga yetardi.
  ///
  ///   2. SEK BAJARILMASA HAM "O'TKAZILDI" DEB YOZILARDI. Sek
  ///      esa bekor bo'lishi mumkin: pleyer hali tayyor emas,
  ///      yoki o'sha joy keshda yo'q (`_commitPendingSeek` uni
  ///      ataylab bekor qiladi). Bunday holda video intro ichida
  ///      qolar, qayta urinish esa BO'LMASDI.
  ///
  /// Endi urinishlar SANALADI: o'tkazib bo'lmasa qaytadan
  /// urinamiz, lekin cheksiz emas — shu sabab kalit kadr sabab
  /// paydo bo'ladigan "sekdan sekka" halqasi ham qaytmaydi.
  final Map<int, int> _introTries = <int, int>{};

  /// Bitta oraliq uchun eng ko'p urinish.
  static const int _introMaxTries = 3;

  /// Urinishlar orasidagi eng kam tanaffus.
  static const Duration _introRetryGap = Duration(milliseconds: 1200);

  /// Oxirgi avtomatik o'tkazish urinishi qachon bo'lgan.
  DateTime _lastIntroSkip = DateTime.fromMillisecondsSinceEpoch(0);

  /// Sek oraliq oxiridan shuncha millisekund KEYINGA qilinadi.
  static const int _introSkipPad = 400;

  /// Uch nuqta menyusi ochiqmi.
  bool _menuOpen = false;

  /// Joriy qismning intro oraliqlari: (boshi, oxiri) millisekundda.
  ///
  /// Qism ochilganda BIR MARTA hisoblanadi: bu ro'yxat pleyerning
  /// har bir yangilanishida (soniyasiga bir necha marta) o'qiladi,
  /// ya'ni uni har safar qaytadan yig'ish bekorga axlat yig'ardi.
  List<(int, int)> _introRanges = const [];

  /// Shu nuqta qaysi intro oralig'iga tushadi (-1 — hech qaysi).
  int _introAt(Duration pos) {
    final ms = pos.inMilliseconds;
    final ranges = _introRanges;
    for (var i = 0; i < ranges.length; i++) {
      if (ms >= ranges[i].$1 && ms < ranges[i].$2) return i;
    }
    return -1;
  }

  /// Har bir pozitsiya yangilanishida chaqiriladi.
  void _updateIntro(Duration pos) {
    final idx = _introAt(pos);
    if (idx < 0) {
      // Oraliq tugadi — tugma ham ketadi.
      if (_introIndex != -1) {
        _introIndex = -1;
        if (_introVisible && mounted) setState(() => _introVisible = false);
      }
      return;
    }
    final entered = idx != _introIndex;
    _introIndex = idx;

    // ── AVTOMATIK O'TKAZISH ─────────────────────────────────
    //
    // TALAB (foydalanuvchi): uch nuqta ostidagi tugma yoqilgan
    // bo'lsa intro O'ZI o'tkazib yuboriladi, o'chiq bo'lsa
    // foydalanuvchi qo'lda bosadi.
    //
    // ── TOPILGAN XATO: CHEKSIZ SEK HALQASI ──────────────────
    //
    // Foydalanuvchi: "avto o'tkazishni yoqib qo'ysam ishlamayapti,
    // shunchaki vaqti kelganda o'rtadagi progress chizig'i aylanib
    // yotibdi".
    //
    // Sabab: sek AYNAN oraliqning oxirgi millisekundiga qilinardi,
    // pleyer esa eng yaqin KALIT KADRGA tushadi va u ko'pincha
    // oraliqning ICHIDA qoladi. Keyingi pozitsiya yangilanishida
    // `_introAt` yana o'sha oraliqni topar, `_skipIntro` yana
    // chaqirilar — video sekdan sekka o'tib, halqa aylanaverardi.
    //
    // Himoyalar:
    //   1. sek oraliq oxiridan `_introSkipPad` keyinga qilinadi;
    //   2. urinishlar SANALADI (`_introTries`) — eng ko'pi uchta
    //      va orasida tanaffus bilan. Ya'ni sek bajarilmay qolsa
    //      qayta urinamiz, halqa esa uchinchi urinishda to'xtaydi
    //      va tugma qo'lda bosish uchun ekranda qoladi.
    if (AppSettings.instance.autoSkipIntro &&
        (_introTries[idx] ?? 0) < _introMaxTries) {
      final waited =
          DateTime.now().difference(_lastIntroSkip) >= _introRetryGap;
      if (entered || waited) {
        _introTries[idx] = (_introTries[idx] ?? 0) + 1;
        _lastIntroSkip = DateTime.now();
        _seekIntroTo(idx);
      }
      // O'tkazish ketyapti (yoki keyingi urinish kutilmoqda) —
      // tugma chiqmaydi, aks holda u bir ko'rinib bir yo'qolardi.
      if (_introVisible && mounted) setState(() => _introVisible = false);
      return;
    }
    _showIntroButton();
  }

  /// Pastki boshqaruv paneli va yuqori o'ng tugmalar qatorining
  /// ekrandagi o'rnini o'lchash uchun kalitlar.
  ///
  /// TOPILGAN XATO (foydalanuvchi): "tugmalarni bosganda 5 soniya
  /// tursin degandim, lekin bosishim bilan yashirilyapti".
  ///
  /// Sabab: sek gesture qatlami (`Listener`) Stack'ning ENG
  /// USTIDA va SHAFFOF — ya'ni tugmaga bosilgan tapni tugmaning
  /// o'zi ham, bu qatlam ham oladi. Qatlam esa uni "videoga
  /// bosildi" deb hisoblab, 300 ms dan keyin `_onTapVideo()` bilan
  /// boshqaruvni YASHIRARDI. Tugmaning `_scheduleHide()` si
  /// (5 soniya) hech qanday rol o'ynamasdi.
  ///
  /// Ilgari bundan "chekka zonalar" (`bottomGuard`/`topGuard`)
  /// himoya qilardi, lekin pastki panel balandligi o'zgargach
  /// (vaqt va progress chizig'i pastga tushdi) tugmalar o'sha
  /// 78 px lik zonadan YUQORIDA qolib ketdi.
  ///
  /// Endi taxminiy zona o'rniga ANIQ o'lcham: tap shu ikki
  /// qatorning haqiqiy to'rtburchagiga tushsa, sek qatlami unga
  /// UMUMAN tegmaydi.
  final GlobalKey _bottomBarKey = GlobalKey();
  final GlobalKey _topBtnsKey = GlobalKey();

  /// Tap boshqaruv tugmalari ustiga tushdimi.
  bool _hitsControls(Offset globalPos) {
    for (final k in [_bottomBarKey, _topBtnsKey]) {
      final box = k.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(globalPos)) return true;
    }
    return false;
  }

  /// Uch nuqta tugmasining o'rnini o'lchash uchun kalit.
  ///
  /// Menyu endi PLEYER ICHIDA emas, BUTUN EKRAN ustidagi
  /// qatlamda chiziladi (foydalanuvchi talabi: "pleyerdan
  /// tashqariga bosganda ham oyna yashirinsin"). Shu sabab uning
  /// joyi tugmaning HAQIQIY o'rnidan hisoblanadi.
  final GlobalKey _menuBtnKey = GlobalKey();

  /// Uch nuqta tugmasining ekrandagi to'rtburchagi (menyu shuning
  /// ostidan chiqadi). Menyu ochilayotganda o'lchanadi.
  Rect? _menuAnchor;

  /// Uch nuqtaga bosilganda menyu ochiladi yoki yopiladi.
  void _toggleMenu() {
    if (!_menuOpen) {
      final ctx = _menuBtnKey.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        _menuAnchor = box.localToGlobal(Offset.zero) & box.size;
      }
    }
    setState(() => _menuOpen = !_menuOpen);
    // Menyu ochiq turganda kontrollar yashirinmasin: aks holda
    // uch nuqta daraxtdan olib tashlanib, oyna "muallaq" qolardi.
    if (_menuOpen) {
      _hideTimer?.cancel();
    } else {
      _scheduleHide();
    }
  }

  void _closeMenu() {
    if (!_menuOpen) return;
    setState(() => _menuOpen = false);
    _scheduleHide();
  }

  /// "Avto o'tkazish" tugmasi bosildi.
  ///
  /// MENYU YOPILMAYDI (foydalanuvchi talabi) — holat o'sha yerda
  /// ko'rinib turadi, oyna esa tashqariga yoki uch nuqtaga
  /// bosilgandagina yo'qoladi.
  void _toggleAutoSkipIntro() {
    final on = !AppSettings.instance.autoSkipIntro;
    AppSettings.instance.setAutoSkipIntro(on);
    if (!mounted) return;
    setState(() {});
    // Hozir intro oralig'ida turgan bo'lsa — darhol o'tkaziladi,
    // ya'ni tugma bosilishi bilan natija ko'rinadi.
    //
    // Sozlama endi yoqildi — oldingi urinishlar hisobi bekor
    // qilinadi, aks holda "uch marta urinib bo'lingan" oraliq
    // o'tkazilmay qolardi.
    if (on) {
      _introTries.clear();
      _lastIntroSkip = DateTime.fromMillisecondsSinceEpoch(0);
      if (_introIndex >= 0) {
        _introTries[_introIndex] = 1;
        _lastIntroSkip = DateTime.now();
        _seekIntroTo(_introIndex);
        setState(() => _introVisible = false);
      }
    }
  }

  /// "Avto qism o'tkazish" tugmasi bosildi.
  ///
  /// Xuddi yuqoridagidek, MENYU YOPILMAYDI.
  void _toggleAutoNextEpisode() {
    AppSettings.instance
        .setAutoNextEpisode(!AppSettings.instance.autoNextEpisode);
    if (!mounted) return;
    setState(() {});
  }

  void _showSpeedPanel() {
    // Ikkalasi ham endi O'NG tomonda chiqadi — bir vaqtda
    // ochilib ustma-ust tushmasligi uchun ikkinchisi yopiladi.
    setState(() {
      _qualityPanelOpen = false;
      _speedPanelOpen = true;
    });
    _hideTimer?.cancel();
  }

  void _closeSpeedPanel() {
    if (!_speedPanelOpen) return;
    setState(() => _speedPanelOpen = false);
    _scheduleHide();
  }

  void _setSpeed(double speed) {
    _playbackSpeed = speed;
    _controller?.setPlaybackSpeed(speed);
    _closeSpeedPanel();
  }

  void _showQualityPanel() {
    setState(() {
      _speedPanelOpen = false;
      _qualityPanelOpen = true;
    });
    _hideTimer?.cancel();
  }

  void _closeQualityPanel() {
    if (!_qualityPanelOpen) return;
    setState(() => _qualityPanelOpen = false);
    _scheduleHide();
  }

  void _toggleLock() {
    setState(() => _isLocked = !_isLocked);
    if (_isLocked) {
      _hideTimer?.cancel();
      _closeMenu();
      _closeSpeedPanel();
      _closeQualityPanel();
      _closeEpisodeListPanel();
      _closeSettingsPanel();
    } else {
      _scheduleHide();
    }
  }

  void _showSleepPanel() {
    setState(() {
      _sleepPanelOpen = true;
      _sleepCustomInput = false;
      _sleepCustomValue = '';
    });
    _hideTimer?.cancel();
  }

  void _closeSleepPanel() {
    if (!_sleepPanelOpen) return;
    setState(() {
      _sleepPanelOpen = false;
      _sleepCustomInput = false;
    });
    _scheduleHide();
  }

  void _setSleepTimer(int minutes) {
    _sleepTickTimer?.cancel();

    if (minutes <= 0) {
      setState(() {
        _sleepMinutes = 0;
        _sleepSecondsLeft = 0;
      });
      _closeSleepPanel();
      return;
    }

    setState(() {
      _sleepMinutes = minutes;
      _sleepSecondsLeft = minutes * 60;
    });

    // ── NEGA HAR SONIYADA `setState` EMAS ───────────────────
    //
    // Sanoq har soniyada tushadi, bu ekran esa juda katta
    // (video, tugmalar, qismlar, izohlar). Har tikda butun
    // daraxtni qayta chizish ijroda sakrashga olib kelardi.
    //
    // Qolgan vaqt FAQAT ikki joyda ko'rinadi: uch nuqta menyusi
    // va fullscreen sozlamalari. Shu sabab qayta chizish aynan
    // o'sha oynalar OCHIQ bo'lgandagina so'raladi.
    _sleepTickTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }

      _sleepSecondsLeft--;

      if (_sleepSecondsLeft <= 0) {
        t.cancel();
        _controller?.pause();
        setState(() {
          _intendedPlaying = false;
          _sleepMinutes = 0;
          _sleepSecondsLeft = 0;
        });
        return;
      }

      if (_menuOpen || _settingsPanelOpen || _sleepPanelOpen) {
        setState(() {});
      }
    });

    _closeSleepPanel();
  }

  String _sleepTimeLabel() {
    if (_sleepSecondsLeft <= 0) return '';
    final m = _sleepSecondsLeft ~/ 60;
    final s = _sleepSecondsLeft % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Uch nuqta menyusi — BUTUN EKRAN ustidagi qatlam.
  ///
  /// Parda ekranning hammasini qoplaydi: pleyerdan tashqariga
  /// (qismlar ro'yxati, tablar, bo'sh joy) bosilsa ham menyu
  /// yopiladi. Menyuning O'ZI esa uch nuqta tugmasining aynan
  /// ostida chiqadi — tugmaning o'rni `_menuAnchor` da.
  Widget _buildMenuOverlay() {
    final size = MediaQuery.of(context).size;
    final a = _menuAnchor;
    // Tayanch o'lchanmagan bo'lsa (kutilmagan holat) — o'ng
    // yuqorida, taxminiy joyda.
    final top = a == null ? 90.0 : a.bottom + 6;
    final right = a == null ? 8.0 : (size.width - a.right).clamp(0.0, 1e6);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeMenu,
          ),
        ),
        Positioned(
          top: top,
          right: right.toDouble(),
          child: _PlayerPanel(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: size.height * 0.6),
              child: SizedBox(
                width: 260,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _MenuToggleRow(
                        icon: Icons.fast_forward_rounded,
                        label: 'Avto intro o\'tkazish',
                        on: AppSettings.instance.autoSkipIntro,
                        onToggle: _toggleAutoSkipIntro,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      _MenuToggleRow(
                        icon: Icons.skip_next_rounded,
                        label: 'Avto qism o\'tkazish',
                        on: AppSettings.instance.autoNextEpisode,
                        onToggle: _toggleAutoNextEpisode,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      // ── UXLASH VAQTI ───────────────────────
                      //
                      // TALAB (foydalanuvchi): "uxlash vaqti
                      // tugmasini bosish qiyin, juda kichik".
                      //
                      // Ilgari bu qator boshqalaridan past edi
                      // (yozuvi 11.5, belgisi 16, balandligi esa
                      // faqat yozuv bo'yicha) va bosish zonasi
                      // ham shunga yarasha tor edi. Endi u
                      // yuqoridagi qatorlar bilan BIR XIL: 46 px
                      // balandlik, butun eni bo'ylab bosiladi.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          _closeMenu();
                          _showSleepPanel();
                        },
                        child: SizedBox(
                          height: 46,
                          child: Row(
                            children: [
                              Icon(Icons.schedule_rounded,
                                  size: 20,
                                  color: _sleepMinutes > 0
                                      ? AppColors.accent
                                      : Colors.white70),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _sleepMinutes > 0
                                      ? 'Uxlash: ${_sleepTimeLabel()}'
                                      : 'Uxlash vaqti',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _sleepMinutes > 0
                                        ? AppColors.accent
                                        : Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Uxlash vaqti oynasi — butun ekran ustidagi qatlam.
  ///
  /// Parda (bosilsa yopadi) + o'rtadagi katta panel. Panelning
  /// eni cheklangan (360) — keng ekranda cho'zilib ketmaydi,
  /// bo'yi esa ekranga sig'masa ICHIDA suriladi.
  Widget _buildSleepOverlay() {
    return Stack(
      children: [
        // Parda: yozuvlar orqasidagi video xiralashadi va
        // tashqariga bosilsa oyna yopiladi.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeSleepPanel,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: _PlayerPanel(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 20),
                child: SingleChildScrollView(
                  child: _sleepCustomInput
                      ? _buildSleepCustomInput()
                      : _buildSleepOptions(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSleepOptions() {
    final options = [
      // Oyna endi butun ekran o'rtasida (pleyer maydoni bilan
      // cheklanmagan), shu sabab yozuvlar TO'LIQ yoziladi —
      // ilgari joy tanqisligidan "15 daq" deb qisqartirilgandi.
      {'label': 'O\'chirish', 'minutes': 0},
      {'label': '15 daqiqa', 'minutes': 15},
      {'label': '30 daqiqa', 'minutes': 30},
      {'label': '60 daqiqa', 'minutes': 60},
      {'label': '120 daqiqa', 'minutes': 120},
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Uxlash vaqti',
            style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700)),
        if (_sleepMinutes > 0) ...[
          const SizedBox(height: 6),
          Text(_sleepTimeLabel(),
              style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            for (final o in options)
              GestureDetector(
                onTap: () => _setSleepTimer(o['minutes'] as int),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                  decoration: BoxDecoration(
                    color: _sleepMinutes == o['minutes'] as int &&
                            (o['minutes'] as int) > 0
                        ? AppColors.accent.withValues(alpha: 0.25)
                        : Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _sleepMinutes == o['minutes'] as int &&
                              (o['minutes'] as int) > 0
                          ? AppColors.accent.withValues(alpha: 0.5)
                          : Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Text(
                    o['label'] as String,
                    style: TextStyle(
                      color: _sleepMinutes == o['minutes'] as int &&
                              (o['minutes'] as int) > 0
                          ? AppColors.accent
                          : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            GestureDetector(
              onTap: () => setState(() => _sleepCustomInput = true),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15)),
                ),
                child: const Text('Qo\'lda kiritish',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSleepCustomInput() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => setState(() => _sleepCustomInput = false),
              child: const Icon(Icons.arrow_back_rounded,
                  color: Colors.white70, size: 24),
            ),
            const SizedBox(width: 10),
            const Text('Daqiqa kiriting',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 18),
        Container(
          width: 170,
          height: 58,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border:
                Border.all(color: Colors.white.withValues(alpha: 0.2)),
          ),
          child: Text(
            _sleepCustomValue.isEmpty ? '0' : _sleepCustomValue,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: 2),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: 280,
          child: Column(
            children: [
              for (final row in [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9'],
                ['⌫', '0', '✓'],
              ])
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: row.map((key) {
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          setState(() {
                            if (key == '⌫') {
                              if (_sleepCustomValue.isNotEmpty) {
                                _sleepCustomValue = _sleepCustomValue
                                    .substring(
                                        0,
                                        _sleepCustomValue.length - 1);
                              }
                            } else if (key == '✓') {
                              final val =
                                  int.tryParse(_sleepCustomValue) ?? 0;
                              if (val > 0) _setSleepTimer(val);
                            } else {
                              if (_sleepCustomValue.length < 4) {
                                _sleepCustomValue += key;
                              }
                            }
                          });
                        },
                        child: Container(
                          height: 58,
                          margin: const EdgeInsets.all(4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: key == '✓'
                                ? AppColors.accent.withValues(alpha: 0.3)
                                : Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            key,
                            style: TextStyle(
                              color: key == '✓'
                                  ? AppColors.accent
                                  : Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _showSettingsPanel() {
    setState(() => _settingsPanelOpen = true);
    _hideTimer?.cancel();
  }

  void _closeSettingsPanel() {
    if (!_settingsPanelOpen) return;
    setState(() => _settingsPanelOpen = false);
    _scheduleHide();
  }

  /// Fullscreen'dagi qismlar ro'yxati uchun surish nazoratchisi.
  ///
  /// Har ochilganda QAYTADAN yaratiladi: ro'yxat aynan hozir
  /// ko'rilayotgan qismdan boshlanib ochilsin. Aks holda 200
  /// qismli bo'limda foydalanuvchi har safar qo'lda surishga
  /// majbur bo'lardi.
  ScrollController? _epListCtrl;

  /// Bitta qator taxminiy balandligi (padding 13*2 + yozuv +
  /// margin). Aniq bo'lishi SHART emas: qiymat faqat boshlang'ich
  /// surish uchun, ortiqchasini ro'yxatning o'zi qisqartiradi.
  static const double _kEpRowHeight = 51;

  void _showEpisodeListPanel() {
    final eps = _orderedEps;
    var idx = -1;
    if (_currentEp != null) {
      final key = _epKeyOf(_currentEp!);
      idx = eps.indexWhere((e) => _epKeyOf(e) == key);
    }
    // Joriy qism ro'yxat O'RTASIDAROQ turadi (tepaga yopishib
    // qolmaydi) — oldingi qismlar ham ko'rinib tursin.
    final offset =
        idx <= 0 ? 0.0 : (idx * _kEpRowHeight - 90).clamp(0.0, 1e6).toDouble();

    _epListCtrl?.dispose();
    _epListCtrl = ScrollController(initialScrollOffset: offset);

    setState(() => _episodeListOpen = true);
    _hideTimer?.cancel();
  }

  void _closeEpisodeListPanel() {
    if (!_episodeListOpen) return;
    setState(() => _episodeListOpen = false);
    _scheduleHide();
  }

  void _selectQualityFromPanel(String q) {
    final ep = _currentEp;
    if (ep == null) return;
    _closeQualityPanel();
    final ctrl = _controller;
    final resumeAt = ctrl?.value.position;
    final resumePlaying = ctrl?.value.isPlaying ?? true;
    setState(() {
      _selectedQuality = q;
      _qualityChosenByUser = true;
    });
    _playEpisode(ep, resumeAt: resumeAt, resumePlaying: resumePlaying);
  }

  /// Tugmani ko'rsatadi.
  ///
  /// TALAB (foydalanuvchi): "intro tugmasi intro TUGAMAGUNCHA
  /// ko'rsatilsin".
  ///
  /// Ilgari 5 soniyalik taymer bor edi va tugma o'zi yashirinardi —
  /// foydalanuvchi o'sha payt ekranga qaramasa, o'tkazib yuborish
  /// imkoni yo'qolardi. Endi tugma oraliq TUGAGUNDA yoki bosilgach
  /// yo'qoladi (`_updateIntro` / `_skipIntro`).
  void _showIntroButton() {
    if (_introIndex < 0 || !mounted) return;
    if (!_introVisible) setState(() => _introVisible = true);
  }

  /// Tugma bosildi — video oraliqning OXIRIGA sakraydi.
  ///
  /// Qo'lda bosilgani uchun shu oraliq boshqa AVTOMATIK
  /// o'tkazilmaydi: foydalanuvchi orqaga qaytarsa, qarori o'ziniki.
  void _skipIntro() {
    final idx = _introIndex;
    if (idx < 0 || idx >= _introRanges.length) return;
    _introTries[idx] = _introMaxTries;
    _introIndex = -1;
    if (mounted) setState(() => _introVisible = false);
    _seekIntroTo(idx);
  }

  /// Berilgan intro oralig'ining oxiriga sek qiladi.
  ///
  /// Oraliqning OXIRIDAN sal keyinga — kalit kadr yaxlitlanishi
  /// bizni yana o'sha oraliq ichiga tushirib qo'ymasin.
  void _seekIntroTo(int idx) {
    final ranges = _introRanges;
    if (idx < 0 || idx >= ranges.length) return;
    _scheduleSeekTo(Duration(milliseconds: ranges[idx].$2 + _introSkipPad));
  }

  /// Pleyerdagi vaqt — FAQAT DAQIQA VA SONIYA.
  ///
  /// TALAB (foydalanuvchi): "pleyerdagi vaqt faqat daqiqa va
  /// soniyalarda ko'rsatilsin; agar video 2 soat bo'lsa pleyer
  /// 120:00 qilib ko'rsatishi kerak".
  ///
  /// Ya'ni soat AJRATILMAYDI — daqiqa 60 dan oshib ketaveradi.
  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Fullscreen: alohida sahifaga o'tmaydi — xuddi shu controller
  // joyida (soat mili bo'ylab) landscape rejimga aylanadi ─────────
  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
      // Uch nuqta menyusi faqat oddiy rejimda bor — fullscreen'ga
      // o'tganda ochiq qolib ketmasin.
      _menuOpen = false;
      if (!_isFullscreen) {
        _isLocked = false;
        _settingsPanelOpen = false;
        _episodeListOpen = false;
        _speedPanelOpen = false;
        _qualityPanelOpen = false;
      }
    });
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
        backgroundColor: AppColors.card,
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
                      setState(() {
                        _selectedQuality = q;
                        // Foydalanuvchi ATAYLAB tanladi — endi
                        // tarixdagi eski sifat ustidan yozmaydi.
                        _qualityChosenByUser = true;
                      });
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
                            : Colors.white.withValues(alpha: 0.06),
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
    // ── "ORQAGA" TUGMASI: PopScope (WillPopScope ESKIRGAN) ─────
    //
    // `WillPopScope` Flutter'da eskirgan va Android'ning "bashoratli
    // orqaga" (predictive back) imkoniyati bilan UMUMAN ishlamaydi —
    // yangi Android'larda fullscreen'dan chiqish o'rniga ekran
    // butunlay yopilib ketishi mumkin edi.
    //
    // `PopScope` esa rasmiy o'rinbosar: `canPop: false` bo'lganda
    // tizim orqaga qaytishni BAJARMAYDI va bizga xabar beradi —
    // biz esa avval fullscreen'dan chiqamiz.
    // ── OBUNASIZ ODAM ANIME KO'RA OLMAYDI ──────────────────────
    //
    // TALAB (foydalanuvchi): "obuna sotib olmaguncha anime
    // ko'rsatmaydigan tizimini yana qaytar".
    //
    // To'siq AYNAN shu yerda, pleyerning O'ZIDA turadi — chunki
    // pleyerga bir necha joydan kiriladi (bosh sahifa, katalog,
    // sevimlilar, tarix, yuklanmalar va pleyerning ichidagi
    // "keyingi bo'lim"). Har biriga alohida tekshiruv qo'yilsa,
    // bittasi esdan chiqsa to'siq ochilib qolardi.
    //
    // Obuna muddati telefonda ham saqlanadi, ya'ni interneti
    // uzilgan, PUL TO'LAGAN odam yuklab olgan animesini bemalol
    // ko'ra oladi (`billing_service.dart` -> `restore` izohi).
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        if (!BillingService.instance.active) {
          return const _SubRequiredScreen();
        }

        return PopScope(
          // Izohlar butun ekranni egallagan bo'lsa "orqaga"
          // AVVAL uni yig'adi — ekrandan chiqib ketmaydi.
          //
          // Uxlash oynasi ochiq bo'lsa "orqaga" AVVAL o'sha
          // oynani yopadi — ekran yopilib ketmaydi.
          canPop: !_isFullscreen && !_commentsExpanded && !_sleepPanelOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_sleepPanelOpen) {
              _closeSleepPanel();
            } else if (_isFullscreen) {
              _toggleFullscreen();
            } else if (_commentsExpanded) {
              _setCommentsExpanded(false);
            }
          },
          // ── UXLASH OYNASI EKRAN O'RTASIDA ──────────────────
          //
          // TALAB (foydalanuvchi): "uxlash vaqti oynasi ekran
          // o'rtasida chiqsin va kattaroq bo'lsin".
          //
          // Shu sabab u pleyer Stack'idan CHIQARILDI va eng
          // tepaga — butun ekranni qoplaydigan qatlamga ko'chdi.
          // Endi o'lchamini video maydoni cheklamaydi: oyna
          // ekran o'rtasida, katta tugmalar bilan chiqadi va
          // fullscreen'da ham xuddi shunday ishlaydi.
          //
          // `Material` kerak: bu qatlam `Scaffold` dan TASHQARIDA
          // turadi, usiz matn uchun odatiy uslub topilmaydi.
          child: Stack(
            // `expand` SHART: usiz ekran (Scaffold) bo'sh
            // cheklov oladi va o'z bo'yiga qarab siqilib
            // qolishi mumkin.
            fit: StackFit.expand,
            children: [
              _isFullscreen
                  ? _buildFullscreenPlayer()
                  : _buildNormalScreen(),
              // Uch nuqta menyusi — butun ekran ustida, ya'ni
              // pleyerdan tashqariga bosilsa ham yopiladi.
              if (_menuOpen && _currentEp != null && _playerError == null)
                Positioned.fill(
                  child: Material(
                    type: MaterialType.transparency,
                    child: _buildMenuOverlay(),
                  ),
                ),
              if (_sleepPanelOpen)
                Positioned.fill(
                  child: Material(
                    type: MaterialType.transparency,
                    child: _buildSleepOverlay(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNormalScreen() {
    // Nom va tavsif AVVAL `_info` dan (to'liq qator — serverdan
    // yoki oflaynda diskdagi nusxadan), keyin ekranga kelgan
    // qatordan. Tarixdan ochilganda `widget.season` da tavsif
    // umuman bo'lmaydi.
    final name = _seasonStr('nomi');
    final tavsif = _seasonStr('tavsif');
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
              // ── IZOHLAR OCHILGANDA TEPA QISM YIG'ILADI ───────
              //
              // Foydalanuvchi talabi: izohlarni yuqoriga surganda
              // oyna butun ekranga kattalashsin.
              //
              // `heightFactor: 0` — bo'yi nolga tushadi, lekin
              // tarkib daraxtda QOLADI. Shu sabab pleyer qayta
              // qurilmaydi va ko'rilayotgan video to'xtamaydi
              // (`_commentsExpanded` izohiga qarang).
              ClipRect(
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  heightFactor: _commentsExpanded ? 0.0 : 1.0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
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
                // ── ALOHIDA QATLAM ──────────────────────────────
                // Pleyer o'z vaqti bilan (pozitsiya, bufer, halqa)
                // qayta chiziladi. Alohida qatlamsiz bu qayta
                // chizish PASTDAGI ro'yxatni ham sudrab ketardi —
                // aynan surish paytida bu sezilarli qotish beradi.
                child: RepaintBoundary(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: _buildInlinePlayer(),
                  ),
                ),
              ),
              // Pleyer bilan qism o'tkazish orasida: qaysi bo'lim va
              // qism ko'rilyapti, u necha marta ko'rilgan, qancha
              // vaqt tomosha qilingan va qachon qo'shilgan.
              RepaintBoundary(child: _buildNowPlayingBar()),
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
                    // Tartib (foydalanuvchi talabi):
                    // Ma'lumot | Qismlar | Bo'limlar.
                    onTap: _goToTab,
                    tabs: const [
                      Tab(height: 32, text: 'Ma\'lumot'),
                      Tab(height: 32, text: 'Qismlar'),
                      Tab(height: 32, text: 'Bo\'limlar'),
                      Tab(height: 32, text: 'Izohlar'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // [<]  N-qism  [>] — tablarning TAGIDA, ro'yxat ustida.
              _buildEpisodeNav(),
              const SizedBox(height: 6),
                    ],
                  ),
                ),
              ),
              Expanded(
                // ── OYNALAR QO'LDA SURILADI ──────────────────────
                //
                // TALAB (foydalanuvchi): tarix oynalaridek, barmoq
                // bilan surib o'tilsin.
                //
                // Har bir oyna `_KeepAlivePage` ichida — ya'ni bir
                // marta qurilgandan keyin TIRIK qoladi va surish
                // paytida qaytadan qurilmaydi. Kuchsiz telefondagi
                // qotish aynan shundan bo'lardi.
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
                  child: PageView(
                    controller: _tabPages,
                    // `ClampingScrollPhysics` — `Bouncing` oynani
                    // chetda cho'zib, qo'yib yuborilgach orqaga
                    // qaytaradi. Har bir qaytish qo'shni oynani
                    // ham chizadi, ya'ni bekorga ish. Bu yerda
                    // cho'zilishning ma'nosi ham yo'q: chapda va
                    // o'ngda boradigan joy bor.
                    physics: const ClampingScrollPhysics(),
                    // Qo'shni oyna OLDINDAN quriladi — surish
                    // paytida qurish ishi qolmaydi (kuchsiz
                    // telefondagi qotish aynan shundan edi).
                    allowImplicitScrolling: true,
                    onPageChanged: (i) {
                      // Izohlardan chiqildi — tepa qism joyiga
                      // qaytadi (aks holda tablar yig'ilgan
                      // holicha qolib, boshqa oynaga o'tib
                      // bo'lmasdi).
                      if (i != 3) _setCommentsExpanded(false);
                      // Tugma bosilgan bo'lsa `_tabCtrl` allaqachon
                      // to'g'ri joyda — bu yerda tegilmaydi
                      // (`_goToTab` izohiga qarang).
                      if (!_tabJumping && _tabCtrl.index != i) {
                        _tabCtrl.animateTo(i);
                      }
                      // "Qismlar" oynasi birinchi marta ochilganda
                      // ro'yxat hali qurilmagan bo'ladi — joriy
                      // qismni o'rtaga olib kelamiz.
                      if (i == 1) {
                        final ep = _currentEp;
                        if (ep != null) _centerOnEpisode(ep);
                      }
                    },
                    // `RepaintBoundary` bu yerda QAYTA yozilmaydi —
                    // u `_KeepAlivePage` ning ichida allaqachon bor
                    // (o'sha yerdagi izohga qarang).
                    children: [
                      _KeepAlivePage(child: _buildInfoTab(tavsif.toString())),
                      _KeepAlivePage(child: _buildEpisodeTab()),
                      _KeepAlivePage(child: _buildSeasonsTab()),
                      _KeepAlivePage(child: _buildCommentsTab()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  PLEYER OSTIDAGI QATOR: HOZIR NIMA KO'RILYAPTI
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): pleyer bilan qism o'tkazish tugmalari
  // ORASIDA — qaysi bo'lim va qism ko'rilayotgani, shu qism necha
  // marta ko'rilgani va qachon qo'shilgani ko'rinsin.
  //
  // Raqamlar qismlar ro'yxati bilan BIRGA keladi (`views_total`,
  // `watch_ms_total`, `created_at`) — qo'shimcha so'rov yo'q.
  Widget _buildNowPlayingBar() {
    final ep = _currentEp;
    if (ep == null) return const SizedBox(height: 8);

    final bolim = _seasonNum('bolim_id') > 0
        ? _seasonNum('bolim_id')
        : _seasonNum('season_id');
    final num_ = _epNumOf(ep);
    final views = (ep['views_total'] as num?)?.toInt() ?? 0;
    final watchMs = (ep['watch_ms_total'] as num?)?.toInt() ?? 0;
    final added = (ep['created_at'] as num?)?.toInt() ?? 0;

    // Karta BUTUN ENNI EGALLAMAYDI — kontent qancha bo'lsa
    // shuncha joy oladi (foydalanuvchi talabi: "eniga cho'zilgan,
    // kichikroq bo'lsin").
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Glass(
          borderRadius: 11,
          blur: 12,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Wrap(
            spacing: 10,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${bolim > 0 ? bolim : 1}-bo\'lim · ${num_}-qism',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              _nowStat(Icons.visibility_outlined, formatCount(views)),
              _nowStat(Icons.schedule_rounded, formatHours(watchMs)),
              if (added > 0)
                _nowStat(Icons.event_available_rounded, formatMoment(added)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nowStat(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11.5, color: Colors.white.withValues(alpha: 0.45)),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.62),
            fontSize: 10.5,
          ),
        ),
      ],
    );
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

  /// Boshqaruvni VIDEO KADRI ichida ushlab turadi.
  ///
  /// TALAB (foydalanuvchi): "tugmalar video kadrini chetida
  /// o'tmasin — hozir video kadr chetidan chiqib turibdi".
  ///
  /// Sabab: telefon ekrani 20:9, video esa 16:9 — fullscreen'da
  /// yon tomonlarda qora yo'laklar qoladi. Boshqaruv esa butun
  /// EKRAN bo'ylab chizilardi, ya'ni tugmalar va progress chizig'i
  /// videodan tashqariga, qora yo'lakka chiqib ketardi.
  ///
  /// Bu yerda o'sha yo'lak kengligi hisoblanadi va boshqaruvga
  /// chetlama (padding) sifatida beriladi. Video nisbati ekranga
  /// teng bo'lsa (yo'lak yo'q) hech narsa o'zgarmaydi.
  /// Boshqaruv elementlari uchun O'LCHAM KOEFFITSIENTI.
  ///
  /// TALAB (foydalanuvchi): "iloji bo'lsa tugmalar joylashuvi
  /// video o'lchamiga qarab o'zgarsin".
  ///
  /// Qiymat videoning EKRANDAGI haqiqiy kadridan olinadi (qora
  /// yo'laklar hisobga olinmaydi). Etalon — odatiy telefonning
  /// yon holatidagi 16:9 kadri (640x360 dp), ya'ni bunday
  /// qurilmada koeffitsient 1.0 va hech nima o'zgarmaydi.
  ///
  ///   * planshet / katta ekran -> kadr kattaroq -> tugmalar ham
  ///     kattaroq (1.6 gacha);
  ///   * 4:3 yoki tik video     -> kadr TOR -> tugmalar kichrayadi
  ///     (0.7 gacha), ya'ni ular kadrga bemalol sig'adi.
  ///
  /// Oddiy (portret) rejimda o'lcham o'zgarmaydi: u yerda
  /// boshqaruv allaqachon ixcham.
  double _ctrlScale(bool isFullscreen) {
    if (!isFullscreen) return 1.0;
    final m = MediaQuery.of(context).size;
    final ctrl = _controller;
    final ar = (ctrl != null &&
            ctrl.value.isInitialized &&
            ctrl.value.aspectRatio > 0)
        ? ctrl.value.aspectRatio
        : 16 / 9;
    var vw = m.width;
    var vh = m.height;
    if (vw / vh > ar) {
      vw = vh * ar;
    } else {
      vh = vw / ar;
    }
    final byWidth = vw / 640.0;
    final byHeight = vh / 360.0;
    final s = byWidth < byHeight ? byWidth : byHeight;
    return s.clamp(0.7, 1.6).toDouble();
  }

  Widget _inVideoFrame(Widget child) {
    return LayoutBuilder(
      builder: (context, c) {
        final ctrl = _controller;
        final ar = (ctrl != null &&
                ctrl.value.isInitialized &&
                ctrl.value.aspectRatio > 0)
            ? ctrl.value.aspectRatio
            : 16 / 9;
        var vw = c.maxWidth;
        var vh = c.maxHeight;
        if (vw / vh > ar) {
          vw = vh * ar;
        } else {
          vh = vw / ar;
        }
        final padX = ((c.maxWidth - vw) / 2).clamp(0.0, 1e6).toDouble();
        final padY = ((c.maxHeight - vh) / 2).clamp(0.0, 1e6).toDouble();
        if (padX < 1 && padY < 1) return child;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: padX, vertical: padY),
          child: child,
        );
      },
    );
  }

  Widget _buildPlayerCore({required bool isFullscreen}) {
    final ctrl = _controller;
    // Yuqori burchakdagi tugmalar ham video kadriga moslashadi.
    final btnS = _ctrlScale(isFullscreen);
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

          // Hech qanday qism ochilmagan. Odatda bu OFLAYN holat:
          // internet yo'q bo'lsa pleyer o'zi ochilmaydi
          // (foydalanuvchi talabi) — yuklab olingan qismni
          // foydalanuvchining O'ZI tanlaydi.
          if (_currentEp == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_outline_rounded,
                        color: Colors.white24, size: 52),
                    SizedBox(height: 8),
                    Text('Ko\'rmoqchi bo\'lgan qismni tanlang',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 13)),
                  ],
                ),
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

          if (_currentEp != null && !_isLocked)
            AnimatedOpacity(
              opacity: (_showControls || _playerLoading) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: _inVideoFrame(RepaintBoundary(
                    child: _buildControls(isFullscreen: isFullscreen))),
              ),
            ),

          // ── HALQA VA TUGMA: BITTA QATLAM ──────────────────────
          //
          // TOPILGAN XATO (foydalanuvchi: "pleyerda sek qilganda
          // aylanadigan progress chizig'idan IKKITA chiqib
          // qolyapti, bitta bo'lishi kerak edi").
          //
          // Sabab: halqa IKKI joyda chizilardi — kontrollar
          // ichidagi tugma atrofida va kontrollar yashiringandagi
          // alohida qatlamda. Ular `_showControls` bo'yicha
          // almashardi, LEKIN kontrollar `AnimatedOpacity` bilan
          // 200 ms so'nadi: bayroq o'zgargan zahoti ikkinchi halqa
          // chiqar, birinchisi esa hali so'nib ulgurmagan bo'lardi.
          // Ustiga ikkovi HAR XIL joyda turardi (biri kontrollar
          // ustunining o'rtasida, ikkinchisi ekran markazida) —
          // shu sabab ular ustma-ust ham tushmasdi va aniq ikkita
          // halqa bo'lib ko'rinardi.
          //
          // Endi play/pause tugmasi ham, halqa ham SHU YAGONA
          // qatlamda: joyi har doim bir xil (ekran markazi),
          // chizuvchi bitta. Kontrollar ichida bu tugma YO'Q —
          // u yerda faqat tugma egallaydigan bo'sh joy qoldi.
          //
          // Nima ko'rinishi holatga bog'liq:
          //
          //   * kontrollar ochiq   -> ikonka + progress halqasi;
          //   * kutish (buferlash, sek, tayyorlash) -> AYLANMA
          //     halqa — kontrollar ochiqmi yoki yopiqmi, farqi yo'q;
          //   * kontrollar yopiq va kutish yo'q -> hech nima.
          //
          // Tap faqat kontrollar ochiq bo'lganda qabul qilinadi:
          // aks holda videoga bosish kontrollarni chiqarish
          // o'rniga pauza qilib qo'yardi.
          if (_currentEp != null && _playerError == null && !_isLocked)
            IgnorePointer(
              ignoring: !_showControls,
              child: Center(
                child: _playPauseReactive(),
              ),
            ),

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
          if (_currentEp != null && (_preparing || _windowWaiting))
            Center(
              child: Transform.translate(
                offset: const Offset(0, 60),
                child: Text(
                  // Video ochilayotgani va videoning KEYINGI bo'lagi
                  // tayyorlanayotgani — foydalanuvchi uchun ikki xil
                  // holat, shu sabab yozuv ham boshqacha.
                  _windowWaiting
                      ? 'Videoning bu qismi tayyorlanmoqda...'
                      : 'Video tayyorlanyabdi...',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

          // ── QISQA XABAR ───────────────────────────────────────
          // Masalan: sek qilingan joyni tayyorlab bo'lmadi. Xato
          // ekrani (`_playerError`) dan farqli o'laroq bu ijroni
          // TO'XTATMAYDI — video o'z joyida ishlab turaveradi.
          if (_currentEp != null && _notice != null)
            Align(
              alignment: const Alignment(0, 0.62),
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _notice!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
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
          // Qulflanganda tap faqat kontrollarni toggle qiladi
          if (_currentEp != null && _isLocked)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onTapVideo,
              ),
            ),

          // boshqaruv paneli) bundan mustasno.
          if (_currentEp != null && !_isLocked)
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
                  // Tugmalar kadr o'lchamiga qarab kattalashadi —
                  // ular ustidagi "sek qilinmaydigan" zona ham
                  // xuddi shunday o'zgaradi.
                  final bottomGuard = _showControls
                      ? (isFullscreen ? 78.0 * btnS : 86.0)
                      : 0.0;
                  final topGuard =
                      (_showControls && isFullscreen) ? 60.0 * btnS : 0.0;
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
                      // Tap haqiqiy tugmalar ustiga tushgan bo'lsa
                      // — bu "videoga bosish" emas, tegilmaydi.
                      if (_showControls && _hitsControls(e.position)) return;
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

          // ── DOIM KO'RINADIGAN PROGRESS CHIZIQI (YouTube uslubi) ──
          //
          // TALAB (foydalanuvchi): "bittasi yo'qolmaguncha
          // ikkinchisi progress chizig'i chiqmasin".
          //
          // Ilgari u `!_showControls` bo'yicha DARHOL chiqardi,
          // kontrollar esa 200 ms so'nib borardi — natijada bir
          // lahza EKRANDA IKKITA chiziq turardi. Endi u
          // `_thinBarOn` ga qaraydi: bayroq kontrollar to'liq
          // so'ngach yoqiladi (`_syncThinBar`).
          //
          // Chiziq ham video kadri ichida — qora yo'lakka
          // cho'zilmaydi.
          if (_currentEp != null && _playerError == null)
            Positioned.fill(
              child: IgnorePointer(
                child: _inVideoFrame(
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _AlwaysVisibleProgress(
                      controller: _controller,
                      currentUrl: _currentUrl,
                      visible: _thinBarOn,
                      playViaLocal: _playViaLocal,
                    ),
                  ),
                ),
              ),
            ),

          // ── "O'TKAZIB YUBORISH" — ENG USTKI QATLAM ────────────
          //
          // Sek gesture qatlamidan KEYIN (ya'ni uning USTIDA)
          // turishi SHART: aks holda tugmaga bosilgan tap sek
          // qatlamiga tushib, video o'tkazish o'rniga oldinga
          // sakrab ketardi.
          // ── INTRO TUGMASI: CHAP YUQORIDA ──────────────────────
          //
          // TALAB (foydalanuvchi): "intro tugmasini pleyer
          // ekranining chap yuqori qismiga, ya'ni videoning chap
          // yuqori qismiga qo'y".
          //
          // Fullscreen'da kontrollar ochiq bo'lsa yuqori qatorda
          // "orqaga" tugmasi turadi — shu sabab intro tugmasi
          // o'sha qatorning TAGIGA tushadi, aks holda ular
          // ustma-ust kelardi.
          if (_currentEp != null && _playerError == null && _introVisible && !_isLocked)
            _inVideoFrame(Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(
                  left: isFullscreen ? 16 : 10,
                  top: isFullscreen && _showControls ? 54 : 10,
                ),
                child: _SkipIntroButton(onTap: _skipIntro),
              ),
            )),

          // ── UCH NUQTA MENYUSI ─────────────────────────────────
          //
          // TALAB (foydalanuvchi): "avto o'tkazishni bosganda oyna
          // yopilib ketmasin, faqat oyna tashqarisiga yoki 3ta
          // nuqtaga bossa yo'qolsin".
          //
          // Aynan shu sabab bu yerda `PopupMenuButton` ISHLATILMAYDI:
          // u tanlangan zahoti o'zini yopadi va buni o'zgartirib
          // bo'lmaydi. O'rniga oddiy uchta qatlam:
          //
          //   1. PARDA — butun ekranni qoplaydi, bosilsa yopadi;
          //   2. OYNA  — uch nuqta ostida;
          //   3. UCH NUQTA — pardadan USTIDA, ya'ni unga bosilsa
          //      menyu yopiladi (parda tutib qolmaydi).
          // ── TEZLIK PANELI (faqat fullscreen) ──────────────────
          if (_speedPanelOpen && isFullscreen)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeSpeedPanel,
              ),
            ),

          // ── PANEL O'NG TOMONDA ────────────────────────────
          //
          // TALAB (foydalanuvchi): panel o'ng tarafga o'tsin,
          // lekin ekran chetiga YOPISHIB qolmasin, va eniga ham
          // bo'yiga ham biroz kattalashsin.
          //
          // Ilgari u `bottomLeft` + `bottom: 90` edi: chap chekka
          // va pastdan 90 — sakkizta qator bunga sig'masdi, ya'ni
          // ro'yxatning tepasi va "2×" qirqilib qolardi (yon
          // holatda ekran bo'yi kichik).
          //
          // Endi `centerRight`: panel o'ngda, chekkadan 24 joy
          // qoldirib, ekran bo'yi bo'ylab O'RTADA turadi. Bo'yi
          // ekranning 85% idan oshmaydi — sig'magani ichida
          // suriladi, ya'ni hech qachon qirqilmaydi.
          if (_speedPanelOpen && isFullscreen)
            _inVideoFrame(Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 24),
                child: _PlayerPanel(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 6),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight:
                          MediaQuery.of(context).size.height * 0.85,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final s in const [
                            0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0
                          ])
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _setSpeed(s),
                              child: Container(
                                width: 72,
                                // Bo'yi kichraytirildi (9 -> 5):
                                // sakkizta qator ekranda juda
                                // baland turardi (foydalanuvchi
                                // talabi). Eni o'zgarmadi.
                                padding: const EdgeInsets.symmetric(
                                    vertical: 5),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _playbackSpeed == s
                                      ? AppColors.accent
                                          .withValues(alpha: 0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${s == s.truncate() ? s.toStringAsFixed(0) : s.toString()}×',
                                  style: TextStyle(
                                    color: _playbackSpeed == s
                                        ? AppColors.accent
                                        : Colors.white,
                                    fontSize: 14,
                                    fontWeight: _playbackSpeed == s
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )),

          // ── SIFAT PANELI (faqat fullscreen) ──────────────────
          if (_qualityPanelOpen && isFullscreen)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeQualityPanel,
              ),
            ),

          // Tezlik paneli bilan BIR XIL: o'ngda, chetdan 24 joy
          // qoldirib, ekran bo'yi bo'ylab o'rtada. Ilgari u
          // `bottom: 90` edi va o'ng chekkaga yopishib turardi.
          if (_qualityPanelOpen && isFullscreen && _currentEp != null)
            _inVideoFrame(Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 24),
                child: _PlayerPanel(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 10),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight:
                          MediaQuery.of(context).size.height * 0.85,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final q in ['1080p', '720p', '480p', '360p']
                              .where(_availableQualities(_currentEp!).contains))
                            () {
                              final sel = _selectedQuality == q ||
                                  (_selectedQuality == null &&
                                      q == _qualityLabel(_currentEp!));
                              final size =
                                  (_currentEp!['size_$q'] as String?) ?? '';
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _selectQualityFromPanel(q),
                                child: Container(
                                  width: 160,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 11),
                                  margin:
                                      const EdgeInsets.symmetric(vertical: 3),
                                  decoration: BoxDecoration(
                                    color: sel
                                        ? AppColors.accent
                                            .withValues(alpha: 0.2)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(q.toUpperCase(),
                                          style: TextStyle(
                                              color: sel
                                                  ? AppColors.accent
                                                  : Colors.white,
                                              fontSize: 16,
                                              fontWeight: sel
                                                  ? FontWeight.w800
                                                  : FontWeight.w600)),
                                      if (size.isNotEmpty) ...[
                                        const Spacer(),
                                        Text(size,
                                            style: TextStyle(
                                                color: sel
                                                    ? AppColors.accent
                                                        .withValues(alpha: 0.7)
                                                    : Colors.white54,
                                                fontSize: 12)),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            }(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )),

          // ── QISMLAR RO'YXATI PANELI (faqat fullscreen) ─────────
          if (_episodeListOpen && isFullscreen)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeEpisodeListPanel,
              ),
            ),

          // ── QISMLAR RO'YXATI: ILOJI BORICHA KATTA ──────────
          //
          // TALAB (foydalanuvchi): bu oyna kattaroq va qulayroq
          // bo'lsin. Ilgari eni qat'iy 220 edi — uzun qism
          // nomlari sig'masdi, tugmalar esa mayda edi.
          //
          // Endi eni EKRANGA QARAB olinadi (yarmigacha, 300–460
          // oralig'ida), bo'yi esa deyarli to'liq (yuqori-quyi
          // 12 dan). Qatorlar ham kattalashdi: barmoq bilan
          // bosish oson.
          if (_episodeListOpen && isFullscreen)
            _inVideoFrame(Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: (MediaQuery.of(context).size.width * 0.5)
                    .clamp(300.0, 460.0)
                    .toDouble(),
                margin: const EdgeInsets.symmetric(
                    vertical: 12, horizontal: 16),
                child: _PlayerPanel(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10, left: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${_seasonStr('nomi')} · '
                                '${(_seasonNum('bolim_id') > 0 ? _seasonNum('bolim_id') : _seasonNum('season_id') > 0 ? _seasonNum('season_id') : 1)}-bo\'lim',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            // Nechta qism borligi — ro'yxat uzun
                            // bo'lsa foydali.
                            const SizedBox(width: 8),
                            Text(
                              '${_orderedEps.length} qism',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.12)),
                      const SizedBox(height: 6),
                      Flexible(
                        child: ListView.builder(
                          controller: _epListCtrl,
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _orderedEps.length,
                          itemBuilder: (context, index) {
                            final ep = _orderedEps[index];
                            final num_ = _epNumOf(ep);
                            final isCurrent = _currentEp != null &&
                                _epKeyOf(ep) == _epKeyOf(_currentEp!);
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                _closeEpisodeListPanel();
                                if (!isCurrent) {
                                  _playEpisode(ep,
                                      resumeAt: _savedPositionOf(ep),
                                      resumePlaying: _intendedPlaying);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 13),
                                margin:
                                    const EdgeInsets.symmetric(vertical: 2),
                                decoration: BoxDecoration(
                                  color: isCurrent
                                      ? AppColors.accent
                                          .withValues(alpha: 0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    if (isCurrent)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: Icon(
                                            Icons.play_arrow_rounded,
                                            size: 20,
                                            color: AppColors.accent),
                                      ),
                                    Text(
                                      '$num_-qism',
                                      style: TextStyle(
                                        color: isCurrent
                                            ? AppColors.accent
                                            : Colors.white,
                                        fontSize: 16,
                                        fontWeight: isCurrent
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                      ),
                                    ),
                                    if ((ep['epizod_name'] ?? '')
                                        .toString()
                                        .isNotEmpty) ...[
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          ep['epizod_name'].toString(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isCurrent
                                                ? AppColors.accent
                                                    .withValues(alpha: 0.7)
                                                : Colors.white54,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )),

          // ── UCH NUQTA MENYUSI BU YERDA EMAS ───────────────
          //
          // TALAB (foydalanuvchi): "pleyerdan tashqariga
          // bosganda ham oyna yashirinsin".
          //
          // Ilgari menyu ham, uni yopadigan parda ham SHU
          // Stack'da — ya'ni pleyer maydonida — turardi. Parda
          // pleyerdan tashqarisini qoplamagani uchun, pastdagi
          // qismlar ro'yxatiga bosilsa menyu ochiq qolaverardi.
          //
          // Endi u butun ekran ustidagi qatlamda — `build()` ga
          // qarang (`_buildMenuOverlay`).

          // ── FULLSCREEN: YUQORI O'NG BURCHAK TUGMALARI ─────────
          //
          // TALAB (foydalanuvchi): "qulflash tugmasini bosganda
          // tugmaning O'ZI qulf holatiga o'tsin, chap tarafdan
          // boshqa qizil qulf chiqmasin".
          //
          // Ilgari qulflanganda bu qator butunlay yo'qolib, uning
          // o'rniga CHAP yuqorida alohida qizil qulf tugmasi
          // chiqardi — ya'ni tugma "sakrab" ketardi. Endi tugma
          // joyida qoladi, faqat ko'rinishi o'zgaradi:
          //
          //   * ochiq  -> oq "lock_open" ikonkasi;
          //   * qulf   -> qizil "lock" ikonkasi (fon bilan).
          //
          // Qulflanganda yonidagi sozlamalar va fullscreen
          // tugmalari ko'rinmaydi — qulfning ma'nosi ham shu.
          if (_currentEp != null &&
              _playerError == null &&
              isFullscreen &&
              (_showControls || _settingsPanelOpen))
            _inVideoFrame(Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: EdgeInsets.only(right: 8 * btnS, top: 6 * btnS),
                child: Row(
                  key: _topBtnsKey,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggleLock,
                      child: Container(
                        margin: EdgeInsets.all(4 * btnS),
                        padding: EdgeInsets.all(5 * btnS),
                        decoration: BoxDecoration(
                          color: _isLocked
                              ? AppColors.accent.withValues(alpha: 0.25)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10 * btnS),
                          border: Border.all(
                            color: _isLocked
                                ? AppColors.accent.withValues(alpha: 0.45)
                                : Colors.transparent,
                          ),
                        ),
                        child: Icon(
                          _isLocked
                              ? Icons.lock_rounded
                              : Icons.lock_open_rounded,
                          color:
                              _isLocked ? AppColors.accent : Colors.white,
                          size: 22 * btnS,
                        ),
                      ),
                    ),
                    if (!_isLocked) ...[
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _showSettingsPanel,
                        child: Padding(
                          padding: EdgeInsets.all(9 * btnS),
                          // SOZLAMALAR ikonkasi. Ilgari bu yerda
                          // chaqmoq (`bolt`) turardi — u sozlamani
                          // emas, "tez rejim"ni anglatadi.
                          child: Icon(Icons.settings_rounded,
                              color: Colors.white, size: 22 * btnS),
                        ),
                      ),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggleFullscreen,
                        child: Padding(
                          padding: EdgeInsets.all(9 * btnS),
                          child: Icon(Icons.fullscreen_exit_rounded,
                              color: Colors.white, size: 22 * btnS),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )),

          // Normal (fullscreen bo'lmagan) rejimda uch nuqta tugmasi
          if (_currentEp != null &&
              _playerError == null &&
              !isFullscreen &&
              (_showControls || _menuOpen))
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 4, top: 2),
                child: GestureDetector(
                  key: _menuBtnKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleMenu,
                  child: const Padding(
                    padding: EdgeInsets.all(9),
                    child: Icon(Icons.more_vert_rounded,
                        color: Colors.white, size: 22),
                  ),
                ),
              ),
            ),

          // ── SOZLAMALAR PANELI (bolt tugmasi, fullscreen) ──────
          if (_settingsPanelOpen && isFullscreen && !_isLocked)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeSettingsPanel,
              ),
            ),

          if (_settingsPanelOpen && isFullscreen && !_isLocked)
            _inVideoFrame(Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 50),
                child: _PlayerPanel(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  // Aniq kenglik: qatorlar bir xil uzunlikda
                  // bo'ladi va oyna yozuv uzunligiga qarab
                  // sakramaydi. Chapdan tekislangan — o'ngdan
                  // tekislanganda ro'yxat tartibsiz ko'rinardi.
                  //
                  // BALANDLIK CHEKLANGAN va ichi SURILADI: menyu
                  // pleyer maydonidan baland bo'lsa Stack uni
                  // kesib tashlardi va pastki qatorlarga yetib
                  // bo'lmasdi (uxlash oynasida aynan shu bo'lgan).
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.5,
                    ),
                    child: SizedBox(
                      width: 260,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                      _MenuToggleRow(
                        icon: Icons.fast_forward_rounded,
                        label: 'Avto intro o\'tkazish',
                        on: AppSettings.instance.autoSkipIntro,
                        onToggle: _toggleAutoSkipIntro,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      _MenuToggleRow(
                        icon: Icons.skip_next_rounded,
                        label: 'Avto qism o\'tkazish',
                        on: AppSettings.instance.autoNextEpisode,
                        onToggle: _toggleAutoNextEpisode,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      // ── UXLASH VAQTI (fullscreen sozlamalari) ──
                      //
                      // TALAB (foydalanuvchi): "sozlamalardagi vaqt
                      // tugmasini ham kattalashtir — faqat uch
                      // nuqtadagini kattalashtiribsan".
                      //
                      // Endi u yuqoridagi ikki qator bilan BIR XIL:
                      // 46 px balandlik, belgi 20, yozuv 14/w600
                      // va butun eni bo'ylab bosiladi.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          _closeSettingsPanel();
                          _showSleepPanel();
                        },
                        child: SizedBox(
                          height: 46,
                          child: Row(
                            children: [
                              Icon(Icons.schedule_rounded,
                                  size: 20,
                                  color: _sleepMinutes > 0
                                      ? AppColors.accent
                                      : Colors.white70),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _sleepMinutes > 0
                                      ? 'Uxlash: ${_sleepTimeLabel()}'
                                      : 'Uxlash vaqti',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _sleepMinutes > 0
                                        ? AppColors.accent
                                        : Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  ),
                    ),
                    ),
                ),
              ),
            )),

          // ── UXLASH VAQTI OYNASI BU YERDA EMAS ──────────────
          //
          // U ilgari shu Stack'da — ya'ni PLEYER MAYDONIDA —
          // turardi. Maydon esa kichik (normal rejimda ekranning
          // atigi uchdan biri), shu sabab oyna siqilib chiqardi
          // va raqam tugmalari qirqilib qolardi.
          //
          // Endi u butun ekran ustida chiziladi — `build()` ga
          // qarang.
        ],
      ),
    );
  }

  Widget _buildControls({required bool isFullscreen}) {
    // Hamma o'lchamlar shu koeffitsientga ko'paytiriladi — ya'ni
    // boshqaruv videoning ekrandagi kadriga MOSLASHADI.
    final s = _ctrlScale(isFullscreen);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.60),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.85),
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
                padding: EdgeInsets.fromLTRB(12 * s, 6 * s, 12 * s, 0),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _toggleFullscreen,
                      child: Padding(
                        padding: EdgeInsets.all(8 * s),
                        child: Icon(Icons.arrow_back_rounded,
                            color: Colors.white, size: 24 * s),
                      ),
                    ),
                    SizedBox(width: 4 * s),
                    // ── SARLAVHA: ANIME NOMI + TAGIDA BO'LIM/QISM ──
                    //
                    // TALAB (foydalanuvchi): "orqaga qaytish
                    // tugmasi yonida anime nomi va tagida
                    // N-bo'lim va N-qismligi yozilgan bo'lsin".
                    //
                    // Ilgari bu yerda faqat bitta qator — qism
                    // nomi (yoki anime nomi) turardi, ya'ni
                    // fullscreen'da qaysi bo'lim va nechanchi
                    // qism ko'rilayotgani bilinmasdi.
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _seasonStr('nomi').isNotEmpty
                                ? _seasonStr('nomi')
                                : (_currentEp?['epizod_name'] ?? '')
                                    .toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14 * s),
                          ),
                          if (_currentEp != null) ...[
                            SizedBox(height: 2 * s),
                            Text(
                              () {
                                final b = _seasonNum('bolim_id') > 0
                                    ? _seasonNum('bolim_id')
                                    : (_seasonNum('season_id') > 0
                                        ? _seasonNum('season_id')
                                        : 1);
                                final q = _epNumOf(_currentEp!);
                                final epName =
                                    (_currentEp!['epizod_name'] ?? '')
                                        .toString();
                                final base = '$b-bo\'lim · $q-qism';
                                // Qismning O'Z nomi bo'lsa u ham
                                // shu qatorda ko'rinadi.
                                return epName.isEmpty
                                    ? base
                                    : '$base · $epName';
                              }(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 11.5 * s),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // O'ng yuqorida uch nuqta turadi (Stack'dagi
                    // alohida qatlamda) — sarlavha uning tagiga
                    // kirib ketmasligi uchun joy qoldiriladi.
                    SizedBox(width: 44 * s),
                  ],
                ),
              ),

            const Spacer(),

            // ── O'rta qator: play/pause tugmasi uchun BO'SH JOY ────
            //
            // Tugmaning o'zi bu yerda EMAS — u Stack'dagi alohida
            // qatlamda, ekran markazida turadi (yuqoridagi "HALQA VA
            // TUGMA: BITTA QATLAM" izohiga qarang). Bu yerda faqat
            // o'sha tugma egallaydigan balandlik qoldirildi, ya'ni
            // ustun tuzilishi va pastki panelning o'rni o'zgarmadi.
            //
            // Sek tugmalari olib tashlangan — ularning o'rniga video
            // ustida ikki marta bosish orqali ishlaydigan gesture bor.
            SizedBox(height: _playPauseDiameter(isFullscreen)),

            const Spacer(),

            KeyedSubtree(
              key: _bottomBarKey,
              child: _bottomBarReactive(isFullscreen: isFullscreen, scale: s),
            ),
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
  /// Markazdagi play/pause tugmasi VA yagona kutish halqasi.
  ///
  /// Kutish deb hisoblanadigan holatlar (foydalanuvchi uchun bularning
  /// hammasi bir xil: "video hozir tayyorlanmoqda"):
  ///   * video endi ochilmoqda (`_playerLoading`, `_preparing`);
  ///   * pleyer buferlamoqda (`isBuffering`);
  ///   * sek kutilmoqda yoki bajarilmoqda;
  ///   * progress chizig'i barmoq bilan surilmoqda.
  ///
  /// Ikonka esa faqat kontrollar ochiq bo'lganda ko'rinadi. Ya'ni
  /// kontrollar yashiringan paytda ekranda faqat aylanma halqa
  /// qoladi — va u HAR DOIM bitta bo'ladi.
  Widget _playPauseReactive() {
    // Yuklanish/tayyorlanish paytida kontrollar majburiy ochiladi,
    // shu sabab ikonka ham o'shanda ko'rinadi.
    //
    // FULLSCREEN'DA YO'Q: u yerda play/pause pastki qatorda turadi
    // va ikkitasi bir vaqtda ko'rinib, ekranda ikki xil play
    // tugmasi paydo bo'lardi. Aylanma halqa (kutish belgisi) esa
    // baribir chiziladi — u `busy` ga bog'liq, `showIcon` ga emas.
    final showIcon = (_showControls || _playerLoading) && !_isFullscreen;

    final ctrl = _controller;
    if (ctrl == null) {
      return GestureDetector(
        onTap: _togglePlayPause,
        child: _centerButton(
          playing: false,
          busy: true,
          showIcon: showIcon,
        ),
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) {
        final busy = !value.isInitialized ||
            value.isBuffering ||
            _isScrubbing ||
            _seekBusy ||
            // Videoning keyingi bo'lagi keshga olinayotgan payt ham
            // "kutish" holati — halqa aylanib turishi kerak.
            _windowWaiting ||
            _pendingTarget != null;
        return GestureDetector(
          onTap: _togglePlayPause,
          child: _centerButton(
            playing: busy ? _intendedPlaying : value.isPlaying,
            busy: busy,
            showIcon: showIcon,
          ),
        );
      },
    );
  }

  /// Halqa + ikonka. HALQANI CHIZADIGAN YAGONA JOY.
  ///
  /// TALAB (foydalanuvchi): "play/pause atrofida aylanadigan chiziq
  /// qolsin va avvalgidek aylansin, faqat orqasida kichkina qizil
  /// chiziq bor — shuni olib tashla".
  ///
  /// Ya'ni halqa ENDI FAQAT kutish paytida (aylanma yoy sifatida)
  /// chiziladi. Videoning qayeridaligini ko'rsatadigan qizil yoy
  /// (va uning orqasidagi xira halqa) butunlay olib tashlandi —
  /// vaqt pastdagi progress chizig'ida ko'rinib turibdi.
  ///
  /// | kutish | ikonka | ekranda                        |
  /// |--------|--------|--------------------------------|
  /// | ha     | ha     | aylanma halqa + ikonka         |
  /// | ha     | yo'q   | faqat aylanma halqa            |
  /// | yo'q   | ha     | faqat ikonka                   |
  /// | yo'q   | yo'q   | hech nima (bo'sh joy)          |
  Widget _centerButton({
    required bool playing,
    required bool busy,
    required bool showIcon,
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
          // Halqa faqat kutish paytida bor — aks holda ikonka
          // atrofida hech nima chizilmaydi.
          if (busy)
            _PlayerRing(
              size: ringSize,
              strokeWidth: 2.6,
              color: AppColors.accent,
            ),
          if (showIcon) _playPauseIcon(playing: playing, size: iconSize),
        ],
      ),
    );
  }

  // Play/pause tugmasining haqiqiy (doira) diametri — ikonka o'lchami
  // + atrofidagi 12px padding ikki tarafdan. Sek gesture'idagi o'lik
  // zona kengligi va sek ko'rsatkichining o'lchami shu qiymatga
  // asoslanadi.
  double _playPauseDiameter(bool isFullscreen) {
    // Ikonka (40) + ichki padding (12×2) + halqa uchun joy (6×2),
    // hammasi kadr o'lchamiga qarab (`_ctrlScale`).
    return (40.0 + 12 * 2 + 6 * 2) * _ctrlScale(isFullscreen);
  }

  Widget _playPauseIcon({required bool playing, required double size}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
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

  // Faqat slayder/vaqtni eng tor ko'lamda yangilaydi.
  Widget _bottomBarReactive(
      {required bool isFullscreen, double scale = 1.0}) {
    final ctrl = _controller;
    // Progress chizig'idagi OQ (tayyor) qism uchun: mahalliy
    // ijroda DownloadManager hisobi kerak bo'ladi.
    Widget bar(VideoPlayerValue? value) => AnimatedBuilder(
          animation: DownloadManager.instance,
          builder: (context, _) => _bottomBar(value, isFullscreen, scale),
        );
    if (ctrl == null) return bar(null);
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) => bar(value),
    );
  }

  Widget _bottomBar(VideoPlayerValue? value, bool isFullscreen,
      [double scale = 1.0]) {
    double bufferedRatio = 0.0;
    if (value != null &&
        value.isInitialized &&
        value.duration.inMilliseconds > 0) {
      Duration ahead = Duration.zero;
      for (final r in value.buffered) {
        if (r.end > ahead) ahead = r.end;
      }
      // ── OQ CHIZIQ ROSTINI KO'RSATSIN ────────────────────
      //
      // TOPILGAN XATO: bu yerda diskdagi ulush (`dlStat.ratio`)
      // PLEYERNING BUFERI o'rniga ko'rsatilardi — fayl qisman
      // yuklab olingan bo'lsa ham. Ya'ni oq chiziq "shu yergacha
      // tayyor" deb turardi, aslida esa pleyerda o'sha ma'lumot
      // YO'Q edi: u worker'dan oqim oladi.
      //
      // Natijada foydalanuvchi "bufer ichiga" sek qilaman deb
      // o'ylab, aslida bufer TASHQARISIGA sek qilardi — pleyer
      // esa tabiiy ravishda hammasini qaytadan yuklardi.
      //
      // Endi disk ulushi FAQAT mahalliy ijroda (fayl to'liq
      // yuklangan va 127.0.0.1 dan o'qilayotganda) ko'rsatiladi —
      // o'shanda u haqiqatan "tayyor" degani. Aks holda
      // pleyerning O'Z buferi.
      final dlStat = DownloadManager.instance.statOf(_currentUrl);
      if (_playViaLocal && dlStat.ratio > 0) {
        bufferedRatio = dlStat.ratio;
      } else {
        bufferedRatio = (ahead.inMilliseconds / value.duration.inMilliseconds)
            .clamp(0.0, 1.0);
      }
    }
    final eps = _orderedEps;
    final i = _currentEpIndex;
    final hasNext = i > 0;
    final hasPrev = i >= 0 && i < eps.length - 1;
    return _BottomBar(
          scale: scale,
          position: _pendingTarget ?? value?.position ?? Duration.zero,
          duration: value?.duration ?? Duration.zero,
          buffered: bufferedRatio,
          fmt: _fmt,
          onSeek: (d) {
            _scheduleSeekTo(d);
            _scheduleHide();
          },
          onQualityTap: isFullscreen ? _showQualityPanel : _showQualityDialog,
          onFullscreen: _toggleFullscreen,
          isFullscreen: isFullscreen,
          onSpeedTap: isFullscreen ? _showSpeedPanel : null,
          onPrev: isFullscreen && hasPrev ? () => _stepEpisode(-1) : null,
          onNext: isFullscreen && hasNext ? () => _stepEpisode(1) : null,
          onPlayPause: isFullscreen ? _togglePlayPause : null,
          onEpisodeList: isFullscreen ? _showEpisodeListPanel : null,
          isPlaying: _intendedPlaying,
          hasPrev: hasPrev,
          hasNext: hasNext,
          // "1x" / "1.5x" — tugmada aynan shu yoziladi.
          speedLabel: _playbackSpeed == _playbackSpeed.roundToDouble()
              ? '${_playbackSpeed.toInt()}x'
              : '${_playbackSpeed}x',
          onScrubStart: () {
            _hideTimer?.cancel();
            if (!_isScrubbing) setState(() => _isScrubbing = true);
          },
          onScrubEnd: () {
            if (_isScrubbing) setState(() => _isScrubbing = false);
            _scheduleHide();
          },
        );
  }

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

  /// Qismning O'ZGARMAS IDsi (`epizod_db.epizod_id`).
  ///
  /// Tomosha tarixi, "davom ettirish" va kadrlar AYNAN shu bilan
  /// bog'lanadi: qism raqami o'zgarsa ham yozuv joyida qoladi.
  static int _epIdOf(Map<String, dynamic> ep) =>
      int.tryParse('${ep['epizod_id'] ?? ''}') ?? 0;

  /// Manzil qaysi sifatga tegishli ('' — topilmadi).
  static String _qualityOfUrl(Map<String, dynamic> ep, String url) {
    if (url.isEmpty) return '';
    for (final k in ['1080p', '720p', '480p', '360p']) {
      if ((ep['url_$k'] ?? '').toString() == url) return k;
    }
    return '';
  }

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

  /// To'xtatish boshlangan payt — "qulf ochilmay qolish"dan
  /// himoya uchun (pastdagi `_gestureBusy` izohiga qarang).
  DateTime _heldAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _holdDownloadUpdates() {
    if (_dlHeld) return;
    _dlHeld = true;
    _heldAt = DateTime.now();
    DownloadManager.instance.hold();
  }

  void _releaseDownloadUpdates() {
    if (!_dlHeld) return;
    _dlHeld = false;
    DownloadManager.instance.release();
  }

  /// Hozir barmoq ekranda (ro'yxat yoki oynalar surilmoqda).
  ///
  /// Davriy ishlar (holat so'rovi, sog'liq tekshiruvi) shu paytda
  /// o'tkazib yuboriladi: ular UI oqimida bajariladi va aynan kadr
  /// tayyorlanayotgan paytga to'g'ri kelsa, surish "tutilib"
  /// ko'rinadi.
  ///
  /// HIMOYA: surish tugaganini bildiruvchi xabar biror sababga
  /// ko'ra kelmay qolsa (ekran almashdi, ro'yxat qayta qurildi),
  /// qulf abadiy yopiq qolmasin — 5 soniyadan keyin o'zi ochiladi.
  bool get _gestureBusy {
    if (!_dlHeld) return false;
    if (DateTime.now().difference(_heldAt) > const Duration(seconds: 5)) {
      _releaseDownloadUpdates();
      return false;
    }
    return true;
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

  // ═══════════════════════════════════════════════════════════
  //  EKRAN OCHILGANDA QAYSI QISM YUKLANADI
  // ═══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "bosh sahifadan qaysi animeni ustiga
  // bossa pleyrda aynan o'sha animega tegishli oxirgi marta
  // ko'rilgan qism kelgan joydan ochilishi kerak".
  //
  // Tartib:
  //   1. tarixdan kelingan bo'lsa — AYNAN o'sha qism, aynan
  //      o'sha vaqtdan (`widget.startEpizodId` / `startAt`);
  //   2. shu bo'limning tomosha tarixida yozuvi bo'lsa — o'sha
  //      qism, to'xtagan joyidan;
  //   3. aks holda — eng birinchi qism, boshidan.
  //
  // IJRO O'ZI BOSHLANMAYDI: kesh-server birinchi bo'lakni oladi
  // va birinchi kadr ekranda turadi, "play" bosilishi bilan video
  // darhol ketadi.
  //
  // OFLAYNDA HAM OCHILADI (2026-09 da o'zgardi): qism to'liq
  // yuklab olingan bo'lsa. Yuklanmagan bo'lsa pleyer o'rnida
  // avvalgidek bo'sh joy qoladi va foydalanuvchi yuklab olingan
  // qismni o'zi tanlaydi.
  void _autoOpenEpisode() {
    if (!mounted || _currentEp != null) return;
    // Internet bor-yo'qligi hali noma'lum — bir zumdan keyin
    // `_watchConnectivity` o'zi qayta chaqiradi.
    if (!_connectivityKnown) return;
    if (_orderedEps.isEmpty) return;
    // ── OFLAYNDA HAM OCHILADI ─────────────────────────────────
    //
    // TOPILGAN XATO (foydalanuvchi: "oflayn vaqtda tomosha
    // tarixidagi kadr ustiga bossa aynan o'sha epizod ochilsin").
    //
    // Bu yerda ilgari shunchaki `if (_offline) return;` turardi —
    // ya'ni internet yo'q bo'lsa pleyer HECH QACHON o'zi qism
    // ochmasdi, hatto qism to'liq yuklab olingan bo'lsa ham.
    //
    // Endi oflaynda ham ochiladi; `_getUrl` allaqachon faqat
    // TO'LIQ yuklab olingan sifatni beradi, ya'ni ochib
    // bo'lmaydigan qism baribir ochilmaydi (pastda tekshiriladi).

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

      var target = _resumeTarget(eps);
      if (_getUrl(target.$1).isEmpty) {
        // Oflaynda tanlangan qism yuklab olinmagan bo'lishi
        // mumkin (masalan bo'lim birinchi marta ochilyapti).
        // Shunday bo'lsa YUKLAB OLINGAN eng oxirgi qism
        // ochiladi — ro'yxat kamayish tartibida saralangan.
        final ready = eps.where((e) => _getUrl(e).isNotEmpty);
        if (ready.isEmpty) return;
        target = (ready.first, _savedPositionOf(ready.first));
      }
      // Tarixdan kelingan bo'lsa IJRO ham darhol boshlanadi
      // (foydalanuvchi aynan o'sha qismni bosgan). Bosh sahifadan
      // kelinganda esa, avvalgidek, birinchi kadr ekranda turadi
      // va "play" ni foydalanuvchi bosadi.
      _playEpisode(
        target.$1,
        resumeAt: target.$2,
        resumePlaying: widget.startEpizodId != null,
      );
      _centerOnEpisode(target.$1);
    });
  }

  /// Qaysi qism va qaysi nuqtadan ochilishi kerak.
  ///
  /// Ro'yxat KAMAYISH tartibida saralangan (3, 2, 1, 0) — shu sabab
  /// eng birinchi qism ro'yxatning OXIRIDA turadi.
  (Map<String, dynamic>, Duration?) _resumeTarget(
      List<Map<String, dynamic>> eps) {
    // 1) Tarixdan kelindi — qismning IDsi bo'yicha.
    final wanted = widget.startEpizodId;
    if (wanted != null) {
      for (final e in eps) {
        if (_epIdOf(e) == wanted) return (e, widget.startAt);
      }
    }

    // 2) Shu bo'limning oxirgi ko'rilgan qismi.
    final animeId = int.tryParse(widget.season['anime_id']?.toString() ?? '');
    final seasonId = int.tryParse(widget.season['season_id']?.toString() ?? '');
    if (animeId != null && seasonId != null) {
      final last = WatchHistory.instance.lastOfSeason(animeId, seasonId);
      if (last != null) {
        for (final e in eps) {
          if (_epIdOf(e) != last.epizodId) continue;
          return (e, _savedPositionOf(e));
        }
      }
    }

    // 3) Eng birinchi qism.
    return (eps.last, null);
  }

  /// Shu qism QAYERDA to'xtatilgan.
  ///
  /// Avval telefondagi nuqta (`WatchProgress` — har soniyada
  /// yangilanadi, eng aniq), bo'lmasa tomosha tarixidagi nuqta.
  ///
  /// Ikkinchi manba SHART: telefondagi ro'yxat sifat bo'yicha
  /// (video manzili bo'yicha) saqlanadi va ilova qayta
  /// o'rnatilganda yoki boshqa sifat tanlanganda bo'sh bo'ladi —
  /// o'shanda ham qism boshidan emas, KELGAN JOYIDAN ochilishi
  /// kerak (foydalanuvchi talabi).
  Duration? _savedPositionOf(Map<String, dynamic> ep) {
    final local = WatchProgress.instance.positionOf(_getUrl(ep));
    if (local != null) return local;

    final animeId = int.tryParse(widget.season['anime_id']?.toString() ?? '');
    final seasonId = int.tryParse(widget.season['season_id']?.toString() ?? '');
    if (animeId == null || seasonId == null) return null;
    final saved =
        WatchHistory.instance.findEpisode(animeId, seasonId, _epIdOf(ep));
    if (saved == null || saved.positionMs <= 0) return null;
    return Duration(milliseconds: saved.positionMs);
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

  /// Keyingi qism BORMI.
  ///
  /// Ro'yxat kamayish tartibida (3-qism, 2-qism, 1-qism...), ya'ni
  /// keyingi qism indeksda YUQORIDA turadi — shu sabab shart
  /// `> 0`. Joriy qism topilmasa (`-1`) o'tadigan joy ham yo'q.
  bool get _hasNextEpisode => _currentEpIndex > 0;

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
    _playEpisode(eps[target],
        resumeAt: _savedPositionOf(eps[target]),
        resumePlaying: _intendedPlaying);
    _centerOnEpisode(eps[target]);
    // Keyingi/oldingi qism bosilgandan keyin ham boshqaruv
    // 5 soniya turadi.
    _scheduleHide();
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
            color: Colors.white.withValues(alpha: enabled ? 0.10 : 0.035),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: Colors.white.withValues(alpha: enabled ? 0.20 : 0.06)),
          ),
          child: Icon(icon,
              size: 24,
              color: Colors.white.withValues(alpha: enabled ? 0.95 : 0.22)),
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
        backgroundColor: AppColors.card,
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
    // Video o'chirilgach "qayerda to'xtagan" nuqtasi ham kerak emas.
    WatchProgress.instance.forget(q.url);

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
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5))));
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
              // Qism KELGAN JOYIDAN ochiladi (boshidan emas).
              _playEpisode(ep, resumeAt: _savedPositionOf(ep));
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
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5))));
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
                  ? AppColors.accent.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: isCur
                      ? AppColors.accent.withValues(alpha: 0.4)
                      : Colors.white12),
            ),
            child: Row(
              children: [
                if (photoUrl != null && photoUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                        cacheManager: AppImageCache.manager,
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
                              color: Colors.white.withValues(alpha: 0.45),
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

  // ══════════════════════════════════════════════════════════
  //  MA'LUMOT OYNASI
  // ══════════════════════════════════════════════════════════
  //
  // Yuqorida ikkita tugma: BAHOLASH (10 ta yulduz) va
  // SEVIMLILARGA QO'SHISH — ikkovi ham BO'LIM darajasida
  // (foydalanuvchi talabi).
  //
  // Tagida shu bo'limning umumiy raqamlari: ko'rishlar, tomosha
  // vaqti, sevimlilar soni, reyting, qismlar soni va qo'shilgan
  // sana. Undan keyin esa to'liq ma'lumot.
  //
  // Raqamlar avval bo'lim ro'yxati bilan kelgan qiymatlardan
  // ko'rsatiladi, keyin `GET /api/season/...` javobi bilan
  // aniqlashadi — ya'ni oyna hech qachon bo'sh turmaydi.

  int _seasonNum(String key) {
    final fresh = _info?.season[key];
    if (fresh is num) return fresh.toInt();
    final base = widget.season[key];
    if (base is num) return base.toInt();
    return int.tryParse(base?.toString() ?? '') ?? 0;
  }

  /// Bo'limning matnli maydoni.
  ///
  /// AVVAL `_info` (to'liq qator — serverdan yoki diskdagi
  /// nusxadan), keyin ekranga kelgan `widget.season`.
  ///
  /// Tartib SHUNDAY bo'lishi SHART: tarixdan yoki sevimlilardan
  /// ochilganda `widget.season` da atigi bir necha maydon bo'ladi
  /// (anime_id, season_id, nomi, rasm) — studiya, tarjimon, janr
  /// va tavsif faqat `_info` da bo'ladi. Ilgari bu yerda faqat
  /// `widget.season` o'qilardi va aynan shu sabab oflaynda (ham
  /// tarixdan ochilganda) ma'lumotlar bo'sh ko'rinardi.
  String _seasonStr(String key) {
    final fresh = _info?.season[key];
    if (fresh != null && fresh.toString().isNotEmpty) return fresh.toString();
    return (widget.season[key] ?? '').toString();
  }

  Widget _buildInfoTab(String tavsif) {
    final studio = _seasonStr('studio');
    final tarjimon = _seasonStr('tarjimon');
    final holati = _seasonStr('holati');
    final turi = _seasonStr('turi');
    final yili = _seasonStr('yili');
    final janri = _seasonStr('janri');

    final info = _info;
    final bolim = _seasonNum('bolim_id');
    final created = _seasonNum('created_at');
    final ratingCount = _seasonNum('rating_count');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── BAHOLASH / SEVIMLILAR ─────────────────────────
          Row(
            children: [
              Expanded(
                child: _ActionTile(
                  icon: info != null && info.myStars > 0
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  color: AppColors.gold,
                  label: info != null && info.myStars > 0
                      ? 'Bahoyingiz: ${info.myStars}'
                      : 'Baholash',
                  onTap: _showRatingSheet,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionTile(
                  icon: (info?.isFav ?? false)
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: AppColors.accent,
                  label: (info?.isFav ?? false)
                      ? 'Sevimlilarda'
                      : 'Sevimlilarga qo\'shish',
                  onTap: _toggleFavorite,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── BO'LIM RAQAMLARI ──────────────────────────────
          Glass(
            borderRadius: 18,
            blur: 14,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statLine(Icons.visibility_outlined, 'Ko\'rishlar',
                    formatCount(_seasonNum('views_total'))),
                _statLine(Icons.schedule_rounded, 'Tomosha vaqti',
                    '${formatHours(_seasonNum('watch_ms_total'))} soat'),
                _statLine(Icons.favorite_border_rounded,
                    'Sevimlilarga qo\'shilgan',
                    formatCount(_seasonNum('fav_count'))),
                _statLine(
                  Icons.star_border_rounded,
                  'Reyting',
                  ratingCount > 0
                      ? '${formatRating(info?.rating ?? 0)}'
                          '  (${formatCount(ratingCount)} ta baho)'
                      : 'hali baholanmagan',
                ),
                _statLine(
                  Icons.movie_creation_outlined,
                  'Bo\'lim',
                  '${bolim > 0 ? bolim : 1}-bo\'lim · '
                      '${formatCount(_seasonNum('epizod_count'))} qism',
                ),
                if (created > 0)
                  _statLine(Icons.event_available_rounded, 'Qo\'shilgan sana',
                      formatMoment(created)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── TO'LIQ MA'LUMOT ───────────────────────────────
          Glass(
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
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 14,
                          height: 1.6)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statLine(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.white.withValues(alpha: 0.45)),
          const SizedBox(width: 9),
          Text(
            '$label:',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── BAHOLASH: 10 TA YULDUZ ────────────────────────────────
  //
  // Yulduzcha bosilganda ekranda 10 ta sariq yulduz chiqadi;
  // qaysi biri bosilsa, o'sha baho saqlanadi (qayta bosilsa
  // o'zgaradi).
  Future<void> _showRatingSheet() async {
    final aid = int.tryParse(widget.season['anime_id']?.toString() ?? '') ?? 0;
    final sid = int.tryParse(widget.season['season_id']?.toString() ?? '') ?? 0;
    if (aid <= 0) return;

    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _RatingSheet(current: _info?.myStars ?? 0),
    );
    if (chosen == null || !mounted) return;

    // Baho DARHOL qabul qilinadi va diskka yoziladi; serverga
    // esa navbat bilan, keyingi paketda ketadi. Shu sabab
    // internet bo'lmasa ham "saqlanmadi" degan xato chiqmaydi.
    final next = SeasonService.rate(aid, sid, chosen, _baseInfo());
    setState(() => _info = next);
  }

  Future<void> _toggleFavorite() async {
    final aid = int.tryParse(widget.season['anime_id']?.toString() ?? '') ?? 0;
    final sid = int.tryParse(widget.season['season_id']?.toString() ?? '') ?? 0;
    if (aid <= 0) return;
    final want = !(_info?.isFav ?? false);

    // Tugma DARHOL javob beradi: holat diskka yoziladi, serverga
    // esa keyingi paket bilan ketadi. Ortga qaytariladigan xato
    // yo'q — internet bo'lmasa yozuv navbatda kutadi.
    final next = SeasonService.setFavorite(aid, sid, want, _baseInfo());
    setState(() => _info = next);
    // Kutubxonadagi "Sevimlilar" ro'yxati endi eskirdi.
    FavoritesService.instance.markChanged();
  }

  /// Ekranda turgan holat; hali yuklanmagan bo'lsa — bo'lim
  /// qatoridan yasalgan bo'sh holat.
  SeasonInfo _baseInfo() =>
      _info ??
      SeasonInfo(
        season: Map<String, dynamic>.from(widget.season),
        rating: 0,
        myStars: 0,
        isFav: false,
      );

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
                      color: Colors.white.withValues(alpha: 0.5), fontSize: 13))),
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
            ? AppColors.accent.withValues(alpha: 0.14)
            : Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isCurrent
                ? AppColors.accent.withValues(alpha: 0.5)
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
                                ? AppColors.accent.withValues(alpha: 0.28)
                                : Colors.white.withValues(alpha: 0.08),
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
                      color: Colors.white.withValues(alpha: 0.08),
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
        // Tezlik FAQAT yuklash ketayotganda ko'rsatiladi —
        // foydalanuvchi "sekinlashdimi yoki yo'q"ni shu raqamdan
        // ko'radi (ilgari ekranda faqat foiz bor edi).
        final speed = st.downloading && !st.queued ? st.speedLabel : '';
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(info.label,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(width: 8),
                        Text('${st.percent}%',
                            style: TextStyle(
                                color: st.complete
                                    ? AppColors.accent
                                    : Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(width: 8),
                        Text(
                            '${_mb(st.downloaded)} / $totalLabel',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.65),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                    if (speed.isNotEmpty || st.retrying || st.queued) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          // Bir vaqtda 3 ta sifat yuklanadi, qolgani
                          // bosilish tartibida kutadi.
                          if (st.queued)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text('navbatda',
                                  style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700)),
                            ),
                          if (speed.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(speed,
                                  style: TextStyle(
                                      color: AppColors.accent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700)),
                            ),
                          if (st.retrying) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text('qayta urinilmoqda',
                                  style: TextStyle(
                                      color: Colors.orange,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 5),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: st.ratio,
                          minHeight: 4,
                          backgroundColor: Colors.white.withValues(alpha: 0.10),
                          valueColor: AlwaysStoppedAnimation(
                              st.complete ? Colors.white : AppColors.accent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!st.complete)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (st.downloading) {
                      DownloadManager.instance.pause(info.url);
                    } else {
                      DownloadManager.instance.download(info.url);
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.only(left: 5),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: st.downloading
                          ? AppColors.accent.withValues(alpha: 0.22)
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: st.downloading
                            ? AppColors.accent.withValues(alpha: 0.4)
                            : Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Icon(
                        st.downloading
                            ? Icons.pause_rounded
                            : Icons.download_rounded,
                        size: 23,
                        color: st.downloading
                            ? AppColors.accent
                            : Colors.white),
                  ),
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
              ? AppColors.accent.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.08),
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
// Bitta vazifasi bor: GOOGLE USLUBIDA aylanish — yoy avval
// uzayadi va boshi tez yuguradi, keyin qisqaradi va sekinlashadi.
//
// TALAB (foydalanuvchi): "play/pause atrofida aylanadigan chiziq
// qolsin va avvalgidek aylansin, faqat orqasida kichkina qizil
// chiziq bor — shuni olib tashla". Shu sabab bu halqa FAQAT
// kutish paytida yaratiladi va hech qachon "progress" ko'rinishiga
// o'tmaydi — `busy`, `progress`, `trackColor` maydonlari olib
// tashlangan.
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

  const _PlayerRing({
    required this.size,
    required this.strokeWidth,
    required this.color,
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
    )..repeat();
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
              color: widget.color,
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
  final Color color;
  final double strokeWidth;

  const _PlayerRingPainter({
    required this.t,
    required this.color,
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
      old.t != t || old.color != color || old.strokeWidth != strokeWidth;
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
        color: Colors.black.withValues(alpha: 0.55),
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
/// Fullscreen boshqaruvidagi YUMALOQ TUGMA.
///
/// Hamma tugma bitta shakl va o'lchamda bo'lishi uchun alohida
/// ajratilgan — ilgari har biri joyida qo'lda yozilardi va
/// o'lchamlari bir-biriga mos kelmasdi.
///
/// `onTap` `null` bo'lsa tugma o'chgan holatda ko'rinadi (yo'qolib
/// qolmaydi): ro'yxat chetida ekanini ko'rsatadi.
class _FsButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  /// Asosiy tugma (play/pause) — kattaroq va urg'u rangida.
  final bool primary;

  /// Video kadriga qarab o'lcham koeffitsienti.
  final double scale;

  const _FsButton({
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    final size = (primary ? 52.0 : 42.0) * scale;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary
              ? AppColors.accent.withValues(alpha: on ? 0.9 : 0.3)
              : Colors.black.withValues(alpha: on ? 0.45 : 0.25),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: on ? 0.18 : 0.06),
          ),
        ),
        child: Icon(
          icon,
          color: Colors.white.withValues(alpha: on ? 1 : 0.3),
          size: (primary ? 30 : 24) * scale,
        ),
      ),
    );
  }
}

/// Fullscreen boshqaruvidagi YOZUVLI tugma (tezlik, sifat).
///
/// Yumaloq tugmalar bilan bir xil fon va chekkada — ikkovi birga
/// bitta to'plamdek ko'rinadi.
class _FsChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  /// Video kadriga qarab o'lcham koeffitsienti.
  final double scale;

  const _FsChip(
      {required this.label,
      this.icon,
      required this.onTap,
      this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 30 * scale,
        constraints: BoxConstraints(minWidth: 44 * scale),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: 10 * scale),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(15 * scale),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white, size: 16 * scale),
              SizedBox(width: 4 * scale),
            ],
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12 * scale,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatefulWidget {
  /// Video kadriga qarab o'lcham koeffitsienti (`_ctrlScale`).
  final double scale;
  final Duration position;
  final Duration duration;
  final double buffered;

  final String Function(Duration) fmt;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onQualityTap;
  final VoidCallback onFullscreen;
  final bool isFullscreen;
  final VoidCallback? onSpeedTap;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onPlayPause;
  final VoidCallback? onEpisodeList;
  final bool isPlaying;
  final bool hasPrev;
  final bool hasNext;
  /// Hozirgi tezlik ("1x", "1.5x"). Tugmada AYNAN shu ko'rinadi —
  /// "Tezlik" so'zidan ko'ra foydaliroq: qaysi tezlik yoqilganini
  /// oynani ochmasdan bilish mumkin (yirik pleyerlar shunday qiladi).
  final String speedLabel;
  final VoidCallback onScrubStart;
  final VoidCallback onScrubEnd;

  const _BottomBar({
    this.scale = 1.0,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.fmt,
    required this.onSeek,
    required this.onQualityTap,
    required this.onFullscreen,
    required this.isFullscreen,
    this.onSpeedTap,
    this.onPrev,
    this.onNext,
    this.onPlayPause,
    this.onEpisodeList,
    this.isPlaying = false,
    this.hasPrev = false,
    this.hasNext = false,
    this.speedLabel = '1x',
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
    //
    // TALAB (foydalanuvchi): "progress chizig'i, vaqt va tugmalarni
    // kichraytir, vaqt bilan tugmalarni o'ng tarafga sur va progress
    // chizig'ini o'ng tarafga cho'z — shunda chiziq uchun kengroq
    // joy ochiladi va ishlatish qulayroq bo'ladi".
    //
    // Avval oddiy (fullscreen bo'lmagan) rejimda elementlar ataylab
    // KATTA edi (vaqt 14, fullscreen ikonkasi 31 px). Ular pastki
    // qatorning yarmiga yaqinini egallab, progress chizig'iga juda
    // kam joy qoldirardi — 24 daqiqalik videoda bir-ikki piksel bir
    // necha soniyaga teng bo'lib, aniq surish qiyin edi.
    //
    // Endi o'lchamlar ixcham: vaqt 14 -> 11.5, ikonka 31 -> 22,
    // HQ 13 -> 10.5, tugmalar orasidagi bo'shliqlar ham qisqardi.
    // Bo'shagan ~70 piksel to'liq progress chizig'iga o'tadi
    // (`Expanded` qolgan hamma joyni oladi).
    final compact = !widget.isFullscreen;
    final trackHeight = compact ? 3.5 : 3.0;
    final thumbRadius = compact ? 6.0 : 5.0;
    final timeFont = compact ? 11.5 : 10.5;
    final iconSize = compact ? 22.0 : 20.0;
    final hqFont = compact ? 10.5 : 10.0;

    if (!compact) {
      // ── FULLSCREEN: tugmalar yuqorida, PROGRESS ENG PASTDA ──
      //
      // TALAB (foydalanuvchi): "progress chizig'ini pastga tushir"
      // va "vaqtni tezlik tugmasining chap yoniga qo'y".
      //
      // Shu sabab ustun tartibi o'zgardi. Ilgari:
      //   progress -> vaqt (chapda) + tezlik/HQ (o'ngda) -> tugmalar
      // Endi:
      //   vaqt + tezlik + HQ (hammasi o'ngda) -> tugmalar -> progress
      //
      // Ya'ni chiziq ekranning eng pastida, barmoq bilan surish
      // uchun eng qulay joyda turadi.
      final s = widget.scale;
      return Padding(
        padding: EdgeInsets.fromLTRB(12 * s, 0, 12 * s, 6 * s),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── TEZLIK + SIFAT — O'NG chetda ──────────────────
            //
            // VAQT bu qatorda EMAS (foydalanuvchi talabi): tezlik
            // tugmasi yonida u ko'rinmay ketardi. Endi u
            // tugmalardan KEYIN, progress chizig'ining ustida —
            // pastga qarang.
            Row(
              children: [
                const Spacer(),
                if (widget.onSpeedTap != null) ...[
                  // TEZLIK — IKONKA (yozuv emas, foydalanuvchi
                  // talabi). Yonidagi kichik raqam hozirgi tezlikni
                  // aytadi, shu sabab oynani ochmasdan ko'rinadi.
                  _FsChip(
                    icon: Icons.speed_rounded,
                    label: widget.speedLabel,
                    onTap: widget.onSpeedTap!,
                    scale: s,
                  ),
                  SizedBox(width: 8 * s),
                ],
                // HQ — sifat tugmasi ataylab YOZUV bo'lib qoladi:
                // foydalanuvchi uni aynan "HQ" deb so'ragan.
                _FsChip(
                    label: 'HQ', onTap: widget.onQualityTap, scale: s),
              ],
            ),
            SizedBox(height: 6 * s),
            // ── QISM BOSHQARUVI — O'NG CHETDA ─────────────────
            //
            // TALAB (foydalanuvchi, aynan shu so'zlar bilan):
            // "vaqt tagiga yani O'NG CHETGA keyingi qismga
            // o'tkazadigan tugma va chap tarafida play pause
            // tugmasi va chap tarafida oldingi qismga o'tkazadigan
            // tugma va chap tarafida qismlar ro'yxati".
            //
            // Ya'ni o'ngdan chapga: keyingi | play | oldingi |
            // ro'yxat. Chapdan o'ngga yozilganda tartib teskari
            // bo'ladi va qator O'NGGA yopishtiriladi.
            //
            // TOPILGAN XATO: qatorda hizalash umuman yo'q edi, shu
            // sabab tugmalar CHAPDA turardi.
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onEpisodeList != null) ...[
                  _FsButton(
                    icon: Icons.playlist_play_rounded,
                    onTap: widget.onEpisodeList,
                    scale: s,
                  ),
                  SizedBox(width: 10 * s),
                ],
                _FsButton(
                  icon: Icons.skip_previous_rounded,
                  onTap: widget.hasPrev ? widget.onPrev : null,
                  scale: s,
                ),
                SizedBox(width: 10 * s),
                if (widget.onPlayPause != null) ...[
                  _FsButton(
                    icon: widget.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    onTap: widget.onPlayPause,
                    primary: true,
                    scale: s,
                  ),
                  SizedBox(width: 10 * s),
                ],
                _FsButton(
                  icon: Icons.skip_next_rounded,
                  onTap: widget.hasNext ? widget.onNext : null,
                  scale: s,
                ),
              ],
            ),
            SizedBox(height: 6 * s),
            // ── ENG PASTKI QATOR: CHIZIQ + YONIDA VAQT ────────
            //
            // TALAB (foydalanuvchi): "progress chizig'ining o'ng
            // tarafini birozgina qisqartir va chiziqning
            // to'g'risiga vaqtni qo'y; vaqt ustidagi tugmalarni
            // pastga tushir — ular ekran o'rtasiga yaqin turibdi".
            //
            // Vaqt endi ALOHIDA qatorda emas, chiziq bilan BIR
            // qatorda: shu sabab tugmalar bir qator pastga
            // tushdi va chiziq o'ng tarafdan vaqt egallagan
            // joycha qisqardi.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _VideoProgressBar(
                    played: ratio,
                    buffered: widget.buffered,
                    trackHeight: 5.0 * s,
                    thumbRadius: 8.0 * s,
                    onDragStart: () {
                      setState(() => _dragValue = ratio);
                      widget.onScrubStart();
                    },
                    onDragUpdate: (v) => setState(() => _dragValue = v),
                    onDragEnd: _commit,
                    onTapSeek: _commit,
                  ),
                ),
                SizedBox(width: 10 * s),
                Text(
                  '${widget.fmt(shownPosition)} / ${widget.fmt(widget.duration)}',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 13 * s,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // ── ODDIY (portrait) rejim ──
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 0, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: _VideoProgressBar(
              played: ratio,
              buffered: widget.buffered,
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
          const SizedBox(width: 6),
          Text(
            '${widget.fmt(shownPosition)}/${widget.fmt(widget.duration)}',
            style: TextStyle(
                color: Colors.white,
                fontSize: timeFont,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: widget.onQualityTap,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: Colors.white30)),
              child: Text('HQ',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: hqFont,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 3),
          GestureDetector(
            onTap: widget.onFullscreen,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 3, vertical: 4),
              child: Icon(Icons.fullscreen_rounded,
                  color: Colors.white, size: iconSize),
            ),
          ),
        ],
      ),
    );
  }
}

/// Uch qatlamli progress chizig'i (shaffof / oq / accent) + tutqich.
class _VideoProgressBar extends StatefulWidget {
  final double played;
  final double buffered;
  final double trackHeight;
  final double thumbRadius;

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;
  final ValueChanged<double> onTapSeek;

  const _VideoProgressBar({
    required this.played,
    this.buffered = 0.0,
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
            //
            // Tutqich kichraytirilgani sabab (8 -> 6) bu qo'shimcha
            // balandlik biroz oshirildi: ko'rinish ixchamlashdi,
            // lekin BOSISH ZONASI avvalgidek qulay qoldi.
            height: thumb + 20,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Orqa chiziq (xira)
                Container(
                  width: w,
                  height: track,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(track / 2),
                  ),
                ),
                // Buffer chiziqi (oq)
                if (widget.buffered > 0)
                  Container(
                    width: w * widget.buffered.clamp(0.0, 1.0),
                    height: track,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(track / 2),
                    ),
                  ),
                // O'tilgan qism (accent)
                Container(
                  width: w * played.clamp(0.0, 1.0),
                  height: track,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(track / 2),
                  ),
                ),
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

// ══════════════════════════════════════════════════════════════
//  MA'LUMOT OYNASI UCHUN KICHIK VIDJETLAR
// ══════════════════════════════════════════════════════════════

/// Yulduzcha / yurakcha tugmasi: belgi va uning tagida yozuv.
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      // Belgi va yozuv YONMA-YON — tugma bo'yiga ikki barobar
      // kichrayadi (foydalanuvchi talabi).
      child: Glass(
        borderRadius: 13,
        blur: 12,
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: color),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 10 ta sariq yulduz — qaysi biri bosilsa, o'sha baho.
class _RatingSheet extends StatefulWidget {
  final int current;
  const _RatingSheet({required this.current});

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  /// Tanlangan yulduzlar soni. "Baholash" bosilmaguncha hech
  /// narsa saqlanmaydi.
  int _hover = 0;

  @override
  void initState() {
    super.initState();
    _hover = widget.current;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Glass(
          borderRadius: 22,
          blur: 18,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Bu bo\'limni baholang',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _hover > 0 ? '$_hover / 10' : '10 ballik tizim',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 14),
              // Kichik ekranda ham sig'sin: 10 ta yulduz teng
              // bo'linadi. Bosilgani FAQAT tanlanadi — saqlash
              // uchun "Baholash" bosiladi (foydalanuvchi talabi).
              Row(
                children: List.generate(10, (i) {
                  final star = i + 1;
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _hover = star),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Icon(
                          star <= _hover
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 28,
                          color: star <= _hover
                              ? AppColors.gold
                              : Colors.white24,
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Bekor qilish'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _hover > 0
                          ? () => Navigator.of(context).pop(_hover)
                          : null,
                      child: const Text('Baholash'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Oynani TIRIK saqlaydi: surish paytida qayta qurilmaydi.
///
/// Kuchsiz telefonda oynalar orasida surganda qotish aynan
/// qayta qurishdan bo'ladi.
// ══════════════════════════════════════════════════════════════
//  "O'TKAZIB YUBORISH" TUGMASI
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "intro tugmasi HQ tugmasi bilan BIR XIL
// darajadagi shaffoflikda bo'lsin".
//
// Shu sabab ko'rinishi pastki paneldagi `HQ` tugmasidan AYNAN
// ko'chirilgan: fon oq 15%, chekkasi `white30`, burchagi 7.
// Ikkovini birga o'zgartiring — aks holda ular ajralib qoladi.
//
// Nomi — "O'tkazish" (foydalanuvchi aniq shunday so'ragan),
// joyi — videoning CHAP YUQORI burchagi. Tugma intro oralig'i
// TUGAGUNCHA turadi.
/// ── PLEYER USTIDAGI OYNALAR: HIRA SHISHA ────────────────────
///
/// TALAB (foydalanuvchi): "pleyerdagi o'tkazish va 3 nuqtani
/// bosganda chiqadigan oynalarni va yozuvlarning qirralarini
/// tiniqlashtir — shaffof bo'lgani uchun yaxshi ko'rinmayapti,
/// yoki hira oyna effektiga o'xshash qilib o'zgartir".
///
/// Ilgari oyna oddiy yarim shaffof to'rtburchak edi: ochiq rangli
/// kadr ustida yozuv ham, chegara ham yo'qolib ketardi.
///
/// Endi uch qatlam:
///   1. quyuq, DEYARLI TO'LA fon — yozuv har qanday kadr ustida
///      o'qiladi;
///   2. aniq chegara — oynaning qirrasi ko'rinib turadi.
///
/// ── `BackdropFilter` NEGA OLIB TASHLANDI ────────────────────
///
/// TALAB (foydalanuvchi): "uini tez va qotmasdan ishlaydigan
/// qil".
///
/// Ilgari bu yerda `BackdropFilter(sigma: 18)` turardi — orqadagi
/// kadrni xiralashtirardi. Bu ilovadagi ENG QIMMAT chizma edi:
///
///   * u `saveLayer` ochadi, ya'ni GPU oynaning ostidagi butun
///     sohani alohida buferga ko'chiradi va blur qiladi;
///   * ostida esa JONLI VIDEO turadi — demak bu ish soniyasiga
///     24-60 marta, HAR KADRDA qaytarilardi;
///   * oyna esa allaqachon 92% quyuq edi, ya'ni xiralashtirilgan
///     kadr deyarli KO'RINMASDI ham.
///
/// Endi fon to'la quyuq. Ko'rinishi deyarli o'sha (rasmdagi
/// uslubda ham oynalar tekis to'q rangli), pleyer esa blursiz
/// ishlaydi.
class _PlayerPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const _PlayerPanel({required this.child, required this.padding});

  @override
  Widget build(BuildContext context) {
    // ── KO'RINISH (foydalanuvchi talabi bilan qayta sozlangan) ──
    //
    // Ilgari panel yarim shaffof (0.52) va oq chekkasi kuchli
    // (0.28) edi: orqadagi video ichidan ko'rinib turib, yozuvni
    // o'qish qiyinlashardi va oyna "iflos" ko'rinardi.
    //
    // Endi fon TO'LA to'q, chekka esa zo'rg'a sezilarli — oyna
    // videodan aniq ajralib turadi va yozuv tiniq o'qiladi.
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderBright, width: 1),
      ),
      child: child,
    );
  }
}

class _SkipIntroButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SkipIntroButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // Tugma atrofidagi kichik bo'sh joy ham tapni qabul qiladi —
      // barmoq bilan tushish oson bo'lsin.
      behavior: HitTestBehavior.opaque,
      child: _PlayerPanel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fast_forward_rounded, size: 15, color: Colors.white),
            SizedBox(width: 5),
            Text(
              'O\'tkazish',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  UCH NUQTA MENYUSI — "AVTO O'TKAZISH"
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "oyna HQ tugmasidek SHAFFOF bo'lib
// chiqishi kerak, yoqib o'chiradigan tugma nomini `avto
// o'tkazish` deb qo'y — juda ko'p joy egallab turibdi, biroz
// kichraytir. Avto o'tkazishni bosganda oyna yopilib ketmasin,
// faqat oyna tashqarisiga yoki 3ta nuqtaga bossa yo'qolsin."
//
// Keyinroq ikkinchi tugma qo'shildi: "avto qism o'tkazish" —
// video tugashi bilan keyingi qismga o'zi o'tadi. Shu sabab
// vidjet endi NOMNI ham parametr qilib oladi va menyuda
// ikkitasi ustma-ust turadi.
//
// Shu sabab bu YUPQA vidjet: `PopupMenuButton` emas (u tanlangan
// zahoti o'zini yopadi), oddiy `Container`. Ochish/yopish
// pleyerning o'zida (`_menuOpen`), parda esa Stack'da.
//
// Ko'rinishi pastki paneldagi `HQ` tugmasidan olingan: fon oq
// 15%, chekkasi `white30`, burchagi 7 — uchovi birga
// o'zgartiriladi.
class _MenuToggleRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool on;
  final VoidCallback onToggle;

  const _MenuToggleRow({
    required this.label,
    required this.icon,
    required this.on,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: SizedBox(
        // Barmoq bilan bosish qulay bo'lishi uchun 38 -> 46
        // (foydalanuvchi: "bosish qiyin bo'lyapti").
        height: 46,
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.white70),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              on ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
              size: 30,
              color: on ? AppColors.accent : Colors.white30,
            ),
          ],
        ),
      ),
    );
  }
}

/// YouTube uslubidagi doim ko'rinadigan progress chiziqi.
/// Kontrollar yashiringanda pastda ingichka, shaffof chiziq turadi.
/// Kontrollar ochiq bo'lganda yashirinadi (asosiy progress bar ko'rinadi).
class _AlwaysVisibleProgress extends StatelessWidget {
  final VideoPlayerController? controller;
  final String currentUrl;
  final bool visible;

  /// Mahalliy (to'liq yuklangan) fayldan ijro etilyaptimi.
  /// Faqat o'shanda diskdagi ulush "tayyor" degani — aks holda
  /// pleyerning O'Z buferi ko'rsatiladi (asosiy chiziqdagi
  /// izohga qarang).
  final bool playViaLocal;

  const _AlwaysVisibleProgress({
    required this.controller,
    required this.currentUrl,
    required this.visible,
    required this.playViaLocal,
  });

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final ctrl = controller;
    if (ctrl == null) return const SizedBox.shrink();
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) {
        if (!value.isInitialized || value.duration.inMilliseconds <= 0) {
          return const SizedBox.shrink();
        }
        final played = (value.position.inMilliseconds /
                value.duration.inMilliseconds)
            .clamp(0.0, 1.0);
        Duration ahead = Duration.zero;
        for (final r in value.buffered) {
          if (r.end > ahead) ahead = r.end;
        }
        final dlStat = DownloadManager.instance.statOf(currentUrl);
        final buffered = (playViaLocal && dlStat.ratio > 0)
            ? dlStat.ratio
            : (ahead.inMilliseconds / value.duration.inMilliseconds)
                .clamp(0.0, 1.0);

        return SizedBox(
          height: 3,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              return Stack(
                children: [
                  Container(
                    width: w,
                    height: 3,
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                  if (buffered > 0)
                    Container(
                      width: w * buffered,
                      height: 3,
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                  Container(
                    width: w * played,
                    height: 3,
                    color: AppColors.accent.withValues(alpha: 0.85),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // ── NEGA `RepaintBoundary` ────────────────────────────────
    //
    // Surish paytida PageView ikkala oynani bir vaqtda ko'rsatadi
    // va ularni HAR KADRDA surib turadi. Alohida qatlam
    // bo'lmasa, oynaning butun mazmuni (ro'yxat, soyalar,
    // yumaloq burchaklar) har kadrda QAYTADAN chiziladi —
    // kuchsiz telefonda aynan shu "qotish" bo'lib ko'rinadi.
    //
    // `RepaintBoundary` bilan har bir oyna bir marta chizilib,
    // GPU'da tayyor qatlam sifatida saqlanadi: surish esa o'sha
    // tayyor qatlamni KO'CHIRISHga aylanadi.
    return RepaintBoundary(child: widget.child);
  }
}

// ══════════════════════════════════════════════════════════════
//  OBUNA KERAK
// ══════════════════════════════════════════════════════════════
//
// Obunasi yo'q odam pleyer o'rniga SHU ekranni ko'radi. Bu yerda
// video umuman yuklanmaydi va hech qanday tarmoq so'rovi yo'q.
class _SubRequiredScreen extends StatelessWidget {
  const _SubRequiredScreen();

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [AppColors.gold, AppColors.accent2],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              AppColors.gold.withValues(alpha: 0.30),
                          blurRadius: 26,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.workspace_premium_rounded,
                        size: 44, color: AppColors.accentTint),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Obuna kerak',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Anime ko\'rish uchun obuna bo\'lishi kerak. '
                    'Tariflar 1 kundan 30 kungacha — profil '
                    'sahifasidan yoki quyidagi tugmadan tanlang.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.62),
                      fontSize: 13.5,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      // Tugma nomi "Obuna olish" — demak AYNAN
                      // Obuna oynasi ochilsin. Oynalar tartibi
                      // almashtirilgach (0 — To'ldirish) bu
                      // raqamsiz To'ldirish ochilib qolardi.
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const BillingScreen(startPage: 1),
                        ),
                      ),
                      child: const Text(
                        'Obuna olish',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () =>
                        BillingService.instance.load(force: true),
                    child: Text(
                      'Obunani yangilash',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
