import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/auth_service.dart';
import '../services/format.dart';
import '../services/stats_service.dart';
import '../widgets/aru_logo.dart';
import '../widgets/glass.dart';
import '../widgets/telegram_logo.dart';
import 'admin_screen.dart';
import 'profile_edit_screen.dart';
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

  /// HISOBNI BUTUNLAY O'CHIRISH — IKKI MARTA SO'RALADI.
  ///
  /// Nega ikki marta: bu amalni ORQAGA QAYTARIB BO'LMAYDI —
  /// serverda foydalanuvchi, uning barcha sessiyalari va profil
  /// rasmi o'chib ketadi. Bitta tasodifiy bosish shuncha narsani
  /// yo'q qilmasligi kerak.
  ///
  /// Ikkinchi so'roq birinchisining takrori emas: u OQIBATLARNI
  /// ro'yxat qilib ko'rsatadi va tasdiq tugmasi "Ha, o'chirilsin"
  /// deb ataladi — ya'ni foydalanuvchi nimaga rozi bo'layotganini
  /// aniq ko'radi.
  Future<void> _deleteAccount(BuildContext context) async {
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Accountni o\'chirish',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Accountingizni butunlay o\'chirmoqchimisiz?',
          style: TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Bekor qilish'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Davom etish',
                style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (first != true || !context.mounted) return;

    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Ishonchingiz komilmi?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Bu amalni orqaga qaytarib bo\'lmaydi.\n\n'
          '• Hisobingiz o\'chiriladi\n'
          '• Barcha qurilmalardan chiqarilasiz\n'
          '• Profil rasmingiz o\'chiriladi\n'
          '• Balansingiz yo\'qoladi',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Yo\'q, bekor qilish'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Ha, o\'chirilsin',
                style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (second != true || !context.mounted) return;

    // O'chirish tarmoq orqali ketadi — kutish belgisi ko'rsatiladi.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      ),
    );
    final err = await AuthService.instance.deleteAccount();
    if (!context.mounted) return;
    Navigator.of(context).pop(); // kutish oynasi

    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.card,
          content: Text(err, style: const TextStyle(color: Colors.white)),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        content: Text('Account o\'chirildi',
            style: TextStyle(color: Colors.white)),
      ),
    );
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
            // `Stack`: asosiy tarkib (rasm + yozuvlar) va uning
            // O'NG YUQORI burchagidagi tahrirlash tugmasi.
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _Avatar(user: user),
                    // Rasm bilan yozuvlar orasi yana kengaytirildi —
                    // yozuvlar biroz o'ngroqda turadi.
                    const SizedBox(width: 30),
                    Expanded(
                      // O'ng tomonda tahrirlash tugmasi turibdi —
                      // uzun ism uning tagiga kirib ketmasin.
                      child: Padding(
                        padding: const EdgeInsets.only(right: 34),
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
                                  fontSize: 21,
                                  fontWeight: FontWeight.w700),
                            ),
                            if (user.username.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('@${user.username}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Color(0xFF6BC7F0), fontSize: 15)),
                            ],
                            const SizedBox(height: 8),
                            // ID cho'zinchoq aylana ichida — uning
                            // ISTALGAN joyiga bosilsa nusxalanadi.
                            _IdPill(id: user.id),
                            const SizedBox(height: 6),
                            Text('Balans: ${user.balance}',
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.62),
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // ── TAHRIRLASH TUGMASI ────────────────────────
                //
                // Ism va username endi yangi hisobga AVTOMATIK
                // beriladi (`User 7` / `user_7`), ya'ni ularni
                // o'zgartirish yo'li ko'rinib turishi shart.
                Positioned(
                  top: 0,
                  right: 0,
                  child: _EditButton(
                    onTap: () => _open(context, const ProfileEditScreen()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── SHAXSIY STATISTIKA (2x2) ─────────────────────────
          //
          // Rasm va balans TAGIDA: nechta anime ko'rgan (bo'lim
          // emas — asosiy anime bo'yicha), nechta qism, necha soat
          // va qancha trafik sarflagan.
          const _MyStatsGrid(),
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
          _DangerTile(
            icon: Icons.delete_forever_rounded,
            label: 'Accountni o\'chirish',
            onTap: () => _deleteAccount(context),
          ),
          const SizedBox(height: 16),
          _DangerTile(
            icon: Icons.logout_rounded,
            label: 'Accountdan chiqish',
            onTap: () => _logout(context),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Divider(height: 1, color: Colors.white.withValues(alpha: 0.12));
}

/// Qizil ("xavfli") amal tugmasi — chiqish va o'chirish uchun
/// bir xil ko'rinish beradi.
/// Foydalanuvchining O'Z statistikasi — 2x2 katak.
class _MyStatsGrid extends StatefulWidget {
  const _MyStatsGrid();

  @override
  State<_MyStatsGrid> createState() => _MyStatsGridState();
}

class _MyStatsGridState extends State<_MyStatsGrid> {
  @override
  void initState() {
    super.initState();
    // Avval diskdagi nusxa (darhol ko'rinadi), keyin yangilanadi.
    MyStatsService.instance.loadFromDisk();
    MyStatsService.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MyStatsService.instance,
      builder: (context, _) {
        final s = MyStatsService.instance.stats;
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _StatBox(
                    icon: Icons.movie_filter_rounded,
                    label: 'Anime',
                    value: formatCount(s.animes),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatBox(
                    icon: Icons.play_circle_outline_rounded,
                    label: 'Qism',
                    value: formatCount(s.episodes),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StatBox(
                    icon: Icons.schedule_rounded,
                    label: 'Tomosha vaqti',
                    value: '${formatHours(s.watchMs)} soat',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatBox(
                    icon: Icons.cloud_download_rounded,
                    label: 'Trafik',
                    value: formatBytes(s.traffic),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _StatBox extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatBox({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Glass(
      borderRadius: 18,
      blur: 14,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _DangerTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _DangerTile(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GlassTappable(
      onTap: onTap,
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
              child: Icon(icon, color: AppColors.accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

/// ID — CHO'ZINCHOQ AYLANA ICHIDA.
///
/// TALAB: ID raqami va nusxalash belgisi eniga cho'zilgan aylana
/// (kapsula) bilan o'ralsin va o'sha aylananing ISTALGAN joyiga
/// bosilsa ID nusxalansin.
///
/// NEGA MUHIM: ilgari faqat kichkina nusxalash belgisiga bosish
/// kerak edi — u 14 nuqta kattalikda bo'lgani uchun barmoq bilan
/// urib bo'lmasdi va odam ID'ni qo'lda ko'chirib yozardi. Endi
/// bosish maydoni butun kapsula: ~150x32 nuqta.
class _IdPill extends StatelessWidget {
  final int id;
  const _IdPill({required this.id});

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: '$id'));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        duration: const Duration(milliseconds: 1400),
        content: Text('ID nusxalandi: $id',
            style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _copy(context),
      // `opaque` — kapsulaning ichidagi bo'sh joyga bosilsa ham
      // bosish hisobga olinadi (aks holda faqat yozuv va belgi
      // ustidagi bosish o'tardi).
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          // Kapsula shakli: radius balandlikdan katta bo'lsa,
          // chetlari to'liq yarim doira bo'lib qoladi.
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ID: $id',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 9),
            Icon(Icons.copy_rounded,
                size: 16, color: Colors.white.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

/// Profil kartasining o'ng yuqori burchagidagi tahrirlash tugmasi.
class _EditButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EditButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Icon(Icons.edit_rounded,
            size: 17, color: Colors.white.withValues(alpha: 0.85)),
      ),
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

  /// `null` bo'lsa bo'lim hali tayyor emas — bosilganda shu haqda
  /// aytiladi.
  ///
  /// NEGA: ilgari tayyor bo'lmagan tugmalar bosilganda MUTLAQO
  /// hech narsa bo'lmasdi (`onTap ?? () {}`). Foydalanuvchi uchun
  /// bu "ilova buzuq" degani — u tugmani qayta-qayta bosib
  /// ko'radi. Endi ilova ochiq javob beradi.
  final VoidCallback? onTap;
  const _ProfileTile({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
      onTap: onTap ??
          () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                backgroundColor: AppColors.card,
                duration: const Duration(milliseconds: 1600),
                content: Text('«$label» bo\'limi tez orada qo\'shiladi',
                    style: const TextStyle(color: Colors.white)),
              ),
            );
          },
    );
  }
}
