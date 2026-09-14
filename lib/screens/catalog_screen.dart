// lib/screens/catalog_screen.dart — KATALOG.
//
// ═══════════════════════════════════════════════════════════════
//  NIMA O'ZGARDI
// ═══════════════════════════════════════════════════════════════
//
// Ilgari bu sahifada JANR NOMLARI yozilgan bo'sh plitkalar
// turardi — ular hech qayerga olib bormasdi va ro'yxat ham
// haqiqiy emas, ilovaga qo'lda yozib qo'yilgan edi.
//
// TALAB (foydalanuvchi):
//   * Katalogda ham Bosh sahifadagidek animelar chiqsin;
//   * tepada ilova logotipi va nomi tursin;
//   * tagida "Barchasi / Reytingi baland / Eng ko'p ko'rilgan /
//     Ongoing / Tugallangan / Filmlar / OVA" tugmalari bo'lsin va
//     ular QO'LDA SURIB o'tkazilsin;
//   * pastda, sahifa tugmalari ustida "Filtrlash" tugmasi tursin.
//
// ── SO'ROV QO'SHILMADI ──────────────────────────────────────
//
// Bu sahifa Bosh sahifa bilan BITTA ro'yxatdan oziqlanadi
// (`SeasonsRepo`). Ya'ni Katalogga o'tish qo'shimcha tarmoq
// so'rovi DEMAK EMAS: ro'yxat allaqachon xotirada turadi.
//
// Saralash va filtrlash ham TELEFONDA bajariladi. Bo'limlar soni
// kichik (kontent, foydalanuvchi emas), shu sabab bu arzon va
// natija DARHOL chiqadi — serverga borib kelish kutilmaydi.

import 'package:flutter/material.dart';

import '../services/offline_library.dart';
import '../services/seasons_repo.dart';
import '../widgets/aru_logo.dart';
import '../widgets/glass.dart';
import 'home_screen.dart' show SeasonCard, openSeasonFromAnywhere;

/// Tepadagi bitta bo'lim (tab).
enum _Tab {
  hammasi('Barchasi'),
  reyting('Reytingi baland'),
  korilgan('Eng ko\'p ko\'rilgan'),
  ongoing('Ongoing'),
  tugallangan('Tugallangan'),
  filmlar('Filmlar'),
  ova('OVA qismlar');

  final String label;
  const _Tab(this.label);
}

/// Tanlangan filtr (janrlar va yillar).
///
/// O'ZGARMAS: filtr oynasi ishlayotgan nusxani emas, YANGI nusxani
/// qaytaradi — ya'ni "Filtrlash" bosilmaguncha ro'yxat qimirlamaydi
/// (foydalanuvchi talabi: oyna yopilgandan KEYIN qo'llanadi).
@immutable
class CatalogFilter {
  final Set<String> genres;
  final Set<String> years;

  const CatalogFilter({this.genres = const {}, this.years = const {}});

  bool get isEmpty => genres.isEmpty && years.isEmpty;

  /// Nechta shart tanlangan — tugmadagi raqam uchun.
  int get count => genres.length + years.length;

  /// Bo'lim shu filtrga to'g'ri keladimi.
  ///
  /// Janrlar orasida — YOKI (bittasi mos kelsa yetarli), yillar
  /// orasida ham YOKI. Janr va yil ORASIDA esa VA: "Komediya" va
  /// "2024" tanlansa — komediya bo'lgan VA 2024-yilgi bo'limlar.
  bool allows(Map<String, dynamic> s) {
    if (genres.isNotEmpty) {
      final g = seasonGenres(s);
      if (!g.any(genres.contains)) return false;
    }
    if (years.isNotEmpty) {
      if (!years.contains('${s['yili'] ?? ''}'.trim())) return false;
    }
    return true;
  }
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  static const _tabs = _Tab.values;

  final _pages = PageController();
  final _tabScroll = ScrollController();

  /// Har bir tab tugmasining kengligini o'lchash uchun — tanlangan
  /// tugma ekran chetida qolib ketmasligi kerak.
  final Map<int, GlobalKey> _tabKeys = {
    for (var i = 0; i < _tabs.length; i++) i: GlobalKey(),
  };

  int _index = 0;
  CatalogFilter _filter = const CatalogFilter();

