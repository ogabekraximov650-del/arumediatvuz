// lib/services/chat_thumbs.dart — YOZISHMADAGI VIDEO UCHUN KADR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "support chatda yuborilgan videoga thumbnail
// qo'ysa bo'ladimi, huddi tomosha tarixidagidek — faqat boshidagi
// kadrni o'zi avtomatik qirqib oladi va thumbnailni diskka
// saqlaydi".
//
// Ilgari yozishmadagi video QORA to'rtburchak bo'lib turardi,
// o'rtasida play belgisi. Qaysi video ekanini ochmasdan bilib
// bo'lmasdi.
//
// ═══════════════════════════════════════════════════════════════
//  QANDAY ISHLAYDI
// ═══════════════════════════════════════════════════════════════
//
// Mexanizm TOMOSHA TARIXI bilan AYNAN BIR XIL (`watch_history.dart`
// dagi "TO'XTAGAN JOYDAGI KADR" bo'limiga qarang):
//
//   1. Rust yadrosidagi "/thumb" yo'li faylning faqat KERAKLI
//      baytlarini oladi — `moov` atomi (0,2-0,8 MB) va bitta kalit
//      kadr (50-300 KB) — va shulardan bitta kadrlik MP4 yasaydi.
//      Ya'ni 50 MB'lik video uchun ham bir necha yuz kilobayt
//      yuklanadi, butun fayl EMAS.
//   2. Android'ning kadr ajratuvchisi (`MainActivity.kt` dagi
//      `aru/thumb` kanali) shu bo'lakdan JPEG chiqaradi.
//   3. JPEG diskda SHIFRLANGAN holda saqlanadi (`secureSave`) —
//      ilovaga tegishli barcha fayllar shifrlanadi degan qoida bu
//      rasmlar uchun ham amal qiladi.
//
// Farqi ikkitagina:
//
//   * vaqt — 2 SONIYA (tarixda "to'xtagan joy"). Yozishmadagi
//     videoda to'xtagan joy degan tushuncha yo'q, eng boshidagi
//     kadr esa ko'pincha qora bo'ladi (`_attemptMs` izohiga
//     qarang);
//   * kalit xabarning FAYL NOMIDAN quriladi (`chat_<vaqt>_<id>`),
//     ya'ni bitta video uchun kadr BIR MARTA yasaladi va keyin
//     abadiy diskdan o'qiladi.
//
// ── NEGA ALOHIDA SINF (WATCH_HISTORY'GA QO'SHILMADI) ─────────
//
// `WatchHistory` — tomosha tarixining O'ZI: u ro'yxatni serverdan
// oladi, saralaydi, `HistoryItem` bilan ishlaydi. Yozishmadagi
// videoning na tarixi, na animesi, na epizodi bor — unga faqat
// "manzil -> kadr" kerak. Kadr mantiqini o'sha sinfga tiqish
// ikkala vazifani ham chalkashtirardi.
//
// ── NEGA `nativeMediaUrl` ISHLATILMAYDI ──────────────────────
//
// Manzil MAHALLIY serverga (127.0.0.1) beriladi, worker'ga emas.
// Tarmoqqa Rust yadrosining O'ZI chiqadi va o'z so'roviga
// `X-App-Sig` sarlavhasini qo'yadi (`video_cache.rs` -> `signed`).
// Ya'ni manzilga token kerak emas.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'rust_bridge.dart';
import 'video_cache_server.dart';

class ChatThumbs extends ChangeNotifier {
  ChatThumbs._();

  static final ChatThumbs instance = ChatThumbs._();

  /// Kadr ajratuvchi bilan aloqa kanali (`MainActivity.kt`).
  static const MethodChannel _channel = MethodChannel('aru/thumb');

  /// Bir vaqtda shuncha kadr yasaladi — yozishma sirg'alayotganda
  /// tarmoq ham, protsessor ham bo'g'ilib qolmasin.
  static const int _maxParallel = 2;

