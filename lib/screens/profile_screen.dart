import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../services/image_cache.dart';

import '../services/admin_badges.dart';
import '../services/app_build.dart';
import '../services/auth_service.dart';
import '../services/billing_service.dart';
import '../services/format.dart';
import '../services/net_meter.dart';
import '../services/stats_service.dart';
import '../services/sync_queue.dart';
import '../services/storage_janitor.dart';
import '../services/storage_usage.dart';
import '../services/traffic_service.dart';
import '../services/user_stats.dart';
import '../widgets/aru_logo.dart';
import '../widgets/glass.dart';
import 'billing_screen.dart';
import '../widgets/telegram_logo.dart';
import '../services/support_service.dart';
import 'admin_screen.dart';
import 'support_chat_screen.dart';
import 'profile_edit_screen.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';
import 'stat_detail_screen.dart';
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
            colors: [AppColors.telegramLight, AppColors.telegram],
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.telegram.withValues(alpha: 0.34),
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

  /// HISOBDAN CHIQISH — AVVAL MA'LUMOTLAR SAQLANADI.
  ///
  /// TALAB (foydalanuvchi): "hisobdan chiqqanda telefondagi
  /// ma'lumotlar Turso'ga yozilsin; nima bo'layotgani va progress
  /// chizig'i ko'rsatilsin, 100% da esa 'sinxronlandi, sizni
  /// ilovamizda kutib qolamiz' degan xabar chiqsin".
  ///
  /// Internet bo'lmasa chiqish BLOKLANMAYDI: navbat hisobning
  /// papkasida qoladi va o'sha hisobga qaytilganda yuboriladi.
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
    if (yes != true || !context.mounted) return;

    final outcome = await showDialog<TaskOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TaskDialog(
        title: 'Ma\'lumotlar saqlanmoqda',
        doneTitle: 'Hammasi saqlandi',
        doneText: 'Ma\'lumotlaringiz sinxronlandi.\n'
            'Sizni ilovamizda kutib qolamiz!',
        anywayLabel: 'Baribir chiqish',
        run: (onStep) async {
          final r = await AuthService.instance.syncBeforeLogout(onStep: onStep);
          return switch (r) {
            SyncResult.done => null,
            SyncResult.noAccount => null,
            SyncResult.offline =>
              'Internet yo\'q — ma\'lumotlar telefonda saqlanadi va '
                  'keyingi kirishingizda yuboriladi.',
          };
        },
      ),
    );
    if (outcome == TaskOutcome.cancel || outcome == null) return;
    await AuthService.instance.logout();
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

    // O'chirish ham, tozalash ham progress chizig'i bilan
    // ko'rsatiladi (foydalanuvchi talabi).
    await showDialog<TaskOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TaskDialog(
        title: 'Ma\'lumotlar tozalanmoqda',
        doneTitle: 'Hisob o\'chirildi',
        doneText: 'Barcha ma\'lumotlaringiz tozalandi.\n'
            'Yaxshi qoling!',
        run: (onStep) =>
            AuthService.instance.deleteAccount(onStep: onStep),
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
                            // ── ISM ─────────────────────────
                            //
                            // TOPILGAN XATO (foydalanuvchi:
                            // "obuna olganini bildiradigan
                            // belgisini boshqa joyga o'tkaz, ismi
                            // ko'rinmayapti").
                            //
                            // PREMIUM belgisi ism bilan bitta
                            // qatorda turardi va o'ng tomonda
                            // tahrirlash tugmasi ham bor —
                            // natijada ismga atigi bir necha
                            // harflik joy qolar, "ARUmedia"
                            // "A..." bo'lib ko'rinardi.
                            //
                            // Endi ism butun qatorni oladi, belgi
                            // esa pastda, ID yonida turadi.
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
                                      color: AppColors.textDim, fontSize: 15)),
                            ],
                            const SizedBox(height: 8),
                            // ID cho'zinchoq aylana ichida — uning
                            // ISTALGAN joyiga bosilsa nusxalanadi.
                            //
                            // TOPILGAN XATO (foydalanuvchi:
                            // "premium belgisi rasm ustiga qo'y,
                            // ID ko'rinmayapti"). Belgi shu
                            // qatorda turardi va uzun ID raqamini
                            // bosib qo'yardi. Endi u PROFIL RASMI
                            // ustida (`_Avatar`), ya'ni hech
                            // qanday yozuvga tegmaydi.
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
          // ── OBUNA VA BALANS ──────────────────────────────────
          //
          // TALAB (foydalanuvchi): "profil ma'lumotlari va shaxsiy
          // statistika orasiga 'Obuna olish va Balans to'ldirish'
          // degan eniga cho'zilgan bitta uzun tugma qo'sh".
          const _BillingButton(),
          const SizedBox(height: 12),
          // ── SHAXSIY STATISTIKA (2x2) ─────────────────────────
          //
          // Rasm va balans TAGIDA: nechta anime ko'rgan (bo'lim
          // emas — asosiy anime bo'yicha), nechta qism, necha soat
          // va qancha trafik sarflagan.
          const _MyStatsGrid(),
          const SizedBox(height: 12),
          const _TrafficBox(),
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
                // ── SOZLAMALAR ────────────────────────────────
                //
                // TALAB (foydalanuvchi): "bu narsalarni boshqalar
                // ko'rishi uchun foydalanuvchi sozlamalar
                // panelidan ruxsat berib chiqishi kerak".
                //
                // Ilgari bu tugma bosilmasdi — ochiladigan ekran
                // yo'q edi.
                _ProfileTile(
                  icon: Icons.settings_rounded,
                  label: 'Sozlamalar',
                  onTap: () => _open(context, const SettingsScreen()),
                ),
                _divider(),
                _ProfileTile(
                  icon: Icons.devices_rounded,
                  label: 'Qurilmalar',
                  onTap: () => _open(context, const SessionsScreen()),
                ),
                _divider(),
                // ── ADMIN BILAN BOG'LANISH ────────────────────
                //
                // TALAB (foydalanuvchi): "profil sahifasiga admin
                // bilan bog'lanadigan chat qo'sh ... xabar
                // o'qilmagan bo'lsa profil sahifasida nuqta yonib
                // tursin".
                //
                // Nuqta FAQAT sonni so'raydigan kichik so'rovdan
                // keladi (`support_service.dart` -> `UnreadBadge`).
                _ProfileTile(
                  icon: Icons.support_agent_rounded,
                  label: 'Admin bilan bog\'lanish',
                  trailing: const _UnreadDot(),
                  onTap: () => _open(context, const SupportChatScreen()),
                ),
                _divider(),
                const _ProfileTile(
                    icon: Icons.info_outline_rounded, label: 'Ilova haqida'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── Admin paneli tugmasi ─────────────────────────────────────
          //
          // TOPILGAN XATO: bu tugma HAMMAGA ko'rinardi. Endi u
          // faqat adminga chiqadi. Belgini SERVER beradi
          // (Telegram raqamiga qarab) — ya'ni ilovani
          // o'zgartirish bilan panelga kirib bo'lmaydi: har bir
          // admin so'rovi serverda ham tekshiriladi.
          // ── ADMIN PANELI: IKKI SHART ──────────────────────
          //
          // TALAB (foydalanuvchi): "ikkita build qil, bittasida
          // admin paneliga tegishli kodlar bo'lmasin".
          //
          // `kAdminBuild` — `const`, ya'ni build paytida ma'lum.
          // `false` bo'lsa Dart kompilyatori butun shu shoxni
          // tashlab yuboradi va `AdminScreen` ga boradigan yo'l
          // qolmaydi — u bilan birga admin ekranlari ham APK'dan
          // chiqib ketadi.
          //
          // `user.isAdmin` esa SERVER bergan belgi: adminli
          // build'ni boshqa odam o'rnatsa ham panel ko'rinmaydi.
          // Haqiqiy to'siq baribir serverda — har admin so'rovi
          // o'sha yerda qayta tekshiriladi.
          if (kAdminBuild && user.isAdmin)
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
                  // ── O'QILMAGAN XABAR NUQTASI ──────────────
                  //
                  // TALAB (foydalanuvchi): "adminga xabar
                  // kelganda ... faqat admin paneli ustida
                  // chiqsin".
                  //
                  // Xabar aslida SHU YERGA keladi: adminning
                  // sanog'i barcha foydalanuvchilar bilan
                  // yozishmalardagi o'qilmaganlar yig'indisi.
                  const _AdminUnreadDot(),
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

// ══════════════════════════════════════════════════════════════
//  JARAYON OYNASI — PROGRESS CHIZIG'I BILAN
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "hisobdan chiqqanda nima bo'layotgani va
// progress chizig'i ko'rsatilsin; chiziq 100% ga yetganda
// ma'lumotlar sinxronlangani va 'sizni ilovamizda kutib qolamiz'
// degan xabar chiqsin. Hisobni o'chirishda ham xuddi shunday —
// ma'lumotlar tozalanayotgani ko'rsatilsin".
//
// Bitta oyna ikkala holatga ham xizmat qiladi: farqi faqat
// sarlavha, tugagandagi xabar va xato holatidagi tugmalarda.
//
// Oyna YOPILMAYDI (`barrierDismissible: false` va orqaga tugmasi
// bloklangan): jarayon o'rtasida tasodifan yopilib qolmasin.
class _TaskDialog extends StatefulWidget {
  /// Ishlayotgan paytdagi sarlavha.
  final String title;

  /// Tugagandagi sarlavha va matn.
  final String doneTitle;
  final String doneText;

  /// Ishning o'zi. `null` qaytarsa — muvaffaqiyat, aks holda
  /// xato matni. `onStep` bosqich nomi va 0..1 ulushni beradi.
  final Future<String?> Function(void Function(String, double) onStep) run;

  /// Xato bo'lganda ko'rsatiladigan "baribir davom etish"
  /// tugmasining nomi. `null` bo'lsa tugma chiqmaydi.
  final String? anywayLabel;

  const _TaskDialog({
    required this.title,
    required this.doneTitle,
    required this.doneText,
    required this.run,
    this.anywayLabel,
  });

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

/// Oynadan qaytadigan javob.
enum TaskOutcome {
  /// Ish muvaffaqiyatli tugadi.
  done,

  /// Xato bo'ldi, lekin foydalanuvchi "baribir davom etish" dedi.
  anyway,

  /// Foydalanuvchi bekor qildi.
  cancel,
}

class _TaskDialogState extends State<_TaskDialog> {
  double _progress = 0;
  String _step = '';
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
      _step = '';
    });
    String? err;
    try {
      err = await widget.run((step, p) {
        if (!mounted) return;
        setState(() {
          _step = step;
          // Chiziq ORQAGA ketmaydi — bu "nimadir buzildi" degan
          // taassurot beradi.
          if (p > _progress) _progress = p.clamp(0.0, 1.0);
        });
      });
    } catch (e) {
      // Kutilmagan xato oynani ABADIY qotirib qo'ymasligi kerak:
      // foydalanuvchi hech bo'lmasa bekor qila olsin.
      err = 'Kutilmagan xato: $e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) _progress = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ok = !_busy && _error == null;
    return PopScope(
      // Jarayon o'rtasida orqaga tugmasi ishlamaydi.
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(
          ok ? widget.doneTitle : widget.title,
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(
                  _error != null ? Colors.orangeAccent : AppColors.accent,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? (ok ? widget.doneText : _step),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                height: 1.45,
              ),
            ),
            if (!ok && _error == null) ...[
              const SizedBox(height: 6),
              Text(
                '${(_progress * 100).round()}%',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 8, bottom: 4),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white38,
                ),
              ),
            ),
          if (ok)
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(TaskOutcome.done),
              child: const Text('Yopish',
                  style: TextStyle(color: AppColors.accent)),
            ),
          if (!_busy && _error != null) ...[
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(TaskOutcome.cancel),
              child: const Text('Bekor qilish'),
            ),
            TextButton(
              onPressed: _start,
              child: const Text('Qayta urinish',
                  style: TextStyle(color: Colors.white70)),
            ),
            if (widget.anywayLabel != null)
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(TaskOutcome.anyway),
                child: Text(widget.anywayLabel!,
                    style: const TextStyle(color: AppColors.accent)),
              ),
          ],
        ],
      ),
    );
  }
}

