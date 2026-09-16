// services/pip_service.dart
//
// ═══════════════════════════════════════════════════════════════
//  ILOVALAR USTIDA SUZUVCHI PLEYER (tizim PiP'i)
// ═══════════════════════════════════════════════════════════════
//
// Bu — ILOVA ICHIDAGI suzuvchi pleyer EMAS (u
// `mini_player_service.dart` da). Bu tizimning o'z PiP oynasi:
// ilova fonga ketganda ham video boshqa ilovalar ustida
// ko'rinib turadi.
//
// Ish taqsimoti:
//   * Android tomoni (`android-template/MainActivity.kt`) —
//     `enterPictureInPictureMode` chaqiradi va PiP holati
//     o'zgarganda xabar qiladi;
//   * bu fayl — o'sha kanalning Dart tomoni.
//
// Android'dan boshqa platformada kanal javob bermaydi — shu
// sabab har bir chaqiruv `MissingPluginException` ga qarshi
// himoyalangan va `false` qaytaradi (ilova yiqilmaydi).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PipService extends ChangeNotifier {
  PipService._() {
    _ch.setMethodCallHandler(_onNative);
  }
  static final instance = PipService._();

  static const _ch = MethodChannel('aru/pip');

  /// Hozir tizim PiP oynasidamizmi.
  ///
  /// Pleyer buni kuzatadi: PiP oynasida boshqaruv tugmalari va
  /// sarlavha yashiriladi — kichik oynada ular faqat rasmni
  /// to'sadi.
  bool _inPip = false;
  bool get inPip => _inPip;

  /// PiP so'raldi, lekin tizim hali javob qaytarmadi.
  ///
  /// ── NEGA BU KERAK ─────────────────────────────────────────
  ///
  /// PiP'ga o'tishda Android AVVAL `onPause` yuboradi, `inPip`
  /// xabari esa UNDAN KEYIN keladi. Oradagi qisqa vaqtda ilova
  /// "fonga ketdim" deb o'ylab videoni to'xtatardi — PiP oynasi
  /// qotib qolgan kadr bilan ochilardi.
  ///
  /// Shu sabab bayroq so'rov YUBORILISHIDAN OLDIN qo'yiladi.
  bool _pending = false;

  /// Hozir PiP'damizmi YOKI unga o'tish jarayonidamizmi.
  ///
  /// Ilovaning hayot-sikli (`didChangeAppLifecycleState`) aynan
  /// shuni tekshiradi: `true` bo'lsa video TO'XTATILMAYDI.
  bool get active => _inPip || _pending;

  /// Tizim javob bermasa bayroq abadiy osilib qolmasin.
  Timer? _pendingGuard;

  /// Qurilma PiP'ni qo'llab-quvvatlaydimi.
  ///
  /// `null` — hali so'ralmagan. Javob keshlanadi: u ilova
  /// ishlagan davomida o'zgarmaydi.
  bool? _supported;

  Future<void> _onNative(MethodCall call) async {
    if (call.method != 'changed') return;

    final args = call.arguments;
    final v = (args is Map) ? args['inPip'] == true : false;

    _pendingGuard?.cancel();
    _pendingGuard = null;

    if (_inPip == v && !_pending) return;

    _inPip = v;
    _pending = false;
    notifyListeners();
  }

  void _clearPending() {
    _pendingGuard?.cancel();
    _pendingGuard = null;
    if (!_pending) return;
    _pending = false;
    notifyListeners();
  }

  /// Qurilma PiP'ni qo'llab-quvvatlaydimi.
  ///
  /// Android 8.0 dan past qurilmalarda va PiP o'chirilgan
  /// nashrlarda `false` — ilova tugmani o'shanda ko'rsatmaydi.
  Future<bool> isSupported() async {
    if (_supported != null) return _supported!;
    if (!_isAndroid) {
      _supported = false;
      return false;
    }
    try {
      _supported = await _ch.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      _supported = false;
    }
    return _supported!;
  }

  /// PiP rejimiga o'tadi.
  ///
  /// [width] va [height] — VIDEONING o'lchami. Nisbat berilmasa
  /// tizim oynani kvadratga yaqin qilib ochadi va rasm yon
  /// tomonlaridan qirqiladi.
  ///
  /// Muvaffaqiyatli bo'lsa `true`. `false` — qurilma
  /// qo'llamaydi yoki tizim rad etdi (masalan ilova allaqachon
  /// fonda). Ikkala holat ham XATO EMAS: chaqiruvchi shunchaki
  /// pleyerni odatdagidek qoldiradi.
  Future<bool> enter({int? width, int? height}) async {
    if (!await isSupported()) return false;

    // Bayroq so'rovdan OLDIN — yuqoridagi `_pending` izohiga qarang.
    _pending = true;
    notifyListeners();

    // Tizim `changed` yubormasa (masalan so'rov jimgina rad
    // etilsa) bayroq osilib qolmasin: video shundan keyin
    // odatdagidek to'xtay oladigan bo'ladi.
    _pendingGuard?.cancel();
    _pendingGuard = Timer(const Duration(seconds: 3), _clearPending);

    try {
      final ok = await _ch.invokeMethod<bool>('enter', {
            'width': (width != null && width > 0) ? width : 16,
            'height': (height != null && height > 0) ? height : 9,
          }) ??
          false;
      if (!ok) _clearPending();
      return ok;
    } catch (_) {
      _clearPending();
      return false;
    }
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
}