  // ── URINISHLAR: QAYSI LAHZADAN ────────────────────────────
  //
  // TOPILGAN XATO (foydalanuvchi, skrinshot bilan): uchta videodan
  // faqat bittasida kadr chiqdi.
  //
  // TALAB (foydalanuvchi): "1-chi soniyada qora rang bo'lishi
  // mumkin, shuning uchun 2-chi sonidagi kadr thumbnail qilib
  // qo'yilgani yaxshi".
  //
  // Bu TO'G'RI kuzatuv: videolar ko'pincha qorong'idan ochiladi
  // yoki birinchi kadri logotip/bo'sh bo'ladi. Shu sabab asosiy
  // lahza — 2 SONIYA.
  //
  // Har urinish boshqa lahzadan so'raydi:
  //
  //   1-urinish — 2 s.   ASOSIY: tasvir ma'noli bo'ladi.
  //   2-urinish — 0 ms.  ZAXIRA: video 2 soniyadan qisqa bo'lsa
  //                      yoki 2 s dagi urinish uzilsa. Eng arzon
  //                      yo'l — kerakli kalit kadr faylning eng
  //                      boshida.
  //   3-urinish — 4 s.
  //
  // ── NARXI HAQIDA ROSTINI AYTISH ───────────────────────────
  //
  // Kech lahza bir oz QIMMATROQ: Rust yadrosi oldingi kalit
  // kadrdan so'ralgan kadrgacha bo'lgan hamma namunani o'qiydi
  // (`build_thumb_clip`), 0 ms da esa atigi bittasini.
  //
  // Lekin farq KICHIK: so'rovning asosiy og'irligi `moov` atomi
  // (0,2-0,8 MB), qo'shimcha namunalar esa P-kadrlar, ya'ni har
  // biri bir necha kilobayt. Ma'noli rasm shunga arziydi.
  //
  // Video 2 soniyadan qisqa bo'lsa ham muammo yo'q: yadro
  // so'ralgan lahzani faylning oxirgi kadriga qisqartiradi
  // (`sample_at_ms` — `min(sample_count)`), ya'ni oxirgi kadr
  // olinadi.
  static const List<int> _attemptMs = [2000, 0, 4000];

  /// Urinishlar orasidagi tanaffus.
  ///
  /// Ilgari 600 ms va 1200 ms edi — sekin tarmoq uchun juda tez:
  /// uchala urinish ikki soniyada tugab, kadr "yasalmadi" deb
  /// belgilanardi.
  static const List<Duration> _pause = [
    Duration(milliseconds: 1500),
    Duration(seconds: 4),
  ];

  /// Yasalmagan kadr shuncha vaqtdan keyin QAYTA sinaladi.
  ///
  /// TOPILGAN XATO: ilgari yasalmagan kadr `_failed` ro'yxatiga
  /// tushardi va shu seansda BOSHQA HECH QACHON so'ralmasdi.
  /// Ya'ni internet bir lahza uzilgan bo'lsa ham, puffak ilova
  /// yopilguncha bo'sh qolardi — aynan skrinshotdagi holat.
  ///
  /// Endi u shunchaki SOVIYDI: bir daqiqadan keyin (yoki ekran
  /// qayta ochilganda, o'sha muddat o'tgan bo'lsa) yana sinaladi.
  static const Duration _cooldown = Duration(seconds: 60);

  /// Xotiradagi kadrlar soni cheklangan: yozishma uzun bo'lsa ham
  /// ilova o'nlab megabaytni ushlab turmasin (har biri ~20 KB).
  static const int _memoryLimit = 40;

  final Map<String, Uint8List> _memory = {};
  final Map<String, Future<Uint8List?>> _work = {};

  /// Yasab bo'lmagan kadrlar: kalit -> qachondan keyin qayta
  /// sinash mumkin (`_cooldown`). Bu ro'yxat har qator
  /// qurilganda bekorga tarmoqqa chiqishni to'xtatadi, lekin
  /// butunlay taslim ham bo'lmaydi.
  final Map<String, DateTime> _retryAfter = {};

  int _running = 0;

