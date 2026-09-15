// lib/services/storage_usage.dart — ILOVA QANCHA JOY EGALLAGAN.
//
// ═══════════════════════════════════════════════════════════════
//  NIMA UCHUN
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): profil sahifasidagi xotira oynasida
// "ilovada qanaqa ma'lumot bo'lsa hammasi tartib bilan bo'lib
// yozib chiqilsin: video 2 MB 50%, anime kartochkasi, tomosha
// tarixi, database ma'lumotlari va hokazo — hajmi va jami hajmdan
// egallab turgan foizi bilan".
//
// Ya'ni endi ekranda BITTA umumiy raqam emas, TOIFALAR RO'YXATI
// bo'ladi. Har bir toifa: nomi, hajmi va umumiy hajmdagi ulushi.
//
// ── NIMA OLIB TASHLANDI (foydalanuvchi talabi) ────────────────
//
//   * "video + rasm" yozuvi — endi toifalar o'zi aytib turadi;
//   * "Tozalash" tugmasi — "endi keragi yo'q";
//   * "Telefon xotirasi 0.00% band" — "endi keragi yo'q".
//
// Shu sabab bu faylda telefon xotirasini o'qiydigan kanal ham,
// tozalash ham YO'Q. Kerak bo'lsa ular git tarixidan olinadi.
//
// ═══════════════════════════════════════════════════════════════
//  QAYSI FAYL QAYSI TOIFAGA KIRADI
// ═══════════════════════════════════════════════════════════════
//
// Ilova uchta papkadan foydalanadi:
//
//   * `<support>` — Rust yadrosining video bo'laklari;
//   * `<temp>`    — posterlar keshi va vaqtinchalik nusxalar;
//   * `<hujjatlar>` — hisob papkalari: ro'yxat keshlari, tarix
//     kadrlari, kirish ma'lumotlari.
//
// Fayl nomi qoidasi (`rust_bridge.dart`):
//
//   | Nom                        | Nima              |
//   |----------------------------|-------------------|
//   | `anime_cache.rustbin`      | anime ro'yxati    |
//   | `list_<kalit>.rustbin`     | ro'yxat keshlari  |
//   | `thumb_<kalit>.rustbin`    | tarix kadrlari    |
//
// ── HISOB FON OQIMIDA ─────────────────────────────────────────
//
// Papkalarni sanash — mingga yaqin fayl statistikasi, ya'ni UI
// oqimida qilinsa ekran qotadi. Shu sabab hisob `Isolate.run`
// ichida bajariladi va faqat natija (toifa -> bayt) qaytadi.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'rust_bridge.dart';

/// Bitta toifa: nomi va hajmi.
@immutable
class StorageSlice {
  final String label;
  final int bytes;

  const StorageSlice(this.label, this.bytes);
}

/// Bitta o'lchov natijasi — toifalar, kattasidan kichigiga.
@immutable
class StorageUsage {
  final List<StorageSlice> slices;

  const StorageUsage({this.slices = const []});

  int get totalBytes {
    var n = 0;
    for (final s in slices) {
      n += s.bytes;
    }
    return n;
  }

  /// Toifaning umumiy hajmdagi ulushi (0..1).
  double shareOf(StorageSlice slice) {
    final total = totalBytes;
    return total > 0 ? slice.bytes / total : 0;
  }
}

class StorageUsageService extends ChangeNotifier {
  StorageUsageService._();
  static final StorageUsageService instance = StorageUsageService._();

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
      final support = await _dir(getApplicationSupportDirectory);
      final temp = await _dir(getTemporaryDirectory);
      // Hisob papkasi emas, ILDIZ hujjatlar papkasi: hamma
      // hisoblarning fayllari (`accountid_*`) shu ichida.
      final docs = RustCore.instance.rootDirPath;

      final byLabel = await Isolate.run(
        () => _measure(support: support, temp: temp, docs: docs),
      );

      final slices = <StorageSlice>[];
      byLabel.forEach((label, bytes) {
        if (bytes > 0) slices.add(StorageSlice(label, bytes));
      });
      // Kattasi tepada — foydalanuvchi eng ko'p joy olganini
      // birinchi ko'rishi kerak.
      slices.sort((a, b) => b.bytes.compareTo(a.bytes));

      _usage = StorageUsage(slices: slices);
      measured = true;
    } catch (e) {
      debugPrint('Xotira hajmi o\'lchanmadi: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<String?> _dir(Future<Directory> Function() get) async {
    try {
      return (await get()).path;
    } catch (_) {
      return null;
    }
  }
}

