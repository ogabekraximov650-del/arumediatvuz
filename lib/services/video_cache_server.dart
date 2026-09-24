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

  // ── Diagnostika ─────────────────────────────────────────────────
  // Ekrandagi jurnal paneli va diskdagi debug_log.txt OLIB TASHLANDI.
  //
  // Sabablari:
  //   1) Panel har 400 ms da Rust'dan loglarni FFI orqali so'rab,
  //      JSON'ga o'girib, qayta tahlil qilib, 300 qatorlik ro'yxatni
  //      qayta qurar va setState chaqirardi — bularning HAMMASI
  //      ASOSIY (UI) OQIMIDA. Bu pleyerni behuda og'irlashtirardi.
  //   2) Diskdagi jurnal fayli shifrlanmagan holda ilova ma'lumotlari
  //      orasida yotardi — yangi himoya siyosatiga zid.
  //
  // Kerak bo'lganda xabarlar faqat ISHLAB CHIQISH (debug) rejimida
  // konsolga chiqadi; release APK'da bu chaqiruvlar butunlay yo'qoladi
  // (assert bloki kompilyatsiyada olib tashlanadi).
  static void log(String msg) {
    assert(() {
      debugPrint('[video-cache] $msg');
      return true;
    }());
  }

  // Berilgan asl (masofaviy) URL o'rniga video_player'ga beriladigan
  // mahalliy proksi URL'ini qaytaradi. Serverni kerak bo'lsa ishga
  // tushiradi (lazy — ilova ochilganda emas, birinchi video o'ynatilganda).
  //
  // MUHIM: 5 soniyalik timeout bilan himoyalangan — kutilmagan holatda
  // Rust tomoni javob bermasa ham, chaqiruvchi (video_player_screen.dart)
  // buni ushlab, ASL (kesh'siz) URL bilan to'g'ridan-to'g'ri o'ynatishga
  // qaytadi.
  /// Serverni ILOVA OCHILISHIDA ishga tushiradi.
  ///
  /// NEGA KERAK: avval server faqat BIRINCHI VIDEO OCHILGANDA ishga
  /// tushardi. Natijada foydalanuvchi videoni ochmasdan turib "yuklab
  /// olish"ni bossa, Rust yadrosidagi kesh tizimi hali umuman
  /// yo'q edi — tugma bosilardi-yu, hech narsa bo'lmasdi.
  /// Ishga tushirish arzon: bitta mahalliy port ochiladi va bitta
  /// native ish oqimi boshlanadi (tarmoqqa chiqilmaydi).
  Future<void> ensureStarted() async {
    try {
      await _ensureStarted().timeout(const Duration(seconds: 5));
    } catch (e) {
      log('Kesh-serverni oldindan ishga tushirib bo\'lmadi: $e');
    }
  }

  Future<Uri> proxyUri(String originalUrl) async {
    log('proxyUri chaqirildi: ${_shortUrl(originalUrl)}');
    final port = await _ensureStarted().timeout(const Duration(seconds: 5));
    return Uri.parse(
        'http://127.0.0.1:$port/v?u=${Uri.encodeQueryComponent(originalUrl)}');
  }

  /// TOMOSHA TARIXI UCHUN KADR MANZILI.
  ///
  /// Rust yadrosi bu manzilda faylning faqat KERAKLI baytlarini
  /// (`moov` + bitta kalit kadr) olib, bitta kadrlik MP4 yasab
  /// beradi. Android'ning kadr ajratuvchisi shundan JPEG chiqaradi.
  ///
  /// Oddiy ijro manzilidan (`/v`) BUTUNLAY alohida: `/v` hech
  /// qachon tarmoqqa chiqmaydi, bu esa chiqishi mumkin — lekin
  /// atigi bir necha yuz kilobayt oladi va hech narsani diskka
  /// yozmaydi.
  ///
  /// [exact] `false` bo'lsa — faqat eng yaqin KALIT KADR (bitta
  /// kichik o'qish). Ko'rish davomidagi oldindan tayyorlash shuni
  /// ishlatadi: aniq kadr uchun kalit kadrdan to'xtagan joygacha
  /// bo'lgan oraliq (8 MB gacha) olinadi va u ijro bilan kanalni
  /// bo'lishib, pleyerni sekinlashtirardi.
  Future<Uri> thumbUri(String originalUrl, int positionMs,
      {bool exact = true}) async {
    final port = await _ensureStarted().timeout(const Duration(seconds: 5));
    final u = Uri.encodeQueryComponent(originalUrl);
    final tail = exact ? '' : '&exact=0';
    return Uri.parse('http://127.0.0.1:$port/thumb?u=$u&ms=$positionMs$tail');
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
    log('Rust video-kesh serveri ishga tushirilmoqda...');
    try {
      final port = await RustCore.instance.startVideoCache();
      _port = port;
      log('Rust video-kesh serveri tayyor: 127.0.0.1:$port');
      if (!completer.isCompleted) completer.complete(port);
    } catch (e) {
      log('XATO: Rust video-kesh serveri ishga tushmadi — $e');
      if (!completer.isCompleted) completer.completeError(e);
    } finally {
      _starting = null;
    }
  }

  static String _shortUrl(String url) =>
      url.length > 70 ? '...${url.substring(url.length - 70)}' : url;
}
