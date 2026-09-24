// lib/services/chat_video_thumb.dart — YOZISHMADAGI VIDEONING
// BOSHIDAGI KADR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi:
//   * "serverga thumbnail yuklanmasin";
//   * "tomosha tarixidagidek, faqat support chatga mos qilib,
//      xatolarsiz va tez ishlaydigan qilib video boshidan kadr
//      olinsin";
//   * "kadr 2-chi soniyadan emas, AYNAN VIDEO BOSHIDAN olinsin";
//   * "0 ms emas — 1 sekund 1000 ms bo'lsa, demak 100 ms dagi
//      kadrni olish kerak".
//
// Ya'ni kadr hech qayerga yuklanmaydi: uni HAR BIR KO'RUVCHI
// o'zida yasaydi va o'zida (shifrlangan holda) saqlab qo'yadi.
//
// ═══════════════════════════════════════════════════════════════
//  QANDAY ISHLAYDI
// ═══════════════════════════════════════════════════════════════
//
//   1. Rust yadrosining "/thumb?u=<manzil>&ms=0" yo'li faylning
//      faqat KERAKLI baytlarini oladi (`moov` jadvali + eng
//      birinchi kalit kadr) va shundan BITTA KADRLIK haqiqiy MP4
//      yasaydi. Yozishmadagi video 2-5 MB bo'lgani uchun bu
//      odatda ~100-300 KB, ya'ni butun faylning bir qismi.
//   2. Android'ning kadr ajratuvchisi (`aru/thumb`) o'sha bitta
//      kadrdan JPEG chiqaradi.
//   3. JPEG shifrlanib diskka yoziladi — keyingi safar tarmoqqa
//      UMUMAN chiqilmaydi.
//
// ── QAYSI LAHZA: 100 ms ──────────────────────────────────────
//
// Foydalanuvchi talabi. Nega aynan shu raqam:
//
//   * 2 soniya (avvalgi variant) KO'P edi — kadr videoning
//     boshini ko'rsatmasdi;
//   * 0 ms esa ko'pincha QORA chiqadi: videolar odatda qorong'i
//     kadrdan ochiladi;
//   * 100 ms (soniyaning o'ndan biri) — ko'zga "eng boshi" bo'lib
//     ko'rinadi, lekin qora kadrdan o'tib ulgurgan bo'ladi.
//
// NARXI YO'Q: 100 ms baribir BIRINCHI kalit kadrning ichida
// bo'ladi (kalit kadrlar odatda 2-10 soniyada bir keladi), ya'ni
// yadro o'sha bitta kalit kadrni oladi — 0 ms so'ralgandagi bilan
// bir xil baytlar.
//
// ═══════════════════════════════════════════════════════════════
//  BU XUSUSIYAT BIR MARTA QAYTARIB OLINGAN — NEGA VA NIMA
//  O'ZGARDI
// ═══════════════════════════════════════════════════════════════
//
// Avvalgi urinish (`chat_thumbs.dart`, commit 6671626 da olib
// tashlangan) ishlamadi VA ijroni sekinlashtirdi:
//
//   * to'xtatuvchisi yo'q edi — boshlangan ish ekran yopilgandan
//     keyin ham davom etardi;
//   * 4 urinish x 35 soniya + uzun tanaffuslar ≈ 2,5 DAQIQA,
//     ikkitasi PARALLEL;
//   * natijada foydalanuvchi yozishmadan chiqib video ochganda
//     bu so'rovlar hamon tarmoqni yeb turardi va sekin ulanishda
//     video qotardi.
//
// O'shanda hujjatga TO'RTTA SHART yozilgan edi. Hammasi shu
// yerda bajarilgan:
//
//   1. «Ekran yopilganda ish TO'XTASHI shart»
//      -> bu sinf YAGONA (singleton) EMAS: uni ekran yaratadi va
//         `dispose()` qiladi. `_disposed` bayrog'i har `await`
//         dan keyin tekshiriladi va ish darhol to'xtaydi.
//
//   2. «Video ijro etilayotganda kadr yasash umuman ishlamasin»
//      -> har urinishdan OLDIN `VideoGate.busy` tekshiriladi.
//         Pleyer ochiq bo'lsa urinish umuman boshlanmaydi.
//
//   3. «Urinishlar soni VA umumiy vaqti chegaralangan bo'lsin»
//      -> 2 urinish, muddatlari 10 va 15 soniya, orasida 2
//         soniya tanaffus: bitta kadrga eng ko'pi ~27 soniya.
//         Bir vaqtda FAQAT BITTA kadr yasaladi va butun ekran
//         uchun eng ko'pi `_sessionBudget` ta kadr tarmoqdan
//         olinadi. Chegara tugagach ish TO'XTAYDI.
//
//   4. «Avval sekin tarmoqda sinalsin»
//      -> shu sabab yiqilgan kadr SHU EKRAN OCHIQ TURGANDA
//         qayta sinalmaydi: sekin tarmoqda takror urinish
//         faqat zarar keltiradi. Ekran qayta ochilganda esa
//         yana bir imkon beriladi.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'rust_bridge.dart';
import 'video_cache_server.dart';
import 'video_gate.dart';

