import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'catalog_screen.dart';
import 'library_screen.dart';
import 'profile_screen.dart';
import 'profile_setup_screen.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _index = 0;
  late final PageController _pageController;

  // ── PASTKI PANELDAGI "SUZUVCHI" TUGMA HOLATI ─────────────────
  // Sahifaning O'ZI sakrab almashadi (`jumpToPage` — pastdagi
  // izohga qarang), harakatlanadigan yagona narsa shu qiymat:
  // tugma bosilganda u eski o'rindan yangisiga 340 ms ichida
  // silliq suzib boradi. Pushti tugma ham, belgilar kattalashishi
  // ham, yozuvlar ochilishi ham aynan shunga bog'langan.
  final ValueNotifier<double> _navPos = ValueNotifier<double>(0);
  late final AnimationController _navAnim;
  Animation<double>? _navTween;
  bool _jumping = false;

  /// Nechanchi suzish ketyapti.
  ///
  /// NEGA KERAK: `forward()` qaytargan `TickerFuture` ning
  /// `whenComplete` chaqirig'i animatsiya BEKOR QILINGANDA ham
  /// ishlaydi. Foydalanuvchi ketma-ket ikki tugmani bossa,
  /// eskisining `whenComplete`'i `stop()` sababli darhol ishga
  /// tushib, tugmani ESKI manzilga sakratib yuborardi. Endi har
  /// bir suzishning o'z raqami bor va faqat oxirgisi yakunlaydi.
  int _navRun = 0;

  @override
  void initState() {
    super.initState();
    // Ilova fonga chiqib qaytganda hisob holatini tekshirish uchun
    // (masalan 5-qurilma kirgan bo'lsa, bu qurilma chegaradan
    // chiqarilgan bo'lishi mumkin).
    WidgetsBinding.instance.addObserver(this);
    // Yangi hisob to'ldirilmagan bo'lsa so'rash oynasini ochish
    // uchun hisob holati kuzatiladi.
    AuthService.instance.addListener(_onAuthChanged);
    _pageController = PageController()..addListener(_onPageScroll);
    // Davomiylik HAR SAFAR yo'lning uzunligiga qarab
    // belgilanadi (`_onTabTap`) — shu sabab bu yerda faqat
    // boshlang'ich qiymat turadi.
    _navAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() {
        final t = _navTween;
        if (t != null) _navPos.value = t.value;
      });

    // Hisob ilova ishga tushishida (runApp'dan OLDIN) tiklanadi,
    // ya'ni yuqoridagi kuzatuvchi hali ulanmagan bo'ladi. Shu
    // sabab bir marta qo'lda ham tekshiriladi.
    _onAuthChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Javob kutilmaydi — sessiya bekor qilingan bo'lsa
    // AuthService o'zi xabar beradi va profil yangilanadi.
    AuthService.instance.refresh();
    // Telegramdan qaytdi. Foydalanuvchi u yerda START bosgan
    // bo'lsa, sessiya serverda allaqachon ochilgan — saqlangan
    // token bilan bir marta so'rasak, hisob o'zi ochiladi.
    // Kirish ekrani ochiq bo'lmasa ham ishlaydi.
    AuthService.instance.resumePendingLogin();
  }

  // ── YANGI HISOB: ISM VA USERNAME SO'RALADI ───────────────────
  //
  // Telegram orqali BIRINCHI marta kirgan foydalanuvchida
  // `profileDone == false` bo'ladi. Oyna aynan shu yerdan
  // ochiladi (profil ekranidan emas): foydalanuvchi kirishdan
  // keyin qaysi sahifada turgan bo'lsa ham so'raladi.
  //
  // `_askingProfile` — oyna IKKI MARTA ochilib qolmasligi uchun:
  // `AuthService` bir necha marta xabar berishi mumkin
  // (saqlangan hisob, keyin serverdan yangilangani).
  bool _askingProfile = false;

  void _onAuthChanged() {
    if (!mounted || _askingProfile) return;
    final u = AuthService.instance.user;
    if (u == null || u.profileDone) return;
    _askingProfile = true;
    // Xabar `build` o'rtasida kelishi mumkin — navigatsiya
    // kadr tugagandan keyin qilinadi.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _askingProfile = false;
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (_) => const ProfileSetupScreen(),
        ),
      );
      _askingProfile = false;
    });
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    _navAnim.dispose();
    _navPos.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    if (_jumping) return;
    if (!_pageController.hasClients) return;
    final p = _pageController.page;
    if (p != null) _navPos.value = p;
  }

  // ── SAHIFA "SUZMAYDI", DARHOL ALMASHADI ──────────────────────
  //
  // TALAB: qaysi sahifaga o'tilsa ham to'g'ridan-to'g'ri o'tsin —
  // suzish (slayd) effektisiz. Harakatlanadigan yagona narsa —
  // pastdagi pushti tugma.
  //
  // Shu bilan birga bu ENG TEZ yo'l ham. Avval qo'shni sahifaga
  // `animateToPage` ishlatilardi: u sahifalarni BIRMA-BIR aylanib
  // o'tadi va yo'l-yo'lakay oradagi ekranlarni ham QURIB chiqishga
  // majbur bo'ladi — hammasi 320 ms ichida. Har bir ekran birinchi
  // marta qurilayotgani uchun (initState, ro'yxatlar, rasm vidjetlari)
  // bu ish bitta kadrga sig'may, ilova bir zumga qotib qolardi.
  //
  // Endi HAR DOIM `jumpToPage`: faqat kerakli ekran quriladi,
  // oradagilar umuman tegilmaydi. Pastdagi suzuvchi tugma esa
  // o'zining 280 ms lik silliq animatsiyasi bilan siljiydi.
  // ── SUZISH TEZLIGI YO'L UZUNLIGIGA BOG'LANGAN ────────────────
  //
  // TOPILGAN NUQSON: davomiylik SOBIT (340 ms) edi. Qo'shni
  // sahifaga o'tishda bu normal ko'rinardi, lekin bosh sahifadan
  // profilga (4 ta tugma narida) o'tishda tugma o'sha 340 ms
  // ichida butun panelni bosib o'tardi — oradagi har bir belgi
  // atigi ~85 ms kattalashib ulgurardi, ya'ni ko'z ilg'amasdi va
  // o'tish "birdaniga" bo'lib tuyulardi.
  //
  // Endi har bir tugma oralig'iga ~240 ms beriladi: bosh sahifadan
  // profilga o'tish ~1 soniya, ya'ni tugma o'rtacha tezlikda suzib
  // boradi va oradagi belgilarni BIRIN-KETIN kattalashtirib o'tadi.
  //
  // 170 ms sinab ko'rilgan edi — foydalanuvchi baribir "uchib
  // o'tyapti" dedi, shu sabab sekinlashtirildi.
  static const int _msPerStep = 240;

  void _onTabTap(int i) {
    if (i == _index) return;
    final from = _navPos.value;
    final steps = (i - from).abs();
    setState(() => _index = i);
    _jumping = true;
    _pageController.jumpToPage(i);
    _navTween = Tween<double>(begin: from, end: i.toDouble()).animate(
      // `easeInOutSine`: harakat silliq boshlanib, silliq tugaydi,
      // lekin O'RTASIDA tezlashib ketmaydi.
      //
      // `easeInOutCubic` sinab ko'rilgan edi va u o'rtasida o'rtacha
      // tezlikdan IKKI BAROBAR tez ketardi — chetlarida sekin,
      // o'rtasida "otilib" o'tardi. Aynan shu "uchib o'tdi" degan
      // hissni bergan. Sinusda esa eng yuqori tezlik o'rtachadan
      // atigi ~1.6 barobar, ya'ni harakat bir tekis ko'rinadi.
      CurvedAnimation(parent: _navAnim, curve: Curves.easeInOutSine),
    );
    final run = ++_navRun;
    _navAnim
      ..stop()
      ..duration = Duration(
          milliseconds: (steps * _msPerStep).round().clamp(300, 1100))
      ..value = 0;

    // ── SUZISH YANGI SAHIFA QURILGANDAN KEYIN BOSHLANADI ──────
    //
    // TOPILGAN SABAB (foydalanuvchi: "planshetda to'g'ri, ekrani
    // kichik telefonda ko'z ilg'amaydi"). Bu ekran o'lchamiga
    // emas, QURILMA TEZLIGIGA bog'liq edi.
    //
    // `jumpToPage` yangi sahifani BIRINCHI MARTA quradi — ro'yxat,
    // rasm vidjetlari, `initState`. Kuchsiz telefonda bu ish bitta
    // kadrga sig'maydi va oqim 300-500 ms qotib qoladi.
    // `AnimationController` esa vaqtni HAQIQIY soat bo'yicha
    // o'lchaydi: qotish tugagach u darhol o'sha 300-500 ms ga
    // "sakraydi". Ya'ni qisqa suzish butunlay, uzunrog'i yarmigacha
    // yeb ketilardi — ekranda esa "uchib o'tdi" bo'lib ko'rinardi.
    // Planshet tez qurgani uchun u yerda hammasi joyida edi.
    //
    // Endi animatsiya SAHIFA QURILGAN KADRDAN KEYIN boshlanadi:
    // og'ir ish allaqachon tugagan bo'ladi va suzish to'liq
    // ko'rinadi.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || run != _navRun) return;
      _navAnim.forward().whenComplete(() {
        if (run != _navRun) return; // bu suzish bekor qilingan
        _jumping = false;
        _navPos.value = i.toDouble();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: SafeArea(
          bottom: false,
          child: PageView(
            controller: _pageController,
            // ── BARMOQ BILAN SURIB O'TISH O'CHIRILGAN ──────────
            //
            // TALAB: sahifalar faqat pastdagi tugma bosilganda
            // almashsin. Ilgari ekranni chapga/o'ngga surib ham
            // o'tib ketardi — ro'yxatni gorizontal siljitmoqchi
            // bo'lganda yoki pleyerdan qaytganda tasodifan boshqa
            // sahifaga tushib qolinardi.
            physics: const NeverScrollableScrollPhysics(),
            // Qo'shni sahifa OLDINDAN (ilova bo'sh turganda) quriladi —
            // shu sabab unga o'tilganda quriladigan ish qolmaydi.
            allowImplicitScrolling: true,
            onPageChanged: (i) => setState(() => _index = i),
            children: const [
              _KeepAlivePage(child: HomeScreen()),
              _KeepAlivePage(child: SearchScreen()),
              _KeepAlivePage(child: CatalogScreen()),
              _KeepAlivePage(child: LibraryScreen()),
              _KeepAlivePage(child: ProfileScreen()),
            ],
          ),
        ),
        bottomNavigationBar: _BottomNav(
          currentIndex: _index,
          position: _navPos,
          onTap: _onTabTap,
        ),
      ),
    );
  }
}

