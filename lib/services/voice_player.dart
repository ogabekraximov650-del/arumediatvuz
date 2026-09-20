// lib/services/voice_player.dart — OVOZLI XABARNI IJRO ETISH.
//
// ═══════════════════════════════════════════════════════════════
//  TOPILGAN XATO
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "yuborilgan audio ishlamayapti".
//
// SABAB. Ijro `video_player` bilan qilingan edi. U TASVIR
// YO'LAGI bor faylga mo'ljallangan: Android tomonida pleyer
// tasvir uchun sirt (surface/texture) yaratadi va o'lchamni
// kutadi. Ovozli faylda tasvir yo'lagi UMUMAN yo'q — shu sabab
// `initialize()` ba'zan tugamaydi, uzunlik esa nol bo'lib
// qoladi. Ya'ni tugma bosilardi-yu, hech narsa bo'lmasdi.
//
// YECHIM. `just_audio` — Flutter'da audio uchun eng keng
// ishlatiladigan paket. Android'da u ham ExoPlayer ustida
// ishlaydi (ya'ni dvigatel o'sha-o'sha), lekin audio uchun
// to'g'ri yo'l bilan: sirt yaratilmaydi, uzunlik konteynerdan
// o'qiladi, oldindan buferlash va surib o'tkazish to'g'ri
// ishlaydi.
//
// Fayl `m4a` (AAC) — bu konteynerda uzunlik va surish jadvali
// bor. Xom `aac` oqimida ular bo'lmaydi va uzunlik noto'g'ri
// chiqadi; shu sabab yozib olishda ham aynan `m4a` tanlangan.
//
// ── BIR VAQTDA BITTA OVOZ ───────────────────────────────────
//
// Ijrochi YAGONA (singleton): boshqa xabar bosilsa oldingisi
// o'zi to'xtaydi. Ikkita ovoz bir vaqtda yangrasa suhbatni
// tinglab bo'lmasdi.
//
// ═══════════════════════════════════════════════════════════════
//  IKKINCHI TOPILGAN XATO — MANZILDA TOKEN YO'Q EDI
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "support chatdagi ovozli xabar ishlamayapti".
//
// SABAB. Yo'llar yopilgach (`needs_app_check` — worker endi
// `/api/media/` ni ham tekshiradi) manzilga ruxsat kerak bo'ldi.
// Video va rasm uchun bu allaqachon qo'yilgan edi, OVOZ esa
// e'tibordan chetda qolgan.
//
// Nega aynan shunday bo'ldi: `_p.setUrl(...)` manzilni Dart'ga
// EMAS, TIZIMGA (Android'da ExoPlayer) beradi. Ya'ni so'rov
// `package:http` dan o'tmaydi va `AppHttpClient` unga
// `X-App-Sig` sarlavhasini qo'sha olmaydi — xuddi
// `VideoPlayerController.networkUrl` dagi kabi. Worker esa
// sarlavhasiz so'rovga 403 qaytaradi.
//
// Tashqaridan bu "tugma bosiladi-yu hech narsa bo'lmaydi" bo'lib
// ko'rinardi, chunki `setUrl` ning xatosi pastda jimgina
// yutilardi.
//
// YECHIM. Manzil `nativeMediaUrl()` dan o'tkaziladi — u
// `?t=<muddat>.<hex HMAC>` tokenini qo'yadi (`app_http.dart`
// izohiga qarang). Token AYNAN shu faylga bog'langan va 6 soat
// yashaydi.
//
// MUHIM: token IJRO BOSHLANGANDA olinadi, xabar ro'yxatda
// chizilganda emas. Uzoq ochiq turgan yozishmada eski token
// muddati tugagan bo'lardi.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'app_http.dart';

class VoicePlayer extends ChangeNotifier {
  VoicePlayer._() {
    // Bitta pleyer butun ilova uchun — har bosishda yangisini
    // yaratish Android'da sekin va resurs talab qiladi.
    _p.playerStateStream.listen((st) {
      // Oxiriga yetdi — boshiga qaytariladi va tugma yana
      // "play" bo'lib ko'rinadi.
      if (st.processingState == ProcessingState.completed) {
        _p.pause();
        _p.seek(Duration.zero);
      }
      notifyListeners();
    });
    _p.positionStream.listen((_) => notifyListeners());
    _p.durationStream.listen((_) => notifyListeners());
  }

  static final VoicePlayer instance = VoicePlayer._();

  final AudioPlayer _p = AudioPlayer();

  /// Hozir ijro etilayotgan (yoki ochilayotgan) xabarning raqami.
  String? _id;
  bool _opening = false;

  String? get currentId => _id;

  bool isCurrent(String id) => _id == id;
  bool isOpening(String id) => _id == id && _opening;
  bool isPlaying(String id) => _id == id && _p.playing;

  Duration positionOf(String id) =>
      _id == id ? _p.position : Duration.zero;

  /// Faylning haqiqiy uzunligi. Hali ochilmagan bo'lsa nol —
  /// bunday paytda xabar bilan kelgan uzunlik ishlatiladi.
  Duration durationOf(String id) =>
      _id == id ? (_p.duration ?? Duration.zero) : Duration.zero;

  /// Bosilganda: shu xabar yangrayotgan bo'lsa to'xtatadi, aks
  /// holda (kerak bo'lsa oldingisini yopib) shuni boshlaydi.
  Future<void> toggle(String id, String url) async {
    if (_id == id) {
      if (_p.playing) {
        await _p.pause();
      } else {
        if (_p.processingState == ProcessingState.completed) {
          await _p.seek(Duration.zero);
        }
        unawaited(_p.play());
      }
      notifyListeners();
      return;
    }

    _id = id;
    _opening = true;
    notifyListeners();
    try {
      await _p.stop();
      // Manzilni TIZIM ochadi, ilova emas — ruxsat shu sabab
      // manzilning O'ZIDA keladi (fayl boshidagi izohga qarang).
      await _p.setUrl(nativeMediaUrl(url));
      // Ochilayotganda boshqa xabar bosilgan bo'lsa — bunisi
      // keraksiz.
      if (_id != id) return;
      _opening = false;
      notifyListeners();
      // `play()` KUTILMAYDI: u ijro TUGAGUNCHA tugamaydi.
      unawaited(_p.play());
    } catch (e) {
      // Xato JIM YUTILMAYDI: aynan shu `catch` tufayli manzildagi
      // token yo'qligi (403) "tugma ishlamayapti" bo'lib
      // ko'rinardi va sababi ko'rinmasdi.
      if (kDebugMode) debugPrint('VoicePlayer: ochilmadi — $e');
      if (_id == id) {
        _id = null;
        _opening = false;
      }
    }
    notifyListeners();
  }

  Future<void> seek(String id, Duration to) async {
    if (_id != id) return;
    await _p.seek(to);
    notifyListeners();
  }

  /// Ijroni to'xtatadi (ekran yopilganda).
  Future<void> stop() async {
    _id = null;
    _opening = false;
    try {
      await _p.stop();
    } catch (_) {}
    notifyListeners();
  }
}

/// 0:07 ko'rinishidagi qisqa vaqt.
String voiceClock(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
