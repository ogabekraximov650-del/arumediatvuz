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

class _RootScreenState extends State<RootScreen> {
  int _index = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTap(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
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
          pageController: _pageController,
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
  final PageController pageController;
  final ValueChanged<int> onTap;

  const _BottomNav({
    required this.currentIndex,
    required this.pageController,
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
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
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
      child: AnimatedBuilder(
        animation: pageController,
        builder: (context, _) {
          final page = pageController.hasClients
              ? (pageController.page ?? currentIndex.toDouble())
              : currentIndex.toDouble();

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
                                  child: Icon(_items[i].icon, size: 22, color: color),
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
    );
  }
}
