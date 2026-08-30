import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import '../services/video_cache_server.dart';
import '../services/rust_bridge.dart';
import '../widgets/glass.dart';
import '../theme/app_background.dart';

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

  // ── BITTA umumiy player ──────────────────────────────────────
  VideoPlayerController? _controller;
  Map<String, dynamic>? _currentEp;
  String? _selectedQuality;
  bool _playerLoading = false;
  int _playToken = 0;
  bool _disposingOld = false;
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
    _restoreSystemUI();
    _controller?.pause();
    _controller?.dispose();
    _controller = null;
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
        final fresh = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
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
        final fresh = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
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

  // MUHIM: bir vaqtning o'zida faqat BITTA controller yashaydi.
  // Eskisi to'liq to'xtatilib (pause) va dispose qilinib bo'lgandan
  // keyingina yangisi yaratiladi — orqa fonda bir nechta video
  // parallel ijro bo'lib qolishining oldini oladi.
  // resumeAt/resumePlaying — sifat almashtirilganda joriy pozitsiya va
  // play/pause holatini saqlab qolish uchun (video boshidan boshlanib
  // qolmasligi kerak). Oddiy epizod tanlashda ikkalasi ham null/true
  // bo'lib, video 0-sekunddan avtomatik boshlanadi.
  Future<void> _playEpisode(
    Map<String, dynamic> ep, {
    Duration? resumeAt,
    bool resumePlaying = true,
  }) async {
    final url = _getUrl(ep);
    if (url.isEmpty) return;

    final myToken = ++_playToken;
    setState(() {
      _currentEp = ep;
      _showControls = true;
      _playerLoading = true;
      _playerError = null;
    });

    final old = _controller;
    _controller = null;
    if (old != null) {
      await old.pause();
      await old.dispose();
    }

    if (!mounted || myToken != _playToken) return;

    // Videoni to'g'ridan-to'g'ri masofaviy URL'dan emas, mahalliy
    // (127.0.0.1) kesh-proksidan o'ynatamiz: diskda mavjud bo'lgan
    // baytlar to'g'ridan-to'g'ri fayldan o'qiladi, faqat yetishmayotgan
    // qismi worker'dan yuklab olinadi (video_cache_server.dart).
    //
    // MUHIM ZAXIRA YO'L: ba'zi qurilmalarda mahalliy HTTP server ochish
    // muammoli bo'lishi mumkin (masalan tarmoq cheklovlari). Bunday
    // holatda kesh-proksisiz, TO'G'RIDAN-TO'G'RI asl URL bilan
    // o'ynatishga o'tamiz — kesh (doimiy saqlash) ishlamaydi, lekin
    // video HECH QACHON abadiy "yuklanmoqda" holatida qotib qolmaydi.
    Uri proxied;
    bool viaProxy = true;
    try {
      proxied = await VideoCacheServer.instance.proxyUri(url);
    } catch (e) {
      VideoCacheServer.log('proxyUri xato berdi, asl URL ishlatiladi: $e');
      proxied = Uri.parse(url);
      viaProxy = false;
    }
    if (!mounted || myToken != _playToken) return;

    // 15 soniya ichida ishga tushmasa (masalan mahalliy kesh-proksi
    // qurilmada ishlamayotgan bo'lsa), sinab ko'rilgan controller
    // bekor qilinadi va null qaytariladi — chaqiruvchi zaxira yo'lga
    // (kesh'siz, to'g'ridan-to'g'ri asl URL) o'tishi mumkin bo'ladi.
    Future<VideoPlayerController?> tryInit(Uri u) async {
      final c = VideoPlayerController.networkUrl(u);
      try {
        await c.initialize().timeout(const Duration(seconds: 15));
        return c;
      } catch (e) {
        VideoCacheServer.log('ctrl.initialize() muvaffaqiyatsiz ($u): $e');
        await c.dispose();
        return null;
      }
    }

    VideoCacheServer.log(viaProxy
        ? 'Proksi orqali initialize sinalyapti...'
        : 'To\'g\'ridan-to\'g\'ri (proksisiz) initialize sinalyapti...');
    var ctrl = await tryInit(proxied);
    var usedProxy = viaProxy;

    // Mahalliy kesh-proksi orqali ishga tushmadi (server javob
    // bermayapti yoki qurilmada bloklangan) — kesh bo'lmasa ham video
    // hech bo'lmasa ochilishi uchun asl URL bilan to'g'ridan-to'g'ri
    // qayta urinib ko'ramiz.
    if (ctrl == null && viaProxy) {
      if (!mounted || myToken != _playToken) return;
      VideoCacheServer.log('Zaxira: asl URL bilan qayta urinilyapti...');
      ctrl = await tryInit(Uri.parse(url));
      usedProxy = false;
    }
    if (ctrl != null) {
      VideoCacheServer.log(
          'Video muvaffaqiyatli ochildi (${usedProxy ? 'proksi orqali' : 'to\'g\'ridan-to\'g\'ri'})');
    }

    if (ctrl == null) {
      if (mounted && myToken == _playToken) {
        setState(() {
          _playerLoading = false;
          _playerError = 'Videoni yuklab bo\'lmadi';
        });
      }
      return;
    }

    if (!mounted || myToken != _playToken) {
      await ctrl.dispose();
      return;
    }

    ctrl.setLooping(false);
    _attachEndOfVideoListener(ctrl, myToken);
    if (resumeAt != null && resumeAt > Duration.zero) {
      await ctrl.seekTo(resumeAt);
    }
    if (resumePlaying) {
      await ctrl.play();
    }
    if (!mounted || myToken != _playToken) {
      await ctrl.dispose();
      return;
    }
    setState(() {
      _controller = ctrl;
      _playerLoading = false;
    });
    _scheduleHide();
  }

  // ── Video oxiriga yetganda (tabiiy tugash YOKI progress chizig'ini
  // oxirigacha surish/sek qilish orqali) pleyer "qotib qolmasligi" uchun:
  // pozitsiya davomiylikka (duration) 300ms qolganda avtomatik 0-ga
  // qaytariladi — video boshidan qayta boshlanadi. `restarted` flag bir
  // marta ishga tushirilib, pozitsiya oxirdan uzoqlashguncha qayta
  // ishlamaydi (takroriy seekTo chaqiruvlarining oldini oladi).
  void _attachEndOfVideoListener(VideoPlayerController ctrl, int token) {
    bool restarted = false;
    void listener() {
      if (!mounted || token != _playToken) return;
      final v = ctrl.value;
      if (!v.isInitialized || v.duration <= Duration.zero) return;
      final remaining = v.duration - v.position;
      if (remaining <= const Duration(milliseconds: 300)) {
        if (!restarted) {
          restarted = true;
          // Bu sek ham UMUMIY navbatdan o'tadi — foydalanuvchining
          // sek qilishlari bilan bir vaqtda ishlab, pleyerni chalkashtirib
          // yubormasligi uchun.
          _runSeek(ctrl, Duration.zero);
        }
      } else {
        restarted = false;
      }
    }

    ctrl.addListener(listener);
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
      ctrl.pause();
    } else {
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

    // Debounce 220ms dan 110ms ga tushirildi — bo'laklar endi fon'da
    // diskka oldindan keshlangani uchun (Rust filler) sek deyarli
    // darhol bajariladi va uzoq kutish shart emas.
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(const Duration(milliseconds: 110), () {
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
      // ctrl.seekTo(duration) chaqirish pleyerni "qotirib qo'yishi" mumkin
      // — shuning o'rniga video boshidan qayta boshlanadi.
      if (dur > Duration.zero && t >= dur) t = Duration.zero;
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
    _seekDebounceTimer = Timer(const Duration(milliseconds: 110), () {
      _seekDebounceTimer = null;
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final dur = c.value.duration;
      var t = target;
      if (t < Duration.zero) t = Duration.zero;
      // Slayder oxirigacha surilganda pleyer qotib qolmasligi uchun
      // video boshidan qayta boshlanadi.
      if (dur > Duration.zero && t >= dur) t = Duration.zero;
      _runSeek(c, t);
    });
  }

  // Barcha sek chaqiruvlari SHU yerdan o'tadi. Bir vaqtning o'zida
  // faqat BITTA sek bajariladi: oldingisi tugamaguncha yangisi
  // yuborilmaydi, o'rniga eng oxirgi so'ralgan nuqta eslab qolinib,
  // joriysi tugagach bir marta qo'llaniladi. Bu pleyer ichida sek
  // buyruqlari navbatga to'planib, uni qotirib qo'yishining oldini
  // oladi — foydalanuvchi qanchalik tez/ko'p sek qilsa ham.
  bool _seekInProgress = false;
  Duration? _queuedSeek;

  Future<void> _runSeek(VideoPlayerController c, Duration t) async {
    if (_seekInProgress) {
      _queuedSeek = t;
      return;
    }
    _seekInProgress = true;
    // Sekdan OLDINGI ijro holatini eslab qolamiz — pastda tiklash uchun.
    final wasPlaying = c.value.isPlaying;
    var target = t;
    while (true) {
      try {
        // Timeout SHART: agar pleyer biror sababdan sekni yakunlamasa,
        // _seekInProgress abadiy "true" bo'lib qolib, sek butunlay
        // ishlamay qolardi. Timeout bu holatdan chiqib ketishni
        // kafolatlaydi.
        await c.seekTo(target).timeout(const Duration(seconds: 5));
      } catch (_) {
        // Sek muvaffaqiyatsiz/kechikkan bo'lsa — jim o'tkazamiz,
        // ilova ishlashda davom etadi.
      }
      final next = _queuedSeek;
      _queuedSeek = null;
      if (next == null) break;
      if (!mounted || _controller != c || !c.value.isInitialized) break;
      target = next;
    }

    // MUHIM TUZATISH (videoni orqaga 00:00 ga sek qilganda qotib
    // qolishi): mdk-sdk ba'zi hollarda — ayniqsa video BOSHIGA
    // (0-pozitsiya) sek qilinganda — sekdan keyin ijroni o'zi qayta
    // boshlamay, pauza holatida qolib ketardi. Tashqaridan bu "video
    // qotib qoldi, play/pause bosish kerak" bo'lib ko'rinardi.
    // Shu sabab sekdan OLDIN ijro ketayotgan bo'lsa, sekdan KEYIN uni
    // aniq (explicit) davom ettiramiz.
    if (wasPlaying && mounted && _controller == c && c.value.isInitialized) {
      try {
        await c.play();
      } catch (_) {}
    }
    _seekInProgress = false;
  }

  // Ekranning chap/o'ng yarmiga ikki marta bosilganda 5 sonyaga
  // orqaga/oldinga suradi. Tez-tez bosilsa jamlanadi (+5, +10, +15...)
  // va qo'l tortilgach 2 soniyadan keyin ko'rsatkich avtomatik yo'qoladi.
  void _handleDoubleTapSeek(bool isLeft) {
    if (_currentEp == null) return;
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    setState(() {
      if (isLeft) {
        _leftSeekAccum += 5;
        _showLeftSeek = true;
      } else {
        _rightSeekAccum += 5;
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
    final ordered = ['1080p', '720p', '480p', '360p'].where(have.contains).toList();

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
                  style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
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
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: sel ? AppColors.accent : Colors.white.withOpacity(0.06),
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
                                        color: sel ? Colors.black : Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15)),
                                if (size.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(size,
                                      style: TextStyle(
                                          color: sel ? Colors.black87 : Colors.white54,
                                          fontSize: 12)),
                                ],
                              ],
                            ),
                          ),
                          if (sel) const Icon(Icons.check_rounded, color: Colors.black),
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
    final bolimId = widget.season['bolim_id'] ?? widget.season['season_id'] ?? '';
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
                        borderRadius: 14, blur: 14, padding: EdgeInsets.all(8),
                        child: Icon(Icons.arrow_back_rounded, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
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
                    if (bolimId.toString().isNotEmpty) _Badge('$bolimId-bo\'lim'),
                    if (turi.toString().isNotEmpty) ...[const SizedBox(width: 6), _Badge(turi.toString())],
                    if (yili.toString().isNotEmpty) ...[const SizedBox(width: 6), _Badge(yili.toString())],
                    if (janri.toString().isNotEmpty) ...[const SizedBox(width: 6), _Badge(janri.toString())],
                  ],
                ),
              ),

              const SizedBox(height: 8),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Glass(
                  borderRadius: 16, blur: 12, padding: const EdgeInsets.all(4),
                  child: TabBar(
                    controller: _tabCtrl,
                    indicator: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)),
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white54,
                    labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
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
                  Icon(Icons.play_circle_outline_rounded, color: Colors.white24, size: 52),
                  SizedBox(height: 8),
                  Text('Epizodni tanlang', style: TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            ),

          if (_currentEp != null && _playerLoading)
            const Center(child: CircularProgressIndicator(color: Colors.white54)),

          // ── Runtime buferlash indikatori: controller allaqachon
          // initialize bo'lgan va ijro boshlangan, lekin tarmoq
          // sekinlashib pleyer qayta buferlanayotganda (masalan sek
          // qilingandan keyin) ko'rinadi. _playerLoading dan farqli —
          // bu holat controller yashab turganda ham qayta-qayta
          // yoqilib-o'chib turishi mumkin.
          if (_currentEp != null && !_playerLoading && _playerError == null)
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
                  const Icon(Icons.error_outline_rounded, color: Colors.white38, size: 40),
                  const SizedBox(height: 10),
                  Text(_playerError!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 14),
                  GestureDetector(
                    onTap: () {
                      final ep = _currentEp;
                      if (ep != null) _playEpisode(ep);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text('Qayta urinish',
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 13)),
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
                child: RepaintBoundary(child: _buildControls(isFullscreen: isFullscreen)),
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

          // ── VAQTINCHALIK DIAGNOSTIKA PANELI: mahalliy kesh-server
          // nima uchun ishlamayotganini to'g'ridan-to'g'ri ekranda,
          // adb/logcat'siz ko'rish uchun. VideoCacheServer.logs'dagi
          // so'nggi qatorlarni ko'rsatadi. Muammo topilgach olib
          // tashlanishi mumkin.
          if (_currentEp != null)
            Positioned(
              left: 6,
              right: 6,
              top: 6,
              child: IgnorePointer(
                child: _DebugLogPanel(),
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
                  final bottomGuard = _showControls ? (isFullscreen ? 78.0 : 64.0) : 0.0;
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
                        child: Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        (_currentEp?['epizod_name'] ?? widget.season['nomi'] ?? '').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
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
            child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2.5),
          ),
        );
      },
    );
  }

  // Faqat play/pause ikonkasini eng tor ko'lamda yangilaydi.
  Widget _playPauseReactive({required double size}) {
    final ctrl = _controller;
    if (ctrl == null) {
      return GestureDetector(
        onTap: _togglePlayPause,
        child: _playPauseIcon(playing: false, size: size),
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) => GestureDetector(
        onTap: _togglePlayPause,
        child: _playPauseIcon(playing: value.isPlaying, size: size),
      ),
    );
  }

  // Play/pause tugmasining haqiqiy (doira) diametri — ikonka o'lchami
  // + atrofidagi 12px padding ikki tarafdan. Sek gesture'idagi o'lik
  // zona kengligi va sek ko'rsatkichining o'lchami shu qiymatga
  // asoslanadi.
  double _playPauseDiameter(bool isFullscreen) {
    final iconSize = isFullscreen ? 46.0 : 40.0;
    return iconSize + 12 * 2;
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
        );
    if (ctrl == null) return bar(null);
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (_, value, __) => bar(value),
    );
  }

  Widget _buildEpisodeTab() {
    if (_loadingEps) {
      return Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation(AppColors.accent)));
    }
    final eps = _playableEps;
    if (eps.isEmpty) {
      return Center(child: Text('Epizodlar topilmadi', style: TextStyle(color: Colors.white.withOpacity(0.5))));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      itemCount: eps.length,
      itemBuilder: (_, i) {
        final ep = eps[i];
        final epNum = ep['epizod_number'] ?? i;
        final epName = (ep['epizod_name'] ?? '').toString();
        final isCurrent = _currentEp != null && _currentEp!['epizod_id'] == ep['epizod_id'];
        String qLabel = '';
        for (final k in ['1080p', '720p', '480p', '360p']) {
          if (((ep['url_$k'] as String?) ?? '').isNotEmpty) { qLabel = k; break; }
        }
        return GlassTappable(
          onTap: () => _playEpisode(ep),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isCurrent ? AppColors.accent.withOpacity(0.14) : Colors.white.withOpacity(0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isCurrent ? AppColors.accent.withOpacity(0.5) : Colors.white12),
            ),
            child: Row(
              children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color: isCurrent ? AppColors.accent.withOpacity(0.28) : Colors.white.withOpacity(0.08),
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
                          style: TextStyle(color: isCurrent ? AppColors.accent : Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                      Text('$epNum-epizod', style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
                    ],
                  ),
                ),
                if (qLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: AppColors.accent.withOpacity(0.85), borderRadius: BorderRadius.circular(6)),
                    child: Text(qLabel, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
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
      return Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation(AppColors.accent)));
    }
    if (_seasons.isEmpty) {
      return Center(child: Text('Bo\'limlar topilmadi', style: TextStyle(color: Colors.white.withOpacity(0.5))));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      itemCount: _seasons.length,
      itemBuilder: (_, i) {
        final s = _seasons[i];
        final bolimId = s['bolim_id'] ?? s['season_id'] ?? '';
        final nomi = (s['nomi'] ?? '').toString();
        final photoUrl = s['photo_url'] as String?;
        final isCur = s['season_id']?.toString() == widget.season['season_id']?.toString();
        return GlassTappable(
          onTap: () {
            if (!isCur) {
              Navigator.of(context).pushReplacement(PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 300),
                pageBuilder: (_, a, __) => VideoPlayerScreen(season: s),
                transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
              ));
            }
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isCur ? AppColors.accent.withOpacity(0.12) : Colors.white.withOpacity(0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isCur ? AppColors.accent.withOpacity(0.4) : Colors.white12),
            ),
            child: Row(
              children: [
                if (photoUrl != null && photoUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(imageUrl: photoUrl, width: 50, height: 50, fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(width: 50, height: 50, color: Colors.white10, child: const Icon(Icons.movie_outlined, color: Colors.white38))),
                  )
                else
                  Container(width: 50, height: 50, decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.movie_outlined, color: Colors.white38)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nomi.isNotEmpty ? nomi : '$bolimId-bo\'lim',
                          style: TextStyle(color: isCur ? AppColors.accent : Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                      Text('$bolimId-bo\'lim', style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
                    ],
                  ),
                ),
                if (isCur) Icon(Icons.play_arrow_rounded, color: AppColors.accent),
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
        borderRadius: 18, blur: 14, padding: const EdgeInsets.all(18),
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
              const Text('Tavsif', style: TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              Text(tavsif, style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14, height: 1.6)),
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
          SizedBox(width: 90, child: Text(label, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13))),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13))),
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
class _DebugLogPanel extends StatefulWidget {
  const _DebugLogPanel();

