// lib/screens/media_view_screen.dart — YOZISHMADAGI RASM/VIDEO.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "admin yoki foydalanuvchi videoni ochib ko'rganda
// FAQATGINA play/pause tugmasi va pastda progress chizig'i
// bo'lsin".
//
// Ya'ni bu ASOSIY PLEYER EMAS. U yerda sifat tanlash, intro
// o'tkazish, qismlar ro'yxati, tezlik, to'liq ekran va yana
// o'nlab narsa bor — yozishmadagi qisqa video uchun ularning
// hammasi ortiqcha. Shu sabab bu ekran ataylab juda sodda va
// asosiy pleyerdan butunlay mustaqil.
//
// Rasm esa shunchaki ko'rsatiladi: barmoq bilan kattalashtirsa
// bo'ladi (`InteractiveViewer`).

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/app_http.dart';
import '../services/image_cache.dart';
import '../services/video_gate.dart';

class MediaViewScreen extends StatefulWidget {
  final String url;

  /// `image` yoki `video`.
  final String type;

  const MediaViewScreen({super.key, required this.url, required this.type});

  @override
  State<MediaViewScreen> createState() => _MediaViewScreenState();
}

class _MediaViewScreenState extends State<MediaViewScreen> {
  VideoPlayerController? _ctrl;
  bool _error = false;

  bool get _isVideo => widget.type == 'video';

  // ── NEGA ALOHIDA NOTIFIER'LAR ─────────────────────────────
  //
  // TOPILGAN XATO (foydalanuvchi: "chatdagi video pleyerdagidek
  // tez va silliq ishlamayapti, sekin va qotib ishlayapti").
  //
  // Ilgari pastdagi chiziq to'g'ridan-to'g'ri pleyerning O'ZINI
  // tinglardi. Pleyer esa holatini SEKUNDIGA O'NLAB MARTA
  // yangilaydi — ya'ni `Slider`, `SliderTheme` va ikkita yozuv
  // har safar qaytadan quriladi. Ustiga video sirtining o'zi ham
  // shu daraxt ichida edi, ya'ni har yangilanishda u ham qayta
  // chizilishga tekshirilardi.
  //
  // Endi ekranga faqat IKKITA kichik qiymat beriladi: pozitsiya
  // (har 250 ms da) va "ijro ketyaptimi" belgisi (faqat
  // O'ZGARGANDA). Video sirti esa `RepaintBoundary` ichida —
  // chiziq harakatlansa ham unga tegilmaydi.
  final ValueNotifier<Duration> _pos = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _playing = ValueNotifier(false);
  Timer? _tick;

