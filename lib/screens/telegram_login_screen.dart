import 'dart:async';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/telegram_apps.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import '../widgets/telegram_logo.dart';

/// TELEGRAM ORQALI KIRISH — kutish ekrani.
///
/// Ekran ochilishi bilan:
///   1. Serverdan bir martalik token oladi;
///   2. Telegram ilovasini `t.me/<bot>?start=<token>` bilan ochadi;
///   3. Foydalanuvchi START bosishini kutib, holatni so'rab turadi.
///
/// SO'RAB TURISH TEZLIGI: har 2 soniyada bir marta, ustiga ilovaga
/// QAYTGAN ZAHOTI (`AppLifecycleState.resumed`) darhol yana bir
/// marta. Amalda foydalanuvchi Telegramdan qaytganda javob
/// deyarli bir zumda keladi — 2 soniyani kutib o'tirmaydi.
class TelegramLoginScreen extends StatefulWidget {
  const TelegramLoginScreen({super.key});

  @override
  State<TelegramLoginScreen> createState() => _TelegramLoginScreenState();
}

enum _Stage { preparing, waiting, success, expired, error }

class _TelegramLoginScreenState extends State<TelegramLoginScreen>
    with WidgetsBindingObserver {
  _Stage _stage = _Stage.preparing;
  String _message = '';
  TelegramLoginRequest? _req;
  Timer? _poll;
  Timer? _tick;
  int _left = 0;
  bool _checking = false;

  /// Foydalanuvchi shu seansda tanlagan Telegram ilovasi.
  /// Ilova qayta ochilganda yana so'ralmasligi uchun saqlanadi.
  TelegramApp? _chosen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _begin();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Telegramdan qaytdi — kutmasdan tekshiramiz.
    if (state == AppLifecycleState.resumed && _stage == _Stage.waiting) {
      _check();
    }
  }

  Future<void> _begin() async {
    setState(() {
      _stage = _Stage.preparing;
      _message = '';
    });

    final req = await AuthService.instance.start();
    if (!mounted) return;

    if (req == null) {
      setState(() {
        _stage = _Stage.error;
        _message = 'Serverga ulanib bo\'lmadi. Internetni tekshirib, '
            'qaytadan urinib ko\'ring.';
      });
      return;
    }

    setState(() {
      _req = req;
      _left = req.expiresIn;
      _stage = _Stage.waiting;
    });

    _poll?.cancel();
    // ── SERVERDAN 0,8 SONIYADA BIR SO'RALADI ────────────────
    //
    // Ilgari 2 soniyada bir so'ralardi. Telegramda START bosilib,
    // server hisobni ochib bo'lgan bo'lsa ham ilova o'rtacha
    // BIR SONIYA shundoq kutib turardi — foydalanuvchi buni
    // "bot sekin" deb sezardi.
    //
    // 0,8 soniya kutishni sezilarli qisqartiradi, serverga esa
    // og'irlik solmaydi: bu so'rov bitta kichkina qatorni
    // o'qiydi va faqat kirish oynasi ochiq turganda (eng ko'pi
    // 5 daqiqa) yuboriladi.
    _poll = Timer.periodic(
        const Duration(milliseconds: 800), (_) => _check());
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = _left > 0 ? _left - 1 : 0);
      if (_left == 0) {
        _poll?.cancel();
        _tick?.cancel();
        AuthService.instance.clearPending();
        setState(() => _stage = _Stage.expired);
      }
    });

    // ── TELEGRAM O'ZI OCHILMAYDI ──────────────────────────
    //
    // TALAB (foydalanuvchi): "Telegram orqali kirish tugmasini
    // bosganda Telegram avtomatik ochilmasin, shunchaki
    // 'Telegramni ochish' degan tugma chiqib tursin".
    //
    // Ilgari ekran ochilishi bilan ilova o'zi Telegramga sakrab
    // ketardi — foydalanuvchi nima bo'layotganini tushunmasdan
    // boshqa ilovada paydo bo'lardi. Endi qaror foydalanuvchida.
    //
    // Faqat bitta so'rov qilamiz: token diskda saqlanadi, ya'ni
    // bu ekran ilova yopilib qaytgandan keyin AVVALGI token
    // bilan ochilishi mumkin. Foydalanuvchi Telegramda START'ni
    // allaqachon bosgan bo'lsa, uni bekorga kutkazmaymiz.
    await _check();
  }

  /// TELEGRAMNI OCHISH — QAYSI ILOVA BILAN, FOYDALANUVCHI HAL QILADI.
  ///
  /// Ilgari havola shunchaki tizimga berilardi va u STANDART
  /// ilovaga ketardi. Natijada telefonida Telegram ham, Telegram X
  /// ham bo'lgan odam o'zi ishlatadigan ilovaga emas, tizim tanlab
  /// qo'ygan ilovaga tushib qolardi.
  ///
  /// Endi:
  ///   * bitta Telegram bo'lsa — to'g'ridan-to'g'ri o'sha ochiladi;
  ///   * bir nechta bo'lsa — ro'yxat chiqadi va foydalanuvchi
  ///     tanlaydi (tanlovi shu seans uchun eslab qolinadi, ya'ni
  ///     "qayta ochish"da yana so'ralmaydi);
  ///   * hech biri topilmasa — odatdagi yo'l bilan ochiladi.
  Future<void> _openTelegram() async {
    final link = _req?.deepLink;
    if (link == null) return;

    // Bu seansda allaqachon tanlangan bo'lsa — qaytadan so'ramaymiz.
    final chosen = _chosen;
    if (chosen != null) {
      if (await TelegramLauncher.openWith(chosen, link)) return;
      // Tanlangan ilova ochilmadi — tanlovni bekor qilib, qaytadan
      // so'raymiz.
      _chosen = null;
    }

    final apps = await TelegramLauncher.installed(link);
    if (!mounted) return;

    if (apps.isEmpty) {
      if (await TelegramLauncher.openDefault(link)) return;
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _message = 'Telegram ochilmadi. Telegram ilovasi o\'rnatilganini '
            'tekshiring.';
      });
      return;
    }

    if (apps.length == 1) {
      _chosen = apps.first;
      if (await TelegramLauncher.openWith(apps.first, link)) return;
      await TelegramLauncher.openDefault(link);
      return;
    }

    final picked = await _pickApp(apps);
    if (picked == null || !mounted) return;
    _chosen = picked;
    if (!await TelegramLauncher.openWith(picked, link)) {
      await TelegramLauncher.openDefault(link);
    }
  }

  /// Qaysi Telegram bilan ochish kerakligini so'raydigan ro'yxat.
  Future<TelegramApp?> _pickApp(List<TelegramApp> apps) {
    return showModalBottomSheet<TelegramApp>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Qaysi ilova bilan ochilsin?',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            for (final a in apps)
              ListTile(
                leading: const TelegramGlyph(size: 22),
                title: Text(a.name,
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
                onTap: () => Navigator.of(ctx).pop(a),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _check() async {
    final req = _req;
    if (req == null || _checking || _stage != _Stage.waiting) return;
    _checking = true;
    final status = await AuthService.instance.check(req.token);
    _checking = false;
    if (!mounted) return;

    switch (status) {
      case LoginStatus.ok:
        _poll?.cancel();
        _tick?.cancel();
        setState(() => _stage = _Stage.success);
        // Muvaffaqiyat belgisi ko'rinib ulgursin.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop(true);
        break;
      case LoginStatus.expired:
        _poll?.cancel();
        _tick?.cancel();
        setState(() => _stage = _Stage.expired);
        break;
      case LoginStatus.error:
      case LoginStatus.pending:
        break;
    }
  }

  String get _timeLeft {
    final m = _left ~/ 60;
    final s = _left % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TelegramLogo(size: 104),
                  const SizedBox(height: 32),
                  ..._content(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content() {
    switch (_stage) {
      case _Stage.preparing:
        return const [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white70),
          ),
          SizedBox(height: 20),
          Text('Tayyorlanmoqda...',
              style: TextStyle(color: Colors.white70, fontSize: 15)),
        ];

      case _Stage.waiting:
        return [
          const Text(
            'Telegram orqali kirish',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          const Text(
            'Quyidagi tugmani bosing, Telegramda START'
            ' tugmasini bosing va ilovaga qayting — hisobingiz '
            'avtomatik ochiladi.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 26),
          // ASOSIY TUGMA — Telegram faqat SHUNI bosganda ochiladi
          // (foydalanuvchi talabi).
          _button('Telegramni ochish', Icons.open_in_new_rounded,
              _openTelegram),
          const SizedBox(height: 20),
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.0, color: Colors.white38),
          ),
          const SizedBox(height: 12),
          Text('Kutilmoqda · $_timeLeft',
              style: const TextStyle(color: Colors.white38, fontSize: 13)),
          const SizedBox(height: 10),
          // Tanlangan ilova noto'g'ri bo'lsa — tanlovni qaytadan
          // so'rash uchun.
          TextButton(
            onPressed: () {
              _chosen = null;
              _openTelegram();
            },
            child: Text('Boshqa ilova bilan ochish',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 13)),
          ),
        ];

      case _Stage.success:
        return const [
          Icon(Icons.check_circle_rounded, color: AppColors.success, size: 46),
          SizedBox(height: 16),
          Text('Kirdingiz!',
              style: TextStyle(
                  color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
        ];

      case _Stage.expired:
        return [
          const Icon(Icons.timer_off_rounded, color: Colors.white54, size: 42),
          const SizedBox(height: 16),
          const Text(
            'Vaqt tugadi',
            style: TextStyle(
                color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          const Text(
            'Havola 5 daqiqa amal qiladi. Qaytadan urinib ko\'ring.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 26),
          _button('Qaytadan urinish', Icons.refresh_rounded, _begin),
        ];

      case _Stage.error:
        return [
          const Icon(Icons.wifi_off_rounded, color: Colors.white54, size: 42),
          const SizedBox(height: 16),
          Text(
            _message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 26),
          _button('Qaytadan urinish', Icons.refresh_rounded, _begin),
        ];
    }
  }

  Widget _button(String label, IconData icon, VoidCallback onTap) {
    return GlassTappable(
      onTap: onTap,
      child: Glass(
        borderRadius: 16,
        blur: 14,
        tint: 0.16,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 19),
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
