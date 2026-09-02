import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
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

class _RootScreenState extends State<RootScreen>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  late final PageController _pageController;

  // ── PASTKI PANELDAGI "SUZUVCHI" TUGMA HOLATI ─────────────────
  // Avval u to'g'ridan-to'g'ri PageController'ning `page` qiymatiga
  // bog'langan edi. Endi alohida qiymat: sahifa BARMOQ bilan
  // surilganda u PageController'ni kuzatadi, tugma bosilganda esa
  // o'zining silliq animatsiyasi bilan siljiydi (pastdagi izohga
  // qarang — sahifa o'zi sakrab o'tadi).
  final ValueNotifier<double> _navPos = ValueNotifier<double>(0);
  late final AnimationController _navAnim;
  Animation<double>? _navTween;
  bool _jumping = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController()..addListener(_onPageScroll);
    _navAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(() {
        final t = _navTween;
        if (t != null) _navPos.value = t.value;
      });
  }

  @override
  void dispose() {
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
  void _onTabTap(int i) {
    if (i == _index) return;
    final from = _navPos.value;
    setState(() => _index = i);
    _jumping = true;
    _pageController.jumpToPage(i);
    _navTween = Tween<double>(begin: from, end: i.toDouble()).animate(
      CurvedAnimation(parent: _navAnim, curve: Curves.easeOutCubic),
    );
    _navAnim
      ..stop()
      ..value = 0
      ..forward().whenComplete(() {
        _jumping = false;
        _navPos.value = i.toDouble();
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
    (icon: Icons.bookmark_rounded, label: 'Kutubxona'),
    (icon: Icons.person_rounded, label: 'Profil'),
  ];

  @override
  Widget build(BuildContext context) {
    // MUHIM TUZATISH: qo'lda MediaQuery.padding.bottom o'qib margin
    // hisoblash ba'zi qurilmalarda (masalan MIUI/Xiaomi 3-tugmali
    // navigatsiya) barqaror ishlamay, panel tizim navigatsiya paneli
    // ortida qolib ketardi. Buning o'rniga Flutter'ning o'zi sinovdan
    // o'tkazgan SafeArea widgeti ishlatiladi — u tizim navigatsiya
    // panelining haqiqiy balandligini har doim to'g'ri hisobga oladi.
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AppColors.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.40),
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
                              color: AppColors.accent.withOpacity(0.35),
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
                        final scale = 1.0 + 0.12 * t;
                        final color = Color.lerp(
                          Colors.white.withOpacity(0.40),
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
                                  if (t > 0.5) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      _items[i].label,
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: color,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
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