/// Qizil ("xavfli") amal tugmasi — chiqish va o'chirish uchun
/// bir xil ko'rinish beradi.
/// ── OBUNA VA BALANS TUGMASI ──────────────────────────────────
///
/// TALAB (foydalanuvchi): "agar foydalanuvchi balansida pul bo'lsa
/// obuna oynasi ochiladi, agar yo'q bo'lsa to'ldirish oynasi
/// ochiladi".
///
/// Shu sabab tugma bosilganda `BillingScreen` qaysi oynadan
/// boshlanishini balans hal qiladi.
// ══════════════════════════════════════════════════════════════
//  PREMIUM BELGISI
// ══════════════════════════════════════════════════════════════
//
// Obunasi FAOL bo'lgan odamning ismi yonida turadigan kichik
// belgi. Obuna yo'q bo'lsa umuman joy egallamaydi.
//
// Manba — `BillingService`: u serverdan kelgan obuna tugash
// vaqtini saqlaydi, ya'ni belgi ilovada "o'ylab topilmaydi".
class _PremiumBadge extends StatefulWidget {
  /// Rasm ustida turadigan kichraytirilgan ko'rinish.
  final bool compact;

  const _PremiumBadge({this.compact = false});

  @override
  State<_PremiumBadge> createState() => _PremiumBadgeState();
}