  @override
  void initState() {
    super.initState();
    SeasonsRepo.instance.load();
    // Tugma pastki panelning YONIDA chiziladi (`CatalogFilterBar`
    // izohiga qarang) — shu sabab u yerga o'zimizni tanishtiramiz.
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void dispose() {
    CatalogFilterBar.instance.hide();
    _pages.dispose();
    _tabScroll.dispose();
    super.dispose();
  }

  /// Tugmaning holatini pastki panelga uzatadi.
  void _publish() {
    CatalogFilterBar.instance.show(
      count: _filter.count,
      onOpen: _openFilter,
      onClear: _clearFilter,
    );
  }

  /// Tugma bosildi — sahifa suzib o'tadi.
  void _goTo(int i) {
    if (i == _index) return;
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// Sahifa almashdi (bosildi yoki BARMOQ BILAN surildi) — tepadagi
  /// tugma ham o'sha joyga siljiydi.
  void _onPageChanged(int i) {
    setState(() => _index = i);
    _revealTab(i);
  }

  /// Tanlangan tugmani ko'rinadigan joyga suradi.
  void _revealTab(int i) {
    final ctx = _tabKeys[i]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      // 0.5 — tugma iloji boricha O'RTAGA keladi, ya'ni yonidagi
      // tugmalar ham ko'rinib turadi.
      alignment: 0.5,
    );
  }

  /// Shu tab uchun ro'yxat: avval oflayn, keyin filtr, keyin
  /// saralash.
  List<Map<String, dynamic>> _listFor(_Tab tab) {
    // ── OFLAYNDA — FAQAT YUKLAB OLINGANLARI ─────────────────
    //
    // Bosh sahifadagi qoida bu yerda ham amal qiladi: internet
    // yo'q bo'lsa faqat telefonda TO'LIQ turgan bo'limlar
    // ko'rsatiladi. Aks holda ochib bo'lmaydigan kartochka
    // bosilib, "ilova ishlamayapti" degan taassurot qolardi.
    //
    // Indeks hali yig'ilmagan bo'lsa hech narsa yashirilmaydi —
    // aks holda ekran bir lahzaga bo'm-bo'sh ko'rinardi.
    final lib = OfflineLibrary.instance;
    var all = SeasonsRepo.instance.items;
    if (lib.isOffline && lib.ready) {
      all = all.where((s) {
        final a = seasonInt(s, 'anime_id');
        final sid = seasonInt(s, 'season_id');
        return lib.hasSeason(a, sid);
      }).toList();
    }
    final rows = _filter.isEmpty
        ? List<Map<String, dynamic>>.from(all)
        : all.where(_filter.allows).toList();

    switch (tab) {
      case _Tab.hammasi:
        return rows;

      case _Tab.reyting:
        // Baho berilmagan bo'limlar bu ro'yxatda umuman yo'q:
        // "reytingi baland" ro'yxatida bahosiz bo'lim turishi
        // mantiqsiz bo'lardi.
        final rated = rows.where((s) => seasonRating(s) > 0).toList()
          ..sort((a, b) => seasonRating(b).compareTo(seasonRating(a)));
        return rated;

      case _Tab.korilgan:
        final seen = rows
            .where((s) => seasonInt(s, 'views_total') > 0)
            .toList()
          ..sort((a, b) => seasonInt(b, 'views_total')
              .compareTo(seasonInt(a, 'views_total')));
        return seen;

      case _Tab.ongoing:
        // Admin panelidagi qiymat — "Davom etmoqda"
        // (`add_season_screen.dart` -> `_holatlar`).
        return rows
            .where((s) => '${s['holati'] ?? ''}'.trim() == 'Davom etmoqda')
            .toList();

      case _Tab.tugallangan:
        return rows
            .where((s) => '${s['holati'] ?? ''}'.trim() == 'Tugallangan')
            .toList();

      case _Tab.filmlar:
        return rows
            .where((s) => '${s['turi'] ?? ''}'.trim().toUpperCase() == 'FILM')
            .toList();

      case _Tab.ova:
        return rows
            .where((s) => '${s['turi'] ?? ''}'.trim().toUpperCase() == 'OVA')
            .toList();
    }
  }

  Future<void> _openFilter() async {
    final res = await showModalBottomSheet<CatalogFilter>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      // Standart chegara oynani ekranning 9/16 qismiga siqadi va
      // uzun janr ro'yxati kesilib qolardi.
      constraints: const BoxConstraints(),
      builder: (_) => _FilterSheet(current: _filter),
    );
    if (res == null || !mounted) return;
    setState(() => _filter = res);
    _publish();
  }

