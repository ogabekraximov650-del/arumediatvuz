import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../services/admin_badges.dart';
import '../services/app_build.dart';
import '../services/auth_service.dart';
import '../services/support_service.dart';
import '../services/season_info.dart';
import '../services/ui_state.dart';
import '../services/downloads_index.dart';
import '../services/watch_history.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'admin_screen.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'catalog_screen.dart';
import 'library_screen.dart';
import 'profile_screen.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

/// `IndexedStack` dagi Katalog sahifasining raqami.
const int _catalogTab = 2;

class _RootScreenState extends State<RootScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _index = 0;

  // ── PASTKI PANELDAGI "SUZUVCHI" TUGMA HOLATI ─────────────────
  //
  // Sahifa DARHOL almashadi (`IndexedStack` — pastdagi izohga
  // qarang), harakatlanadigan yagona narsa shu qiymat: tugma
  // bosilganda u eski o'rindan yangisiga silliq suzib boradi.
  // Pushti tugma ham, belgilar kattalashishi ham, yozuvlar
  // ochilishi ham aynan shunga bog'langan.
  final ValueNotifier<double> _navPos = ValueNotifier<double>(0);

  // ── SUZISH `AnimationController` BILAN EMAS ──────────────────
  //
  // `AnimationController` vaqtni HAQIQIY soat bo'yicha o'lchaydi.
  // Telefon bir kadrni 300 ms chizsa, keyingi kadrda u darhol
  // o'sha 300 ms ga SAKRAYDI — ya'ni qisqa suzish butunlay yeb
  // ketiladi va ekranda "birdan o'tdi" bo'lib ko'rinadi. Aynan
  // shu sabab kuchsiz telefonda suzish ko'rinmasdi.
  //
  // Bu yerda esa har kadrda o'tgan vaqt QO'LDA qo'shiladi va u
  // 32 ms bilan CHEGARALANADI (`_maxFrameMs`). Qotish bo'lsa
  // suzish shuncha vaqtga cho'ziladi, lekin HECH QACHON
  // sakramaydi: tugma har doim oradagi hamma belgini birin-ketin
  // kattalashtirib o'tadi.
  late final Ticker _navTicker;
  Timer? _unreadTimer;
  double _navFrom = 0;
  double _navTo = 0;

  /// Suzish qay darajada bajarildi: 0 dan 1 gacha.
  double _navT = 1;

  /// Joriy suzishning davomiyligi (millisekundda).
  double _navMs = 300.0;

  /// Oldingi kadr vaqti. `null` — suzish endi boshlandi.
  Duration? _navLastTick;

  @override
  void initState() {
    super.initState();
    // Ilova fonga chiqib qaytganda hisob holatini tekshirish uchun
    // (masalan 5-qurilma kirgan bo'lsa, bu qurilma chegaradan
    // chiqarilgan bo'lishi mumkin).
    WidgetsBinding.instance.addObserver(this);
    _navTicker = createTicker(_onNavTick);

    // ── O'QILMAGAN XABARLAR NUQTASI ──────────────────────────
    //
    // Taymer AYNAN shu yerda: nuqta ham pastki paneldagi "Profil"
    // tugmasida, ham profil sahifasida, ham admin panelida
    // ko'rinadi. Ilgari u profil sahifasining ichida edi va
    // "sahifa qurilganmi" degan tasodifga bog'liq bo'lib qolardi.
    //
    // So'rov juda kichik — faqat SON qaytadi (`/api/chat/unread`).
    //
    // 30 -> 12 soniya: yozishma ekrani OCHIQ bo'lmaganda ham
    // nuqta tez yonsin (foydalanuvchi: "supportga yuborilgan
    // xabar tez kelmayapti"). Suhbatning O'ZI ochiq turganda
    // esa umuman kutilmaydi — u yerda uzoq kutish ishlaydi
    // (`ChatController._watchLoop`).
    unawaited(UnreadBadge.instance.refresh());
    _unreadTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) {
        UnreadBadge.instance.refresh();
        _refreshAdminBadges();
      },
    );
    _refreshAdminBadges();

    // ── ADMIN PANELIGA QAYTISH ───────────────────────────────
    //
    // Rasm yoki video tanlash paytida tizim ilovani yopib qo'ygan
    // bo'lsa, foydalanuvchi qaytganda O'SHA joyda turishi kerak
    // (foydalanuvchi talabi). Belgi diskda turadi —
    // `UiState` izohiga qarang.
    // `kAdminBuild` — `const`: admin paneli bo'lmagan build'da
    // kompilyator butun shu shoxni tashlab yuboradi
    // (`app_build.dart` izohiga qarang).
    if (kAdminBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !UiState.takeAdminRestore()) return;
        // Belgi diskda qolib ketgan bo'lsa ham panel faqat
        // adminga ochiladi.
        if (AuthService.instance.user?.isAdmin != true) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AdminScreen()),
        );
      });
    }
  }

  /// ── ADMIN PANELIDAGI YANGILIKLAR ────────────────────────
  ///
  /// TALAB (foydalanuvchi): "admin paneliga yangilik kelsa
  /// (shikoyat, support, yangi foydalanuvchi) admin paneli
  /// tugmasida qizil nuqta yonib tursin".
  ///
  /// So'rov FAQAT adminga ketadi: oddiy foydalanuvchida server
  /// baribir 403 qaytaradi va bekorga tarmoqqa chiqishning
  /// ma'nosi yo'q. Adminlikni ilova o'zi taxmin qilmaydi —
  /// `UnreadBadge` serverdan kelgan belgini eslab qoladi
  /// (`support_service.dart` izohiga qarang).
  void _refreshAdminBadges() {
    // Admin paneli yo'q build'da bu so'rov umuman kerak emas.
    if (!kAdminBuild || !UnreadBadge.instance.isAdmin) return;
    unawaited(AdminBadges.instance.refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Javob kutilmaydi — sessiya bekor qilingan bo'lsa
    // AuthService o'zi xabar beradi va profil yangilanadi.
    AuthService.instance.refresh();
    // Fon'dan qaytdi — admin javob yozgan bo'lsa nuqta yonsin.
    unawaited(UnreadBadge.instance.refresh());
    _refreshAdminBadges();
    // Telegramdan qaytdi. Foydalanuvchi u yerda START bosgan
    // bo'lsa, sessiya serverda allaqachon ochilgan — saqlangan
    // token bilan bir marta so'rasak, hisob o'zi ochiladi.
    // Kirish ekrani ochiq bo'lmasa ham ishlaydi.
    AuthService.instance.resumePendingLogin();
  }

  // ── YANGI HISOBDA ENDI HECH NARSA SO'RALMAYDI ────────────────
  //
  // Ilgari birinchi kirishda majburiy oyna ochilar va u ism bilan
  // username kiritilmaguncha yopilmasdi.
  //
  // TALAB O'ZGARDI: yangi hisobga nomni SERVER o'zi qo'yadi —
  // bazada band bo'lmagan eng kichik raqamdan `User 7` (ism) va
  // `user_7` (username). Ya'ni foydalanuvchi START bosgan zahoti
  // ilovaga kiradi, hech narsa to'ldirmaydi.
  //
  // Nomni o'zgartirmoqchi bo'lsa — profil kartasidagi tahrirlash
  // tugmasi (`ProfileEditScreen`).

  @override
  void dispose() {
    _unreadTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _navTicker.dispose();
    _navPos.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════
  //  SAHIFA DARHOL, TUGMA SEKIN
  // ═══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "bosishim bilan o'sha sahifaga o'tishi
  // kerak, lekin tugmani kattalashtiradigan narsa birozgina
  // sekinroq va silliq, ketma-ket tugmalarni kattalashtirib
  // o'tishi kerak".
  //
  // Ya'ni ikkovi BIR-BIRIDAN MUSTAQIL:
  //   • sahifa — bosilgan zahoti (`IndexedStack` indeksi);
  //   • pushti tugma — o'z yo'lini sekin bosib o'tadi.
  //
  // ── NEGA ILGARI "BIRDAN O'TIB" KETARDI ─────────────────────
  //
  // Ikkita sabab bor edi va ikkovi ham tuzatildi.
  //
  // 1. SAHIFA AYNAN SUZISH PAYTIDA QURILARDI. `PageView` +
  //    `jumpToPage` yangi sahifani BIRINCHI marta o'sha damda
  //    quradi (`initState`, ro'yxatlar, rasm vidjetlari) va
  //    kuchsiz telefonda bu bir necha kadr qotish beradi.
  //    Endi `IndexedStack`: BARCHA sahifalar ilova ochilganda
  //    bir marta quriladi va keyin faqat qaysi biri
  //    ko'rinishi almashadi — tugma bosilganda quriladigan ish
  //    UMUMAN QOLMAYDI.
  //
  // 2. ANIMATSIYA VAQTNI HAQIQIY SOAT BO'YICHA O'LCHARDI.
  //    `AnimationController` shunday ishlaydi: bitta kadr 300 ms
  //    chizilsa, keyingi kadrda u darhol o'sha 300 ms ga
  //    sakraydi — qisqa suzish esa butunlay yeb ketiladi.
  //    Endi vaqt QO'LDA qo'shiladi va har kadrda eng ko'pi
  //    `_maxFrameMs` qo'shiladi (`_onNavTick`). Qotish bo'lsa
  //    suzish shunchaki cho'ziladi, lekin sakrab o'tmaydi.
  //
  // ── TEZLIK ─────────────────────────────────────────────────
  //
  // Bitta tugma oralig'iga 280 ms. Bosh sahifadan profilga
  // (4 oraliq) ~1,1 soniya — tugma oradagi Qidiruv, Katalog va
  // Kutubxona belgilarini birin-ketin kattalashtirib o'tadi.
  static const double _msPerStep = 280.0;

  /// Bitta kadrda eng ko'pi shuncha millisekund qo'shiladi.
  ///
  /// 32 ms — sekin qurilmadagi ikkita oddiy kadr. Undan uzun
  /// qotish suzishni ilgarilatmaydi.
  static const double _maxFrameMs = 32.0;

  /// Ekran kengligi bo'yicha davomiylik ko'paytmasi.
  ///   ~360 dp (kichik telefon) -> 1.20 (sekinroq, silliqroq)
  ///   ~600 dp (katta telefon)  -> 1.00
  ///   ~900 dp (planshet)       -> 0.90
  ///
  /// Kichik ekranda tugma bosib o'tadigan MASOFA qisqa, shu sabab
  /// bir xil vaqt u yerda "shosha-pisha" ko'rinadi.
  double _speedFactor(double width) {
    if (width <= 0) return 1.0;
    final f = 600 / width;
    if (f < 0.90) return 0.90;
    if (f > 1.20) return 1.20;
    return f;
  }

  void _onNavTick(Duration elapsed) {
    final last = _navLastTick;
    _navLastTick = elapsed;
    // Birinchi kadrda faqat vaqt belgilanadi — suzish keyingi
    // kadrdan boshlanadi.
    if (last == null) return;

    var dt = (elapsed - last).inMicroseconds / 1000.0;
    if (dt > _maxFrameMs) dt = _maxFrameMs;

    _navT += dt / _navMs;
    if (_navT >= 1) {
      _navT = 1;
      _navTicker.stop();
      _navLastTick = null;
    }

    // `easeInOutSine`: silliq boshlanib, silliq tugaydi, lekin
    // o'rtasida "otilib" ketmaydi. `easeInOutCubic` sinab
    // ko'rilgan edi — u o'rtasida o'rtacha tezlikdan IKKI BAROBAR
    // tez ketardi va aynan shu "uchib o'tdi" hissini bergan.
    final e = Curves.easeInOutSine.transform(_navT);
    _navPos.value = _navFrom + (_navTo - _navFrom) * e;
  }

  /// Kutubxona nechanchi tugma (tomosha tarixi shu yerda).
  static const int _libraryTab = 3;

  void _onTabTap(int i) {
    if (i == _index) return;

    // ── 1. SAHIFA DARHOL ALMASHADI ──────────────────────────
    setState(() => _index = i);

    // ── TOMOSHA TARIXI AYNAN SHU YERDA YUKLANADI ────────────
    //
    // Kutubxona sahifasi ilova ochilganda birga quriladi, shu
    // sabab uning o'zida yuklab bo'lmaydi — foydalanuvchi
    // kutubxonani ochmasa ham serverga so'rov ketardi. Bu yerda
    // esa so'rov faqat tugma BOSILGANDA ketadi va ro'yxat 60
    // soniya "yangi" hisoblangani uchun ketma-ket ochishlarda
    // takrorlanmaydi.
    if (i == _libraryTab) {
      WatchHistory.instance.load();
      // Sevimlilar ro'yxati ham shu yerda — oyna ochilganda emas,
      // aynan tugma bosilganda (ortiqcha so'rov ketmasin).
      FavoritesService.instance.load();
      // Yuklanmalar ro'yxati DISKDAN yig'iladi (tarmoq kerak emas),
      // lekin u ham faqat kerak bo'lganda yangilanadi.
      unawaited(DownloadsIndex.instance.refresh());
    }

    // ── 2. TUGMA ESA SEKIN SUZIB BORADI ─────────────────────
    //
    // Suzish TUGAGAN o'rindan emas, HOZIRGI o'rindan boshlanadi:
    // oldingi suzish tugamagan bo'lsa ham tugma sakramaydi.
    _navFrom = _navPos.value;
    _navTo = i.toDouble();
    _navT = 0;
    _navLastTick = null;

    final steps = (_navTo - _navFrom).abs();
    final ms = steps * _msPerStep * _speedFactor(MediaQuery.sizeOf(context).width);
    _navMs = ms < 320.0 ? 320.0 : (ms > 1400.0 ? 1400.0 : ms);

    if (!_navTicker.isTicking) _navTicker.start();
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: SafeArea(
          bottom: false,
          // ── NEGA `PageView` EMAS, `IndexedStack` ──────────────
          //
          // TALAB: sahifa bosilgan zahoti almashsin (suzish,
          // slayd, barmoq bilan surish — hech qaysisi kerak emas).
          // Aynan shu ish uchun `IndexedStack` yaratilgan.
          //
          // Ilgari `PageView` + `NeverScrollableScrollPhysics` +
          // `jumpToPage` ishlatilardi. Farqi kichkina ko'rinadi,
          // lekin muhim: `PageView` sahifani BIRINCHI marta
          // o'tilgan damda quradi va kuchsiz telefonda bu bir
          // necha kadr qotish beradi — o'sha paytda pastdagi
          // tugmaning suzishi ham yeb ketilardi.
          //
          // `IndexedStack` esa BARCHA sahifalarni ilova
          // ochilganda bir marta quradi va keyin faqat qaysi biri
          // ko'rinishini almashtiradi. Ya'ni tugma bosilganda
          // quriladigan ish umuman qolmaydi va suzish to'liq
          // ko'rinadi.
          //
          // Qurilish narxi: Bosh sahifadan boshqa to'rttasi yengil
          // (Qidiruv, Katalog, Kutubxona, Profil hech qanday
          // tarmoq so'rovi bilan boshlanmaydi), shu sabab ilova
          // ochilishiga sezilarli ta'sir qilmaydi.
          //
          // `StackFit.expand` — sahifalar butun ekranni egallashi
          // uchun SHART: `IndexedStack` standart holatda bolalarga
          // "iloji boricha kichik bo'l" deydi.
          child: IndexedStack(
            index: _index,
            sizing: StackFit.expand,
            children: const [
              HomeScreen(),
              SearchScreen(),
              CatalogScreen(),
              LibraryScreen(),
              ProfileScreen(),
            ],
          ),
        ),
        // ── PANEL VA UNGA YOPISHGAN TUGMA ────────────────────
        //
        // TALAB (foydalanuvchi): "Filtrlash tugmasi pastdagi
        // sahifa tugmalari oynasiga yopishib tursin".
        //
        // Tugma AYNAN shu yerda, panel bilan BITTA ustunda
        // chiziladi — ya'ni orasidagi masofa hisoblanmaydi,
        // shunchaki 10 nuqta bo'sh joy (`CatalogFilterBar`
        // izohiga qarang). Katalogdan chiqilsa tugma o'zi
        // yo'qoladi.
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Faqat Katalog sahifasida. `IndexedStack` hamma
            // sahifani tirik saqlaydi, ya'ni Katalogdan chiqilsa
            // ham u "men bormar" deb turaveradi — shuning uchun
            // ko'rsatishni SAHIFA RAQAMI hal qiladi.
            if (_index == _catalogTab)
              AnimatedBuilder(
                animation: CatalogFilterBar.instance,
                builder: (context, _) =>
                    CatalogFilterBar.instance.build(context),
              ),
            _BottomNav(
              currentIndex: _index,
              position: _navPos,
              onTap: _onTabTap,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Yangi tezkor pastki navigatsiya ───────────────────────────
// Blur yo'q — faqat Container + BoxShadow. 60fps+ istalgan qurilmada.
/// Pastda tizim tugmalari egallagan jismoniy balandlik (nuqtada).
double systemBottomInset(BuildContext context) {
  var best = 0.0;
  void take(double v) {
    if (v.isFinite && v > best) best = v;
  }

  // 1) Qurilmadan to'g'ridan — eng ishonchli manba.
  final view = View.of(context);
  final dpr = view.devicePixelRatio <= 0 ? 1.0 : view.devicePixelRatio;
  take(view.viewPadding.bottom / dpr);
  take(view.padding.bottom / dpr);
  take(view.systemGestureInsets.bottom / dpr);

  // 2) `MediaQuery` — shu bilan birga QAYTA CHIZISHGA obuna
  //    bo'lamiz (tizim o'lchovi o'zgarsa widget yangilanadi).
  final mq = MediaQuery.maybeOf(context);
  if (mq != null) {
    take(mq.viewPadding.bottom);
    take(mq.padding.bottom);
  }
  return best;
}


/// Pastki navigatsiya paneli EGALLAGAN to'liq balandlik.
///
/// NEGA KERAK: Katalogdagi "Filtrlash" tugmasi shu panelning
/// USTIDA turishi kerak (foydalanuvchi talabi: "sahifa tugmalari
/// oynasi ustida, oynaga yopishgan holda").
///
/// Raqamni qo'lda yozib qo'yish XATO bo'lardi: chekinish
/// qurilmaga qarab o'zgaradi va panel balandligi ham shu yerda
/// bir joyda hisoblanadi. Shu sabab o'lchov MANBASI bitta —
/// panelning o'zi va shu funksiya.
///
///   chekinish + (10 + 52 + 10) + chegara ≈ chekinish + 74
double bottomNavHeight(BuildContext context) {
  final raw = systemBottomInset(context);
  final inset = (raw < 26 ? 26.0 : raw) + 12;
  return inset + 74;
}

/// Ikonka va uning o'ng yuqorisidagi kichik nuqta.
///
/// Nuqta ikonkaning O'LCHAMIGA ta'sir qilmaydi (`Stack` +
/// `clipBehavior: none`), ya'ni yonidagi tugmalar qimirlamaydi.
class _IconWithDot extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool dot;

  const _IconWithDot({
    required this.icon,
    required this.color,
    required this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: 22, color: color),
        if (dot)
          Positioned(
            right: -2,
            top: -1,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
                // Panelning o'zi ham qizg'ish bo'lishi mumkin —
                // oq halqa nuqtani har qanday fonda ajratib turadi.
                border: Border.all(color: Colors.white, width: 1.4),
              ),
            ),
          ),
      ],
    );
  }
}

