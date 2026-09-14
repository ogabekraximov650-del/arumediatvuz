// lib/services/voice_player.dart — OVOZLI XABARNI IJRO ETISH.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "chatda ovozli xabar yuborish tizimini ham
// qo'sh".
//
// ── NEGA YANGI PAKET OLINMADI ───────────────────────────────
//
// Ijro uchun `video_player` ishlatiladi. U Android'da ExoPlayer
// (androidx.media3) ustida ishlaydi, ExoPlayer esa audio faylni
// (m4a/aac) video kabi bemalol o'ynatadi — shunchaki tasvir
// yo'lagi bo'lmaydi. Ya'ni ilovada ALLAQACHON bor va sinalgan
// dvigatel ishlatiladi; yangi paket qo'shish esa yana bitta
// native bog'lanish va yana bitta sinishi mumkin bo'lgan joy
// degani.
//
// ── BIR VAQTDA BITTA OVOZ ───────────────────────────────────
//
// Ijrochi YAGONA (singleton). Boshqa xabar bosilsa oldingisi
// o'zi to'xtaydi: ikkita ovoz bir vaqtda yangrasa suhbatni
// tinglab bo'lmasdi.

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

class VoicePlayer extends ChangeNotifier {
  VoicePlayer._();
  static final VoicePlayer instance = VoicePlayer._();

  VideoPlayerController? _c;

  /// Hozir ijro etilayotgan (yoki ochilayotgan) xabarning raqami.
  String? _id;
  bool _opening = false;

  String? get currentId => _id;

  bool isCurrent(String id) => _id == id;
  bool isOpening(String id) => _id == id && _opening;
  bool isPlaying(String id) =>
      _id == id && (_c?.value.isPlaying ?? false);

  Duration positionOf(String id) =>
      _id == id ? (_c?.value.position ?? Duration.zero) : Duration.zero;

  /// Faylning haqiqiy uzunligi. Hali ochilmagan bo'lsa nol —
  /// bunday paytda xabar bilan kelgan uzunlik ishlatiladi.
  Duration durationOf(String id) =>
      _id == id ? (_c?.value.duration ?? Duration.zero) : Duration.zero;

  /// Bosilganda: shu xabar yangrayotgan bo'lsa to'xtatadi, aks
  /// holda (kerak bo'lsa oldingisini yopib) shuni boshlaydi.
  Future<void> toggle(String id, String url) async {
    if (_id == id && _c != null) {
      final c = _c!;
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        // Oxirigacha yetgan bo'lsa boshidan.
        if (c.value.position >= c.value.duration) {
          await c.seekTo(Duration.zero);
        }
        await c.play();
      }
      notifyListeners();
      return;
    }

    await stop();
    _id = id;
    _opening = true;
    notifyListeners();

    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
      // Ochilayotganda boshqa xabar bosilgan bo'lsa — bunisi
      // keraksiz.
      if (_id != id) {
        await c.dispose();
        return;
      }
      _c = c;
      c.addListener(_tick);
      await c.setVolume(1.0);
      await c.play();
    } catch (_) {
      await c.dispose();
      if (_id == id) _id = null;
    }
    _opening = false;
    notifyListeners();
  }

  Future<void> seek(String id, Duration to) async {
    if (_id != id || _c == null) return;
    await _c!.seekTo(to);
    notifyListeners();
  }

  void _tick() {
    final c = _c;
    if (c == null) return;
    // Oxiriga yetdi — boshiga qaytaramiz va to'xtatamiz, shunda
    // tugma yana "play" bo'lib ko'rinadi.
    if (c.value.isInitialized &&
        !c.value.isPlaying &&
        c.value.duration > Duration.zero &&
        c.value.position >= c.value.duration) {
      c.seekTo(Duration.zero);
    }
    notifyListeners();
  }

  /// Ijroni to'xtatadi va resurslarni bo'shatadi.
  Future<void> stop() async {
    final c = _c;
    _c = null;
    _id = null;
    _opening = false;
    if (c != null) {
      c.removeListener(_tick);
      try {
        await c.pause();
      } catch (_) {}
      try {
        await c.dispose();
      } catch (_) {}
    }
    notifyListeners();
  }
}

/// 0:07 ko'rinishidagi qisqa vaqt.
String voiceClock(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
