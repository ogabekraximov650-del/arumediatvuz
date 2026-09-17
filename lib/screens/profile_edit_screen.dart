import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

/// ISM VA USERNAME'NI TAHRIRLASH.
///
/// ═══════════════════════════════════════════════════════════════
///  NEGA BU ENDI "SO'RASH" EMAS, "TAHRIRLASH" OYNASI
/// ═══════════════════════════════════════════════════════════════
///
/// Ilgari yangi hisob ochilganda shu oyna MAJBURAN ochilar va uni
/// yopib bo'lmasdi: foydalanuvchi ism va username yozmaguncha
/// ilovaga kira olmasdi.
///
/// TALAB O'ZGARDI: endi hech narsa so'ralmaydi — server yangi
/// hisobga bazada band bo'lmagan eng kichik raqamdan `User 7` /
/// `user_7` kabi nom qo'yib beradi. Bu oyna esa profil
/// sahifasidagi tahrirlash tugmasi orqali, foydalanuvchi O'ZI
/// xohlaganda ochiladi.
///
/// Shu sababli: oyna yopiladi (orqaga tugmasi ishlaydi), maydonlar
/// hozirgi qiymat bilan to'ldirilgan turadi va "Hisobdan chiqish"
/// tugmasi bu yerda yo'q (u profil sahifasida turibdi).
///
/// USERNAME REAL VAQTDA TEKSHIRILADI: yozish to'xtaganidan 350 ms
/// keyin server so'raladi (`_debounce`). Har bosishda so'ralsa,
/// 15 ta harf 15 ta so'rov bo'lardi va oxirgi javob birinchisidan
/// oldin kelib, natija chalkashardi.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

/// Username qanday holatda.
enum _Check { boshlangich, yozilmoqda, tekshirilmoqda, bosh, band, xato }

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _userCtrl;

  /// Oyna ochilgandagi username — o'zgarmagan bo'lsa serverdan
  /// so'rashning hojati yo'q (o'z nomi o'ziga "band" emas).
  late final String _startUser;
  late final String _startName;

  Timer? _debounce;
  _Check _state = _Check.boshlangich;
  String _problem = '';
  bool _saving = false;
  String? _saveError;

  /// Qaysi so'rov ketayotgani. Javob kelganda username o'zgargan
  /// bo'lsa, eski javob e'tiborsiz qoldiriladi.
  int _run = 0;

  @override
  void initState() {
    super.initState();
    final u = AuthService.instance.user;
    _startName = u?.firstName ?? '';
    _startUser = u?.username ?? '';
    _nameCtrl = TextEditingController(text: _startName);
    _userCtrl = TextEditingController(text: _startUser);
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

  /// Username o'zgarmaganmi (registr hisobga olinmaydi — server
  /// ham `LOWER(username)` bo'yicha solishtiradi).
  bool get _userUnchanged =>
      _userCtrl.text.trim().toLowerCase() == _startUser.toLowerCase();

  void _onUsernameChanged() {
    _debounce?.cancel();
    final u = _userCtrl.text.trim();

    // O'zining nomi — tekshirish shart emas, u allaqachon uniki.
    if (_userUnchanged) {
      setState(() {
        _state = _Check.boshlangich;
        _problem = '';
      });
      return;
    }

    if (u.isEmpty) {
      setState(() {
        _state = _Check.xato;
        _problem = 'Username bo\'sh bo\'lmasin';
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
        _state = _Check.bosh;
        _problem = '';
      } else {
        _state = _Check.band;
        _problem = 'Bu username band';
      }
    });
  }

  /// Saqlash mumkinmi.
  ///
  /// Ikki shart: ism qoidaga to'g'ri kelsin va username YO o'sha-
  /// o'shaligicha qolsin, YO bo'sh ekani tasdiqlangan bo'lsin.
  /// Hech narsa o'zgarmagan bo'lsa ham tugma so'nadi — behuda
  /// so'rov ketmasin.
  bool get _canSave {
    if (_saving) return false;
    if (AuthService.nameProblem(_nameCtrl.text) != null) return false;
    if (!_userUnchanged && _state != _Check.bosh) return false;
    return _nameCtrl.text.trim() != _startName.trim() || !_userUnchanged;
  }

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

  @override
  Widget build(BuildContext context) {
    final nameProblem = AuthService.nameProblem(_nameCtrl.text);

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Sarlavha va orqaga tugmasi ─────────────────
                Row(
                  children: [
                    GlassTappable(
                      onTap: _saving ? () {} : () => Navigator.of(context).pop(),
                      child: const Glass(
                        borderRadius: 14,
                        blur: 14,
                        padding: EdgeInsets.all(8),
                        child:
                            Icon(Icons.arrow_back_rounded, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text(
                        'Profilni tahrirlash',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 26),

                _label('Ism'),
                const SizedBox(height: 8),
                _field(
                  controller: _nameCtrl,
                  hint: 'Ismingiz',
                  icon: Icons.person_outline_rounded,
                  // Ko'zga ko'ringan belgilar bo'yicha kesiladi —
                  // ya'ni bitta emoji bitta belgi bo'lib sanaladi.
                  maxLength: kNameMaxLength,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    nameProblem ??
                        'Eng ko\'pi $kNameMaxLength ta belgi. Emoji va '
                            'istalgan belgi ishlatsangiz bo\'ladi.',
                    style: TextStyle(
                        color: nameProblem == null
                            ? Colors.white.withValues(alpha: 0.38)
                            : AppColors.accent,
                        fontSize: 12.5,
                        height: 1.4),
                  ),
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
              ],
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
    if (_userUnchanged) return null;
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
      case _Check.bosh:
        return const Icon(Icons.check_circle_rounded,
            color: AppColors.success, size: 20);
      case _Check.band:
      case _Check.xato:
        return const Icon(Icons.error_outline_rounded,
            color: AppColors.accent, size: 20);
      case _Check.boshlangich:
        return null;
    }
  }

  Widget _statusText() {
    late final String text;
    late final Color color;

    if (_userUnchanged) {
      text = 'Bu — hozirgi username\'ingiz.';
      color = Colors.white.withValues(alpha: 0.38);
    } else {
      switch (_state) {
        case _Check.boshlangich:
          text = '3-15 ta belgi. Faqat harf, raqam va _ ishlatiladi.';
          color = Colors.white.withValues(alpha: 0.38);
        case _Check.yozilmoqda:
        case _Check.tekshirilmoqda:
          text = 'Tekshirilmoqda...';
          color = Colors.white.withValues(alpha: 0.45);
        case _Check.bosh:
          text = 'Bu username bo\'sh — olsangiz bo\'ladi';
          color = AppColors.success;
        case _Check.band:
        case _Check.xato:
          text = _problem;
          color = AppColors.accent;
      }
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
                    'Saqlash',
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
