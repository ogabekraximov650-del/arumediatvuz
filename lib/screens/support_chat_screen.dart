// lib/screens/support_chat_screen.dart — ADMIN BILAN YOZISHMA.
//
// ═══════════════════════════════════════════════════════════════
//  IKKI TOMON, BITTA EKRAN
// ═══════════════════════════════════════════════════════════════
//
// Bu ekran ikki joyda ishlatiladi:
//
//   * FOYDALANUVCHI — profil sahifasidagi "Admin bilan bog'lanish"
//     tugmasidan. `userId` berilmaydi, ya'ni o'z suhbati ochiladi;
//   * ADMIN — barcha suhbatlar ro'yxatidan bittasini bosganda.
//     `userId` beriladi va o'sha odamning suhbati ochiladi.
//
// Farqi faqat kimning xabari qaysi tomonda turishida: o'zining
// xabari O'NGDA, suhbatdoshiniki CHAPDA — Telegram'dagidek.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../services/chat_video_thumb.dart';
import '../services/image_cache.dart';

import '../services/auth_service.dart';
import '../services/screen_guard.dart';
import '../services/storage_janitor.dart';
import '../services/support_service.dart';
import '../services/voice_player.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'media_view_screen.dart';
import 'public_profile_screen.dart';

class SupportChatScreen extends StatefulWidget {
  /// Admin boshqa odamning suhbatini ochsa — o'sha odamning raqami.
  final int? userId;

  /// Sarlavhada ko'rinadigan nom.
  final String title;

  /// Sarlavhadagi kichik rasm (admin ko'rinishida).
  final String photoUrl;

