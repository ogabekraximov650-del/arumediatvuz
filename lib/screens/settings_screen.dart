// lib/screens/settings_screen.dart — SOZLAMALAR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "sozlamalardan avvalgi yashirish tugmasini olib
// tashla va o'rniga HAR BITTA statistika uchun alohida yashirish
// tugmalarini qo'yib chiq. Barcha accountda statistika OCHIQ
// turadi va foydalanuvchi qo'lda statistikalarni sozlamalardan
// yashirib chiqishi kerak va qaysi statistika yashirilgani bazada
// ham saqlanishi kerak".
//
// ── ODATIY HOLAT ENDI "OCHIQ" ───────────────────────────────
//
// Ilgari bitta tugma bor edi va u odatda O'CHIQ turardi (hech
// kim hech narsani ko'rmasdi). Endi teskari: yangi hisobda
// hamma statistika ochiq, odam esa keraksizini bittalab
// yashiradi. Yashirilganlar ro'yxati `users_db.hidden_stats` da.
//
// ── HAQIQIY TO'SIQ SERVERDA ─────────────────────────────────
//
// Bu yerdagi tugmalar shunchaki sozlamani yuboradi. Yashirilgan
// statistika javobga UMUMAN qo'shilmaydi va uning ro'yxati 403
// bilan qaytadi (`public_profile` va `user_stats_list` izohlariga
// qarang), ya'ni ilovani o'zgartirish bilan boshqaning
// ma'lumotini ko'rib bo'lmaydi.
//
// BALANS ESA HECH QACHON KO'RINMAYDI: u faqat egasiga va
// adminga. Hech qanday sozlama uni ochmaydi.

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/user_stats.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Sozlamalarda ko'rinadigan tugmalar — har bir statistika uchun
/// bittadan, tushuntirishi bilan.
const List<({StatKind kind, IconData icon, String hint})> _rows = [
  (
    kind: StatKind.anime,
    icon: Icons.movie_filter_rounded,
    hint: 'Nechta anime ko\'rganingiz'
  ),
  (
    kind: StatKind.episodes,
    icon: Icons.play_circle_outline_rounded,
    hint: 'Nechta qism ko\'rganingiz va ularning ro\'yxati'
  ),
  (
    kind: StatKind.seasons,
    icon: Icons.grid_view_rounded,
    hint: 'Ko\'rgan bo\'limlaringiz ro\'yxati'
  ),
  (
    kind: StatKind.favorites,
    icon: Icons.bookmark_rounded,
    hint: 'Sevimlilarga saqlaganlaringiz'
  ),
  (
    kind: StatKind.rated,
    icon: Icons.star_rounded,
    hint: 'Baho bergan bo\'limlaringiz va bergan bahoyingiz'
  ),
  (
    kind: StatKind.comments,
    icon: Icons.mode_comment_rounded,
    hint: 'Yozgan izohlaringiz, javoblari va layklari'
  ),
  (
    kind: StatKind.watch,
    icon: Icons.schedule_rounded,
    hint: 'Jami necha soat tomosha qilganingiz'
  ),
];

class _SettingsScreenState extends State<SettingsScreen> {
  /// Hozir so'rov ketayotgan statistika (bo'sh — hech biri).
  String _busy = '';

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

  /// `visible` — endi KO'RINSINMI. Ya'ni tugma yoqilgan holat
  /// "ko'rinadi", o'chirilgani "yashirilgan".
  Future<void> _toggle(StatKind kind, bool visible) async {
    if (_busy.isNotEmpty) return;
    final now = List<String>.from(
        AuthService.instance.user?.hiddenStats ?? const <String>[]);
    if (visible) {
      now.remove(kind.key);
    } else if (!now.contains(kind.key)) {
      now.add(kind.key);
    }
    setState(() => _busy = kind.key);
    final err = await AuthService.instance.setHiddenStats(now);
    if (!mounted) return;
    setState(() => _busy = '');
    if (err != null) {
      _say(err);
      return;
    }
    _say(visible
        ? '${kind.label} endi boshqalarga ko\'rinadi'
        : '${kind.label} yashirildi');
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
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'Statistikangiz odatda OCHIQ turadi. Keraksizini '
                      'shu yerdan yashirib qo\'ying — yashirilgani '
                      'boshqalarga umuman ko\'rinmaydi.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.42),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final r in _rows) ...[
                    _PrivacyRow(
                      icon: r.icon,
                      title: r.kind.label,
                      hint: r.hint,
                      // Tugma "ko'rinsinmi" degan savolga javob
                      // beradi, shu sabab ro'yxatdagi holat
                      // TESKARISIGA o'giriladi.
                      value: !(u?.isHidden(r.kind.key) ?? false),
                      busy: _busy == r.kind.key,
                      onChanged: (on) => _toggle(r.kind, on),
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'Profil rasmi, ismingiz, username va ID raqamingiz '
                      'har doim ko\'rinadi.\n'
                      'Balansingiz va sarflagan trafigingiz esa HECH '
                      'QACHON boshqalarga ko\'rinmaydi.',
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

/// Bitta statistika qatori: belgi, nom, tushuntirish va tugma.
class _PrivacyRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  final bool value;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _PrivacyRow({
    required this.icon,
    required this.title,
    required this.hint,
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Glass(
      borderRadius: 18,
      blur: 16,
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            // Rasmdagi uslub: apelsin tusli yumaloq kvadratcha,
            // ichida apelsin belgi (oq emas).
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppColors.accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (busy)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white54),
            )
          else
            Switch(
              value: value,
              activeThumbColor: Colors.white,
              activeTrackColor: AppColors.accent,
              onChanged: onChanged,
            ),
        ],
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
