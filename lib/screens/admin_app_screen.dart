// lib/screens/admin_app_screen.dart — ILOVA VERSIYASI VA KALIT.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "admin panelga versiya raqam yozadigan bo'lim
// qo'sh, ya'ni versiya raqamini yozaman 0.0.9+9 yoki 0.0.9 qilib
// yozaman. Worker esa shu va shundan katta versiyalarda ishlaydi,
// agar versiya past bo'lsa ishlamaydi" va "agar workerni
// tekshirmoqchi bo'lsang ulanish kaliti yasab bazaga qo'sh".
//
// ── IKKI QISM ───────────────────────────────────────────────
//
//   VERSIYA — eng past ruxsat etilgan. Undan pastdagi ilova
//             serverdan 426 oladi va "yangilang" deb yozadi.
//             Bo'sh qoldirilsa tekshiruv o'chadi.
//
//   KALIT   — serverga faqat ilovadan so'rov kelishini
//             ta'minlaydi. Bo'sh bo'lsa tekshiruv o'chiq.
//
// ── DIQQAT ──────────────────────────────────────────────────
//
// Ikkalasi ham ILOVANI UZIB QO'YISHI mumkin:
//   * versiya juda baland qo'yilsa — hamma eski ilova to'xtaydi;
//   * kalit o'zgartirilsa — eski ilovalarda eski kalit qoladi.
// Shu sabab har ikkisi tasdiq so'raydi va ekranda ogohlantirish
// yozilgan.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/app_build.dart';
import '../services/auth_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

class AdminAppScreen extends StatefulWidget {
  const AdminAppScreen({super.key});

  @override
  State<AdminAppScreen> createState() => _AdminAppScreenState();
}

class _AdminAppScreenState extends State<AdminAppScreen> {
  final _version = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  String? _error;

  String _minVersion = '';

  /// Nechta imzo qabul qilinadi.
  int _sigCount = 0;

  /// SHU ilovaning imzosi (server so'rov sarlavhasidan oladi).
  String _mySig = '';

  /// SHU ilova ro'yxatdami.
  bool _myTrusted = false;

