import 'dart:async';

import 'package:flutter/foundation.dart';

import 'rust_bridge.dart';

// ── Videoni doimiy, bayt-darajasida diskka keshlaydigan mahalliy proksi ──
//
// HAQIQIY server mantiqi endi TO'LIQ RUST'DA (rust/src/video_cache.rs),
// mustaqil native OS ish oqimida ishlaydi — Dart/Flutter isolate holatidan
// qat'i nazar har doim so'rovlarga javob bera oladi. Bu klass shunchaki
// FFI (rust_bridge.dart) orqali o'sha serverni ishga tushiradigan va
// undan kelayotgan diagnostika jurnalini so'rab turadigan YUPQA
// (Dart-tomon) qatlam.
//
// Ilgari bu server to'liq Dart'da (dart:io HttpServer) yozilgan edi va
// asosiy isolate band bo'lib qolganda o'z-o'ziga qulflanish (deadlock)
// muammosiga duch kelgan edi. Rust versiyasi bu muammo sinfini butunlay
// yo'q qiladi: server native ish oqimida ishlagani uchun Dart VM/Flutter
// engine holatiga umuman bog'liq emas.
class VideoCacheServer {
  VideoCacheServer._();
  static final VideoCacheServer instance = VideoCacheServer._();

  int? _port;
  Future<int>? _starting;
  Timer? _pollTimer;

  // ── Diagnostika jurnali ──────────────────────────────────────────
  // Rust tomonidan yozilgan loglar davriy so'rov (poll) orqali shu
  // yerga ko'chiriladi. video_player_screen.dart shu ro'yxatni
  // tinglab, so'nggi qatorlarni ekranda kichik panel sifatida
  // ko'rsatadi (adb/logcat kerak bo'lmasdan).
  static final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  // video_player_screen.dart kabi tashqi fayllar ham shu umumiy
  // (xronologik) jurnalga yozishi uchun ochiq wrapper.
  static void log(String msg) => _log(msg);

  static void _log(String msg) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    _appendLines(['[$ts] $msg']);
    // Pleyer loglari ham Rust'ning YAGONA debug_log.txt fayliga tushadi —
    // shunda foydalanuvchi bitta faylni yuborsa, server va pleyer
    // hodisalari bir xil xronologik tartibda ko'rinadi.
    RustCore.instance.writeVideoCacheLog('[$ts] $msg');
  }

  /// Diskdagi yagona jurnal faylining to'liq yo'li (ekranda ko'rsatish
  /// va foydalanuvchiga topib berish uchun).
  static String get logFilePath => RustCore.instance.videoCacheLogPath;

  static void _appendLines(List<String> lines) {
    if (lines.isEmpty) return;
    final list = List<String>.from(logs.value)..addAll(lines);
    if (list.length > 300) list.removeRange(0, list.length - 300);
    logs.value = list;
  }

  // Berilgan asl (masofaviy) URL o'rniga video_player'ga beriladigan
  // mahalliy proksi URL'ini qaytaradi. Serverni kerak bo'lsa ishga
  // tushiradi (lazy — ilova ochilganda emas, birinchi video o'ynatilganda).
  //
  // MUHIM: 5 soniyalik timeout bilan himoyalangan — kutilmagan holatda
  // Rust tomoni javob bermasa ham, chaqiruvchi (video_player_screen.dart)
  // buni ushlab, ASL (kesh'siz) URL bilan to'g'ridan-to'g'ri o'ynatishga
  // qaytadi.
  Future<Uri> proxyUri(String originalUrl) async {
    _log('proxyUri chaqirildi: ${_shortUrl(originalUrl)}');
    final port = await _ensureStarted().timeout(const Duration(seconds: 5));
    return Uri.parse(
        'http://127.0.0.1:$port/v?u=${Uri.encodeQueryComponent(originalUrl)}');
  }

  Future<int> _ensureStarted() {
    if (_port != null) return Future.value(_port);
    if (_starting != null) return _starting!;
    final completer = Completer<int>();
    _starting = completer.future;
    _start(completer);
    return completer.future;
  }

  Future<void> _start(Completer<int> completer) async {
    _log('Rust video-kesh serveri ishga tushirilmoqda...');
    try {
      final port = await RustCore.instance.startVideoCache();
      _port = port;
      _log('Rust video-kesh serveri tayyor: 127.0.0.1:$port');
      if (!completer.isCompleted) completer.complete(port);
      _startLogPolling();
    } catch (e) {
      _log('XATO: Rust video-kesh serveri ishga tushmadi — $e');
      if (!completer.isCompleted) completer.completeError(e);
    } finally {
      _starting = null;
    }
  }

  // Rust tomonida to'planayotgan diagnostika loglarini davriy so'rab,
  // umumiy (ekranda ko'rsatiladigan) jurnalga qo'shib boradi.
  void _startLogPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final lines = RustCore.instance.pullVideoCacheLogs();
      if (lines.isNotEmpty) _appendLines(lines);
    });
  }

  static String _shortUrl(String url) =>
      url.length > 70 ? '...${url.substring(url.length - 70)}' : url;
}
