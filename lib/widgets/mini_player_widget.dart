// widgets/mini_player_widget.dart
//
// Ilova ichidagi suzuvchi kichik pleyer. Nima uchun kerakligi va
// nega kontroller bu yerda yangidan ochilishi —
// `services/mini_player_service.dart` boshidagi izohda.

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../screens/video_player_screen.dart';
import '../services/mini_player_service.dart';
import 'glass.dart';

/// Kichik oynaning o'lchami. Nisbat 16:9 ga yaqin.
const double _kMiniW = 196;
const double _kMiniH = 134;

/// Ostidagi yozuv qatorining balandligi.
const double _kLabelH = 24;

/// Ekran chetidan qoldiriladigan eng kichik bo'shliq.
const double _kEdge = 12;

class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({super.key});

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> {
  VideoPlayerController? _controller;

  /// Bir vaqtda ikkita kontroller ochilib qolmasligi uchun.
  bool _opening = false;

  /// Chap-yuqori burchagining o'rni. `null` — hali joylashtirilmagan
  /// (birinchi chizishda pastki-chap burchakka qo'yiladi).
  Offset? _pos;

  /// `null` bo'lmasa — kontroller ochilmadi, xato yozuvi ko'rsatiladi.
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    // Kontroller FAQAT shu yerda yopiladi: widget daraxtdan
    // olib tashlanganda Flutter buni doim chaqiradi.
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;

    final data = MiniPlayerService.instance.data;
    final uri = data == null ? null : Uri.tryParse(data.url);
    if (data == null || uri == null) {
      _opening = false;
      if (mounted) setState(() => _error = 'Video manzili noto\'g\'ri');
      return;
    }

    final ctrl = VideoPlayerController.networkUrl(uri);
    try {
      await ctrl.initialize().timeout(const Duration(seconds: 20));

      // Ochilguncha foydalanuvchi oynani yopgan bo'lishi mumkin —
      // o'shanda kontroller ortda qolib ketmasin.
      if (!mounted) {
        await ctrl.dispose();
        return;
      }

      await ctrl.seekTo(data.position);
      await ctrl.play();
      ctrl.addListener(_onTick);
      setState(() {
        _controller = ctrl;
        _error = null;
      });
    } catch (e) {
      try {
        await ctrl.dispose();
      } catch (_) {}
      if (mounted) setState(() => _error = 'Video ochilmadi');
    } finally {
      _opening = false;
    }
  }

  /// Soniyani servisga yozib boradi — oyna kattalashtirilganda
  /// pleyer aynan shu joydan davom etadi.
  ///
  /// Bu yerda `setState` ATAYLAB chaqirilmaydi: tick sekundiga bir
  /// necha marta keladi. Faqat ijro holati (play/pause) o'zgarganda
  /// qayta chiziladi — tugma belgisi shunga bog'liq.
  bool _lastPlaying = false;
  void _onTick() {
    final c = _controller;
    if (c == null || !mounted) return;
    MiniPlayerService.instance.updatePosition(c.value.position);
    if (c.value.isPlaying != _lastPlaying) {
      _lastPlaying = c.value.isPlaying;
      setState(() {});
    }
  }

  void _close() => MiniPlayerService.instance.deactivate();

  /// Oynani yopib, to'liq pleyerni o'sha joydan ochadi.
  void _expand() {
    final data = MiniPlayerService.instance.data;
    if (data == null) return;

    // Navigator'ni O'CHIRISHDAN OLDIN olamiz: `deactivate()` shu
    // widget'ni daraxtdan olib tashlaydi va undan keyin
    // `context` ishlatib bo'lmaydi.
    final nav = Navigator.of(context);
    final pos = _controller?.value.position ?? data.position;

    MiniPlayerService.instance.deactivate();

    nav.push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, __, ___) => VideoPlayerScreen(
          season: data.season,
          startEpizodId: data.epizodId == 0 ? null : data.epizodId,
          startAt: pos,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final safe = media.padding;

    // Oyna ekrandan tashqariga chiqmasin. Ekran burilganda ham
    // shu yerda qayta siqiladi — shu sabab `_pos` xom holda
    // saqlanadi, siqilgani esa har chizishda hisoblanadi.
    final minX = _kEdge;
    final maxX = (size.width - _kMiniW - _kEdge).clamp(minX, double.infinity);
    final minY = safe.top + _kEdge;
    final maxY = (size.height - _kMiniH - safe.bottom - _kEdge)
        .clamp(minY, double.infinity);

    // Birinchi chizish: pastki-chap burchak (pastki menyu ustida).
    final raw = _pos ?? Offset(minX, maxY);
    final at = Offset(
      raw.dx.clamp(minX, maxX),
      raw.dy.clamp(minY, maxY),
    );

    return Positioned(
      left: at.dx,
      top: at.dy,
      child: GestureDetector(
        // Surilganda xom qiymat yangilanadi; chegara yuqorida
        // qo'llanadi, shu sabab barmoq chetga chiqsa ham oyna
        // "yopishib" qolmaydi.
        onPanUpdate: (d) => setState(() => _pos = at + d.delta),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: _kMiniW,
            height: _kMiniH,
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderBright),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Column(
                children: [
                  Expanded(child: _videoArea()),
                  _label(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _videoArea() {
    final c = _controller;

    if (_error != null) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.white54, size: 20),
              const SizedBox(height: 4),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ),
        ),
      );
    }

    if (c == null || !c.value.isInitialized) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: c.value.size.width,
            height: c.value.size.height,
            child: VideoPlayer(c),
          ),
        ),

        // O'rtadagi play/pause. Rasm ustida turgani uchun ostiga
        // to'q doira qo'yiladi — oq belgi oq kadrda yo'qolmasin.
        Center(
          child: GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
              child: Icon(
                c.value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),

        Positioned(
          left: 4,
          top: 4,
          child: _btn(Icons.open_in_full_rounded, _expand),
        ),
        Positioned(
          right: 4,
          top: 4,
          child: _btn(Icons.close_rounded, _close),
        ),
      ],
    );
  }

  Widget _label() {
    return Container(
      height: _kLabelH,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: AppColors.surface,
      alignment: Alignment.centerLeft,
      child: Text(
        MiniPlayerService.instance.data?.title ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(icon, color: Colors.white, size: 15),
      ),
    );
  }
}
