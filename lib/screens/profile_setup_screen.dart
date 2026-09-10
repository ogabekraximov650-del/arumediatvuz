import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../theme/app_background.dart';
import '../widgets/aru_logo.dart';
import '../widgets/glass.dart';

/// YANGI HISOB — ISM VA USERNAME.
///
/// Telegram orqali birinchi marta kirgan foydalanuvchidan ism va
/// username SO'RALADI. Ular Telegramdan OLINMAYDI (foydalanuvchi
/// talabi): Telegramdan faqat hisobni tanish uchun `telegram_id`
/// olinadi.
///
/// Bu oynani yopib bo'lmaydi — `PopScope(canPop: false)`. Sabab:
/// ism/username'siz hisob yarim qolgan bo'ladi (profilda bo'sh
/// joy turadi, boshqalar uni topa olmaydi). Chiqishning yagona
/// yo'li — to'ldirish yoki hisobdan chiqish.
///
/// USERNAME REAL VAQTDA TEKSHIRILADI: har bir belgi qo'shilganda
/// yoki olinganda server so'raladi. Lekin HAR BOSISHDA emas —
/// yozish to'xtaganidan 350 ms keyin (`_debounce`). Aks holda
/// 15 ta harf 15 ta so'rov bo'lardi va oxirgi javob birinchisidan
/// oldin kelib, natija chalkashardi.
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