  /// Barmoq chiziqni surayapti.
  ///
  /// SEK SURISH PAYTIDA EMAS, QO'YIB YUBORILGANDA bajariladi:
  /// aks holda barmoq harakatlanganda sekundiga o'nlab `seekTo`
  /// ketardi va pleyer har safar buferni tashlab qaytadan
  /// yuklashga tushardi — "qotib qolish" hissi aynan shundan.
  /// Anime pleyeri ham aynan shunday ishlaydi (surish tugaganda
  /// bir marta).
  ///
  /// `setState` ATAYLAB ishlatilmaydi: surish davomida faqat
  /// pastdagi chiziq yangilanadi, video sirtiga tegilmaydi.
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    // Yozishmadagi video SHU YERDA ijro etiladi. Kadr yasovchi
    // shu paytda tarmoqqa chiqmasin — ijro birinchi o'rinda
    // (`video_gate.dart` izohiga qarang).
    if (_isVideo) {
      VideoGate.enter();
      _open();
    }
  }

  void _startTicker(VideoPlayerController c) {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final v = c.value;
      if (!_dragging) _pos.value = v.position;
      if (_playing.value != v.isPlaying) _playing.value = v.isPlaying;
    });
  }

  Future<void> _open() async {
    // ── ANIME PLEYERI BILAN BIR XIL ─────────────────────────
    //
    // TALAB (foydalanuvchi): "chat video pleyeri anime pleyeri
    // bilan bir xil bo'lishi kerak, faqat unda play/pause
    // tugmasi va pastida qo'lda surasa bo'ladigan progress
    // chizig'i bo'lsin".
    //
    // Shu sabab pleyer ANIQ o'sha sozlamalar bilan ochiladi:
    //
    //   * `platformView` (SurfaceView) — Android'da Google'ning
    //     rasmiy tavsiyasi. Video o'z ekran qatlamiga chiziladi,
    //     Flutter sahnasiga aralashmaydi; quvvat sarfi kam va
    //     tekstura bilan bog'liq muammolar (Impeller) tegmaydi.
    //     Asosiy pleyer aynan shu sababdan unga o'tkazilgan edi.
    //
    //   * ovoz fokusi o'ziniki (`mixWithOthers: false`) va ilova
    //     fon'ga ketsa to'xtaydi.
    //
    // Ko'rinish esa ataylab sodda: sifat tanlash, intro
    // o'tkazish, qismlar, tezlik va to'liq ekran — yozishmadagi
    // qisqa video uchun ularning hammasi ortiqcha.
    setState(() => _error = false);
    final c = VideoPlayerController.networkUrl(
      // Manzilni ExoPlayer ochadi — unga sarlavha qo'shib
      // bo'lmaydi, shu sabab ruxsat manzilning o'zida keladi
      // (`nativeMediaUrl` izohiga qarang).
      Uri.parse(nativeMediaUrl(widget.url)),
      viewType: VideoViewType.platformView,
      videoPlayerOptions: VideoPlayerOptions(
        allowBackgroundPlayback: false,
        mixWithOthers: false,
      ),
    );
    try {
      // Birinchi ochishda fayl Cloudflare keshiga ko'chiriladi
      // (`b2_media` izohiga qarang) — shu sabab muddat uzunroq.
      await c.initialize().timeout(const Duration(seconds: 40));
      if (!mounted) {
        await c.dispose();
        return;
      }
      if (!c.value.isInitialized) {
        await c.dispose();
        setState(() => _error = true);
        return;
      }
      await c.setVolume(1.0);
      setState(() => _ctrl = c);
      _startTicker(c);
      await c.play();
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    if (_isVideo) VideoGate.leave();
    _tick?.cancel();
    _pos.dispose();
    _playing.dispose();
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      extendBodyBehindAppBar: true,
      body: Center(child: _isVideo ? _video() : _image()),
    );
  }

  Widget _image() {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: CachedNetworkImage(
        cacheManager: AppImageCache.manager,
        imageUrl: widget.url,
        fit: BoxFit.contain,
        placeholder: (_, __) => const SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
        ),
        errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined,
            size: 54, color: Colors.white30),
      ),
    );
  }

  Widget _video() {
    if (_error) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Videoni ochib bo\'lmadi',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _open,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Qayta urinish'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white30),
            ),
          ),
        ],
      );
    }
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) {
      return const SizedBox(
        width: 34,
        height: 34,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
      );
    }
    final total = c.value.duration.inMilliseconds;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Video sirti ALOHIDA qatlamda: pastdagi chiziq
                  // harakatlansa ham unga tegilmaydi.
                  RepaintBoundary(child: VideoPlayer(c)),
                  // ── FAQAT PLAY/PAUSE ──────────────────────────
                  //
                  // Butun kadr bosiladi — kichkina tugmani izlab
                  // o'tirmaydi. `setState` CHAQIRILMAYDI: aks holda
                  // har bosishda butun ekran (video sirti bilan
                  // birga) qaytadan qurilardi.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      final wasPlaying = c.value.isPlaying;
                      if (wasPlaying) {
                        c.pause();
                      } else {
                        c.play();
                      }
                      // Belgi DARHOL almashadi — pleyerning javobi
                      // kutilmaydi. Taymer keyin haqiqiy holat
                      // bilan tekislab qo'yadi.
                      _playing.value = !wasPlaying;
                    },
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _playing,
                      builder: (context, playing, child) => AnimatedOpacity(
                        // Ijro ketayotganda tugma so'nadi — kadrni
                        // to'sib turmasin.
                        opacity: playing ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 180),
                        child: Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.25)),
                          ),
                          child: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 36,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // ── PASTDAGI PROGRESS CHIZIG'I ────────────────────────
        //
        // Faqat SHU qism qayta chiziladi (har 250 ms da).
        RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            child: ValueListenableBuilder<Duration>(
              valueListenable: _pos,
              builder: (context, position, _) {
                final shown =
                    position.inMilliseconds.clamp(0, total).toDouble();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 14),
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        value: total <= 0 ? 0 : shown,
                        max: total <= 0 ? 1 : total.toDouble(),
                        // ── SEK FAQAT QO'YIB YUBORILGANDA ────────
                        //
                        // Surish davomida faqat TUTQICH siljiydi,
                        // pleyerga tegilmaydi. Aks holda sekundiga
                        // o'nlab `seekTo` ketib, pleyer har safar
                        // buferni tashlar va qaytadan yuklardi —
                        // "sekin va qotib ishlaydi" hissi aynan
                        // shundan edi.
                        onChangeStart: (_) => _dragging = true,
                        // Surish davomida FAQAT tutqich siljiydi.
                        onChanged: (x) =>
                            _pos.value = Duration(milliseconds: x.round()),
                        onChangeEnd: (x) {
                          _dragging = false;
                          _pos.value = Duration(milliseconds: x.round());
                          c.seekTo(Duration(milliseconds: x.round()));
                        },
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_clock(Duration(milliseconds: shown.round())),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        Text(_clock(c.value.duration),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  String _clock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (d.inHours > 0) {
      return '${d.inHours}:${two(m % 60)}:${two(s)}';
    }
    return '${two(m)}:${two(s)}';
  }
}