  bool _gateOn = false;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${AuthService.instance.sessionToken}',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _version.dispose();
    super.dispose();
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        content: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await http
          .get(Uri.parse('$kApiBase/api/admin/app'), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        setState(() {
          _minVersion = '${j['min_version'] ?? ''}';
          _sigCount = ((j['sig_count'] as num?) ?? 0).toInt();
          _mySig = '${j['my_sig'] ?? ''}';
          _myTrusted = j['my_sig_trusted'] == true;
          _gateOn = j['gate_on'] == true;
          _version.text = _minVersion;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Yuklanmadi (${r.statusCode})';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Internet yo\'q';
          _loading = false;
        });
      }
    }
  }

  Future<void> _post(Map<String, dynamic> body, String done) async {
    setState(() => _busy = true);
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/admin/app'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() => _busy = false);
      if (r.statusCode != 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _say('${j['error'] ?? 'Saqlanmadi'}');
        return;
      }
      _say(done);
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _say('Internet yo\'q');
    }
  }

  Future<bool> _confirm(String title, String note) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Glass(
          borderRadius: 22,
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 8),
              Text(
                note,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.orange.shade300,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Yo\'q'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent),
                      child: const Text('Ha'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return ok == true;
  }

  Future<void> _saveVersion() async {
    final v = _version.text.trim();
    if (v == _minVersion) return;
    final ok = await _confirm(
      v.isEmpty
          ? 'Versiya tekshiruvi o\'chirilsinmi?'
          : 'Eng past versiya "$v" bo\'lsinmi?',
      v.isEmpty
          ? 'Har qanday versiyadagi ilova ishlaydi.'
          : 'Bundan PAST versiyadagi ilovalar darhol to\'xtaydi.',
    );
    if (!ok) return;
    await _post({'min_version': v}, v.isEmpty ? 'O\'chirildi' : 'Saqlandi');
  }

  /// Shu ilovaning imzosini ishonchlilar ro'yxatiga qo'shadi.
  ///
  /// Eskilari JOYIDA QOLADI: aks holda yangi APK tarqatilguncha
  /// hamma uzilib qolardi.
  Future<void> _trustMe() async {
    final ok = await _confirm(
      'Shu ilovaga ishonilsinmi?',
      'Bundan keyin server FAQAT shunday imzolangan ilovalarga '
      'javob beradi. Ilgari qo\'shilgan imzolar ham ishlaydi.',
    );
    if (!ok) return;
    await _post({'trust_me': true}, 'Qo\'shildi');
  }

  /// Faqat shu imzoni qoldiradi.
  Future<void> _onlyMe() async {
    final ok = await _confirm(
      'Faqat shu ilova qolsinmi?',
      'Boshqa imzoli ilovalar SHU ZAHOTI ishlamay qoladi. Yangi '
      'APK hamma tarqatilganiga ishonch hosil qiling.',
    );
    if (!ok) return;
    await _post({'only_me': true}, 'Faqat shu ilova qoldi');
  }

  /// Tekshiruvni butunlay o'chiradi.
  Future<void> _clearSigs() async {
    final ok = await _confirm(
      'Imzo tekshiruvi o\'chirilsinmi?',
      'Serverga tashqaridan ham so\'rov yuborish mumkin bo\'ladi.',
    );
    if (!ok) return;
    await _post({'clear': true}, 'O\'chirildi');
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('Ilova va xavfsizlik',
              style: TextStyle(color: Colors.white, fontSize: 18)),
        ),
        body: SafeArea(
          top: false,
          child: _loading
              ? Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppColors.accent),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  children: [
                    if (_error != null) ...[
                      Text(_error!,
                          style: TextStyle(
                              color: Colors.red.shade300, fontSize: 13)),
                      const SizedBox(height: 12),
                    ],

                    // ── HOZIRGI HOLAT ─────────────────────────
                    Glass(
                      borderRadius: 18,
                      blur: 14,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _row('Bu ilova versiyasi',
                              kAppVersion.isEmpty ? '—' : kAppVersion),
                          const SizedBox(height: 8),
                          _row('Eng past ruxsat etilgan',
                              _minVersion.isEmpty ? 'tekshirilmaydi' : _minVersion),
                          const SizedBox(height: 8),
                          _row(
                            'Himoya',
                            _gateOn ? 'YOQILGAN' : 'o\'chiq',
                            color: _gateOn
                                ? const Color(0xFF7BD88F)
                                : Colors.orange.shade300,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),

                    // ── VERSIYA ───────────────────────────────
                    _label('ENG PAST VERSIYA'),
                    const SizedBox(height: 8),
                    Glass(
                      borderRadius: 16,
                      blur: 14,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 4),
                      child: TextField(
                        controller: _version,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 15),
                        inputFormatters: [
                          // Faqat versiya belgilari: raqam, nuqta
                          // va `+`. Boshqa belgi tushsa server
                          // baribir rad etardi.
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.+]')),
                          LengthLimitingTextInputFormatter(20),
                        ],
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: '0.0.9  yoki  0.0.9+9',
                          hintStyle: TextStyle(
                              color: Colors.white.withValues(alpha: 0.35)),
                          prefixIcon: const Icon(Icons.tag_rounded,
                              color: Colors.white54),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Shu va undan KATTA versiyalar ishlaydi. Bo\'sh '
                      'qoldirilsa tekshiruv o\'chadi.\n'
                      '`0.0.9` = `0.0.9+0`, ya\'ni `0.0.9+9` ham o\'tadi.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.42),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: _busy ? null : _saveVersion,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        backgroundColor: AppColors.accent,
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Saqlash',
                              style:
                                  TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 24),

                    // ── ILOVA IMZOSI ──────────────────────────
                    _label('ILOVA HAQIQIYLIGI'),
                    const SizedBox(height: 8),
                    Glass(
                      borderRadius: 16,
                      blur: 14,
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _row(
                            'Qabul qilinadigan imzolar',
                            _sigCount == 0 ? 'yo\'q' : '$_sigCount ta',
                          ),
                          const SizedBox(height: 8),
                          _row(
                            'Shu ilova',
                            _mySig.isEmpty
                                ? 'imzo kelmadi'
                                : (_myTrusted ? 'ISHONCHLI' : 'ro\'yxatda yo\'q'),
                            color: _mySig.isEmpty
                                ? Colors.orange.shade300
                                : (_myTrusted
                                    ? const Color(0xFF7BD88F)
                                    : Colors.orange.shade300),
                          ),
                          if (_mySig.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            SelectableText(
                              _mySig,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                height: 1.4,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Imzo APK\'ni qanday kalit bilan imzolanganidan '
                      'kelib chiqadi va uni ilova O\'ZI tanlay olmaydi — '
                      'tizim beradi. Kimdir ilovani o\'zgartirib qayta '
                      'yig\'sa, u boshqa kalit bilan imzolanadi va '
                      'server uni rad etadi.\n\n'
                      'Hech narsa ko\'chirib yozish shart emas: siz shu '
                      'ilovadan turib "Shu ilovaga ishonish"ni bosasiz.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.42),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (!_myTrusted && _mySig.isNotEmpty)
                      FilledButton.icon(
                        onPressed: _busy ? null : _trustMe,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 46),
                          backgroundColor: AppColors.accent,
                        ),
                        icon: const Icon(Icons.verified_user_rounded, size: 19),
                        label: const Text('Shu ilovaga ishonish',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    if (_sigCount > 1 && _myTrusted) ...[
                      OutlinedButton(
                        onPressed: _busy ? null : _onlyMe,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 46),
                          foregroundColor: Colors.orange.shade300,
                          side: BorderSide(
                              color: Colors.orange.shade300
                                  .withValues(alpha: 0.4)),
                        ),
                        child: const Text('Faqat shu ilova qolsin'),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_gateOn) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _busy ? null : _clearSigs,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 46),
                          foregroundColor: Colors.red.shade300,
                          side: BorderSide(
                              color:
                                  Colors.red.shade300.withValues(alpha: 0.4)),
                        ),
                        child: const Text('Tekshiruvni o\'chirish'),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(
          t,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      );

  Widget _row(String k, String v, {Color? color}) => Row(
        children: [
          Expanded(
            child: Text(
              k,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 13,
              ),
            ),
          ),
          Text(
            v,
            style: TextStyle(
              color: color ?? Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
}