// ── IZOLYATDA BAJARILADIGAN ISH ───────────────────────────────
//
// Bu funksiyalar sinf ichida EMAS: `Isolate.run` ga beriladigan
// yopilma faqat oddiy ma'lumotni ushlashi kerak (obyekt ushlasa
// "Illegal argument in isolate message" xatosi chiqadi).

/// Toifa nomlari — ekranda AYNAN shu ko'rinishda chiqadi.
const String _kVideo = 'Videolar';
const String _kPoster = 'Posterlar';
const String _kFrames = 'Tarix kadrlari';
const String _kAnime = 'Anime kartochkalari';
const String _kEpisodes = 'Qismlar ro\'yxati';
const String _kHistory = 'Tomosha tarixi';
const String _kFavorites = 'Sevimlilar';
const String _kStats = 'Statistika';
const String _kSettings = 'Sozlamalar';
const String _kTemp = 'Vaqtinchalik fayllar';
const String _kOther = 'Boshqa';

/// Ekrandagi tartib uchun barqaror ro'yxat (rang shu tartibdan
/// olinadi — `profile_screen.dart`).
const List<String> kStorageLabels = [
  _kVideo,
  _kPoster,
  _kFrames,
  _kAnime,
  _kEpisodes,
  _kHistory,
  _kFavorites,
  _kStats,
  _kSettings,
  _kTemp,
  _kOther,
];

Map<String, int> _measure({
  required String? support,
  required String? temp,
  required String? docs,
}) {
  final out = <String, int>{};
  void add(String label, int bytes) {
    if (bytes <= 0) return;
    out[label] = (out[label] ?? 0) + bytes;
  }

  // ── VIDEOLAR ──────────────────────────────────────────────
  if (support != null) {
    _walk(Directory('$support/video_byte_cache'), (_, size) {
      add(_kVideo, size);
    });
    // Qo'llab-quvvatlash papkasining qolgani.
    //
    // Posterlar keshi ENDI SHU YERDA (`image_cache.dart`): u
    // vaqtinchalik papkadan ko'chirildi, chunki tizim u yerdagi
    // fayllarni o'zi o'chirib yuborardi.
    _walk(Directory(support), (path, size) {
      if (path.contains('/video_byte_cache/')) return;
      if (path.contains('/aru_images/')) {
        add(_kPoster, size);
        return;
      }
      add(_kOther, size);
    });
  }

  // ── POSTERLAR VA VAQTINCHALIK FAYLLAR ─────────────────────
  if (temp != null) {
    _walk(Directory(temp), (path, size) {
      final name = path.split('/').last;
      if (path.contains('/libCachedImageData/') ||
          name.startsWith('libCachedImageData')) {
        add(_kPoster, size);
      } else {
        // Rasm/video tanlashda qolgan nusxalar va tizim qoldiqlari.
        add(_kTemp, size);
      }
    });
  }

  // ── HISOB FAYLLARI ────────────────────────────────────────
  if (docs != null) {
    _walk(Directory(docs), (path, size) {
      add(_labelOfDocFile(path.split('/').last), size);
    });
  }
  return out;
}

/// Hujjatlar papkasidagi fayl qaysi toifaga tegishli.
String _labelOfDocFile(String name) {
  if (name.startsWith('thumb_')) return _kFrames;
  if (name == 'anime_cache.rustbin') return _kAnime;
  if (name.startsWith('list_')) {
    // `list_<kalit>.rustbin` — kalit nomidan toifa aniqlanadi.
    final key = name.substring(5);
    if (key.startsWith('watch_history')) return _kHistory;
    if (key.startsWith('watch_positions')) return _kHistory;
    if (key.startsWith('favorites')) return _kFavorites;
    if (key.startsWith('eps_')) return _kEpisodes;
    if (key.startsWith('seasons_') || key.startsWith('season_')) {
      return _kAnime;
    }
    if (key.startsWith('settings')) return _kSettings;
    if (key.startsWith('app_stats') ||
        key.startsWith('my_stats') ||
        key.startsWith('traffic')) {
      return _kStats;
    }
    return _kOther;
  }
  return _kOther;
}

/// Papkadagi HAR BIR faylni ko'rib chiqadi (`yo'l`, `hajm`).
///
/// Xato yutiladi: fayl shu orada o'chgan yoki band bo'lishi
/// mumkin — o'shanda hisob shunchaki shu fayldan kichik bo'ladi.
void _walk(Directory dir, void Function(String path, int size) visit) {
  if (!dir.existsSync()) return;
  try {
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      try {
        visit(e.path, e.lengthSync());
      } catch (_) {}
    }
  } catch (_) {}
}
