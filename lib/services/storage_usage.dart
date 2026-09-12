// lib/services/storage_usage.dart — ILOVA QANCHA JOY EGALLAGAN.
//
// ═══════════════════════════════════════════════════════════════
//  NIMA UCHUN
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): profil sahifasidagi shaxsiy statistika
// ostida eniga cho'zilgan oyna bo'lsin —
//
//   * o'ng yuqorida ilovadagi VIDEOLAR va RASMLAR hajmi, tagida
//     supurgili "Tozalash" tugmasi;
//   * chapda ikkita progress chizig'i: birinchisi shu hajmning
//     ichida video necha foiz, rasm necha foiz; ikkinchisi
//     telefonning JAMI xotirasidan necha foizi ishlatilgani.
//
// ═══════════════════════════════════════════════════════════════
//  QAYERDA NIMA YOTADI
// ═══════════════════════════════════════════════════════════════
//
// | Nima            | Qayerda                                   |
// |-----------------|-------------------------------------------|
// | Videolar        | `<support>/video_byte_cache` (Rust yadrosi)|
// | Posterlar       | `<temp>/libCachedImageData`               |
// | Tarix kadrlari  | `<hujjatlar>/accountid_*/thumb_*.rustbin` |
//
// ── TOZALASHDA NIMA O'CHADI ───────────────────────────────────
//
// TALAB (foydalanuvchi): "faqat tarixdagi kadr rasmlariga
// tegilmasin".
//
// Ya'ni videolar va posterlar keshi o'chiriladi, TARIX KADRLARI
// esa joyida qoladi — tomosha tarixi oflaynda ham rasmli
// ko'rinishi kerak, va ularni qaytadan yasab bo'lmaydi (video
// o'chib ketgan bo'lishi mumkin).
//
// ── HISOB FON OQIMIDA ─────────────────────────────────────────
//
// Papkani sanash — mingga yaqin fayl statistikasi, ya'ni UI
// oqimida qilinsa ekran qotadi. Shu sabab hisob `Isolate.run`
// ichida bajariladi va faqat natija (uchta son) qaytadi.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'rust_bridge.dart';

/// Bitta o'lchov natijasi.
@immutable
class StorageUsage {
  /// Yuklab olingan video bo'laklari (bayt).
  final int videoBytes;

  /// Posterlar keshi + tomosha tarixi kadrlari (bayt).
  final int imageBytes;

  /// Telefon xotirasining JAMI hajmi (bayt). 0 — o'qib bo'lmadi.
  final int deviceTotal;

  /// Telefon xotirasida BO'SH joy (bayt).
  final int deviceFree;

  const StorageUsage({
    this.videoBytes = 0,
    this.imageBytes = 0,
    this.deviceTotal = 0,
    this.deviceFree = 0,
  });

  int get totalBytes => videoBytes + imageBytes;

  /// Ilova egallagan joyning ichida video ulushi (0..1).
  double get videoShare => totalBytes > 0 ? videoBytes / totalBytes : 0;

  /// Ilova egallagan joyning ichida rasm ulushi (0..1).
  double get imageShare => totalBytes > 0 ? imageBytes / totalBytes : 0;

  /// Telefon xotirasining necha ulushi BAND (0..1).
  ///
  /// Ilovaning o'z hajmi emas — telefonda umuman qancha joy
  /// ishlatilgani (foydalanuvchi talabi: "telefonning jami
  /// xotirasidan 0.00% necha foizidan foydalanayotgani").
  double get deviceShare {
    if (deviceTotal <= 0) return 0;
    final used = deviceTotal - deviceFree;
    if (used <= 0) return 0;
    return (used / deviceTotal).clamp(0.0, 1.0);
  }
}

class StorageUsageService extends ChangeNotifier {
  StorageUsageService._();
  static final StorageUsageService instance = StorageUsageService._();

  static const MethodChannel _channel = MethodChannel('aru/storage');

  StorageUsage _usage = const StorageUsage();
  StorageUsage get usage => _usage;

  bool _busy = false;
  bool get isBusy => _busy;

  /// Hech bo'lmaganda bir marta o'lchandimi.
  bool measured = false;

