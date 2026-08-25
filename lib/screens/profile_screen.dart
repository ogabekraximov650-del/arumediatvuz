import 'package:flutter/material.dart';
import '../widgets/glass.dart';
import 'admin_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      child: Column(
        children: [
          Glass(
            borderRadius: 20,
            blur: 16,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const CircleAvatar(
                  radius: 38,
                  backgroundColor: Colors.white24,
                  child: Icon(Icons.person_rounded, size: 40, color: Colors.white),
                ),
                const SizedBox(height: 12),
                const Text('Mehmon foydalanuvchi',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('Profilni sozlash uchun kiring',
                    style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Glass(
            borderRadius: 20,
            blur: 16,
            child: Column(
              children: [
                _ProfileTile(icon: Icons.settings_rounded, label: 'Sozlamalar'),
                _divider(),
                _ProfileTile(icon: Icons.notifications_none_rounded, label: 'Bildirishnomalar'),
                _divider(),
                _ProfileTile(icon: Icons.info_outline_rounded, label: 'Ilova haqida'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── Admin paneli tugmasi ─────────────────────────────────────
          GlassTappable(
            onTap: () => Navigator.of(context).push(
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 320),
                // const olib tashlandi — pageBuilder lambda ichida const
                // constructor ishlatib bo'lmaydi.
                pageBuilder: (_, animation, __) => AdminScreen(),
                transitionsBuilder: (_, animation, __, child) {
                  final curved = CurvedAnimation(
                      parent: animation, curve: Curves.easeOutCubic);
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
            ),
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
                      color: Colors.white.withOpacity(0.12),
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
                  const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Divider(height: 1, color: Colors.white.withOpacity(0.12));
}

class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String label;
  const _ProfileTile({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
      onTap: () {},
    );
  }
}
