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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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

  @override
  void initState() {
    super.initState();
    if (_isVideo) _open();
  }

  Future<void> _open() async {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _ctrl = c);
      await c.play();
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
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
      return const Text(
        'Videoni ochib bo\'lmadi',
        style: TextStyle(color: Colors.white54),
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
                  VideoPlayer(c),
                  // ── FAQAT PLAY/PAUSE ──────────────────────────
                  //
                  // Butun kadr bosiladi — kichkina tugmani izlab
                  // o'tirmaydi.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(
                        () => c.value.isPlaying ? c.pause() : c.play()),
                    child: ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: c,
                      builder: (context, v, _) => AnimatedOpacity(
                        // Ijro ketayotganda tugma so'nadi — kadrni
                        // to'sib turmasin.
                        opacity: v.isPlaying ? 0.0 : 1.0,
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
                            v.isPlaying
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: c,
            builder: (context, v, _) {
              final total = v.duration.inMilliseconds;
              final pos = v.position.inMilliseconds.clamp(0, total);
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
                      value: total <= 0 ? 0 : pos.toDouble(),
                      max: total <= 0 ? 1 : total.toDouble(),
                      onChanged: (x) =>
                          c.seekTo(Duration(milliseconds: x.round())),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_clock(v.position),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                      Text(_clock(v.duration),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ],
              );
            },
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
