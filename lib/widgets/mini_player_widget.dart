import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../screens/video_player_screen.dart';
import '../services/mini_player_service.dart';
import 'glass.dart';

class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({super.key});

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> {
  VideoPlayerController? _controller;
  bool _initializing = false;
  Offset _position = const Offset(16, -1);
  bool _needsInitialPosition = true;

  @override
  void initState() {
    super.initState();
    MiniPlayerService.instance.addListener(_onServiceChange);
    if (MiniPlayerService.instance.active) _initController();
  }

  @override
  void dispose() {
    MiniPlayerService.instance.removeListener(_onServiceChange);
    _controller?.dispose();
    super.dispose();
  }

  void _onServiceChange() {
    if (!mounted) return;
    if (MiniPlayerService.instance.active && _controller == null && !_initializing) {
      _initController();
    } else if (!MiniPlayerService.instance.active) {
      _disposeController();
      setState(() {});
    }
  }

  Future<void> _initController() async {
    _initializing = true;
    final data = MiniPlayerService.instance.data;
    if (data == null) {
      _initializing = false;
      return;
    }
    final uri = Uri.tryParse(data.url);
    if (uri == null) {
      _initializing = false;
      return;
    }
    final ctrl = VideoPlayerController.networkUrl(uri);
    try {
      await ctrl.initialize();
      if (!mounted || !MiniPlayerService.instance.active) {
        ctrl.dispose();
        _initializing = false;
        return;
      }
      await ctrl.seekTo(data.position);
      await ctrl.play();
      setState(() {
        _controller = ctrl;
        _needsInitialPosition = true;
      });
      ctrl.addListener(_onVideoTick);
    } catch (_) {
      ctrl.dispose();
    }
    _initializing = false;
  }

  void _onVideoTick() {
    if (_controller == null) return;
    MiniPlayerService.instance.updatePosition(_controller!.value.position);
  }

  void _disposeController() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    _controller = null;
  }

  void _close() {
    _disposeController();
    MiniPlayerService.instance.deactivate();
  }

  void _expand() {
    final data = MiniPlayerService.instance.data;
    if (data == null) return;
    final pos = _controller?.value.position ?? data.position;
    _disposeController();
    MiniPlayerService.instance.deactivate();
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, anim, __) => VideoPlayerScreen(
          season: data.season,
          startEpizodId: int.tryParse(data.episode['id']?.toString() ?? ''),
          startAt: pos,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  void _togglePlay() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!MiniPlayerService.instance.active || _controller == null) {
      return const SizedBox.shrink();
    }

    final screenSize = MediaQuery.of(context).size;
    const playerW = 200.0;
    const playerH = 130.0;

    if (_needsInitialPosition) {
      _position = Offset(16, screenSize.height - playerH - 100);
      _needsInitialPosition = false;
    }

    final clamped = Offset(
      _position.dx.clamp(0, screenSize.width - playerW),
      _position.dy.clamp(0, screenSize.height - playerH),
    );

    return Positioned(
      left: clamped.dx,
      top: clamped.dy,
      child: GestureDetector(
        onPanUpdate: (d) {
          setState(() => _position = Offset(
                _position.dx + d.delta.dx,
                _position.dy + d.delta.dy,
              ));
        },
        onTap: _expand,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: playerW,
            height: playerH,
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderBright),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        VideoPlayer(_controller!),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: _miniBtn(
                            Icons.close_rounded,
                            _close,
                          ),
                        ),
                        Positioned(
                          left: 4,
                          top: 4,
                          child: _miniBtn(
                            Icons.open_in_full_rounded,
                            _expand,
                          ),
                        ),
                        Center(
                          child: GestureDetector(
                            onTap: _togglePlay,
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _controller!.value.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    color: AppColors.surface,
                    child: Row(
                      children: [
                        Expanded(
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
                        ),
                      ],
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

  Widget _miniBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, color: Colors.white, size: 14),
      ),
    );
  }
}
