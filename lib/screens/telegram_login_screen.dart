import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';
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
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = _left > 0 ? _left - 1 : 0);
      if (_left == 0) {
        _poll?.cancel();
        _tick?.cancel();
        setState(() => _stage = _Stage.expired);
      }
    });

    await _openTelegram();
  }

  Future<void> _openTelegram() async {
    final link = _req?.deepLink;
    if (link == null) return;
    try {
      // `canLaunchUrl` ATAYLAB ishlatilmaydi: Android 11+ da u
      // manifestda `<queries>` e'lonini talab qiladi va u bo'lmasa
      // ochilishi mumkin bo'lgan havola uchun ham `false` qaytaradi.
      // To'g'ridan-to'g'ri ochish esa bunday cheklovga tushmaydi.
      await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _message = 'Telegram ochilmadi. Telegram ilovasi o\'rnatilganini '
            'tekshiring.';
      });
    }
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
            'Telegramda START tugmasini bosing',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          const Text(
            'Bosganingizdan so\'ng ilovaga qayting — hisobingiz '
            'avtomatik ochiladi.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 28),
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white54),
          ),
          const SizedBox(height: 16),
          Text('Kutilmoqda · $_timeLeft',
              style: const TextStyle(color: Colors.white38, fontSize: 13)),
          const SizedBox(height: 28),
          _button('Telegramni qayta ochish', Icons.open_in_new_rounded,
              _openTelegram),
        ];

      case _Stage.success:
        return const [
          Icon(Icons.check_circle_rounded, color: Color(0xFF4ADE80), size: 46),
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