  const SupportChatScreen({
    super.key,
    this.userId,
    this.title = 'Admin bilan bog\'lanish',
    this.photoUrl = '',
  });

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen>
    // ── SKRINSHOT VA EKRAN YOZUVI TAQIQLANADI ────────────────
    //
    // TALAB (foydalanuvchi): yozishmada ham skrinshot olish va
    // ekranni yozib olish taqiqlansin (`screen_guard.dart`).
    with ScreenGuarded<SupportChatScreen> {
  late final ChatController _chat = ChatController(userId: widget.userId);
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  // ── FAYL YUKLASH HOLATI ──────────────────────────────────
  //
  // TALAB (foydalanuvchi): "video yoki rasm yuborilayotganda
  // huddi admin video yuklagandagidek progress chiziqi va foiz
  // ko'rsatilsin, lekin progress chizig'i AYLANA ko'rinishda
  // bo'lsin".
  //
  // Shu sabab bu yerda ikkita son: 0..1 oralig'idagi ulush
  // (aylana shuni chizadi) va ko'rsatiladigan foiz.
  bool _uploading = false;
  double _upProgress = 0;

  // ── YUKLANAYOTGAN FAYL CHAT OYNASIDA ──────────────────────
  //
  // TALAB (foydalanuvchi): "video, ovozli xabar yoki rasm
  // yuborganda to'g'ridan-to'g'ri chat oynasida ko'rinsin va
  // progress chizig'i play/pause tugmasi atrofida aylanib
  // kattalashsin, huddi Telegramdagidek".
  //
  // Shu sabab yuklash davomida ro'yxatning oxiriga VAQTINCHALIK
  // puffak qo'yiladi: rasm bo'lsa o'zi ko'rinadi, video va ovoz
  // uchun esa tugma atrofida aylana to'lib boradi.
  String _upType = '';
  String _upPath = '';
  int _upMs = 0;

  /// Yozishmadagi videolarning kadrlari.
  ///
  /// Ekranga TEGISHLI (yagona/singleton EMAS): `dispose()` bilan
  /// birga butun ish to'xtaydi.
  final ChatVideoThumb _thumbs = ChatVideoThumb();

  // ── PASTDAN TORTIB YANGILASH ──────────────────────────────
  //
  // TALAB (foydalanuvchi): "chatdagi xabarlarni yuqoriga
  // ko'tarsa pastda aylanadigan narsa chiqsin va serverdan
  // chatga xabar kelgan-kelmaganini tekshirsin".
  //
  // Ro'yxatning oxiridan tashqariga chiqilgan masofa yig'iladi;
  // yetarli bo'lsa serverga so'rov ketadi.
  double _pullUp = 0;
  bool _pullBusy = false;

  // ── TANLASH REJIMI ────────────────────────────────────────
  //
  // TALAB (foydalanuvchi): "xabarni bittalab emas — ustiga bosib
  // turadi, xabar tanlandi, keyin qolganlarini qo'lda tanlab
  // o'chirsa bo'ladigan qil; va hammasini bittada tanlab
  // o'chiradigan tugma qo'sh. Chiqindi tugmasi o'ng yuqori
  // qismida bo'lsin. Va faqatgina admin o'chirishi mumkin
  // bo'lsin, foydalanuvchi o'chira olmasin".
  //
  // Bitta xabar uzoq bosilishi bilan rejim ochiladi; shundan
  // keyin oddiy bosish tanlaydi/tanlovni oladi. Ro'yxat bo'shashi
  // bilan rejim o'zi yopiladi.
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  // ── OVOZLI XABAR ──────────────────────────────────────────
  //
  // TALAB (foydalanuvchi): "chatda ovozli xabar yuborish
  // tizimini ham qo'sh".
  //
  // Mikrofon tugmasi BOSILGANDA yozib olish boshlanadi va
  // tugmagacha davom etadi (barmoqni ushlab turish SHART EMAS).
  // Sabab: ushlab turish paytida ro'yxatni surish, ekranni
  // qulflash yoki tasodifiy qo'yib yuborish yozuvni yo'qotadi —
  // qo'yib yuborish bilan yozuv tugaydigan tizimda bu eng
  // ko'p uchraydigan shikoyat.
  final _rec = AudioRecorder();
  bool _recording = false;
  Duration _recLen = Duration.zero;
  Timer? _recTimer;
  String? _recPath;

  @override
  void initState() {
    super.initState();
    _chat.addListener(_onData);
    // Avval DISK (darhol), keyin tarmoq.
    _chat.loadFromDisk();
    _chat.load().then((_) => _toBottom(jump: true));
    // Suhbat OCHIQ turgandagina yangi xabarlar so'raladi.
    _chat.startPolling();
  }

  @override
  void dispose() {
    // ── KADR YASASH SHU YERDA TO'XTAYDI ──────────────────
    //
    // Avvalgi urinish AYNAN shuning yo'qligidan yiqilgan edi:
    // boshlangan so'rovlar ekran yopilgandan keyin ham davom
    // etib, video ijrosiga qoladigan tezlikni yeb turardi
    // (`chat_video_thumb.dart` dagi tarixga qarang).
    _thumbs.dispose();
    // Ekran yopilsa ovoz ham to'xtaydi — aks holda u orqa fonda
    // yangrab qolardi.
    unawaited(VoicePlayer.instance.stop());
    _recTimer?.cancel();
    unawaited(_rec.dispose());
    _chat.removeListener(_onData);
    _chat.stopPolling();
    _chat.dispose();
    _input.dispose();
    _scroll.dispose();
    // Ekran yopildi — profil sahifasidagi nuqta yangilansin.
    UnreadBadge.instance.refresh();
    super.dispose();
  }

  int _seen = 0;
  void _onData() {
    // Yangi xabar kelgan bo'lsa pastga tushamiz. Foydalanuvchi
    // yuqoriga surib eski xabarlarni o'qiyotgan bo'lsa —
    // TEGILMAYDI, aks holda ekran o'zidan o'zi sakrab ketardi.
    final n = _chat.items.length;
    if (n > _seen) {
      _seen = n;
      _toBottom();
    }
  }

  /// Ro'yxat pastdan tortildimi — shunda yangilanadi.
  bool _onScroll(ScrollNotification n) {
    if (_pullBusy) return false;
    if (n is OverscrollNotification) {
      // Musbat `overscroll` — OXIRIDAN tashqariga chiqish.
      if (n.overscroll > 0) {
        _pullUp += n.overscroll;
        if (_pullUp > 90) {
          _pullUp = 0;
          unawaited(_pullRefresh());
        }
      }
    } else if (n is ScrollEndNotification) {
      _pullUp = 0;
    }
    return false;
  }

  Future<void> _pullRefresh() async {
    if (_pullBusy) return;
    setState(() => _pullBusy = true);
    await _chat.load(force: true);
    await UnreadBadge.instance.refresh();
    if (!mounted) return;
    setState(() => _pullBusy = false);
  }

  void _toBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      // Pastga yaqin bo'lsagina o'zi tushadi.
      if (!jump && _scroll.position.pixels < max - 300) return;
      if (jump) {
        _scroll.jumpTo(max);
      } else {
        _scroll.animateTo(max,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut);
      }
    });
  }

  /// O'chirish MUMKINMI.
  ///
  /// TALAB (foydalanuvchi): "foydalanuvchi support chatda
  /// yuborgan narsalarini o'chira olmasin, o'chirish faqat admin
  /// panelida mumkin bo'lsin".
  ///
  /// Shu sabab ikkita shart: admin bo'lishi VA suhbat admin
  /// panelidan ochilgan bo'lishi (`userId` berilgan). Admin o'z
  /// profilidan "Admin bilan bog'lanish"ni ochsa — u yerda ham
  /// o'chirish yo'q.
  ///
  /// Server ham shunday tekshiradi (admin bo'lmasa 403), ya'ni
  /// o'zgartirilgan ilova bilan ham o'chirib bo'lmaydi.
  bool get _canDelete =>
      AuthService.instance.user?.isAdmin == true && widget.userId != null;

  /// Rasm yoki video tanlab, B2'ga yuklaydi va xabar qilib
  /// yuboradi.
  ///
  /// Yo'l admin panelidagi video yuklash bilan BIR XIL: worker
  /// bir martalik B2 token beradi, fayl esa TO'G'RIDAN B2'ga
  /// oqim bo'lib ketadi (`dio`). Ya'ni fayl worker orqali
  /// o'tmaydi va xotiraga to'liq yuklanmaydi.
  Future<void> _pickAndSend({required bool video}) async {
    if (_uploading) return;
    final picker = ImagePicker();
    final picked = video
        ? await picker.pickVideo(source: ImageSource.gallery)
        : await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;

    final ext = picked.path.split('.').last.toLowerCase();
    await _uploadAndSend(
      file: File(picked.path),
      ext: ext,
      type: video ? 'video' : 'image',
      contentType: video
          ? (ext == 'mkv' ? 'video/x-matroska' : 'video/mp4')
          : (ext == 'png' ? 'image/png' : 'image/jpeg'),
      // `image_picker` tanlangan faylni ilovaning vaqtinchalik
      // papkasiga NUSXALAYDI — yuklash tugashi bilan nusxa
      // o'chiriladi (`storage_janitor.dart` izohiga qarang).
      cleanup: () => StorageJanitor.dropPicked(picked.path),
    );
  }

  /// Faylni B2'ga yuklaydi va xabar qilib yuboradi.
  ///
  /// Rasm, video va ovozli xabar — uchovi ham SHU yo'ldan
  /// o'tadi, farqi faqat turida va uzunligida.
  Future<void> _uploadAndSend({
    required File file,
    required String ext,
    required String type,
    required String contentType,
    int ms = 0,
    Future<void> Function()? cleanup,
  }) async {
    if (_uploading) return;
    final size = await file.length();
    Future<void> dropCopy() async {
      if (cleanup != null) await cleanup();
    }

    final ct = contentType;
    final name =
        'chat_${DateTime.now().millisecondsSinceEpoch}_${_chat.userId ?? 0}.$ext';

    setState(() {
      _uploading = true;
      _upProgress = 0;
      _upType = type;
      _upPath = file.path;
      _upMs = ms;
    });
    _toBottom();

    // ── KADR BU YERDA YASALMAYDI ────────────────────────────
    //
    // TALAB (foydalanuvchi): "serverga thumbnail yuklanmasin".
    //
    // Ilgari kadr shu yerda mahalliy fayldan ajratilib, video
    // bilan birga B2'ga yuklanardi va xabarda uning nomi
    // ketardi. Endi bunday emas: kadrni HAR BIR KO'RUVCHI o'zida
    // yasaydi va o'zida saqlaydi
    // (`lib/services/chat_video_thumb.dart`).
    //
    // Ya'ni ombor ham, xabar maydoni ham, yuklash qadami ham
    // kerak emas — yuborish endi soddaroq va tezroq.

    try {
      final tok = await http
          .post(Uri.parse('$kApiBase/api/upload-token'))
          .timeout(const Duration(seconds: 25));
      if (tok.statusCode != 200) throw 'Token olinmadi';
      final td = jsonDecode(tok.body) as Map<String, dynamic>;

      final res = await Dio().post(
        td['uploadUrl'] as String,
        data: file.openRead(),
        options: Options(
          headers: {
            'Authorization': td['authorizationToken'],
            'X-Bz-File-Name': name,
            'Content-Type': ct,
            'X-Bz-Content-Sha1': 'do_not_verify',
            'Content-Length': size,
          },
          receiveDataWhenStatusError: true,
        ),
        onSendProgress: (sent, total) {
          if (!mounted) return;
          setState(() =>
              _upProgress = total > 0 ? sent / total : sent / (size == 0 ? 1 : size));
        },
      );
      if (res.statusCode != 200) throw 'B2 xato (${res.statusCode})';
      final data = res.data is String
          ? jsonDecode(res.data as String)
          : res.data as Map;
      final b2Name = '${data['fileName']}';

      // Fayl joyida — endi xabarning o'zi yuboriladi.
      final err = await _chat.send(
        // Ovozli xabarga matn qo'shilmaydi: yozayotgan matn
        // o'z holicha qolsin, keyin alohida yuboriladi.
        type == 'voice' ? '' : _input.text.trim(),
        mediaFile: b2Name,
        mediaType: type,
        mediaMs: ms,
      );
      if (!mounted) return;
      if (err != null) {
        _snack(err);
      } else {
        if (type != 'voice') _input.clear();
        _toBottom();
      }
    } catch (e) {
      if (mounted) _snack('Yuborilmadi: $e');
    } finally {
      await dropCopy();
      if (mounted) {
        setState(() {
          _uploading = false;
          _upProgress = 0;
          _upType = '';
          _upPath = '';
          _upMs = 0;
        });
      }
    }
  }

  // ══════════════════════════════════════════════════════════
  //  OVOZ YOZIB OLISH
  // ══════════════════════════════════════════════════════════

  /// Mikrofon bosildi — yozib olish boshlanadi.
  Future<void> _startRecording() async {
    if (_recording || _uploading) return;
    // Ruxsatni paketning o'zi so'raydi. Berilmasa — sababi
    // aytiladi, jim qolinmaydi.
    bool allowed = false;
    try {
      allowed = await _rec.hasPermission();
    } catch (_) {}
    if (!allowed) {
      if (mounted) _snack('Mikrofonga ruxsat berilmadi');
      return;
    }
    // Ovoz yozilayotganda ijro to'xtaydi — mikrofon va
    // karnayning bir vaqtda ishlashi keraksiz.
    await VoicePlayer.instance.stop();

    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        // AAC/m4a — Android ham, iOS ham tug'ma qo'llaydi va
        // ExoPlayer uni bemalol o'ynatadi.
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      _recPath = path;
      _recLen = Duration.zero;
      setState(() => _recording = true);
      _recTimer?.cancel();
      _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _recLen += const Duration(milliseconds: 200));
        // Juda uzun yozuvni o'zi to'xtatadi: 5 daqiqadan uzun
        // ovozli xabar yozishmaga to'g'ri kelmaydi.
        if (_recLen.inMinutes >= 5) _stopRecording(send: true);
      });
    } catch (e) {
      if (mounted) _snack('Yozib bo\'lmadi: $e');
    }
  }

  /// Yozishni tugatadi. `send` bo'lsa yuboradi, aks holda
  /// faylni o'chirib tashlaydi.
  Future<void> _stopRecording({required bool send}) async {
    if (!_recording) return;
    _recTimer?.cancel();
    _recTimer = null;
    final len = _recLen;
    setState(() => _recording = false);

    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    path ??= _recPath;
    _recPath = null;
    if (path == null) return;

    final file = File(path);
    Future<void> drop() async {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    if (!send) {
      await drop();
      return;
    }
    // Tasodifan bosilgan tugma xabar bo'lib ketmasin.
    if (len.inMilliseconds < 700) {
      await drop();
      if (mounted) _snack('Juda qisqa');
      return;
    }
    await _uploadAndSend(
      file: file,
      ext: 'm4a',
      type: 'voice',
      contentType: 'audio/mp4',
      ms: len.inMilliseconds,
      cleanup: drop,
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        content: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  /// Xabarni tanlaydi yoki tanlovdan chiqaradi.
  ///
  /// FAQAT ADMIN: foydalanuvchida tanlash umuman ochilmaydi.
  /// (Server ham shunday: o'chirish so'rovi admin bo'lmasa 403
  /// qaytaradi — ya'ni o'zgartirilgan ilova ham o'chira olmaydi.)
  void _toggleSelect(ChatMessage m) {
    if (!_canDelete) return;
    setState(() {
      if (!_selected.remove(m.id)) _selected.add(m.id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  void _selectAll() => setState(() {
        _selected
          ..clear()
          ..addAll(_chat.items.map((m) => m.id));
      });

  /// ADMIN: TANLANGAN xabarlarni butunlay o'chiradi.
  Future<void> _deleteSelected() async {
    if (!_canDelete || _selected.isEmpty) return;
    final n = _selected.length;
    final ok = await _confirm(n == 1
        ? 'Xabar butunlay o\'chirilsinmi?'
        : '$n ta xabar butunlay o\'chirilsinmi?');
    if (ok != true) return;
    final ids = _selected.toList();
    final err = await _chat.removeMessages(ids);
    if (!mounted) return;
    _clearSelection();
    if (err != null) _snack(err);
  }

  /// Ha/Yo'q so'raydigan oyna.
  Future<bool?> _confirm(String text) async {
    if (!_canDelete) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Glass(
          borderRadius: 22,
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Yo\'q'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade600),
                      child: const Text('Ha'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return ok;
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final err = await _chat.send(text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      _snack(err);
      return;
    }
    _input.clear();
    setState(() {});
    _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: PopScope(
        // Tanlash rejimi ochiq bo'lsa "orqaga" avval TANLOVNI
        // bekor qiladi — ekran yopilib ketmaydi.
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _selecting) _clearSelection();
        },
        child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _selecting ? _selectionBar() : _normalBar(),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: AnimatedBuilder(
                  animation: _chat,
                  builder: (context, _) => _body(),
                ),
              ),
              _composer(),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// ── TANLASH PANELI ──────────────────────────────────────
  ///
  /// Chapda — tanlovni bekor qilish, o'rtada nechtasi
  /// tanlangani, O'NG YUQORIDA esa chiqindi tugmasi
  /// (foydalanuvchi talabi). Yonida "hammasini tanlash".
  PreferredSizeWidget _selectionBar() {
    final all = _chat.items.isNotEmpty &&
        _selected.length >= _chat.items.length;
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      iconTheme: const IconThemeData(color: Colors.white),
      titleSpacing: 0,
      leading: IconButton(
        icon: const Icon(Icons.close_rounded, color: Colors.white),
        onPressed: _clearSelection,
      ),
      title: Text(
        '${_selected.length} ta tanlandi',
        style: const TextStyle(color: Colors.white, fontSize: 17),
      ),
      actions: [
        IconButton(
          tooltip: all ? 'Tanlovni olish' : 'Hammasini tanlash',
          icon: Icon(
            all ? Icons.deselect_rounded : Icons.select_all_rounded,
            color: Colors.white,
          ),
          onPressed: all ? _clearSelection : _selectAll,
        ),
        IconButton(
          tooltip: 'O\'chirish',
          icon: const Icon(Icons.delete_outline_rounded),
          color: Colors.red.shade400,
          onPressed: _deleteSelected,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  PreferredSizeWidget _normalBar() {
    return AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          titleSpacing: 0,
          title: Row(
            children: [
              // ── RASMGA BOSSA — PROFIL ─────────────────────────
              //
              // TALAB: "chatdagi profil rasmi ustiga bosganda
              // profili ochilib profil to'liq ko'rinsin".
              if (widget.userId != null) ...[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          PublicProfileScreen(userId: widget.userId!),
                    ),
                  ),
                  child: _TitleAvatar(
                      url: widget.photoUrl, name: widget.title),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                ),
              ),
            ],
          ),
        );
  }

  Widget _body() {
    if (_chat.isLoading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    final items = _chat.items;
    if (items.isEmpty && !_uploading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.support_agent_rounded,
                  size: 54, color: Colors.white.withValues(alpha: 0.2)),
              const SizedBox(height: 14),
              Text(
                _chat.error ??
                    (_chat.isAdminView
                        ? 'Bu odam hali yozmagan'
                        : 'Savolingiz bormi? Yozing — admin javob beradi.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      // ── PASTDAN TORTIB YANGILASH ────────────────────────
      //
      // TALAB (foydalanuvchi): "chatdagi xabarlarni yuqoriga
      // ko'tarsa pastda aylanadigan narsa chiqsin va serverdan
      // chatga xabar kelgan-kelmaganini tekshirsin".
      //
      // Ro'yxatda eng yangi xabar PASTDA turadi, ya'ni "yuqoriga
      // ko'tarish" — ro'yxatning OXIRIDAN tashqariga chiqish.
      // Shu sabab oddiy `RefreshIndicator` yaramaydi (u faqat
      // tepadan ishlaydi) va tekshiruv qo'lda qilinadi.
      onNotification: _onScroll,
      child: ListView.builder(
      controller: _scroll,
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      // Oxirida: yuklanayotgan fayl va (kerak bo'lsa) aylana.
      itemCount: items.length + (_uploading ? 1 : 0) + (_pullBusy ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= items.length + (_uploading ? 1 : 0)) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white54),
              ),
            ),
          );
        }
        if (i >= items.length) {
          return _UploadingBubble(
            type: _upType,
            path: _upPath,
            progress: _upProgress,
            ms: _upMs,
          );
        }
        final m = items[i];
        // O'z xabarim o'ngda. Admin ekranida "o'ziniki" — admin
        // yozganlari; foydalanuvchi ekranida esa aksincha.
        final mine = _chat.isAdminView ? m.fromAdmin : !m.fromAdmin;
        // ── SUHBATDOSH RASMI XABAR YONIDA ──────────────────
        //
        // TALAB (foydalanuvchi): "admin bilan gaplashadigan chat
        // ichida izohlardagidek adminga foydalanuvchi profili
        // ko'rinib tursin, ustiga bosib profilni ko'rish mumkin
        // bo'lsin".
        //
        // Rasm faqat SUHBATDOSHNING xabari yonida turadi (o'z
        // xabarining yonida o'z rasmini ko'rsatishning ma'nosi
        // yo'q — Telegram ham shunday qiladi).
        //
        // Ketma-ket kelgan xabarlarda rasm faqat OXIRGISIDA
        // chiziladi: aks holda bir xil rasm ustma-ust takrorlanib,
        // ro'yxat g'ijimlanib ketardi.
        final next = i + 1 < items.length ? items[i + 1] : null;
        final lastOfGroup =
            next == null || next.fromAdmin != m.fromAdmin;
        return _Bubble(
          thumbs: _thumbs,
          message: m,
          mine: mine,
          avatarUrl: mine ? '' : widget.photoUrl,
          avatarName: mine ? '' : widget.title,
          showAvatar: !mine && lastOfGroup,
          onAvatarTap: widget.userId == null
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          PublicProfileScreen(userId: widget.userId!),
                    ),
                  ),
          // Admin uzoq bosib TANLAYDI, keyin qolganlarini oddiy
          // bosib qo'shadi. Foydalanuvchida ikkovi ham ishlamaydi.
          onLongPress: _canDelete ? () => _toggleSelect(m) : null,
          onTap: _selecting ? () => _toggleSelect(m) : null,
          selected: _selected.contains(m.id),
          selecting: _selecting,
          onOpenMedia: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MediaViewScreen(
                url: m.mediaUrl,
                type: m.mediaType,
              ),
            ),
          ),
        );
      },
      ),
    );
  }

  Widget _composer() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      // ── KLAVIATURA JOYINI `Scaffold` O'ZI OCHADI ──────────
      //
      // TOPILGAN XATO (foydalanuvchi: "yozadigan oyna judayam
      // yuqoriga ko'tarilib ketgan").
      //
      // `Scaffold` standart holatda `resizeToAvoidBottomInset:
      // true` bilan ishlaydi, ya'ni klaviatura ochilganda TANANI
      // o'zi qisqartiradi. Bu yerda esa ustiga YANA klaviatura
      // balandligi qo'shilardi — natijada qator ikki barobar
      // yuqoriga sakrab, ekranning tepasiga chiqib ketardi.
      //
      // Shu sabab bu yerda klaviaturaga umuman tegilmaydi.
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      // Ovoz yozilayotganda qator butunlay boshqacha: vaqt,
      // bekor qilish va yuborish.
      child: _recording ? _recordingRow() : _composerRow(),
    );
  }

  /// Ovoz yozilayotgandagi qator.
  Widget _recordingRow() {
    return Row(
      children: [
        // Qizil nuqta "yozilyapti" degani.
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.red.shade400,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          voiceClock(_recLen),
          style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Ovoz yozilmoqda...',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45), fontSize: 13),
          ),
        ),
        // Bekor qilish — fayl o'chib ketadi.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _stopRecording(send: false),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.10),
            ),
            child: Icon(Icons.delete_outline_rounded,
                size: 20, color: Colors.red.shade300),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _stopRecording(send: true),
          child: Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent,
            ),
            child: const Icon(Icons.send_rounded, size: 19, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _composerRow() {
    return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  counterText: '',
                  isDense: true,
                  hintText: 'Xabar yozing...',
                  hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.38),
                      fontSize: 14),
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          // ── RASM / VIDEO BIRIKTIRISH ────────────────────────
          //
          // TALAB (foydalanuvchi): "fayl yuklash tugmasi yozish
          // joyi va yuborish tugmasining ORASIDA bo'lsin".
          //
          // Yuklash ketayotganda tugma o'rnida AYLANA progress va
          // uning ichida foiz turadi.
          const SizedBox(width: 6),
          _AttachButton(
            uploading: _uploading,
            progress: _upProgress,
            // Progress endi CHAT PUFFAGIDA ko'rinadi; tugmada
            // faqat "band" holati qoladi.
            showProgress: false,
            onImage: () => _pickAndSend(video: false),
            onVideo: () => _pickAndSend(video: true),
          ),
          const SizedBox(width: 6),
          // ── YUBORISH YOKI MIKROFON ──────────────────────────
          //
          // Matn yozilgan bo'lsa — yuborish, bo'sh bo'lsa —
          // mikrofon (Telegram va WhatsApp ham shunday qiladi).
          // Shu sabab qatorga qo'shimcha tugma qo'shilmaydi va
          // joy tig'iz bo'lib qolmaydi.
          Builder(builder: (context) {
            final empty = _input.text.trim().isEmpty;
            return GestureDetector(
              onTap: _sending
                  ? null
                  : (empty ? _startRecording : _send),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accent,
                ),
                child: _sending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(
                        empty ? Icons.mic_rounded : Icons.send_rounded,
                        size: empty ? 21 : 19,
                        color: Colors.white,
                      ),
              ),
            );
          }),
        ],
      );
  }
}

