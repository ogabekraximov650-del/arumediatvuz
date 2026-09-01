import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
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
// Mahalliy Rust kesh-serveri (127.0.0.1) O'ZGARISHSIZ qoladi:
// ExoPlayer oddiy HTTP Range so'rovlari bilan ishlaydi.
import 'package:video_player/video_player.dart';

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
  String? _selectedQuality;
  bool _playerLoading = false;
  int _playToken = 0;
  String? _playerError;

  // ── Ikki marta bosib sek qilishda tarmoqqa yuboriladigan seekTo
  // so'rovini debounce qilish uchun: tez-tez ketma-ket bosilganda
  // faqat OXIRGI holatga BITTA marta sek qilinadi.
  Timer? _seekDebounceTimer;
  Duration? _pendingSeekBase;
  int _pendingSeekDeltaSeconds = 0;

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
    _loadEpisodes();
    _loadSeasons();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabCtrl.dispose();
    _hideTimer?.cancel();
    _leftSeekHideTimer?.cancel();
    _rightSeekHideTimer?.cancel();
    _seekDebounceTimer?.cancel();
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

  // ── Player yordamchilari ───────────────────────────────────────
  String _getUrl(Map<String, dynamic> ep) {
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
      _showControls = true;
      _playerLoading = true;
      _playerError = null;
      _intendedPlaying = resumePlaying;
    });

    // Sek navbatini tozalaymiz — eski epizodga tegishli so'rovlar
    // yangisiga tushib qolmasligi kerak.
    _seekDebounceTimer?.cancel();
    _queuedSeek = null;
    _pendingSeekBase = null;
    _pendingSeekDeltaSeconds = 0;
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

    // ── Video manzili: HAMISHA mahalliy kesh-server orqali ────
    Uri source;
    bool viaProxy = true;
    try {
      source = await VideoCacheServer.instance.proxyUri(url);
    } catch (e) {
      VideoCacheServer.log('proxyUri xato berdi, asl URL ishlatiladi: $e');
      source = Uri.parse(url);
      viaProxy = false;
    }
    if (!mounted || myToken != _playToken) return;

    var ctrl = await _openController(source, myToken);
    // Mahalliy proksi ishlamasa — kesh bo'lmasa ham video ochilishi
    // uchun asl URL bilan qayta urinamiz.
    if (ctrl == null && viaProxy) {
      if (!mounted || myToken != _playToken) return;
      VideoCacheServer.log('Zaxira: asl URL bilan qayta urinilyapti...');
      ctrl = await _openController(Uri.parse(url), myToken);
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

    // Video tugaganda o'zi boshidan boshlanadi. Bu NATIVE (ExoPlayer)
    // takrorlash — u fayl oxirini o'zi to'g'ri boshqaradi, bizning
    // qo'lda "qayta ochish" mantig'imiz kerak emas.
    try {
      await ctrl.setLooping(true);
    } catch (_) {}

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
    _startHealthWatchdog();
    _scheduleHide();
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
  void _onControllerUpdate() {
    final c = _controller;
    if (c == null || !mounted) return;
    if (c.value.hasError && !_recovering) {
      VideoCacheServer.log('Pleyer xatosi: ${c.value.errorDescription}');
      _recoverPlayer(c.value.position);
    }
  }

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

    if (ctrl.value.isPlaying) {
      setState(() => _intendedPlaying = false);
      ctrl.pause();
    } else {
      setState(() => _intendedPlaying = true);
      ctrl.play();
    }
    _scheduleHide();
  }

  // Ketma-ket tez-tez bosilgan double-tap seklarni yig'ib, faqat OXIRGI
  // holatga BITTA marta ctrl.seekTo() chaqiradi (debounce ~220ms).
  // Bu tarmoqqa ortiqcha seek so'rovlari ketib, ularning navbatga
  // to'planib video "qotib qolishi"ning oldini oladi. Vizual jamlanish
  // (_leftSeekAccum/_rightSeekAccum va ularning ko'rsatkichi) darhol,
  // hech qanday kechikishsiz yangilanadi — foydalanuvchi taplarning
  // "his qilinishini" yo'qotmaydi, faqat haqiqiy tarmoq/dekod so'rovi
  // kechiktiriladi.
  void _scheduleSeek(int deltaSeconds) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    _pendingSeekBase ??= ctrl.value.position;
    _pendingSeekDeltaSeconds += deltaSeconds;

    // Ketma-ket bosilgan taplar bitta so'rovga birlashtiriladi
    // (debounce). ExoPlayer sek so'rovlarini o'zi ham birlashtiradi,
    // lekin bu qatlam platformaga bo'ladigan chaqiruvlar sonini
    // yanada kamaytiradi.
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(const Duration(milliseconds: 90), () {
      final base = _pendingSeekBase;
      final delta = _pendingSeekDeltaSeconds;
      _pendingSeekBase = null;
      _pendingSeekDeltaSeconds = 0;
      _seekDebounceTimer = null;

      final c = _controller;
      if (base == null || c == null || !c.value.isInitialized) return;
      final dur = c.value.duration;
      var t = base + Duration(seconds: delta);
      if (t < Duration.zero) t = Duration.zero;
      // Oldinga sek qilib video oxiriga (yoki undan nariga) yetib borsa,
      // ctrl.seekTo(duration) chaqirish pleyerni "qotirib qo'yishi"
      // mumkin (EOF holati). Avval bunday holatda video BOSHIGA
      // sakrardi — bu ham kutilmagan, ham EOF muammosini keltirib
      // chiqarardi. Endi shunchaki oxiridan 1 soniya oldinga
      // "qisiladi" (clamp) — pleyer EOF holatiga tushmaydi.
      t = _clampSeekTarget(t, dur);
      _runSeek(c, t);
    });
  }

  // Progress chizig'idan (yoki boshqa MUTLAQ pozitsiyadan) kelgan sek.
  // Ikki marta bosib sek qilish bilan BITTA umumiy debounce navbatini
  // baham ko'radi — shu sabab foydalanuvchi qanchalik tez bossa/sursa
  // ham, pleyerga sek buyruqlari to'planib ketmaydi.
  void _scheduleSeekTo(Duration target) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    // Nisbiy (ikki marta bosish) navbati bekor qilinadi — oxirgi
    // harakat ustun.
    _pendingSeekBase = null;
    _pendingSeekDeltaSeconds = 0;
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = null;

    // MUHIM: progress chizig'idan kelgan sek KECHIKTIRILMAYDI.
    //
    // Bu chaqiruv barmoq slayderdan UZILGANDA (onChangeEnd) bitta
    // marta keladi — ya'ni u allaqachon "yakuniy" nuqta. Uni yana
    // 110 ms kutish foyda bermaydi, faqat javobni sekinlashtiradi.
    // (Surish davomida esa pleyerga umuman tegilmaydi — faqat
    // slayderning o'z ko'rinishi yangilanadi.)
    final dur = ctrl.value.duration;
    var t = target;
    if (t < Duration.zero) t = Duration.zero;
    // Slayder oxirigacha surilganda pleyer EOF holatiga tushib
    // qolmasligi uchun oxiridan 1 soniya oldinga qisiladi.
    t = _clampSeekTarget(t, dur);
    _runSeek(ctrl, t);
  }

  // Barcha sek chaqiruvlari SHU yerdan o'tadi. Bir vaqtning o'zida
  // faqat BITTA sek bajariladi: oldingisi tugamaguncha yangisi
  // yuborilmaydi, o'rniga eng oxirgi so'ralgan nuqta eslab qolinib,
  // joriysi tugagach bir marta qo'llaniladi. Bu pleyer ichida sek
  // buyruqlari navbatga to'planib, uni qotirib qo'yishining oldini
  // oladi — foydalanuvchi qanchalik tez/ko'p sek qilsa ham.
  bool _seekBusy = false;
  Duration? _queuedSeek;
  Timer? _healthTimer;
  // Foydalanuvchi OXIRGI marta sek so'ragan / sek tugagan payt.
  // Sog'liq kuzatuvchisi shu vaqtlarga qarab "sek davom etyapti"
  // holatini qotib qolish deb xato hisoblamaydi.
  DateTime _lastSeekRequest = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSeekDone = DateTime.fromMillisecondsSinceEpoch(0);
  // UMUMIY qotish kuzatuvi: pozitsiya o'zgarmay turgan takrorlar soni
  // va oxirgi ko'rilgan pozitsiya. _startHealthWatchdog izohiga qarang.
  int _stuckTicks = 0;
  Duration? _lastWatchPosition;

  // Sek nuqtasini xavfsiz oraliqqa qisadi: [0 .. duration-1s] — video
  // ENG OXIRIGA sek qilinishining oldini oladi: EOF holatiga tushish
  // demukserni keraksiz "tugadi" yo'liga olib boradi.
  static Duration _clampSeekTarget(Duration t, Duration dur) {
    if (t < Duration.zero) return Duration.zero;
    if (dur <= Duration.zero) return t;
    final limit = dur - const Duration(seconds: 1);
    if (limit <= Duration.zero) return Duration.zero;
    return t > limit ? limit : t;
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
          await c.seekTo(target).timeout(const Duration(seconds: 10));
        } catch (e) {
          VideoCacheServer.log('seekTo xato/kechikish: $e');
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
    final base = _pendingSeekBase ?? v.position;
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
      _leftSeekHideTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _showLeftSeek = false;
            _leftSeekAccum = 0;
          });
        }
      });
    } else {
      _rightSeekHideTimer?.cancel();
      _rightSeekHideTimer = Timer(const Duration(seconds: 2), () {
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
    final bolimId =
        widget.season['bolim_id'] ?? widget.season['season_id'] ?? '';
    final turi = widget.season['turi'] ?? '';
    final yili = widget.season['yili'] ?? '';
    final janri = widget.season['janri'] ?? '';
    final tavsif = widget.season['tavsif'] ?? '';

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
              SizedBox(
                height: 28,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    if (bolimId.toString().isNotEmpty)
                      _Badge('$bolimId-bo\'lim'),
                    if (turi.toString().isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _Badge(turi.toString())
                    ],
                    if (yili.toString().isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _Badge(yili.toString())
                    ],
                    if (janri.toString().isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _Badge(janri.toString())
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Glass(
                  borderRadius: 16,
                  blur: 12,
                  padding: const EdgeInsets.all(4),
                  child: TabBar(
                    controller: _tabCtrl,
                    indicator: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(12)),
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white54,
                    labelStyle: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    unselectedLabelStyle: const TextStyle(fontSize: 13),
                    dividerColor: Colors.transparent,
                    tabs: const [
                      Tab(text: 'Epizodlar'),
                      Tab(text: 'Bo\'limlar'),
                      Tab(text: 'Ma\'lumot'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  controller: _tabCtrl,
                  children: [
                    _buildEpisodeTab(),
                    _buildSeasonsTab(),
                    _buildInfoTab(tavsif.toString()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
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
                  Text('Epizodni tanlang',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            ),

          if (_currentEp != null && _playerLoading)
            const Center(
                child: CircularProgressIndicator(color: Colors.white54)),

          // ── Runtime buferlash indikatori: controller allaqachon
          // initialize bo'lgan va ijro boshlangan, lekin tarmoq
          // sekinlashib pleyer qayta buferlanayotganda (masalan sek
          // qilingandan keyin) ko'rinadi. _playerLoading dan farqli —
          // bu holat controller yashab turganda ham qayta-qayta
          // yoqilib-o'chib turishi mumkin.
          // Kontrollar KO'RINIB turganda buferlash markaziy tugmaning
          // halqasi orqali ko'rsatiladi (_centerButton) — bu yerda
          // ikkinchi aylanani chizish shart emas.
          if (_currentEp != null &&
              !_playerLoading &&
              _playerError == null &&
              !_showControls)
            _bufferingReactive(),

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
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: RepaintBoundary(
                    child: _buildControls(isFullscreen: isFullscreen)),
              ),
            ),

          // ── Sek ko'rsatkichlari — asosiy kontrollardan mustaqil,
          // faqat bosilgan tarafda chiqadi va 2s dan keyin yo'qoladi.
          // Doiraviy shaklda, play/pause tugmasidan biroz kattaroq
          // (avval 2 barobar edi — portret rejimda ekranni to'sib
          // qo'yadigan darajada katta ko'rinardi).
          // MUHIM: play/pause tugmasi (markaz) bilan video cheti
          // o'rtasidagi nuqtaga joylashtirilgan — chetga emas.
          if (_showLeftSeek)
            Align(
              alignment: const Alignment(-0.5, 0),
              child: IgnorePointer(
                child: _SeekBadge(
                  seconds: _leftSeekAccum,
                  isLeft: true,
                  diameter: _playPauseDiameter(isFullscreen) * 1.3,
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
                  diameter: _playPauseDiameter(isFullscreen) * 1.3,
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
                  final bottomGuard =
                      _showControls ? (isFullscreen ? 78.0 : 64.0) : 0.0;
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

  // Faqat isBuffering holatini eng tor ko'lamda kuzatadi — tarmoq
  // sekinlashib pleyer qayta buferlanayotganda kichik spinner ko'rsatadi.
  Widget _bufferingReactive() {
    final ctrl = _controller;
    if (ctrl == null) return const SizedBox.shrink();
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) {
        if (!value.isBuffering) return const SizedBox.shrink();
        return const Center(
          child: SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
                color: Colors.white54, strokeWidth: 2.5),
          ),
        );
      },
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
            _seekBusy;
        final dur = value.duration.inMilliseconds;
        final progress = dur > 0
            ? (value.position.inMilliseconds / dur).clamp(0.0, 1.0)
            : 0.0;
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
          SizedBox(
            width: ringSize,
            height: ringSize,
            child: CircularProgressIndicator(
              // `value: null` — aylanuvchi (aniqlanmagan) rejim.
              value: busy ? null : progress,
              strokeWidth: 2.6,
              color: AppColors.accent,
              backgroundColor:
                  busy ? Colors.transparent : Colors.white.withOpacity(0.22),
            ),
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

  // Faqat slayder/vaqtni eng tor ko'lamda yangilaydi.
  Widget _bottomBarReactive({required bool isFullscreen}) {
    final ctrl = _controller;
    Widget bar(VideoPlayerValue? value) => _BottomBar(
          position: value?.position ?? Duration.zero,
          duration: value?.duration ?? Duration.zero,
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
    if (ctrl == null) return bar(null);
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) => bar(value),
    );
  }

  Widget _buildEpisodeTab() {
    if (_loadingEps) {
      return Center(
          child: CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation(AppColors.accent)));
    }
    final eps = _playableEps;
    if (eps.isEmpty) {
      return Center(
          child: Text('Epizodlar topilmadi',
              style: TextStyle(color: Colors.white.withOpacity(0.5))));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      itemCount: eps.length,
      itemBuilder: (_, i) {
        final ep = eps[i];
        final epNum = ep['epizod_number'] ?? i;
        final epName = (ep['epizod_name'] ?? '').toString();
        final isCurrent =
            _currentEp != null && _currentEp!['epizod_id'] == ep['epizod_id'];
        String qLabel = '';
        for (final k in ['1080p', '720p', '480p', '360p']) {
          if (((ep['url_$k'] as String?) ?? '').isNotEmpty) {
            qLabel = k;
            break;
          }
        }
        return GlassTappable(
          onTap: () => _playEpisode(ep),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? AppColors.accent.withOpacity(0.28)
                        : Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isCurrent ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: isCurrent ? AppColors.accent : Colors.white54,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(epName.isNotEmpty ? epName : '$epNum-epizod',
                          style: TextStyle(
                              color:
                                  isCurrent ? AppColors.accent : Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                      Text('$epNum-epizod',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.45),
                              fontSize: 12)),
                    ],
                  ),
                ),
                if (qLabel.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: AppColors.accent.withOpacity(0.85),
                        borderRadius: BorderRadius.circular(6)),
                    child: Text(qLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
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
class _Badge extends StatelessWidget {
  final String label;
  const _Badge(this.label);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24)),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
    );
  }
}

// Ikki marta bosib sek qilingandagi ko'rsatkich — DOIRA shaklida
// (play/pause tugmasidan 2 barobar katta diametrda): 3 ta kichik
// uchburchak yuqorida qator bo'lib ketma-ket miltillaydi, ularning
// tagida "Ns" matni turadi. Play/pause tugmasi bilan video cheti
// o'rtasiga joylashtiriladi (build metodida Align orqali).
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
            fontSize: widget.diameter * 0.13));

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
        children: [chevrons, const SizedBox(height: 8), text],
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
                  Icon(icon, color: Colors.white, size: widget.diameter * 0.19),
            );
          }),
        );
      },
    );
  }
}