/// Username qanday holatda.
enum _Check { bosh, yozilmoqda, tekshirilmoqda, bosh_emas, band, xato }

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _nameCtrl = TextEditingController();
  final _userCtrl = TextEditingController();

  Timer? _debounce;
  _Check _state = _Check.bosh;
  String _problem = '';
  bool _saving = false;
  String? _saveError;

  /// Qaysi so'rov ketayotgani. Javob kelganda username o'zgargan
  /// bo'lsa, eski javob e'tiborsiz qoldiriladi.
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _userCtrl.addListener(_onUsernameChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _userCtrl.removeListener(_onUsernameChanged);
    _nameCtrl.dispose();
    _userCtrl.dispose();
    super.dispose();
  }

  void _onUsernameChanged() {
    _debounce?.cancel();
    final u = _userCtrl.text.trim();

    if (u.isEmpty) {
      setState(() {
        _state = _Check.bosh;
        _problem = '';
      });
      return;
    }

    // Qolip xatosi darhol ko'rinadi — server so'ralmaydi.
    final problem = AuthService.usernameProblem(u);
    if (problem != null) {
      setState(() {
        _state = _Check.xato;
        _problem = problem;
      });
      return;
    }

    setState(() {
      _state = _Check.yozilmoqda;
      _problem = '';
    });
    _debounce = Timer(const Duration(milliseconds: 350), () => _ask(u));
  }

  Future<void> _ask(String u) async {
    final run = ++_run;
    if (mounted) setState(() => _state = _Check.tekshirilmoqda);

    final free = await AuthService.instance.usernameAvailable(u);
    // Javob kechikkan bo'lsa va foydalanuvchi allaqachon boshqa
    // nom yozgan bo'lsa — bu javob endi ahamiyatsiz.
    if (!mounted || run != _run || _userCtrl.text.trim() != u) return;

    setState(() {
      if (free == null) {
        _state = _Check.xato;
        _problem = 'Tekshirib bo\'lmadi — internetni tekshiring';
      } else if (free) {
        _state = _Check.bosh_emas;
        _problem = '';
      } else {
        _state = _Check.band;
        _problem = 'Bu username band';
      }
    });
  }

  bool get _canSave =>
      !_saving &&
      _nameCtrl.text.trim().isNotEmpty &&
      _state == _Check.bosh_emas;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final err = await AuthService.instance
        .saveProfile(_nameCtrl.text, _userCtrl.text.trim());
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _saveError = err;
    });
  }

  Future<void> _logout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Chiqish', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Ism va username kiritilmasa hisob ochilmaydi. Chiqasizmi?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Bekor qilish'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Chiqish',
                style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await AuthService.instance.logout();
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Orqaga tugmasi bilan yopilmaydi — pastda "Chiqish" bor.
      canPop: false,
      child: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics()),
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: AruLogo(height: 34)),
                  const SizedBox(height: 30),
                  const Text(
                    'Xush kelibsiz!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Hisobingizni to\'ldiring — ism va username tanlang.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 14,
                        height: 1.45),
                  ),
                  const SizedBox(height: 30),

                  _label('Ism'),
                  const SizedBox(height: 8),
                  _field(
                    controller: _nameCtrl,
                    hint: 'Ismingiz',
                    icon: Icons.person_outline_rounded,
                    maxLength: 32,
                    onChanged: (_) => setState(() {}),
                  ),

                  const SizedBox(height: 22),
                  _label('Username'),
                  const SizedBox(height: 8),
                  _field(
                    controller: _userCtrl,
                    hint: 'username',
                    icon: Icons.alternate_email_rounded,
                    maxLength: 15,
                    // Taqiqlangan belgilar KLAVIATURADAN ham
                    // o'tmaydi: emoji yoki bo'shliq yozib
                    // bo'lmaydi, ya'ni xato ko'rsatishning ham
                    // hojati qolmaydi.
                    formatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]')),
                    ],
                    suffix: _statusIcon(),
                  ),
                  const SizedBox(height: 8),
                  _statusText(),

                  const SizedBox(height: 30),
                  _saveButton(),
                  if (_saveError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _saveError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.accent, fontSize: 13.5),
                    ),
                  ],
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: _saving ? null : _logout,
                    child: Text('Hisobdan chiqish',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 13.5)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
        text,
        style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 13.5,
            fontWeight: FontWeight.w600),
      );

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required int maxLength,
    List<TextInputFormatter>? formatters,
    Widget? suffix,
    ValueChanged<String>? onChanged,
  }) {
    return Glass(
      borderRadius: 16,
      blur: 14,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: TextField(
        controller: controller,
        inputFormatters: formatters,
        maxLength: maxLength,
        onChanged: onChanged,
        enabled: !_saving,
        style: const TextStyle(color: Colors.white, fontSize: 15.5),
        decoration: InputDecoration(
          counterText: '',
          border: InputBorder.none,
          icon: Icon(icon, color: Colors.white38, size: 20),
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.28)),
          suffixIcon: suffix,
        ),
      ),
    );
  }

  Widget? _statusIcon() {
    switch (_state) {
      case _Check.tekshirilmoqda:
      case _Check.yozilmoqda:
        return const Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white38),
          ),
        );
      case _Check.bosh_emas:
        return const Icon(Icons.check_circle_rounded,
            color: Color(0xFF4ADE80), size: 20);
      case _Check.band:
      case _Check.xato:
        return const Icon(Icons.error_outline_rounded,
            color: AppColors.accent, size: 20);
      case _Check.bosh:
        return null;
    }
  }

  Widget _statusText() {
    late final String text;
    late final Color color;

    switch (_state) {
      case _Check.bosh:
        text = '3-15 ta belgi. Faqat harf, raqam va _ ishlatiladi.';
        color = Colors.white.withValues(alpha: 0.38);
      case _Check.yozilmoqda:
      case _Check.tekshirilmoqda:
        text = 'Tekshirilmoqda...';
        color = Colors.white.withValues(alpha: 0.45);
      case _Check.bosh_emas:
        text = 'Bu username bo\'sh — olsangiz bo\'ladi';
        color = const Color(0xFF4ADE80);
      case _Check.band:
      case _Check.xato:
        text = _problem;
        color = AppColors.accent;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 12.5, height: 1.4)),
    );
  }

  Widget _saveButton() {
    final on = _canSave;
    return GlassTappable(
      onTap: on ? _save : () {},
      child: Opacity(
        opacity: on ? 1 : 0.45,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.accent, AppColors.accent2],
            ),
          ),
          child: Center(
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: Colors.white),
                  )
                : const Text(
                    'Davom etish',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600),
                  ),
          ),
        ),
      ),
    );
  }
}