/// Sarlavhadagi kichik rasm.
class _TitleAvatar extends StatelessWidget {
  final String url;
  final String name;
  final double size;

  const _TitleAvatar({
    required this.url,
    required this.name,
    this.size = 34,
  });

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: AppColors.cardAlt,
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.7),
          fontSize: size * 0.42,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? fallback
            : CachedNetworkImage(
                cacheManager: AppImageCache.manager,
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: (size * 3).round(),
                placeholder: (_, __) => fallback,
                errorWidget: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

/// Bitta xabar puffagi.
class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;

  /// Suhbatdoshning rasmi (o'z xabarida bo'sh).
  final String avatarUrl;
  final String avatarName;

  /// Guruhdagi OXIRGI xabarmi — rasm faqat shunda chiziladi.
  final bool showAvatar;
  final VoidCallback? onAvatarTap;

  /// Admin uchun — uzoq bosilganda tanlash boshlanadi.
  final VoidCallback? onLongPress;

  /// Tanlash rejimida bosish tanlaydi, oddiy holatda esa
  /// rasm/video ochiladi.
  final VoidCallback? onTap;
  final VoidCallback onOpenMedia;

  /// Videoning boshidagi kadrni yasovchi (ekranga tegishli).
  final ChatVideoThumb thumbs;

  /// Shu xabar hozir tanlanganmi.
  final bool selected;

  /// Umuman tanlash rejimi ochiqmi (bitta bo'lsa ham).
  final bool selecting;

  const _Bubble({
    required this.message,
    required this.mine,
    required this.onOpenMedia,
    required this.thumbs,
    this.avatarUrl = '',
    this.avatarName = '',
    this.showAvatar = false,
    this.onAvatarTap,
    this.onLongPress,
    this.onTap,
    this.selected = false,
    this.selecting = false,
  });

  @override
  Widget build(BuildContext context) {
    final m = message;
    // ── TANLANGAN XABAR AJRALIB TURADI ────────────────────────
    //
    // Butun qator (rasm bilan birga) bo'yaladi — Telegram ham
    // shunday qiladi, ya'ni nimani tanlagani bir qarashda
    // ko'rinadi.
    return Container(
      color: selected
          ? AppColors.accent.withValues(alpha: 0.16)
          : Colors.transparent,
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) ...[
            // Rasm chizilmasa ham JOYI saqlanadi — aks holda
            // guruhdagi xabarlar bir-biriga nisbatan siljib
            // ketardi.
            SizedBox(
              width: 30,
              child: showAvatar
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onAvatarTap,
                      child: _TitleAvatar(
                        url: avatarUrl,
                        name: avatarName,
                        size: 30,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress,
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.76,
                ),
                padding: EdgeInsets.fromLTRB(
                    m.isViewable ? 4 : 13, m.isViewable ? 4 : 9,
                    m.isViewable ? 4 : 13, 7),
                decoration: BoxDecoration(
                  color: mine
                      ? AppColors.accent.withValues(alpha: 0.92)
                      : Colors.white.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(mine ? 16 : 4),
                    bottomRight: Radius.circular(mine ? 4 : 16),
                  ),
                  border: mine
                      ? null
                      : Border.all(
                          color: Colors.white.withValues(alpha: 0.10)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m.hasMedia) _media(context),
                    if (m.body.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                            m.isViewable ? 9 : 0, m.isViewable ? 7 : 0,
                            m.isViewable ? 9 : 0, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            m.body,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              height: 1.38,
                            ),
                          ),
                        ),
                      ),
                    // ── VAQT ────────────────────────────────────
                    //
                    // TALAB (foydalanuvchi): "adminga xabar
                    // yuborganda vaqti ham ko'rsatilsin".
                    Padding(
                      padding: EdgeInsets.only(
                          top: 3, right: m.isViewable ? 9 : 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            chatTime(m.createdAt),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 10.5,
                            ),
                          ),
                          // ── YUBORILISH BELGISI ────────────────
                          //
                          // TALAB (foydalanuvchi): "pastida vaqt
                          // ikoni aylanib tursin va yuborilgach
                          // Telegramdagidek bitta ✓ tursin, admin
                          // o'qiganidan keyingina ✓✓ ikkita
                          // bo'lsin".
                          //
                          // Belgi FAQAT o'z xabaringizda turadi:
                          // suhbatdoshning xabari yonida uning
                          // "o'qildi" holati ma'nosiz.
                          if (mine) ...[
                            const SizedBox(width: 4),
                            _SendState(pending: m.pending, seen: m.seen),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Rasm yoki videoning kichik ko'rinishi.
  ///
  /// Video uchun qora fon va o'rtada play belgisi — bosilganda
  /// sodda ko'ruvchi ochiladi (`media_view_screen.dart`).
  Widget _media(BuildContext context) {
    final m = message;
    // ── OVOZLI XABAR ────────────────────────────────────────
    //
    // U ko'ruvchida ochilmaydi — xabarning O'ZIDA ijro etiladi
    // (Telegram ham shunday qiladi).
    if (m.isVoice) {
      return _VoiceBubble(
        message: m,
        mine: mine,
        // Tanlash rejimida bosish TANLAYDI, ijro qilmaydi.
        onSelect: selecting ? onTap : null,
      );
    }
    return GestureDetector(
      // Tanlash rejimida rasm/video OCHILMAYDI — bosish tanlaydi.
      // Aks holda tanlayman deb bosgan odam har safar video
      // ko'ruvchiga tushib ketardi.
      onTap: selecting ? onTap : onOpenMedia,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 240, minWidth: 150),
          color: Colors.black.withValues(alpha: 0.35),
          child: m.isVideo
              ? SizedBox(
                  height: 150,
                  width: 220,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // ── VIDEONING BOSHIDAGI KADRI ────────
                      //
                      // Serverdan KELMAYDI (foydalanuvchi
                      // talabi: "serverga thumbnail
                      // yuklanmasin") — uni shu telefonning
                      // o'zi yasaydi va o'zida saqlaydi
                      // (`chat_video_thumb.dart`).
                      //
                      // Kadr tayyor bo'lmasa — bo'sh joy: pastda
                      // play belgisi baribir turadi.
                      _VideoThumb(thumbs: thumbs, url: m.mediaUrl),
                      Center(
                        child: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.3)),
                          ),
                          child: const Icon(Icons.play_arrow_rounded,
                              size: 32, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                )
              : CachedNetworkImage(
                  cacheManager: AppImageCache.manager,
                  imageUrl: m.mediaUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 700,
                  placeholder: (_, __) => const SizedBox(
                    height: 150,
                    width: 220,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white54),
                      ),
                    ),
                  ),
                  errorWidget: (_, __, ___) => const SizedBox(
                    height: 150,
                    width: 220,
                    child: Icon(Icons.broken_image_outlined,
                        color: Colors.white38),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Biriktirish tugmasi — yuklash ketayotganda AYLANA progress.
/// VIDEONING BOSHIDAGI KADRI (puffak ichida).
///
/// ── NEGA ALOHIDA VIDJET ─────────────────────────────────────
///
/// Kadr tayyor bo'lganda FAQAT SHU puffak qaytadan chiziladi —
/// butun ro'yxat emas. Uzun yozishmada bu sezilarli farq:
/// aks holda har bir tayyor kadr o'nlab qatorni qayta
/// qurdirardi.
///
/// Hech qanday hisob-kitob bu yerda bo'lmaydi: vidjet faqat
/// XOTIRADAN o'qiydi (`peek`), yasash esa fon'da ketadi.
class _VideoThumb extends StatefulWidget {
  final ChatVideoThumb thumbs;
  final String url;

  const _VideoThumb({required this.thumbs, required this.url});

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  @override
  void initState() {
    super.initState();
    widget.thumbs.addListener(_onThumb);
    // Ro'yxat qurilayotgan kadrda tarmoqqa chiqmaymiz: so'rov
    // birinchi kadrdan KEYIN yuboriladi, ya'ni surish silliq
    // qoladi.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.thumbs.request(widget.url);
    });
  }

  @override
  void didUpdateWidget(covariant _VideoThumb old) {
    super.didUpdateWidget(old);
    // Ro'yxat qatorlarni qayta ishlatadi — manzil almashsa
    // yangisi so'raladi.
    if (old.url != widget.url) widget.thumbs.request(widget.url);
  }

  @override
  void dispose() {
    widget.thumbs.removeListener(_onThumb);
    super.dispose();
  }

  void _onThumb() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.thumbs.peek(widget.url);
    if (bytes == null) return const SizedBox.shrink();
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      // Kadr almashganda puffak bir lahza oqarib ketmasin.
      gaplessPlayback: true,
    );
  }
}