  void _clearFilter() {
    setState(() => _filter = const CatalogFilter());
    _publish();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          [SeasonsRepo.instance, OfflineLibrary.instance]),
      builder: (context, _) {
        return Column(
          children: [
            _Header(offline: OfflineLibrary.instance.isOffline),
            _TabBar(
              tabs: _tabs,
              index: _index,
              keys: _tabKeys,
              controller: _tabScroll,
              onTap: _goTo,
            ),
            Expanded(
              // Barmoq bilan surib o'tkaziladi (talab).
              child: PageView.builder(
                controller: _pages,
                onPageChanged: _onPageChanged,
                itemCount: _tabs.length,
                itemBuilder: (context, i) => _Grid(
                  rows: _listFor(_tabs[i]),
                  loading: SeasonsRepo.instance.isLoading,
                  filtered: !_filter.isEmpty,
                  onRefresh: SeasonsRepo.instance.refresh,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}


// ══════════════════════════════════════════════════════════════
//  TEPA: LOGOTIP VA NOM
// ══════════════════════════════════════════════════════════════
//
// Bosh sahifadagi bilan bir xil — foydalanuvchi talabi.

class _Header extends StatelessWidget {
  final bool offline;
  const _Header({required this.offline});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const AruLogo(height: 30),
              const SizedBox(height: 4),
              Text(
                'Katalog',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
          const Spacer(),
          if (offline)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_off_rounded,
                      size: 14, color: Colors.orange.shade300),
                  const SizedBox(width: 4),
                  Text(
                    'Offline',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange.shade300,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  TUGMALAR QATORI
// ══════════════════════════════════════════════════════════════

class _TabBar extends StatelessWidget {
  final List<_Tab> tabs;
  final int index;
  final Map<int, GlobalKey> keys;
  final ScrollController controller;
  final ValueChanged<int> onTap;

  const _TabBar({
    required this.tabs,
    required this.index,
    required this.keys,
    required this.controller,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final sel = i == index;
          return Center(
            child: GestureDetector(
              key: keys[i],
              onTap: () => onTap(i),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: sel
                      ? AppColors.accent
                      : Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: sel
                        ? AppColors.accent
                        : Colors.white.withValues(alpha: 0.14),
                  ),
                  boxShadow: sel
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.32),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  tabs[i].label,
                  style: TextStyle(
                    color: sel
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.65),
                    fontSize: 13,
                    fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  BITTA TABNING RO'YXATI
// ══════════════════════════════════════════════════════════════

class _Grid extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final bool loading;
  final bool filtered;
  final Future<void> Function() onRefresh;

  const _Grid({
    required this.rows,
    required this.loading,
    required this.filtered,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (loading && rows.isEmpty) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
          strokeWidth: 2,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: AppColors.accent,
      backgroundColor: AppColors.card,
      strokeWidth: 2.5,
      child: rows.isEmpty
          ? ListView(
              physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics()),
              children: [
                SizedBox(
                  height: 280,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          filtered
                              ? Icons.filter_alt_off_rounded
                              : Icons.movie_creation_outlined,
                          size: 52,
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          filtered
                              ? 'Bu filtrga mos anime topilmadi'
                              : 'Bu bo\'limda hozircha anime yo\'q',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : GridView.builder(
              physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics()),
              // Pastda "Filtrlash" tugmasi turadi (u pastki
              // panelga yopishgan) — oxirgi qator uning ostida
              // qolmasin.
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.65,
              ),
              itemCount: rows.length,
              itemBuilder: (context, i) => RepaintBoundary(
                child: SeasonCard(
                  season: rows[i],
                  onTap: () => openSeasonFromAnywhere(context, rows[i]),
                ),
              ),
            ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  "FILTRLASH" TUGMASI
// ══════════════════════════════════════════════════════════════
//
// Filtr yoqilgan bo'lsa tugmada nechta shart tanlangani yoziladi
// va YONIDA X chiqadi — foydalanuvchi talabi: "X ni bosib filtr
// tozalanadi".

// ══════════════════════════════════════════════════════════════
//  TUGMA QAYERDA CHIZILADI
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi, ikki marta): "Filtrlash tugmasi pastdagi
// sahifa tugmalari oynasiga YOPISHIB tursin".
//
// ── NEGA HISOBLASH TASHLANDI ────────────────────────────────
//
// Ilgari tugma Katalog sahifasining ichida, `Stack` ustida
// turardi va panelgacha bo'lgan masofa HISOBLANARDI (tizim
// chekinishi, panel balandligi, tana panel ortiga cho'zilganmi
// yoki yo'qmi). Har bir hisob-kitobda bitta noma'lum qolar va
// tugma har safar noto'g'ri joyda chiqardi.
//
// Endi hech narsa hisoblanmaydi: tugma AYNAN panelning O'ZI
// bilan bitta ustunda chiziladi (`root_screen.dart` ->
// `bottomNavigationBar`). Ular yonma-yon tursa, orasidagi masofa
// ham aniq — qurilma qanaqa bo'lishidan qat'iy nazar.
//
// Katalog sahifasi esa shu yerga faqat HOLATNI beradi: nechta
// shart tanlangan va bosilganda nima qilish kerak.
class CatalogFilterBar extends ChangeNotifier {
  CatalogFilterBar._();
  static final CatalogFilterBar instance = CatalogFilterBar._();

  bool _visible = false;
  int _count = 0;
  VoidCallback? _onOpen;
  VoidCallback? _onClear;

  bool get visible => _visible && _onOpen != null;
  int get count => _count;

  void show({
    required int count,
    required VoidCallback onOpen,
    required VoidCallback onClear,
  }) {
    _visible = true;
    _count = count;
    _onOpen = onOpen;
    _onClear = onClear;
    notifyListeners();
  }

  void hide() {
    if (!_visible) return;
    _visible = false;
    _onOpen = null;
    _onClear = null;
    notifyListeners();
  }

  void open() => _onOpen?.call();
  void clear() => _onClear?.call();

  /// Panel ustida chiziladigan tugma.
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Padding(
      // Panel bilan tugma orasidagi yagona masofa — shu 10 nuqta.
      padding: const EdgeInsets.only(bottom: 10),
      child: Center(
        child: _FilterButton(
          count: _count,
          onTap: open,
          onClear: clear,
        ),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _FilterButton({
    required this.count,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final on = count > 0;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: on ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: on ? AppColors.accent : AppColors.border,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.42),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: EdgeInsets.fromLTRB(18, 11, on ? 12 : 18, 11),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.tune_rounded,
                        size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      on ? 'Filtrlash · $count' : 'Filtrlash',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (on)
              InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(24),
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(4, 11, 16, 11),
                  child: Icon(Icons.close_rounded,
                      size: 19, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  FILTR OYNASI
// ══════════════════════════════════════════════════════════════
//
// Janrlar va yillar — BAZADA BOR qiymatlardan (`SeasonsRepo`).
//
// Pastda ikkita tugma DOIM ko'rinib turadi (talab): "Tozalash" va
// "Filtrlash". Ro'yxat uzun bo'lsa faqat USTKI qism suriladi,
// tugmalar esa joyida qoladi.

class _FilterSheet extends StatefulWidget {
  final CatalogFilter current;
  const _FilterSheet({required this.current});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late Set<String> _genres = {...widget.current.genres};
  late Set<String> _years = {...widget.current.years};

  void _toggle(Set<String> set, String v) {
    setState(() {
      if (!set.remove(v)) set.add(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottom = mq.viewPadding.bottom > mq.padding.bottom
        ? mq.viewPadding.bottom
        : mq.padding.bottom;
    final repo = SeasonsRepo.instance;
    final genres = repo.genres;
    final years = repo.years;

    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottom + 14),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
        child: Glass(
          borderRadius: 22,
          blur: 18,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Filtrlash',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),

              // Uzun ro'yxat — faqat shu qism suriladi.
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (genres.isNotEmpty) ...[
                        const _SectionTitle('Janrlar'),
                        const SizedBox(height: 8),
                        _Chips(
                          values: genres,
                          selected: _genres,
                          onTap: (v) => _toggle(_genres, v),
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (years.isNotEmpty) ...[
                        const _SectionTitle('Yillar'),
                        const SizedBox(height: 8),
                        _Chips(
                          values: years,
                          selected: _years,
                          onTap: (v) => _toggle(_years, v),
                        ),
                      ],
                      if (genres.isEmpty && years.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            'Hozircha filtrlaydigan narsa yo\'q.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),
              // ── DOIM KO'RINIB TURADIGAN IKKI TUGMA ──────────
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        side: const BorderSide(color: AppColors.border),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      // "Tozalash" — belgilarni olib tashlaydi VA
                      // oynani yopib, filtrsiz ro'yxatni qaytaradi
                      // (foydalanuvchi talabi: "filtrlash oynasini
                      // qaytadan ochib tozalash tugmasini bossa
                      // filtr tozalanadi").
                      onPressed: () => Navigator.of(context)
                          .pop(const CatalogFilter()),
                      child: const Text(
                        'Tozalash',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        minimumSize: const Size(0, 46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(
                        CatalogFilter(genres: _genres, years: _years),
                      ),
                      child: const Text(
                        'Filtrlash',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.85),
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Tanlanadigan yorliqlar to'plami.
class _Chips extends StatelessWidget {
  final List<String> values;
  final Set<String> selected;
  final ValueChanged<String> onTap;

  const _Chips({
    required this.values,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: values.map((v) {
        final sel = selected.contains(v);
        return GestureDetector(
          onTap: () => onTap(v),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding:
                const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: sel
                  ? AppColors.accent
                  : Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: sel
                    ? AppColors.accent
                    : Colors.white.withValues(alpha: 0.16),
              ),
            ),
            child: Text(
              v,
              style: TextStyle(
                color:
                    sel ? Colors.white : Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
