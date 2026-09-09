import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/glass.dart';
import '../widgets/telegram_logo.dart';
import 'admin_screen.dart';
import 'sessions_screen.dart';
import 'telegram_login_screen.dart';

/// PROFIL.
///
/// Kirilmagan bo'lsa — ekranda FAQAT Telegram logotipi va
/// "Telegram orqali kirish" tugmasi bo'ladi, boshqa hech narsa yo'q.
/// Kirilgandan keyin to'liq profil ochiladi.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // AuthService — ChangeNotifier. Kirish/chiqish sodir bo'lishi
    // bilan bu ekran o'zi qayta quriladi; hech qanday qo'shimcha
    // holat boshqaruvi kerak emas.
    return AnimatedBuilder(
      animation: AuthService.instance,
      builder: (context, _) {
        final auth = AuthService.instance;
        // Saqlangan hisob hali o'qilmagan — bir zumga "kirish"
        // ekrani miltillab ketmasligi uchun bo'sh turamiz.
        if (!auth.restored) return const SizedBox.shrink();
        return auth.isLoggedIn
            ? _ProfileBody(user: auth.user!)
            : const _LoginBody();
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  KIRILMAGAN HOLAT — faqat logotip va bitta tugma
// ══════════════════════════════════════════════════════════════

class _LoginBody extends StatelessWidget {
  const _LoginBody();

  Future<void> _login(BuildContext context) async {
    final ok = await Navigator.of(context).push<bool>(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, __, ___) => const TelegramLoginScreen(),
        transitionsBuilder: (_, animation, __, child) {
          final curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 0.06), end: Offset.zero)
                  .animate(curved),
              child: child,
            ),
          );
        },
      ),
    );

    if (ok == true && context.mounted) {
      final name = AuthService.instance.user?.firstName ?? '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.card,
          content: Text(
            name.isEmpty ? 'Xush kelibsiz!' : 'Xush kelibsiz, $name!',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        physics:
            const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 140),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TelegramLogo(size: 116),
            const SizedBox(height: 44),
            _TelegramButton(onTap: () => _login(context)),
          ],
        ),
      ),
    );
  }
}

/// Telegram'ning o'z rangidagi kirish tugmasi.
class _TelegramButton extends StatelessWidget {
  final VoidCallback onTap;
  const _TelegramButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GlassTappable(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2AABEE), Color(0xFF229ED9)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF229ED9).withValues(alpha: 0.34),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TelegramGlyph(size: 20),
            SizedBox(width: 12),
            Text(
              'Telegram orqali kirish',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  KIRILGAN HOLAT
// ══════════════════════════════════════════════════════════════

class _ProfileBody extends StatelessWidget {
  final AppUser user;
  const _ProfileBody({required this.user});

  Future<void> _logout(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Chiqish', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Hisobdan chiqmoqchimisiz?',
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
    if (yes == true) await AuthService.instance.logout();
  }

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, animation, __, child) {
          final curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                      begin: const Offset(0, 0.06), end: Offset.zero)
                  .animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics:
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      child: Column(
        children: [
          Glass(
            borderRadius: 20,
            blur: 16,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                _Avatar(user: user),
                const SizedBox(height: 12),
                Text(
                  user.fullName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600),
                ),
                if (user.username.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('@${user.username}',
                      style: const TextStyle(
                          color: Color(0xFF6BC7F0), fontSize: 13.5)),
                ],
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('ID: #${user.id}',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Glass(
            borderRadius: 20,
            blur: 16,
            child: Column(
              children: [
                _ProfileTile(
                  icon: Icons.devices_rounded,
                  label: 'Kirgan qurilmalar',
                  onTap: () => _open(context, const SessionsScreen()),
                ),
                _divider(),
                const _ProfileTile(
                    icon: Icons.settings_rounded, label: 'Sozlamalar'),
                _divider(),
                const _ProfileTile(
                    icon: Icons.notifications_none_rounded,
                    label: 'Bildirishnomalar'),
                _divider(),
                const _ProfileTile(
                    icon: Icons.info_outline_rounded, label: 'Ilova haqida'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── Admin paneli tugmasi ─────────────────────────────────────
          GlassTappable(
            onTap: () => _open(context, AdminScreen()),
            child: Glass(
              borderRadius: 20,
              blur: 16,
              tint: 0.18,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.admin_panel_settings_rounded,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text('Admin paneli',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      color: Colors.white38),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          GlassTappable(
            onTap: () => _logout(context),
            child: Glass(
              borderRadius: 20,
              blur: 16,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.logout_rounded,
                        color: AppColors.accent, size: 22),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text('Chiqish',
                        style: TextStyle(
                            color: AppColors.accent,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Divider(height: 1, color: Colors.white.withValues(alpha: 0.12));
}

/// Telegram avatari. Rasm worker orqali keladi (`/api/avatar/:id`)
/// — Telegram fayl manzilida bot tokeni bo'lgani uchun u hech
/// qachon ilovaga berilmaydi. Rasm bo'lmasa bosh harflar chiqadi.
class _Avatar extends StatelessWidget {
  final AppUser user;
  const _Avatar({required this.user});

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: 38,
      backgroundColor: Colors.white24,
      child: Text(
        user.initials,
        style: const TextStyle(
            color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600),
      ),
    );

    if (user.photoUrl.isEmpty) return fallback;

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: user.photoUrl,
        width: 76,
        height: 76,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _ProfileTile({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
      onTap: onTap ?? () {},
    );
  }
}