class _BottomNav extends StatefulWidget {
  final int currentIndex;

  /// Suzuvchi tugmaning joriy o'rni (0..4 oralig'idagi kasr son).
  final ValueListenable<double> position;
  final ValueChanged<int> onTap;

  const _BottomNav({
    required this.currentIndex,
    required this.position,
    required this.onTap,
  });

  @override
  State<_BottomNav> createState() => _BottomNavState();
}

class _BottomNavState extends State<_BottomNav>
    with WidgetsBindingObserver {
  // ── TIZIM CHEKINISHI QURILMADAN TO'G'RIDAN O'QILADI ───────
  //
  // TOPILGAN SABAB (foydalanuvchi: "sahifa tugmalari yana telefon
  // tugmasining orqasiga o'tib qoldi").
  //
  // `MediaQuery.of(context)` — bu DARAXTDAN meros qolgan qiymat.
  // Uni yo'l-yo'lakay har qanday `SafeArea`, `Scaffold` yoki
  // `MediaQuery.removePadding` KESIB tashlashi mumkin, va o'sha
  // holatda pastki chekinish NOL bo'lib keladi. Pleyer
  // `immersiveSticky` dan qaytganda esa qiymat bir necha kadr
  // ESKI bo'lib turadi.
  //
  // `View.of(context)` esa meros emas — u qurilmaning O'ZIDAN
  // keladi va hech kim uni kesa olmaydi. Shuning uchun endi
  // asosiy o'lchov shundan olinadi, `MediaQuery` esa faqat
  // qo'shimcha tekshiruv sifatida qoladi.
  //
  // `didChangeMetrics` — tizim paneli ko'rinishi o'zgargan
  // zahoti qayta chizadi, ya'ni pleyerdan qaytilganda panel
  // o'z joyiga darhol ko'tariladi.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  static const _items = [
    (icon: Icons.home_rounded, label: 'Bosh sahifa'),
    (icon: Icons.search_rounded, label: 'Qidiruv'),
    (icon: Icons.grid_view_rounded, label: 'Katalog'),
    (icon: Icons.folder_rounded, label: 'Kutubxona'),
    (icon: Icons.person_rounded, label: 'Profil'),
  ];

  @override
  Widget build(BuildContext context) {
    // Chekinish qurilmadan olinadi (`_systemInset` izohiga qarang).
    //
    // Eng kam 26 nuqta — chekinish umuman kelmagan qurilmada ham
    // panel ekran chetiga yopishib qolmasin. Ustiga 12 nuqta
    // qo'shiladi: foydalanuvchi talabi "biroz yuqoriga ko'tar".
    final raw = systemBottomInset(context);
    final inset = (raw < 26 ? 26.0 : raw) + 12;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AppColors.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.40),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ValueListenableBuilder<double>(
          valueListenable: widget.position,
          builder: (context, page, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = constraints.maxWidth / _items.length;

                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Suzuvchi accent pill
                    Positioned(
                      left: page * itemWidth + 4,
                      top: 0,
                      bottom: 0,
                      width: itemWidth - 8,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [AppColors.accent, AppColors.accent2],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accent.withValues(alpha: 0.35),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Tugmalar
                    Row(
                      children: List.generate(_items.length, (i) {
                        final distance = (page - i).abs().clamp(0.0, 1.0);
                        final t = 1.0 - distance;
                        final scale = 1.0 + 0.22 * t;
                        final color = Color.lerp(
                          Colors.white.withValues(alpha: 0.40),
                          Colors.white,
                          t,
                        )!;

                        return Expanded(
                          child: GestureDetector(
                            onTap: () => widget.onTap(i),
                            behavior: HitTestBehavior.opaque,
                            child: SizedBox(
                              height: 52,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // ── O'QILMAGAN XABAR NUQTASI ──
                                  //
                                  // TALAB (foydalanuvchi): "admin
                                  // foydalanuvchiga xabar yuborgan
                                  // bo'lsa profil TUGMASINING ustida
                                  // ham nuqta yonib turishi kerak",
                                  // va admin uchun ham xuddi shunday.
                                  //
                                  // Manba bitta (`UnreadBadge`), ya'ni
                                  // profil sahifasidagi nuqta bilan
                                  // bu nuqta hech qachon bir-biriga
                                  // zid bo'lib qolmaydi.
                                  //
                                  // ── ADMINDA CHIQMAYDI ──────────
                                  //
                                  // TALAB (foydalanuvchi): "adminga
                                  // xabar kelganda support chat va
                                  // profil tugmasida qizil nuqta
                                  // chiqmasin, faqat admin paneli
                                  // ustida chiqsin".
                                  //
                                  // Adminning sanog'i — BARCHA
                                  // suhbatlardagi o'qilmaganlar
                                  // yig'indisi, ya'ni uning O'Z
                                  // yozishmasiga aloqasi yo'q.
                                  // Shu sabab `hasForUser`
                                  // (`support_service.dart` izohiga
                                  // qarang).
                                  Transform.scale(
                                    scale: scale,
                                    child: _items[i].label == 'Profil'
                                        ? AnimatedBuilder(
                                            animation: UnreadBadge.instance,
                                            builder: (context, child) =>
                                                _IconWithDot(
                                              icon: _items[i].icon,
                                              color: color,
                                              dot: UnreadBadge
                                                  .instance.hasForUser,
                                            ),
                                          )
                                        : Icon(_items[i].icon,
                                            size: 22, color: color),
                                  ),
                                  // ── YOZUV HAM SILLIQ OCHILADI ──
                                  //
                                  // Ilgari yozuv `if (t > 0.5)` bilan
                                  // BIRDANIGA paydo bo'lib, birdaniga
                                  // yo'qolardi. Suzuvchi tugma silliq
                                  // siljib borayotgan bo'lsa ham,
                                  // ko'zga aynan shu sakrash tashlanar
                                  // va o'tish "birdaniga" bo'lib
                                  // tuyulardi.
                                  //
                                  // Endi yozuv `t` bilan birga ochiladi:
                                  // `heightFactor` balandligini, `Opacity`
                                  // esa ko'rinishini bosqichma-bosqich
                                  // o'zgartiradi.
                                  ClipRect(
                                    child: Align(
                                      alignment: Alignment.topCenter,
                                      heightFactor: t,
                                      child: Opacity(
                                        opacity: t,
                                        child: Padding(
                                          padding:
                                              const EdgeInsets.only(top: 3),
                                          child: Text(
                                            _items[i].label,
                                            maxLines: 1,
                                            // Ensiz ekranda yozuv
                                            // qisqartiriladi — chetga
                                            // chiqib ketmaydi.
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: color,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