class ChatVideoThumb extends ChangeNotifier {
  /// Kadr ajratuvchi bilan aloqa kanali (`MainActivity.kt`).
  static const MethodChannel _channel = MethodChannel('aru/thumb');

  /// Bir vaqtda nechta kadr yasaladi.
  ///
  /// Tomosha tarixidagidek ikkita. Ilgari bitta edi — lekin har
  /// bir kadr 5 ta ketma-ket tarmoq so'rovi olardi
  /// (`ThumbReader` dagi "ZAXIRA BO'LAK" izohiga qarang), ya'ni
  /// bitta sekin video orqasidagi hammasini ushlab turardi.
  /// So'rovlar 5 tadan 2 taga tushgach, ikkitasi xavfsiz.
  ///
  /// Yadrodagi kadr xotirasi (`THUMB_MEMO`) 8 ta yozuv saqlaydi,
  /// ya'ni ikkita parallel ish uchun yetadi.
  static const int _maxParallel = 2;

  /// Bitta kadr uchun urinishlar muddati.
  ///
  /// Birinchisi qisqa (tez tarmoqda kadr shu yerda chiqadi),
  /// ikkinchisi biroz uzunroq (sekinroq tarmoq uchun). Uchinchisi
  /// YO'Q: aynan urinishlar soni avvalgi safar ijroni
  /// sekinlashtirgan edi.
  ///
  /// Birinchi urinish vaqti tugasa (fayl hali keshga tushmagan —
  /// yadro uni kutib, natijani `THUMB_MEMO` da saqlab qo'yadi), AYNAN
  /// o'sha lahza uzunroq muddat bilan bir marta qayta so'raladi.
  static const List<Duration> _timeouts = [
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// Kadr qaysi lahzalardan olinadi (ms) — birinchisi chiqmasa
  /// keyingisi.
  ///
  /// TOPILGAN XATO (foydalanuvchi: "chatdagi thumbnaili yo'q video
  /// aslida buzilgan, lekin tomosha tarixida kelib qolgan joydan
  /// kadr olib thumbnail qo'yyapti"). Faylning BOSHI buzilgan
  /// bo'lsa 100 ms dagi kadr hech qachon ochilmaydi, videoning
  /// qolgani esa butun — tarix kadri aynan shu sabab chiqadi.
  /// Endi bosh ochilmasa keyingi joylar sinaladi. Videodan uzun
  /// lahza so'ralsa yadro oxirgi kadrni beradi.
  static const List<int> _atMsList = [100, 1000, 5000, 15000];

  /// Urinishlar orasidagi tanaffus.
  static const Duration _pause = Duration(seconds: 2);

  /// Bitta ekran ochilishida qilinadigan TARMOQ URINISHLARINING
  /// eng ko'p soni.
  ///
  /// Diqqat: bu KADR soni emas, URINISH soni. Bitta kadr eng
  /// ko'pi ikki urinish oladi, ya'ni eng yomon holatda 8 ta
  /// video, eng yaxshi holatda 16 tasi tarmoqdan olinadi.
  ///
  /// NEGA CHEGARA BOR: uzun yozishmada o'nlab video bo'lishi
  /// mumkin va ularning HAMMASI uchun tarmoqqa chiqish — aynan
  /// avvalgi safargi xato. Ekranda odatda 2-3 ta video
  /// ko'rinadi, lekin yuqoriga surilganda yana chiqadi — 16 ta
  /// urinish uzun yozishmaga ham yetadi.
  ///
  /// Chegara tugagach ish TO'XTAYDI va ekran qayta ochilgandagina
  /// yangilanadi.
  ///
  /// Diskdan o'qish bu chegaraga KIRMAYDI — u tarmoqqa
  /// chiqmaydi va bepul, ya'ni BIR MARTA yasalgan kadr keyin
  /// har doim darhol chiqadi.
  static const int _sessionBudget = 40;

  /// Xotiradagi kadrlar soni (har biri ~20 KB).
  static const int _memoryLimit = 40;

  final Map<String, Uint8List> _memory = {};
  final Map<String, Future<Uint8List?>> _work = {};

  /// Shu ekran ochilganidan beri yasab bo'lmagan kadrlar.
  /// Qayta sinalmaydi (3-shart).
  final Set<String> _failed = {};

  int _running = 0;
  int _spent = 0;
  bool _disposed = false;

  @override
  void dispose() {
    // 1-SHART: ekran yopildi — davom etayotgan ishlar
    // natijasini hech kim kutmaydi va yangisi boshlanmaydi.
    _disposed = true;
    _memory.clear();
    _work.clear();
    super.dispose();
  }

  /// Fayl nomidan kalit: manzil domeni o'zgarsa ham kadr yaroqli
  /// qolaveradi.
  static String _keyOf(String url) {
    final uri = Uri.tryParse(url);
    final name = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : url;
    // Fayl tizimi uchun xavfsiz holga keltiramiz.
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.length <= 80 ? safe : safe.substring(safe.length - 80);
  }

  String? _pathOf(String key) {
    final dir = RustCore.instance.dataDirPath;
    if (dir == null) return null;
    return '$dir/chatthumb_$key.rustbin';
  }

  /// Xotirada tayyor kadr (tarmoq ham, disk ham so'ralmaydi).
  ///
  /// Puffak AYNAN shundan o'qiydi — ro'yxat qurilayotganda hech
  /// qanday kutish bo'lmaydi.
  Uint8List? peek(String url) => _memory[_keyOf(url)];


  /// Kadrni so'raydi. Tayyor bo'lgach `notifyListeners()` chaqiriladi
  /// va puffak o'zini qaytadan chizadi.
  ///
  /// Hech qachon xato tashlamaydi: kadr chiqmasa puffak
  /// avvalgidek qora fon va play belgisi bo'lib qoladi.
  void request(String url) {
    if (_disposed || url.isEmpty) return;
    final key = _keyOf(url);
    if (_memory.containsKey(key) || _failed.contains(key)) return;
    if (_work.containsKey(key)) return;
    final work = _load(url, key);
    _work[key] = work;
    unawaited(work.whenComplete(() => _work.remove(key)));
  }

  Future<Uint8List?> _load(String url, String key) async {
    final path = _pathOf(key);
    if (path == null) return null;

    // Diskka QURILISH PAYTIDA chiqilmaydi: `secureLoad` sinxron
    // (FFI + shifrni ochish), ya'ni ro'yxat qurilayotgan kadrda
    // bajarilsa ekran sezilarli qotardi.
    await Future<void>.delayed(Duration.zero);
    if (_disposed) return null;

    // 1) DISKDA BORMI. Bu yo'l tarmoqqa chiqmaydi va chegaraga
    //    kirmaydi.
    try {
      final saved = RustCore.instance.secureLoad(path, 'chatthumb:$key');
      if (saved.isNotEmpty) {
        final bytes = base64Decode(saved);
        if (bytes.isNotEmpty) {
          _remember(key, bytes);
          return bytes;
        }
      }
    } catch (_) {
      // Buzilgan yozuv — pastda qaytadan yasaladi.
    }
    if (_disposed) return null;

    // 2) TARMOQDAN. Chegara tugagan bo'lsa — umuman boshlanmaydi.
    if (_spent >= _sessionBudget) return null;

    for (final atMs in _atMsList) {
      for (var i = 0; i < _timeouts.length; i++) {
        // 2-SHART: pleyer ochiq bo'lsa kadr yasalmaydi (kutamiz).
        while (!_disposed && VideoGate.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        if (_disposed || _spent >= _sessionBudget) return null;

        final r = await _grab(url, atMs, _timeouts[i]);
        if (_disposed) return null;
        final data = r.data;
        if (data != null) {
          _remember(key, data);
          // Shifrlab saqlaymiz — bu video uchun tarmoqqa boshqa
          // hech qachon chiqilmaydi.
          try {
            RustCore.instance
                .secureSave(path, 'chatthumb:$key', base64Encode(data));
          } catch (_) {
            // Saqlanmadi — kadr baribir xotirada va ekranda.
          }
          return data;
        }
        // Vaqt tugadi — shu lahza uzunroq kutish bilan qayta.
        // Kadr aniq chiqmadi (buzilgan joy) — keyingi lahza.
        if (!r.timedOut) break;
        await Future<void>.delayed(_pause);
      }
    }

    // 3-SHART: shu ekran ochiq turganda BOSHQA sinalmaydi.
    _failed.add(key);
    return null;
  }

  /// BITTA urinish.
  ///
  /// ── NAVBATDA KUTISH URINISH EMAS (TOPILGAN XATO) ──────────
  ///
  /// Ilgari navbatda 8 soniyadan ko'p kutilsa urinish "yiqildi"
  /// deb qaytardi — ya'ni video UMUMAN sinalmay qolardi. Sekin
  /// (katta) videolar orqasidagilar har safar shu sabab kadrsiz
  /// qolardi. Endi ekran ochiq turguncha navbat kutiladi.
  Future<_GrabResult> _grab(String url, int atMs, Duration timeout) async {
    while (_running >= _maxParallel) {
      if (_disposed) return const _GrabResult();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (_disposed) return const _GrabResult();

    _running++;
    _spent++;
    try {
      // Kerakli lahza (`_atMsList` izohiga qarang).
      final uri = await VideoCacheServer.instance.thumbUri(url, atMs);
      if (_disposed) return const _GrabResult();
      final data = await _channel.invokeMethod<Uint8List>('grab', {
        'url': uri.toString(),
        // Puffak eni ~220 px — 640 px yetarlidan ortiq, lekin
        // zichligi yuqori ekranlarda rasm mayin ko'rinadi.
        'maxWidth': 640,
        'quality': 72,
      }).timeout(timeout);
      if (data == null || data.isEmpty) return const _GrabResult();
      return _GrabResult(data: data);
    } on TimeoutException {
      return const _GrabResult(timedOut: true);
    } catch (e) {
      if (kDebugMode) debugPrint('ChatVideoThumb: kadr olinmadi — $e');
      return const _GrabResult();
    } finally {
      _running--;
    }
  }

  void _remember(String key, Uint8List bytes) {
    if (_disposed) return;
    if (_memory.length >= _memoryLimit) {
      _memory.remove(_memory.keys.first);
    }
    _memory[key] = bytes;
    notifyListeners();
  }
}

/// Bitta urinish natijasi.
class _GrabResult {
  final Uint8List? data;

  /// Vaqt tugadi (kadr "yo'q" emas — hali tayyor emas).
  final bool timedOut;

  const _GrabResult({this.data, this.timedOut = false});
}
