import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/auth_service.dart';
import '../widgets/aru_logo.dart';
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
            // Kirishdan OLDIN ham ilova o'zini tanitib tursin.
            const AruLogo(height: 38),
            const SizedBox(height: 40),
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
          // ── PROFIL KARTASI ────────────────────────────────────
          //
          // Karta ENIGA TO'LIQ — pastdagi kartalar bilan bir xil.
          // Ilgari hamma narsa markazga, ustma-ust terilgan edi va
          // karta ensiz ko'rinardi.
          //
          // Chapda katta rasm, o'ngida esa ustma-ust: ism,
          // @username, ID va balans.
          Glass(
            borderRadius: 20,
            blur: 16,
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Avatar(user: user),
                // Rasm bilan yozuvlar orasi kengaytirildi — yozuvlar
                // biroz o'ngroqda turadi.
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        user.fullName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700),
                      ),
                      if (user.username.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text('@${user.username}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Color(0xFF6BC7F0), fontSize: 13.5)),
                      ],
                      const SizedBox(height: 6),
                      // ID panjarasiz (`#` belgisisiz) va ramkasiz —
                      // oddiy qator sifatida, yonida nusxalash
                      // tugmasi bilan.
                      _IdRow(id: user.id),
                      const SizedBox(height: 3),
                      Text('Balans: ${user.balance}',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.62),
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── TUGMALAR TARTIBI (foydalanuvchi belgilagan) ───────
          //   1. Bildirishnoma
          //   2. Sozlamalar
          //   3. Qurilmalar
          //   4. Ilova haqida
          Glass(
            borderRadius: 20,
            blur: 16,
            child: Column(
              children: [
                const _ProfileTile(
                    icon: Icons.notifications_none_rounded,
                    label: 'Bildirishnoma'),
                _divider(),
                const _ProfileTile(
                    icon: Icons.settings_rounded, label: 'Sozlamalar'),
                _divider(),
                _ProfileTile(
                  icon: Icons.devices_rounded,
                  label: 'Qurilmalar',
                  onTap: () => _open(context, const SessionsScreen()),
                ),
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
                    child: Text('Accountdan chiqish',
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

/// ID qatori — yonida nusxalash tugmasi bilan.
///
/// Foydalanuvchi ID'sini qo'lda ko'chirib yozishga majbur
/// bo'lmasin: bosilsa buferga tushadi va "Nusxalandi" deb chiqadi.
class _IdRow extends StatelessWidget {
  final int id;
  const _IdRow({required this.id});

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: '$id'));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        duration: const Duration(milliseconds: 1400),
        content: const Text('Nusxalandi',
            style: TextStyle(color: Colors.white)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        color: Colors.white.withValues(alpha: 0.62),
        fontSize: 13,
        fontWeight: FontWeight.w600);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('ID: $id', style: style),
        const SizedBox(width: 6),
        // `InkWell` emas, `GestureDetector` + kattaroq bosish
        // maydoni: tugma kichkina ko'rinadi, lekin barmoq bilan
        // bemalol bosiladi.
        GestureDetector(
          onTap: () => _copy(context),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Icon(Icons.copy_rounded,
                size: 14, color: Colors.white.withValues(alpha: 0.55)),
          ),
        ),
      ],
    );
  }
}

/// PROFIL RASMI.
///
/// Ikki manbadan keladi (workerdagi `user_public` ga qarang):
/// foydalanuvchi o'zi tanlagan rasm (B2) yoki Telegram avatari.
/// Ikkalasi ham worker manzili orqali beriladi — Telegram fayl
/// manzilida bot tokeni bo'lgani uchun u hech qachon ilovaga
/// berilmaydi. Rasm bo'lmasa bosh harflar chiqadi.
///
/// RASM USTIGA BOSILSA galereya ochiladi va tanlangan rasm yangi
/// profil rasmi bo'ladi (eskisi B2'dan butunlay o'chiriladi).
class _Avatar extends StatefulWidget {
  final AppUser user;
  const _Avatar({required this.user});

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> {
  static const double _size = 96;
  bool _busy = false;

  Future<void> _change() async {
    if (_busy) return;

    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // Profil rasmi katta bo'lishi shart emas: kichraytirish
        // yuklashni tezlashtiradi va B2'da joy tejaydi.
        maxWidth: 720,
        maxHeight: 720,
        imageQuality: 88,
      );
    } catch (_) {
      if (mounted) _say('Galereyani ochib bo\'lmadi');
      return;
    }
    if (picked == null || !mounted) return;

    setState(() => _busy = true);
    final bytes = await picked.readAsBytes();
    final err = await AuthService.instance.updateAvatar(bytes);
    if (!mounted) return;
    setState(() => _busy = false);
    _say(err ?? 'Profil rasmi yangilandi');
  }

  void _say(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        content: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;

    final fallback = Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      color: Colors.white24,
      child: Text(
        user.initials,
        style: const TextStyle(
            color: Colors.white, fontSize: 32, fontWeight: FontWeight.w600),
      ),
    );

    final image = user.photoUrl.isEmpty
        ? fallback
        : CachedNetworkImage(
            imageUrl: user.photoUrl,
            width: _size,
            height: _size,
            fit: BoxFit.cover,
            placeholder: (_, __) => fallback,
            errorWidget: (_, __, ___) => fallback,
          );

    return GestureDetector(
      onTap: _change,
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          children: [
            ClipOval(child: image),
            // Yuklanayotganda rasm ustida aylana chiqadi va ikkinchi
            // marta bosish ta'sir qilmaydi (`_busy`).
            if (_busy)
              ClipOval(
                child: Container(
                  width: _size,
                  height: _size,
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white),
                  ),
                ),
              ),
            // "Bosish mumkin" ekanini ko'rsatuvchi kichik belgi.
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.card, width: 2),
                ),
                child: const Icon(Icons.photo_camera_rounded,
                    size: 13, color: Colors.white),
              ),
            ),
          ],
        ),
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