  /// Fayl nomidan kalit. Manzil domeni o'zgarsa ham kalit o'sha
  /// bo'lib qoladi — eski kadrlar yaroqli qolaveradi.
  static String _keyOf(String url) {
    final uri = Uri.tryParse(url);
    final name = (uri?.pathSegments.isNotEmpty ?? false)
        ? uri!.pathSegments.last
        : url;
    // Fayl tizimi uchun xavfsiz holga keltiramiz.
    return name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  String? _pathOf(String key) {
    final dir = RustCore.instance.dataDirPath;
    if (dir == null) return null;
    return '$dir/chatthumb_$key.rustbin';
  }

  /// Xotirada tayyor kadr bormi (kutmasdan).
  ///
  /// Puffak shu orqali chiziladi: kadr tayyor bo'lishi bilan
  /// `notifyListeners` chaqiriladi va puffak o'sha zahoti rasmni
  /// oladi.
  Uint8List? peek(String url) => _memory[_keyOf(url)];

  void _remember(String key, Uint8List bytes) {
    if (_memory.length >= _memoryLimit) {
      _memory.remove(_memory.keys.first);
    }
    _memory[key] = bytes;
  }

  /// Kadrni tayyorlaydi: avval xotiradan, keyin diskdan, bo'lmasa
  /// yasaydi. Hech qanday holatda xato tashlamaydi — kadr
  /// bo'lmasa puffak avvalgidek qora fon bo'lib qolaveradi.
  Future<Uint8List?> ensure(String url) {
    if (url.isEmpty) return Future.value(null);
    final key = _keyOf(url);

    final ready = _memory[key];
    if (ready != null) return Future.value(ready);
    // Yaqinda urinib ko'rilgan va bo'lmagan — hali sovimagan.
    final after = _retryAfter[key];
    if (after != null && DateTime.now().isBefore(after)) {
      return Future.value(null);
    }

    final running = _work[key];
    if (running != null) return running;

    final work = _load(url, key);
    _work[key] = work;
    return work.whenComplete(() => _work.remove(key));
  }

  Future<Uint8List?> _load(String url, String key) async {
    final path = _pathOf(key);
    if (path == null) return null;

    // Diskka QURILISH PAYTIDA chiqilmaydi: `secureLoad` sinxron
    // (FFI + shifr ochish), ya'ni ro'yxat qurilayotgan kadrda
    // bajarilsa ekran sezilarli qotardi.
    await Future<void>.delayed(Duration.zero);

    // 1) Diskda bormi?
    try {
      final saved = RustCore.instance.secureLoad(path, 'chatthumb:$key');
      if (saved.isNotEmpty) {
        final bytes = base64Decode(saved);
        _remember(key, bytes);
        notifyListeners();
        return bytes;
      }
    } catch (_) {
      // Buzilgan yozuv — qaytadan yasaymiz.
    }

    // 2) Yo'q — yasaymiz. Har urinish boshqa lahzadan
    //    (`_attemptMs` izohiga qarang).
    for (var i = 0; i < _attemptMs.length; i++) {
      final data = await _grab(url, _attemptMs[i]);
      if (data != null) {
        _remember(key, data);
        _retryAfter.remove(key);
        notifyListeners();
        // Shifrlab saqlaymiz — keyingi safar tarmoqqa umuman
        // chiqilmaydi.
        try {
          RustCore.instance
              .secureSave(path, 'chatthumb:$key', base64Encode(data));
        } catch (_) {
          // Saqlanmadi — kadr baribir xotirada, ekranda ko'rinadi.
        }
        return data;
      }
      if (i < _pause.length) await Future<void>.delayed(_pause[i]);
    }

    // Hech biri bo'lmadi — bir muddat tinch qo'yamiz va KEYIN
    // yana sinaymiz (butunlay taslim BO'LMAYMIZ).
    _retryAfter[key] = DateTime.now().add(_cooldown);
    return null;
  }

  /// BITTA urinish: mahalliy serverdan kadr olib, JPEG qaytaradi.
  ///
  /// Navbat AYNAN shu yerda: urinishlar orasidagi tanaffusda navbat
  /// BAND QILINMAYDI — aks holda bitta muvaffaqiyatsiz kadr qolgan
  /// puffaklarni ushlab turardi.
  Future<Uint8List?> _grab(String url, int atMs) async {
    while (_running >= _maxParallel) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    _running++;
    try {
      // Qaysi lahza — `_attemptMs` izohiga qarang (asosiysi 2 s).
      final uri = await VideoCacheServer.instance.thumbUri(url, atMs);
      final data = await _channel.invokeMethod<Uint8List>('grab', {
        'url': uri.toString(),
        // Puffak eni 220 px atrofida — 640 px yetarlidan ham ortiq,
        // lekin ekran zichligi yuqori telefonlarda rasm mayin
        // ko'rinadi.
        'maxWidth': 640,
        'quality': 72,
        // 25 -> 35 soniya: skrinshotdagi tarmoq 6,3 KB/s edi, ya'ni
        // 25 soniyada atigi ~160 KB ulguradi — `moov` atomi
        // (0,2-0,8 MB) uchun yetmaydi va urinish kadr kelmasdan
        // uzilardi.
      }).timeout(const Duration(seconds: 35));
      if (data == null || data.isEmpty) return null;
      return data;
    } catch (e) {
      // Urinish uzildi — yuqorida yana bir marta sinaladi.
      if (kDebugMode) {
        debugPrint('ChatThumbs: kadr olinmadi (ms=$atMs) — $e');
      }
      return null;
    } finally {
      _running--;
    }
  }
}
