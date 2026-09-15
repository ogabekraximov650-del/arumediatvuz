// lib/screens/settings_screen.dart — SOZLAMALAR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "foydalanuvchi boshqa profilni ko'rishi mumkin
// bo'lsin, faqat to'liq emas — faqatgina profil surati, nomi va
// usernameni ko'rishga ruxsat berilsin. ID, balans va qolgan
// statistikalar ko'rinmasin. Bu narsalarni boshqalar ko'rishi
// uchun foydalanuvchi sozlamalar panelidan ruxsat berib chiqishi
// kerak".
//
// ── NEGA ODATIY HOLAT "YOPIQ" ───────────────────────────────
//
// Maxfiylik "o'chirib qo'yiladigan" emas, "yoqiladigan" narsa
// bo'lishi kerak. Yangi hisob ochilganda hech kim uning
// statistikasini ko'rmaydi — odam o'zi xohlasa ochadi.
//
// ── HAQIQIY TO'SIQ SERVERDA ─────────────────────────────────
//
// Bu yerdagi tugma shunchaki sozlamani yuboradi. Ruxsat
// berilmagan bo'lsa statistika javobga UMUMAN qo'shilmaydi
// (`public_profile` izohiga qarang), ya'ni ilovani o'zgartirish
// bilan boshqaning ma'lumotini ko'rib bo'lmaydi.
//
// BALANS ESA HECH QACHON KO'RINMAYDI: u faqat egasiga va
// adminga. Sozlama uni ochmaydi.

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

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

  Future<void> _toggleStats(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await AuthService.instance.setShowStats(on);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _say(err);
      return;
    }
    _say(on
        ? 'Statistikangiz endi boshqalarga ko\'rinadi'
        : 'Statistikangiz yashirildi');
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
          title: const Text('Sozlamalar',
              style: TextStyle(color: Colors.white, fontSize: 18)),
        ),
        body: SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: AuthService.instance,
            builder: (context, _) {
              final u = AuthService.instance.user;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                children: [
                  _SectionLabel('MAXFIYLIK'),
                  const SizedBox(height: 8),
                  Glass(
                    borderRadius: 20,
                    blur: 16,
                    padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.bar_chart_rounded,
                              color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Statistikam ko\'rinsin',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'ID raqam, nechta anime ko\'rganingiz va '
                                'tomosha vaqtingiz',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_busy)
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white54),
                          )
                        else
                          Switch(
                            value: u?.showStats ?? false,
                            activeThumbColor: Colors.white,
                            activeTrackColor: AppColors.accent,
                            onChanged: _toggleStats,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Odam nima yopiq qolishini ham bilsin — aks
                  // holda "tugmani yoqsam hammasi ko'rinadimi"
                  // degan savol qoladi.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'Profil rasmi, ismingiz va username har doim '
                      'ko\'rinadi.\n'
                      'Balansingiz esa HECH QACHON boshqalarga '
                      'ko\'rinmaydi.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.42),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.35),
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