class _PremiumBadgeState extends State<_PremiumBadge> {
  @override
  void initState() {
    super.initState();
    // Profil ochilganda obuna holati bir marta so'raladi.
    // `force` YO'Q: holat allaqachon olingan bo'lsa qayta
    // so'ralmaydi (`billing_service.dart` -> `load`).
    unawaited(BillingService.instance.load());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        if (!BillingService.instance.active) {
          return const SizedBox.shrink();
        }
        final c = widget.compact;
        return Padding(
          padding: EdgeInsets.only(left: c ? 0 : 7),
          child: Tooltip(
            message: 'Obuna: ${formatLeft(BillingService.instance.left)}',
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: c ? 6 : 8, vertical: c ? 2.5 : 3),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.gold, AppColors.accent2],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.gold.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.workspace_premium_rounded,
                      size: c ? 11 : 13, color: AppColors.accentTint),
                  SizedBox(width: c ? 2 : 3),
                  Text(
                    'PREMIUM',
                    style: TextStyle(
                      color: AppColors.accentTint,
                      fontSize: c ? 8 : 9.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: c ? 0.2 : 0.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BillingButton extends StatefulWidget {
  const _BillingButton();

  @override
  State<_BillingButton> createState() => _BillingButtonState();
}

/// Obuna tugaydigan aniq sana: `21.09.2026 14:30`.
///
/// TALAB (foydalanuvchi): muddat "aniq qilib" yozilsin. Faqat
/// "2 kun" deyish yetarli emas — odam qaysi kuni tugashini
/// bilishi kerak.
String _subUntilText(int ms) {
  if (ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} '
      '${two(d.hour)}:${two(d.minute)}';
}

class _BillingButtonState extends State<_BillingButton> {
  @override
  void initState() {
    super.initState();
    // Balans va obuna holati fonda olinadi — tugmada darhol
    // ko'rinadi va qaysi oyna ochilishi ham shu bilan hal bo'ladi.
    unawaited(BillingService.instance.load());
  }

  void _open() {
    final b = BillingService.instance;
    // Balansda pul bo'lsa — Obuna, bo'lmasa — To'ldirish.
    //
    // Oynalar tartibi almashtirilgan (foydalanuvchi talabi), shu
    // sabab raqamlar ham almashdi: 0 — To'ldirish, 1 — Obuna.
    final start = b.balance > 0 ? 1 : 0;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, __, ___) => BillingScreen(startPage: start),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        final b = BillingService.instance;
        return GestureDetector(
          onTap: _open,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.accent, AppColors.accent2],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.28),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            // ── OBUNA MUDDATI YOZUVNING TAGIDA ────────────
            //
            // TALAB (foydalanuvchi): "obuna tugash vaqti aniq
            // qilib yozuv tagida bo'lishi kerak — hozirgisida
            // qancha vaqt qolgani aniq yozilmagan va balans
            // to'ldirish yozuvi ustida turibdi".
            //
            // Ilgari o'ng chetda tor belgi bor edi va u yozuvni
            // qisqartirib qo'yardi ("Obuna olish va Balans
            // to'l..."). Endi belgi olib tashlandi: yozuv to'liq
            // sig'adi, muddat esa TAGIDA to'liq ko'rinishda —
            // aniq sana va qancha qolgani.
            child: Row(
              children: [
                const Icon(Icons.workspace_premium_rounded,
                    size: 20, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Obuna olish va Balans to\'ldirish',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        b.active
                            ? 'Obuna ${_subUntilText(b.until)} gacha'
                            : 'Obuna yo\'q',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (b.active) ...[
                        const SizedBox(height: 1),
                        // Har soniyada yangilanadi (`SubCountdown`):
                        // kun qolgan bo'lsa "2 kun 05:12:33".
                        const SubCountdown(
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right_rounded,
                    size: 20, color: Colors.white70),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Foydalanuvchining O'Z statistikasi — ikkitadan kataklar.
///
/// Ochiladigan kataklar (Qismlar, Bo'limlar, Sevimlilar,
/// Baholangan, Izohlar) bosilganda o'sha statistikaning to'liq
/// ro'yxati chiqadi (`StatDetailScreen`).
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
    // Xotira endi shu to'rtlikda ko'rsatiladi (Trafik esa pastdagi
    // keng oynaga ko'chdi — foydalanuvchi talabi).
    unawaited(StorageUsageService.instance.refresh());
  }

  @override
  Widget build(BuildContext context) {
    // ── XOTIRA VA TRAFIK O'RNINI ALMASHDI ───────────────────
    //
    // TALAB (foydalanuvchi): "profildagi Xotira va Trafik
    // statistikalarining o'rnini almashtir: xotirada faqat xotira
    // ko'rsatilsin, trafikda esa nimaga qancha trafik ketgani
    // aniq qilib ko'rsatilsin".
    //
    // Ya'ni bu to'rtlikda endi XOTIRA (bitta umumiy raqam), keng
    // oynada esa TRAFIK toifalari turadi (`_TrafficBox`).
    return AnimatedBuilder(
      animation: Listenable.merge([
        MyStatsService.instance,
        TrafficService.instance,
        StorageUsageService.instance,
        AuthService.instance,
      ]),
      builder: (context, _) {
        final s = MyStatsService.instance.stats;
        final storage = StorageUsageService.instance;
        final me = AuthService.instance.user?.id ?? 0;

        // ── QAYSI KATAK QAYERGA OLIB BORADI ─────────────────
        //
        // TALAB (foydalanuvchi): "qismlar, sevimlilar, bo'limlar,
        // baholangan, kommentariya statistikalari ustiga bossa
        // o'sha statistikaga tegishli oyna ochilishi kerak.
        // Anime statistikasini hech kim ko'ra olmaydi".
        //
        // Ya'ni Anime va Tomosha vaqti — oddiy raqam, qolganlari
        // ochiladi (`StatKind.openable`).
        void open(StatKind kind) {
          if (me <= 0 || !kind.openable) return;
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => StatDetailScreen(
                userId: me,
                kind: kind,
                isMe: true,
              ),
            ),
          );
        }

        Widget box(StatKind kind, IconData icon, String value) => _StatBox(
              icon: icon,
              label: kind.label,
              value: value,
              onTap: kind.openable ? () => open(kind) : null,
            );

        // Ikkitadan qator qilib chiqaramiz — ekran kengligi
        // qat'iy emas, kataklar teng bo'linadi.
        Widget row(Widget a, Widget b) => Row(
              children: [
                Expanded(child: a),
                const SizedBox(width: 12),
                Expanded(child: b),
              ],
            );

        return Column(
          children: [
            row(
              box(StatKind.anime, Icons.movie_filter_rounded,
                  formatCount(s.animes)),
              box(StatKind.episodes, Icons.play_circle_outline_rounded,
                  formatCount(s.episodes)),
            ),
            const SizedBox(height: 12),
            row(
              box(StatKind.seasons, Icons.grid_view_rounded,
                  formatCount(s.seasons)),
              box(StatKind.favorites, Icons.bookmark_rounded,
                  formatCount(s.favorites)),
            ),
            const SizedBox(height: 12),
            row(
              box(StatKind.rated, Icons.star_rounded, formatCount(s.rated)),
              box(StatKind.comments, Icons.mode_comment_rounded,
                  formatCount(s.comments)),
            ),
            const SizedBox(height: 12),
            row(
              box(StatKind.watch, Icons.schedule_rounded,
                  '${formatHours(s.watchMs)} soat'),
              _StatBox(
                icon: Icons.sd_storage_rounded,
                // Xotira SERVERDA yo'q — u faqat shu telefonga
                // tegishli, shu sabab `StatKind` ro'yxatida ham
                // yo'q va hech qachon boshqalarga ko'rinmaydi.
                label: 'Xotira',
                value: storage.measured
                    ? formatBytes(storage.usage.totalBytes)
                    : '—',
              ),
            ),
          ],
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  TRAFIK OYNASI
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "trafikda nimaga qancha trafik ketgani
// aniq qilib ko'rsatilsin".
//
// O'ng yuqorida JAMI trafik, tagida bitta ko'p rangli chiziq va
// toifalar ro'yxati (kattasidan kichigiga):
//
//   ● Videolar        1,20 GB   93.10%
//   ● Rasmlar          6,2 MB    0.48%
//   ● Ma'lumotlar      420 KB    0.03%
//
// ── JAMI QAYERDAN OLINADI ────────────────────────────────────
//
// Serverdagi raqam (`users_db.traffic_bytes`) + ilovada hozircha
// yuborilmagan yig'indi. Sabab (eski talab): hisobot sutkada bir
// marta ketadi, lekin ko'rsatkich kutib turmasligi kerak.
//
// Toifalar esa FAQAT telefonda ma'lum: serverda bitta umumiy son
// turadi, u nimaga ketganini bilmaydi. Shu sabab toifalar
// yig'indisi jamidan KAM bo'lishi mumkin (masalan ilova qayta
// o'rnatilgan). O'sha farq "Oldingi hisob" qatoriga tushadi —
// foizlar har doim 100% ni beradi.

class _TrafficBox extends StatefulWidget {
  const _TrafficBox();

  @override
  State<_TrafficBox> createState() => _TrafficBoxState();
}

class _TrafficBoxState extends State<_TrafficBox> {
  static const String _kOlder = 'Oldingi hisob';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
        [MyStatsService.instance, TrafficService.instance],
      ),
      builder: (context, _) {
        // ── JAMI RAQAM: IKKI MANBANING KATTASI ──────────────
        //
        // TOPILGAN XATO (foydalanuvchi: "megabayt hisoblash
        // avvalgidek to'g'ri ishlamayapti"): tepadagi jami raqam
        // SERVERDAN (+ hali yuborilmagan qism) olinardi, pastdagi
        // taqsimot esa TELEFONDAGI umrbod hisobdan. Ikkovi har xil
        // manba — telefondagisi kattaroq bo'lib qolsa, foizlar
        // 100% dan oshib ketardi (ekranda "70,9 MB — 100.00%"
        // bo'lib, jami esa 70,3 MB bo'lib turardi).
        //
        // Endi jami — ikkovining KATTASI. Shunda foiz hech qachon
        // 100 dan oshmaydi, server oldinda bo'lsa esa farq
        // "Oldingi hisob" qatoriga tushadi (avvalgidek).
        final synced = MyStatsService.instance.stats.traffic +
            TrafficService.instance.pendingBytes;
        var known = 0;
        TrafficService.instance.totals.forEach((_, b) {
          if (b > 0) known += b;
        });
        final total = synced > known ? synced : known;
        final rows = _rows(total);
        return Glass(
          borderRadius: 18,
          blur: 14,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.cloud_download_rounded,
                      size: 15, color: AppColors.accent),
                  const SizedBox(width: 6),
                  Text(
                    'Trafik',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatBytes(total),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _StackedBar(slices: rows, colorOf: trafficColorOf),
              const SizedBox(height: 12),
              if (rows.isEmpty)
                Text(
                  'Hozircha trafik sarflanmagan',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                )
              else
                for (final row in rows) ...[
                  _UsageRow(
                    color: trafficColorOf(row.label),
                    label: row.label,
                    size: formatBytes(row.bytes),
                    percent: _pct(total > 0 ? row.bytes / total : 0),
                  ),
                  if (row != rows.last) const SizedBox(height: 7),
                ],
            ],
          ),
        );
      },
    );
  }

  /// Toifalar ro'yxati (kattasidan kichigiga) + "Oldingi hisob".
  List<StorageSlice> _rows(int total) {
    final out = <StorageSlice>[];
    var known = 0;
    TrafficService.instance.totals.forEach((label, bytes) {
      if (bytes <= 0) return;
      known += bytes;
      out.add(StorageSlice(label, bytes));
    });
    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    // Serverdagi raqam telefondagi taqsimotdan katta bo'lsa (ilova
    // qayta o'rnatilgan, boshqa qurilmadan ko'rilgan) — farq
    // alohida qator bo'ladi.
    final rest = total - known;
    if (rest > 0 && known > 0) out.add(StorageSlice(_kOlder, rest));
    // Taqsimot umuman bo'lmasa, jami raqamning o'zi bitta qator
    // bo'lib turadi — oyna bo'sh ko'rinmasin.
    if (out.isEmpty && total > 0) out.add(StorageSlice(_kOlder, total));
    return out;
  }
}

/// Trafik toifalarining ranglari.
const Map<String, Color> _kTrafficColors = {
  TrafficKind.video: AppColors.accent,
  TrafficKind.image: AppColors.gold,
  TrafficKind.api: AppColors.success,
};

Color trafficColorOf(String label) =>
    _kTrafficColors[label] ?? AppColors.textFaint;

/// `12,34%` — ikki kasr xona (foydalanuvchi ko'rsatgan ko'rinish).
String _pct(double share) {
  final v = (share.isNaN ? 0.0 : share * 100).clamp(0.0, 100.0);
  return '${v.toStringAsFixed(2)}%';
}

/// Hamma toifa bitta chiziqda, har biri o'z rangida.
class _StackedBar extends StatelessWidget {
  final List<StorageSlice> slices;
  final Color Function(String label) colorOf;

  const _StackedBar({required this.slices, required this.colorOf});

  @override
  Widget build(BuildContext context) {
    var total = 0;
    for (final s in slices) {
      total += s.bytes;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 7,
        child: total <= 0
            ? ColoredBox(color: Colors.white.withValues(alpha: 0.10))
            : Row(
                children: [
                  for (final slice in slices)
                    Expanded(
                      // Juda kichik toifa ham ko'rinib tursin
                      // (aks holda chiziq "bo'sh" bo'lib qolardi).
                      flex: (slice.bytes / total * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: colorOf(slice.label)),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Bitta qator: "● Videolar        2,0 MB   50.00%".
class _UsageRow extends StatelessWidget {
  final Color color;
  final String label;
  final String size;
  final String percent;

  const _UsageRow({
    required this.color,
    required this.label,
    required this.size,
    required this.percent,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 12.5,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          size,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          // Foizlar bir tekis turadi — ro'yxat "sakramaydi".
          width: 58,
          child: Text(
            percent,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatBox extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  /// Bo'sh bo'lsa katak oddiy raqam bo'lib qoladi (Anime, Xotira,
  /// Tomosha vaqti). Aks holda bosilganda o'sha statistikaning
  /// oynasi ochiladi.
  final VoidCallback? onTap;

  const _StatBox({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = _box(context);
    if (onTap == null) return box;
    return GlassTappable(onTap: onTap!, child: box);
  }

  Widget _box(BuildContext context) {
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
    // `image_picker` rasmni ilovaning vaqtinchalik papkasiga
    // nusxalaydi. Baytlar o'qib bo'lindi — nusxa endi keraksiz.
    unawaited(StorageJanitor.dropPicked(picked.path));
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
            cacheManager: AppImageCache.manager,
            imageUrl: user.photoUrl,
            width: _size,
            height: _size,
            fit: BoxFit.cover,
            // Avatar ekranda `_size` dp — xotirada ham shuncha
            // tursin. Telegram avatarlari 640 px keladi, ya'ni
            // cheklanmasa 100 dp lik doira uchun ~1,6 MB bekorga
            // ushlab turilardi.
            memCacheWidth: (_size * 3).round(),
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
            // ── PREMIUM BELGISI RASM USTIDA ──────────────────
            //
            // TALAB (foydalanuvchi): "premium belgisi rasm ustiga
            // qo'y, ID ko'rinmayapti".
            //
            // Yuqori o'rtada: pastki o'ng burchakda rasm
            // almashtirish tugmasi turibdi, ikkovi to'qnashmasin.
            // Obuna yo'q bo'lsa belgi umuman chizilmaydi.
            const Positioned(
              left: 0,
              right: 0,
              top: 3,
              child: Center(child: _PremiumBadge(compact: true)),
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

/// O'qilmagan xabar bo'lsa yonadigan nuqta.
///
/// Ekran ochilganda va har 30 soniyada bir marta so'raladi —
/// so'rov juda kichik (faqat son), shu sabab bu arzon. Ilova
/// fon'da turganda esa hech narsa so'ralmaydi.
class _UnreadDot extends StatefulWidget {
  const _UnreadDot();

  @override
  State<_UnreadDot> createState() => _UnreadDotState();
}

class _UnreadDotState extends State<_UnreadDot> {
  @override
  void initState() {
    super.initState();
    // Sahifa ochilganda darhol bir marta. Doimiy yangilash esa
    // `root_screen.dart` da, butun ilova uchun bitta taymerda —
    // aks holda ikkovi ham so'rab, so'rovlar ikki barobar
    // bo'lardi.
    UnreadBadge.instance.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: UnreadBadge.instance,
      builder: (context, _) {
        // Adminda chiqmaydi: uning sanog'i BARCHA suhbatlarniki
        // bo'lib, bu qatorga (o'z yozishmasiga) aloqasi yo'q.
        // Foydalanuvchi talabi — nuqta faqat admin paneli
        // tugmasida chiqsin.
        if (!UnreadBadge.instance.hasForUser) {
          return const SizedBox.shrink();
        }
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: AppColors.accent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.6),
                blurRadius: 7,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Admin paneli tugmasidagi qizil nuqta.
///
/// `_UnreadDot` dan farqi: bu FAQAT adminda yonadi, u esa faqat
/// oddiy foydalanuvchida (`support_service.dart` -> `UnreadBadge`
/// izohiga qarang). Ikkovi hech qachon bir vaqtda ko'rinmaydi.
///
/// ── FAQAT XABAR EMAS ───────────────────────────────────────
///
/// TALAB (foydalanuvchi): "admin paneliga yangilik kelsa, ya'ni
/// shikoyat, support, yangi foydalanuvchi va boshqa narsalar
/// kelganda admin paneli tugmasida qizil nuqta yonib tursin".
///
/// Shu sabab nuqta `AdminBadges` ga qaraydi — u uchala manbani
/// (shikoyat, yozishma, yangi hisob) bitta so'rovda oladi.
class _AdminUnreadDot extends StatelessWidget {
  const _AdminUnreadDot();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          [UnreadBadge.instance, AdminBadges.instance]),
      builder: (context, _) {
        if (!UnreadBadge.instance.isAdmin || !AdminBadges.instance.any) {
          return const SizedBox.shrink();
        }
        return Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: AppColors.accent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.6),
                blurRadius: 7,
              ),
            ],
          ),
        );
      },
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

  /// O'ng tomondagi qo'shimcha belgi (masalan o'qilmagan nuqtasi).
  /// Berilmasa oddiy ">" strelkasi turadi.
  final Widget? trailing;

  const _ProfileTile({
    required this.icon,
    required this.label,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) ...[trailing!, const SizedBox(width: 6)],
          const Icon(Icons.chevron_right_rounded, color: Colors.white38),
        ],
      ),
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
