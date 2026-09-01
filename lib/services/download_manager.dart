// lib/services/download_manager.dart
//
// ── VIDEO YUKLAB OLISH: REAL VAQTDAGI HOLAT ─────────────────────────
//
// Bu qatlam Rust yadrosidagi kesh-serverning HISOBINI o'qiydi va uni
// ekranga uzatadi. Muhim tafsilot: yuklab olish ham, video ko'rish ham
// AYNAN BIR XIL bo'lak fayllariga yozadi — shu sabab hisob bitta:
// foydalanuvchi videoni oddiy ko'rsa ham, foiz ko'rsatkichi o'sib
// boradi; keyin "yuklab olish"ni bossa, faqat YETISHMAYOTGAN bo'laklar
// olinadi.
//
// Nima uchun so'rab turish (polling) tanlandi: Rust tomonidagi hisob
// bir nechta native ish oqimida yangilanadi. Ularning har biridan
// Dart'ga hodisa yuborish (NativeApi.postCObject) murakkab va nozik
// bo'lardi; hisobni o'qish esa BEPUL — u xotiradagi bitta HashMap'dan
// olinadi, diskka ham, tarmoqqa ham chiqmaydi. Shu sabab 500 ms da bir
// marta so'rab turish eng sodda va eng ishonchli yo'l.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'rust_bridge.dart';

/// Bitta video (aniq bir sifat) uchun yuklab olish holati.
@immutable
class VideoCacheStat {
  /// Faylning to'liq hajmi (bayt). 0 — hali noma'lum (hech qachon
  /// ochilmagan va yuklab olinmagan).
  final int total;

  /// Diskda tayyor turgan hajm (bayt).
  final int downloaded;

  /// Hozir fon'da yuklab olinyaptimi.
  final bool downloading;

  const VideoCacheStat({
    this.total = 0,
    this.downloaded = 0,
    this.downloading = false,
  });

  static const empty = VideoCacheStat();

  double get ratio =>
      total > 0 ? (downloaded / total).clamp(0.0, 1.0) : 0.0;

  int get percent => (ratio * 100).round();

  bool get complete => total > 0 && downloaded >= total;

  @override
  bool operator ==(Object other) =>
      other is VideoCacheStat &&
      other.total == total &&
      other.downloaded == downloaded &&
      other.downloading == downloading;

  @override
  int get hashCode => Object.hash(total, downloaded, downloading);
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  /// Ekran (yoki boshqa "egasi") -> u kuzatayotgan URL'lar.
  final Map<Object, Set<String>> _watchers = {};

  /// Foydalanuvchi yuklab olishni boshlagan URL'lar. Ular ekran
  /// yopilsa ham kuzatilaveradi — yuklash fon'da davom etadi.
  final Set<String> _active = {};

  final Map<String, VideoCacheStat> _stats = {};

  Timer? _timer;

  VideoCacheStat statOf(String url) => _stats[url] ?? VideoCacheStat.empty;

  /// Ekran ko'rsatayotgan URL'lar ro'yxatini yangilaydi. Ro'yxat
  /// o'zgarmagan bo'lsa hech narsa qilinmaydi (keraksiz qayta
  /// chizishlarning oldini oladi).
  void watch(Object owner, Set<String> urls) {
    final current = _watchers[owner];
    if (current != null &&
        current.length == urls.length &&
        current.containsAll(urls)) {
      return;
    }
    _watchers[owner] = urls;
    _sync();
  }

  void unwatch(Object owner) {
    if (_watchers.remove(owner) != null) _sync();
  }

  Set<String> get _tracked => {
        for (final s in _watchers.values) ...s,
        ..._active,
      };

  void _sync() {
    if (_tracked.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _poll();
    _timer ??= Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  void _poll() {
    final urls = _tracked.toList();
    if (urls.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final raw = RustCore.instance.videoStats(urls);
    var changed = false;
    for (final entry in raw.entries) {
      final v = entry.value;
      final stat = VideoCacheStat(
        total: (v['total'] as num?)?.toInt() ?? 0,
        downloaded: (v['downloaded'] as num?)?.toInt() ?? 0,
        downloading: v['downloading'] == true,
      );
      if (_stats[entry.key] != stat) {
        _stats[entry.key] = stat;
        changed = true;
      }
      // Yuklab olish tugagan (yoki to'xtagan) bo'lsa, uni doimiy
      // kuzatuvdan chiqaramiz — aks holda ilova ishlagan davomida
      // ro'yxat cheksiz o'sib borardi.
      if (!stat.downloading && _active.contains(entry.key)) {
        _active.remove(entry.key);
      }
    }
    if (changed) notifyListeners();
  }

  /// Yuklab olishni boshlaydi. Videoning bir qismi allaqachon keshda
  /// bo'lsa (masalan ko'rilgani sabab), FAQAT yetishmayotgan bo'laklar
  /// olinadi.
  void download(String url) {
    if (url.isEmpty) return;
    RustCore.instance.videoDownload(url);
    _active.add(url);
    // Tugmaning ko'rinishi darhol o'zgarishi uchun holatni "yuklanyapti"
    // deb belgilab qo'yamiz — keyingi so'rovda Rust'dan kelgan haqiqiy
    // qiymat uni almashtiradi.
    final cur = _stats[url] ?? VideoCacheStat.empty;
    _stats[url] = VideoCacheStat(
      total: cur.total,
      downloaded: cur.downloaded,
      downloading: true,
    );
    notifyListeners();
    _sync();
  }

  /// Yuklab olishni pauza qiladi — olingan qism joyida qoladi va
  /// keyinroq xuddi shu joydan davom etadi.
  void pause(String url) {
    if (url.isEmpty) return;
    RustCore.instance.videoPause(url);
    _active.remove(url);
    final cur = _stats[url] ?? VideoCacheStat.empty;
    _stats[url] = VideoCacheStat(
      total: cur.total,
      downloaded: cur.downloaded,
      downloading: false,
    );
    notifyListeners();
  }

  /// Shu sifatdagi videoni keshdan butunlay o'chiradi.
  void delete(String url) {
    if (url.isEmpty) return;
    RustCore.instance.videoDelete(url);
    _active.remove(url);
    final cur = _stats[url] ?? VideoCacheStat.empty;
    _stats[url] = VideoCacheStat(total: cur.total, downloaded: 0);
    notifyListeners();
  }
}