  /// Hajmlarni qaytadan sanaydi.
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      final video = await _videoDir();
      final posters = await _posterDir();
      final thumbs = RustCore.instance.dataDirPath;

      // Papkalarni sanash — alohida izolyatda (UI qotmasin).
      final sizes = await Isolate.run(() => _measure([
            if (video != null) video,
            if (posters != null) posters,
          ]));
      final thumbSize = thumbs == null
          ? 0
          : await Isolate.run(() => _measureThumbs(thumbs));

      final disk = await _disk();
      _usage = StorageUsage(
        videoBytes: video == null ? 0 : (sizes[video] ?? 0),
        imageBytes:
            (posters == null ? 0 : (sizes[posters] ?? 0)) + thumbSize,
        deviceTotal: disk.$1,
        deviceFree: disk.$2,
      );
      measured = true;
    } catch (e) {
      debugPrint('Xotira hajmi o\'lchanmadi: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Videolar va posterlar keshini o'chiradi.
  ///
  /// TARIX KADRLARIGA TEGILMAYDI (foydalanuvchi talabi).
  Future<void> clear() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      // 1) Videolar — Rust yadrosi o'zi tozalaydi (ochiq fayllarni
      //    ham to'g'ri yopadi).
      RustCore.instance.videoCacheWipe();
      // 2) Posterlar keshi — kesh boshqaruvchisining O'Z vositasi
      //    bilan. Papkani qo'lda o'chirish xavfli: kesh
      //    yozuvlari alohida bazada turadi va fayllar yo'q
      //    bo'lsa ham "rasm bor" deb ko'rsatilaverardi.
      await DefaultCacheManager().emptyCache();
    } catch (e) {
      debugPrint('Tozalashda xato: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
    await refresh();
  }

  // ── Papkalar ────────────────────────────────────────────────

  Future<String?> _videoDir() async {
    try {
      final support = await getApplicationSupportDirectory();
      return '${support.path}/video_byte_cache';
    } catch (_) {
      return null;
    }
  }

  Future<String?> _posterDir() async {
    try {
      final tmp = await getTemporaryDirectory();
      return '${tmp.path}/libCachedImageData';
    } catch (_) {
      return null;
    }
  }

  /// Telefon xotirasi: (jami, bo'sh).
  Future<(int, int)> _disk() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('disk');
      if (m == null) return (0, 0);
      final total = (m['total'] as num?)?.toInt() ?? 0;
      final free = (m['free'] as num?)?.toInt() ?? 0;
      return (total, free);
    } catch (_) {
      // Android bo'lmagan tizim yoki kanal yo'q — foiz
      // ko'rsatilmaydi, xato chiqmaydi.
      return (0, 0);
    }
  }
}

// ── IZOLYATDA BAJARILADIGAN ISH ───────────────────────────────
//
// Bu funksiyalar sinf ichida EMAS: `Isolate.run` ga beriladigan
// yopilma faqat oddiy ma'lumotni ushlashi kerak (obyekt ushlasa
// "Illegal argument in isolate message" xatosi chiqadi).

Map<String, int> _measure(List<String> dirs) {
  final out = <String, int>{};
  for (final path in dirs) {
    out[path] = _dirSize(Directory(path));
  }
  return out;
}

/// Faqat `thumb_*.rustbin` fayllari (hisob papkasidagi qolgan
/// yozuvlar — ro'yxat keshlari — rasm emas).
int _measureThumbs(String dir) {
  var total = 0;
  final d = Directory(dir);
  if (!d.existsSync()) return 0;
  try {
    for (final e in d.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final name = e.path.split('/').last;
      if (!name.startsWith('thumb_')) continue;
      try {
        total += e.lengthSync();
      } catch (_) {}
    }
  } catch (_) {}
  return total;
}

int _dirSize(Directory d) {
  if (!d.existsSync()) return 0;
  var total = 0;
  try {
    for (final e in d.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      try {
        total += e.lengthSync();
      } catch (_) {
        // Fayl shu orada o'chgan — e'tiborsiz.
      }
    }
  } catch (_) {}
  return total;
}