class _AttachButton extends StatelessWidget {
  final bool uploading;
  final double progress;

  /// Progress tugmada ko'rsatilsinmi.
  ///
  /// Endi u CHAT PUFFAGIDA ko'rinadi (foydalanuvchi talabi), shu
  /// sabab tugmada faqat "band" holati qoladi.
  final bool showProgress;
  final VoidCallback onImage;
  final VoidCallback onVideo;

  const _AttachButton({
    required this.uploading,
    required this.progress,
    required this.onImage,
    required this.onVideo,
    this.showProgress = true,
  });

  @override
  Widget build(BuildContext context) {
    if (uploading && !showProgress) {
      return SizedBox(
        width: 42,
        height: 42,
        child: Icon(Icons.attach_file_rounded,
            size: 20, color: Colors.white.withValues(alpha: 0.25)),
      );
    }
    if (uploading) {
      final pct = (progress.clamp(0.0, 1.0) * 100).round();
      return SizedBox(
        width: 42,
        height: 42,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Aylana progress — talab AYNAN shunday edi.
            SizedBox(
              width: 42,
              height: 42,
              child: CircularProgressIndicator(
                // Hali bitta ham bayt ketmagan bo'lsa cheksiz
                // (aylanuvchi) ko'rinish: soxta 0% turmaydi.
                value: progress <= 0 ? null : progress.clamp(0.0, 1.0),
                strokeWidth: 3,
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
            Text(
              '$pct',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Glass(
              borderRadius: 20,
              blur: 18,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.image_rounded,
                        color: Colors.white70),
                    title: const Text('Rasm yuborish',
                        style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(ctx);
                      onImage();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.videocam_rounded,
                        color: Colors.white70),
                    title: const Text('Video yuborish',
                        style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(ctx);
                      onVideo();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.08),
        ),
        child: const Icon(Icons.attach_file_rounded,
            size: 20, color: Colors.white70),
      ),
    );
  }
}


// ══════════════════════════════════════════════════════════════
//  OVOZLI XABAR
// ══════════════════════════════════════════════════════════════
//
// Play/pause tugmasi, surib o'tkaziladigan chiziq va vaqt.
// Ijro YAGONA ijrochida (`VoicePlayer`): boshqa xabar bosilsa
// bunisi o'zi to'xtaydi.

class _VoiceBubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  final VoidCallback? onSelect;

  const _VoiceBubble({
    required this.message,
    required this.mine,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final m = message;
    final vp = VoicePlayer.instance;
    return AnimatedBuilder(
      animation: vp,
      builder: (context, _) {
        final playing = vp.isPlaying(m.id);
        final opening = vp.isOpening(m.id);
        final pos = vp.positionOf(m.id);
        // Uzunlik: ijro ochilgan bo'lsa fayldan, aks holda
        // xabar bilan kelgan qiymatdan. Ikkovi ham bo'lmasa
        // chiziq bo'sh turadi.
        final real = vp.durationOf(m.id);
        final total = real > Duration.zero
            ? real
            : Duration(milliseconds: m.mediaMs);
        final maxMs = total.inMilliseconds;
        final posMs = pos.inMilliseconds.clamp(0, maxMs <= 0 ? 0 : maxMs);

        return SizedBox(
          width: 210,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSelect ?? () => vp.toggle(m.id, m.mediaUrl),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: mine
                        ? Colors.white.withValues(alpha: 0.22)
                        : AppColors.accent,
                  ),
                  child: opening
                      ? const Padding(
                          padding: EdgeInsets.all(11),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 22,
                          color: Colors.white,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 5),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12),
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                        thumbColor: Colors.white,
                      ),
                      child: SizedBox(
                        height: 22,
                        child: Slider(
                          value: maxMs <= 0 ? 0 : posMs.toDouble(),
                          max: maxMs <= 0 ? 1 : maxMs.toDouble(),
                          // Ijro boshlanmagan bo'lsa surib bo'lmaydi —
                          // surish uchun avval fayl ochilishi kerak.
                          onChanged: (maxMs <= 0 || !vp.isCurrent(m.id))
                              ? null
                              : (x) => vp.seek(
                                  m.id, Duration(milliseconds: x.round())),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Text(
                        // Yangramayotgan bo'lsa umumiy uzunlik,
                        // yangrayotganda esa hozirgi nuqta.
                        vp.isCurrent(m.id) && maxMs > 0
                            ? '${voiceClock(pos)} / ${voiceClock(total)}'
                            : voiceClock(total),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.62),
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}


// ══════════════════════════════════════════════════════════════
//  YUBORILISH BELGISI
// ══════════════════════════════════════════════════════════════
//
// Uch holat:
//   * yuborilmoqda — AYLANIB turgan soat;
//   * yuborildi    — bitta ✓;
//   * o'qildi      — ikkita ✓✓.

class _SendState extends StatefulWidget {
  final bool pending;
  final bool seen;

  const _SendState({required this.pending, required this.seen});

  @override
  State<_SendState> createState() => _SendStateState();
}

class _SendStateState extends State<_SendState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pending) _spin.repeat();
  }

  @override
  void didUpdateWidget(covariant _SendState old) {
    super.didUpdateWidget(old);
    // Yuborilib bo'lgach aylanish to'xtaydi — bekor aylanayotgan
    // animatsiya batareyani yeydi.
    if (widget.pending && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.pending && _spin.isAnimating) {
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
    final color = Colors.white.withValues(alpha: widget.seen ? 0.95 : 0.6);
    if (widget.pending) {
      return RotationTransition(
        turns: _spin,
        child: Icon(Icons.schedule_rounded, size: 12, color: color),
      );
    }
    // Ikkita belgi bir-biriga QISMAN kirib turadi — Telegramda
    // ham shunday, alohida ikkita ✓ bo'lib ko'rinmaydi.
    if (widget.seen) {
      return SizedBox(
        width: 17,
        height: 12,
        child: Stack(
          children: [
            Icon(Icons.check_rounded, size: 12, color: color),
            Positioned(
              left: 5,
              child: Icon(Icons.check_rounded, size: 12, color: color),
            ),
          ],
        ),
      );
    }
    return Icon(Icons.check_rounded, size: 12, color: color);
  }
}

// ══════════════════════════════════════════════════════════════
//  YUKLANAYOTGAN FAYL
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "video, ovozli xabar yoki rasm
// yuborganda to'g'ridan-to'g'ri chat oynasida ko'rinsin va
// progress chizig'i play/pause tugmasi atrofida aylanib
// kattalashsin, huddi Telegramdagidek".
//
// Ya'ni fayl yuborilmasdan TURIB puffak bo'lib paydo bo'ladi:
// rasm bo'lsa o'zi ko'rinadi (telefondagi faylidan, tarmoq
// kutilmaydi), video va ovoz uchun esa tugma atrofida aylana
// to'lib boradi. Pastda aylanuvchi soat — "hali yuborilmadi".

class _UploadingBubble extends StatelessWidget {
  final String type;
  final String path;
  final double progress;
  final int ms;

  const _UploadingBubble({
    required this.type,
    required this.path,
    required this.progress,
    required this.ms,
  });

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    final image = type == 'image';
    // Rasm VA video — ikkovi ham puffakda TASVIR bo'lib turadi
    // (video endi kadri bilan), shu sabab ramka ingichka.
    // Ovozli xabarda esa tasvir yo'q — unga odatdagi ichki
    // masofa qoladi. Yuborilgan xabar puffagi ham shu qoidaga
    // amal qiladi (`isViewable`).
    final wide = image || type == 'video';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.76,
            ),
            padding: EdgeInsets.fromLTRB(
                wide ? 4 : 13, wide ? 4 : 9, wide ? 4 : 13, 7),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.92),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (image)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                              maxHeight: 240, minWidth: 150),
                          child: Image.file(File(path), fit: BoxFit.cover),
                        ),
                        Container(color: Colors.black38),
                        _Ring(progress: p),
                      ],
                    ),
                  )
                else if (type == 'video')
                  ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: SizedBox(
                      height: 150,
                      width: 220,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                            ),
                          ),
                          Center(child: _Ring(progress: p)),
                        ],
                      ),
                    ),
                  )
                else
                  SizedBox(
                    width: 210,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Ring(progress: p, size: 38),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            voiceClock(Duration(milliseconds: ms)),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                // Pastda aylanuvchi soat — hali yuborilmadi.
                const Padding(
                  padding: EdgeInsets.only(top: 4, right: 4),
                  child: _SendState(pending: true, seen: false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Play tugmasi atrofida aylanib KATTALASHADIGAN progress.
class _Ring extends StatelessWidget {
  final double progress;
  final double size;

  const _Ring({required this.progress, this.size = 52});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              // Hali bitta ham bayt ketmagan bo'lsa cheksiz
              // (aylanuvchi) ko'rinish: soxta 0% turmaydi.
              value: progress <= 0 ? null : progress,
              strokeWidth: 3,
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          Text(
            '${(progress * 100).round()}',
            style: TextStyle(
              color: Colors.white,
              fontSize: size > 44 ? 13 : 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