// ── Progress chizig'i: BITTA muhim tuzatish shu yerda ────────────
// Avval Slider.onChanged HAR bir drag harakatida ctrl.seekTo() ni
// chaqirar edi — barmoq bilan surganda soniyasiga o'nlab tarmoq
// seek so'rovi ketib, ular navbatga to'planib 9-12 soniyagacha
// qotib qolishga sabab bo'lgan. Endi drag paytida faqat mahalliy
// _dragValue yangilanadi (hech qanday tarmoq so'rovisiz, darhol),
// video esa faqat barmoq QO'YIB YUBORILGANDA (onChangeEnd) BITTA
// marta sek qilinadi.
class _BottomBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final String Function(Duration) fmt;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onQualityTap;
  final VoidCallback onFullscreen;
  final bool isFullscreen;
  // Barmoq slayderga qo'yilganda/uzilganda xabar beradi — markaziy
  // tugmaning halqasi shu paytda aylanadi.
  final VoidCallback onScrubStart;
  final VoidCallback onScrubEnd;

  const _BottomBar({
    required this.position,
    required this.duration,
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

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                thumbColor: accent,
                activeTrackColor: accent,
                inactiveTrackColor: Colors.white.withOpacity(0.28),
                overlayColor: accent.withOpacity(0.2),
              ),
              child: Slider(
                value: ratio,
                onChangeStart: (v) {
                  setState(() => _dragValue = v);
                  widget.onScrubStart();
                },
                onChanged: (v) {
                  setState(() => _dragValue = v);
                },
                onChangeEnd: (v) {
                  if (widget.duration.inMilliseconds > 0) {
                    widget.onSeek(Duration(
                        milliseconds:
                            (v * widget.duration.inMilliseconds).round()));
                  }
                  setState(() => _dragValue = null);
                  widget.onScrubEnd();
                },
              ),
            ),
          ),
          Text(widget.fmt(shownPosition),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w500)),
          Text('/${widget.fmt(widget.duration)}',
              style: const TextStyle(color: Colors.white, fontSize: 11)),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: widget.onQualityTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Colors.white30)),
              child: const Text('HQ',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: widget.onFullscreen,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Icon(
                  widget.isFullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  color: Colors.white,
                  size: 20),
            ),
          ),
        ],
      ),
    );
  }
}
