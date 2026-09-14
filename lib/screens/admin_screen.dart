import 'package:flutter/material.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import '../services/support_service.dart';
import 'admin_chats_screen.dart';
import 'anime_management_screen.dart';

class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ───────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Glass(
                  borderRadius: 20,
                  blur: 16,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  child: Row(
                    children: [
                      GlassTappable(
                        onTap: () => Navigator.of(context).pop(),
                        child: const Glass(
                          borderRadius: 14,
                          blur: 14,
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.arrow_back_rounded,
                              color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Text('Admin paneli',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                      ),
                      const Icon(Icons.admin_panel_settings_rounded,
                          color: Colors.white54),
                    ],
                  ),
                ),
              ),

              // ── Boshqaruv tugmalari ──────────────────────────────────
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    _AdminButton(
                      icon: Icons.movie_filter_rounded,
                      label: 'Animelarni boshqarish',
                      subtitle: "Qo'shish, tahrirlash, o'chirish",
                      onTap: () => Navigator.of(context).push(
                        PageRouteBuilder(
                          transitionDuration: const Duration(milliseconds: 320),
                          // const olib tashlandi
                          pageBuilder: (_, animation, __) =>
                              AnimeManagementScreen(),
                          transitionsBuilder: (_, animation, __, child) {
                            final curved = CurvedAnimation(
                                parent: animation, curve: Curves.easeOutCubic);
                            return FadeTransition(
                              opacity: curved,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                        begin: const Offset(1, 0),
                                        end: Offset.zero)
                                    .animate(curved),
                                child: child,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // ── BARCHA SUHBATLAR ──────────────────────
                    //
                    // TALAB: "admin paneliga barcha chatlar
                    // bo'limini qo'sh, huddi animelarni boshqarish
                    // bo'limiga kirgandek".
                    //
                    // O'qilmagan xabar bo'lsa tugmada ham soni
                    // ko'rinadi — panelga kirmasdan turib bilinadi.
                    AnimatedBuilder(
                      animation: UnreadBadge.instance,
                      builder: (context, _) {
                        final n = UnreadBadge.instance.count;
                        return _AdminButton(
                          icon: Icons.forum_rounded,
                          label: 'Barcha suhbatlar',
                          subtitle: n > 0
                              ? '$n ta o\'qilmagan xabar'
                              : 'Foydalanuvchilar bilan yozishma',
                          badge: n,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const AdminChatsScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  /// O'qilmaganlar soni (0 — belgi ko'rsatilmaydi).
  final int badge;

  const _AdminButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GlassTappable(
      onTap: onTap,
      child: Glass(
        borderRadius: 20,
        blur: 16,
        tint: 0.12,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55), fontSize: 12)),
                ],
              ),
            ),
            if (badge > 0) ...[
              Container(
                constraints: const BoxConstraints(minWidth: 22),
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  '$badge',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            const Icon(Icons.chevron_right_rounded, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