  @override
  State<_DebugLogPanel> createState() => _DebugLogPanelState();
}

class _DebugLogPanelState extends State<_DebugLogPanel> {
  Timer? _netTimer;
  int _netBytes = 0;

  @override
  void initState() {
    super.initState();
    // Tarmoq hisoblagichini doimiy yangilab turamiz — u loglar oqib
    // ketsa ham har doim ko'rinib turadi.
    _netTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      final v = RustCore.instance.videoCacheNetBytes;
      if (v != _netBytes && mounted) setState(() => _netBytes = v);
    });
  }

  @override
  void dispose() {
    _netTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: VideoCacheServer.logs,
      builder: (context, lines, __) {
        final last = lines.length > 7 ? lines.sublist(lines.length - 7) : lines;
        final mb = _netBytes / (1024 * 1024);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.62),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── DOIMIY KO'RSATKICH ──────────────────────────────
              // Video kesh-serveri TARMOQDAN olgan umumiy hajm.
              // Keshdan o'qilganlar bunga KIRMAYDI. Agar video
              // o'ynayotganda bu son O'SMAY tursa — demak video uchun
              // tarmoqqa umuman chiqilmayapti va qurilmada ko'rinayotgan
              // trafik BOSHQA manbadan ketayotgan bo'ladi.
              Text(
                'VIDEO TARMOQ: ${mb.toStringAsFixed(2)} MB',
                style: TextStyle(
                  color: _netBytes == 0 ? Colors.lightBlueAccent : Colors.orangeAccent,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  height: 1.4,
                ),
              ),
              ...last.map((l) => Text(
                    l,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 9,
                      fontFamily: 'monospace',
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )),
            ],
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  const _Badge(this.label);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
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
  const _SeekBadge({required this.seconds, required this.isLeft, required this.diameter});

  @override
  State<_SeekBadge> createState() => _SeekBadgeState();
}