class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ── Yangi tezkor pastki navigatsiya ───────────────────────────
// Blur yo'q — faqat Container + BoxShadow. 60fps+ istalgan qurilmada.
class _BottomNav extends StatelessWidget {
  final int currentIndex;

  /// Suzuvchi tugmaning joriy o'rni (0..4 oralig'idagi kasr son).
  final ValueListenable<double> position;
  final ValueChanged<int> onTap;

  const _BottomNav({
    required this.currentIndex,
    required this.position,
    required this.onTap,
  });

  static const _items = [
    (icon: Icons.home_rounded, label: 'Bosh sahifa'),
    (icon: Icons.search_rounded, label: 'Qidiruv'),
    (icon: Icons.grid_view_rounded, label: 'Katalog'),
    (icon: Icons.folder_rounded, label: 'Kutubxona'),
    (icon: Icons.person_rounded, label: 'Profil'),
  ];

  @override
  Widget build(BuildContext context) {
    // ── PANEL TIZIM TUGMALARI ORTIDA QOLMASLIGI KERAK ─────────
    //
    // TOPILGAN SABAB (foydalanuvchi: "ko'pincha pleyerga kirib
    // chiqqandan keyin shunaqa bo'lyapti"). Pleyer to'liq ekranga
    // o'tganda `immersiveSticky` rejimini yoqadi va O'SHA PAYTDA
    // `MediaQuery.padding.bottom` NOLGA tushadi — tizim paneli
    // yashiringani uchun. Pleyerdan chiqilganda rejim qaytariladi,
    // lekin MIUI yangilangan `padding` qiymatini kechikib
    // yuboradi. `SafeArea` esa aynan `padding` ga tayanadi — shu
    // sabab panel tizim tugmalari ortida qolib ketardi.
    //
    // `viewPadding` bunday emas: u tizim paneli YASHIRINGAN
    // bo'lsa ham JISMONIY chekinishni ko'rsatib turadi, ya'ni
    // immersive rejimdan qaytishda nolga tushmaydi.
    //
    // Ustiga 14 nuqta bo'sh joy qo'shiladi (foydalanuvchi talabi:
    // "biroz yuqoriga ko'tar"), pastki chegara esa 16 — chekinish
    // umuman kelmagan qurilmada ham panel yopishib qolmasin.
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset < 16 ? 16 : inset + 14),
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
          valueListenable: position,
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
                            onTap: () => onTap(i),
                            behavior: HitTestBehavior.opaque,
                            child: SizedBox(
                              height: 52,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Transform.scale(
                                    scale: scale,
                                    child: Icon(_items[i].icon,
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