class _SeekBadgeState extends State<_SeekBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = widget.isLeft ? Icons.arrow_left_rounded : Icons.arrow_right_rounded;
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
            final opacity = t < 0.5 ? (0.3 + 0.7 * (t / 0.5)) : (1.0 - 0.7 * ((t - 0.5) / 0.5));
            return Opacity(
              opacity: opacity.clamp(0.3, 1.0),
              child: Icon(icon, color: Colors.white, size: widget.diameter * 0.19),
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

  const _BottomBar({
    required this.position,
    required this.duration,
    required this.fmt,
    required this.onSeek,
    required this.onQualityTap,
    required this.onFullscreen,
    required this.isFullscreen,
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
        ? (widget.position.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final ratio = _dragValue ?? liveRatio;
    final shownPosition = _dragValue != null && widget.duration.inMilliseconds > 0
        ? Duration(milliseconds: (_dragValue! * widget.duration.inMilliseconds).round())
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
                thumbColor: accent, activeTrackColor: accent,
                inactiveTrackColor: Colors.white.withOpacity(0.28),
                overlayColor: accent.withOpacity(0.2),
              ),
              child: Slider(
                value: ratio,
                onChangeStart: (v) {
                  setState(() => _dragValue = v);
                },
                onChanged: (v) {
                  setState(() => _dragValue = v);
                },
                onChangeEnd: (v) {
                  if (widget.duration.inMilliseconds > 0) {
                    widget.onSeek(Duration(milliseconds: (v * widget.duration.inMilliseconds).round()));
                  }
                  setState(() => _dragValue = null);
                },
              ),
            ),
          ),
          Text(widget.fmt(shownPosition), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500)),
          Text('/${widget.fmt(widget.duration)}', style: const TextStyle(color: Colors.white, fontSize: 11)),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: widget.onQualityTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(5), border: Border.all(color: Colors.white30)),
              child: const Text('HQ', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: widget.onFullscreen,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Icon(widget.isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}
