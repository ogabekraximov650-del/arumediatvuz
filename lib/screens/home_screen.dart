import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/image_cache.dart';
import '../widgets/aru_logo.dart';
import '../widgets/glass.dart';
import '../widgets/stats_banner.dart';
import '../services/app_build.dart';
import '../services/auth_service.dart';
import '../services/format.dart';
import '../services/offline_library.dart';
import '../services/seasons_repo.dart';
import '../services/watch_history.dart';
import 'video_player_screen.dart';

const String API_BASE = 'https://arumediatv.uzcom.workers.dev';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ── RO'YXAT ENDI UMUMIY ──────────────────────────────────
  //
  // Bo'limlar ro'yxati Katalog sahifasida ham kerak. Ilgari
  // ikkovi alohida so'rov qilardi; endi manba BITTA
  // (`SeasonsRepo`), ya'ni ro'yxat ilova ochilganda bir marta
  // olinadi va ikkala sahifada ham bir vaqtda yangilanadi.
  SeasonsRepo get _repo => SeasonsRepo.instance;
  List<Map<String, dynamic>> get _seasons => _repo.items;
  bool get _isLoading => _repo.isLoading && _seasons.isEmpty;

  bool _isOffline = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _wasOffline = false;

  @override
  void initState() {
    super.initState();
    _repo.load();
    _listenConnectivity();
    // Diskdagi tomosha tarixi — TARMOQSIZ o'qiladi. Anime ustiga
    // bosilganda "oxirgi ko'rilgan qism" darhol ma'lum bo'lishi
    // uchun kerak.
    WatchHistory.instance.loadFromDisk();
  }

  // ═══════════════════════════════════════════════════════════
  //  KIRMAGAN FOYDALANUVCHI ANIMENI OCHOLMAYDI
  // ═══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): kartalar KO'RINIB tursin, lekin ustiga
  // bosilganda hisobga kirish so'ralsin.
  void _openSeason(Map<String, dynamic> season) =>
      openSeasonFromAnywhere(context, season);

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  void _listenConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (!isOnline) {
        _wasOffline = true;
        // Ro'yxat darhol to'g'ri filtrlansin.
        unawaited(OfflineLibrary.instance.refresh(_seasons));
        if (mounted) setState(() => _isOffline = true);
      } else if (_wasOffline) {
        _wasOffline = false;
        if (mounted) setState(() => _isOffline = false);
        _repo.fetch();
      }
    });
  }

  // ══════════════════════════════════════════════════════════
  //  OFLAYNDA — FAQAT YUKLAB OLINGANLARI
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "oflayn vaqtda ilovaning bosh
  // sahifasida faqat yuklab olingan qismlari bor anime
  // kartochkasi ko'rinishi kerak".
  //
  // Ro'yxatning O'ZI tegilmaydi — u keshda to'liq turaveradi va
  // internet yoqilishi bilan hammasi qaytadi. Bu yerda faqat
  // KO'RSATILADIGANI ajratiladi.
  //
  // Indeks hali yig'ilmagan bo'lsa (`ready == false`) hech narsa
  // yashirilmaydi: aks holda ilova oflaynda ochilganda ekran bir
  // lahzaga bo'm-bo'sh ko'rinardi.
  List<Map<String, dynamic>> get _visibleSeasons {
    final lib = OfflineLibrary.instance;
    if (!_isOffline || !lib.ready) return _seasons;
    return _seasons.where((s) {
      final a = int.tryParse('${s['anime_id'] ?? ''}') ?? 0;
      final sid = int.tryParse('${s['season_id'] ?? ''}') ?? 0;
      return lib.hasSeason(a, sid);
    }).toList();
  }

  Future<void> _onRefresh() => _repo.refresh();

  @override
  Widget build(BuildContext context) {
    // Oflayn indeksi yangilanganda ro'yxat qayta chizilsin.
    return AnimatedBuilder(
      // Ro'yxat ham, oflayn indeksi ham qayta chizishga sabab.
      animation: Listenable.merge(
          [SeasonsRepo.instance, OfflineLibrary.instance]),
      builder: (context, _) => _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    final visible = _visibleSeasons;
    return RefreshIndicator(
      onRefresh: _onRefresh,
      color: AppColors.accent,
      backgroundColor: AppColors.card,
      strokeWidth: 2.5,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Ilova nomi endi YOZUV emas, LOGOTIP: shu
                      // paytgacha bu yerda 'Fulutter' deb turardi va
                      // ARU logotipi ilovaning hech bir joyida
                      // ko'rinmasdi.
                      const AruLogo(height: 30),
                      const SizedBox(height: 4),
                      Text('Anime dunyosi',
                          style: TextStyle(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.45))),
                    ],
                  ),
                  const Spacer(),
                  if (_isOffline)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.wifi_off_rounded,
                              size: 14, color: Colors.orange.shade300),
                          const SizedBox(width: 4),
                          Text('Offline',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange.shade300,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Icon(Icons.notifications_none_rounded,
                        color: Colors.white.withValues(alpha: 0.7), size: 22),
                  ),
                ],
              ),
            ),
          ),
          // ── SHAFFOF STATISTIKA ──────────────────────────
          //
          // Eng tepada: kunlik foydalanuvchilar va o'zi almashib
          // turadigan kunlik raqamlar. Ustiga bosilsa — to'liq
          // statistika sahifasi.
          if (kHomeStats)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 6, 16, 2),
                child: StatsBanner(),
              ),
            ),
          if (_isOffline && _seasons.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Keshdan ko\'rsatilmoqda · Yuqoriga torting',
                    style:
                        TextStyle(fontSize: 12, color: Colors.orange.shade400)),
              ),
            ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Text('Ommabop anime',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          ),
          if (_isLoading)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 260,
                child: Center(
                  child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(AppColors.accent),
                      strokeWidth: 2),
                ),
              ),
            )
          else if (visible.isEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 260,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isOffline
                            ? Icons.wifi_off_rounded
                            : Icons.movie_creation_outlined,
                        size: 52,
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isOffline
                            ? (_seasons.isEmpty
                                ? 'Internet yo\'q · yuqoriga torting'
                                : 'Yuklab olingan qism yo\'q')
                            : 'Anime topilmadi',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.65,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => RepaintBoundary(
                    child: SeasonCard(
                      season: visible[index],
                      onTap: () => _openSeason(visible[index]),
                    ),
                  ),
                  childCount: visible.length,
                  addRepaintBoundaries: false,
                  addAutomaticKeepAlives: false,
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  ANIMENI OCHISH — BITTA JOYDA
// ══════════════════════════════════════════════════════════════
//
// Pleyerga bir necha sahifadan kiriladi (Bosh sahifa, Katalog,
// Sevimlilar). Kirish tekshiruvi ham, o'tish animatsiyasi ham
// hamma joyda BIR XIL bo'lishi kerak — shu sabab u shu yerda,
// bitta funksiyada.
//
// TALAB (foydalanuvchi): kartalar KO'RINIB tursin, lekin ustiga
// bosilganda hisobga kirish so'ralsin.
void openSeasonFromAnywhere(
    BuildContext context, Map<String, dynamic> season) {
  if (!AuthService.instance.isLoggedIn) {
    _askLoginDialog(context);
    return;
  }
  // Tarix hali o'qilmagan bo'lsa (masalan endigina kirilgan) —
  // shu yerda o'qib olamiz, so'rov ketmaydi.
  WatchHistory.instance.loadFromDisk();
  Navigator.of(context).push(
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, anim, __) => VideoPlayerScreen(season: season),
      transitionsBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: child,
      ),
    ),
  );
}

void _askLoginDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Glass(
        borderRadius: 22,
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 44, color: AppColors.accent),
            const SizedBox(height: 14),
            const Text(
              'Iltimos anime ko\'rish uchun avval profil sahifasiga '
              'o\'tib accountingizga kiring yoki yangi accaunt oching',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white, fontSize: 14.5, height: 1.45),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Tushunarli'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ── Season kartochkasi ──────────────────────────────────────────────────────
class SeasonCard extends StatelessWidget {
  final Map<String, dynamic> season;
  final VoidCallback onTap;

  /// Rasm ustidagi belgilar (reyting, ko'rishlar, yosh) chizilsinmi.
  ///
  /// TALAB (foydalanuvchi): statistika oynalarida "karta ustida
  /// hech narsa bo'lmasin" — u yerda kartochka faqat poster va
  /// nomdan iborat bo'ladi.
  final bool showBadges;

  /// Rasmning o'ng yuqorisiga qo'yiladigan qo'shimcha belgi.
  ///
  /// "Baholangan" statistikasida foydalanuvchining O'Z bahosi shu
  /// yerda ko'rinadi (foydalanuvchi talabi).
  final Widget? corner;

  const SeasonCard({
    super.key,
    required this.season,
    required this.onTap,
    this.showBadges = true,
    this.corner,
  });

  // ── KARTADAGI YOZUV ───────────────────────────────────────
  //
  // TALAB (foydalanuvchi): bo'lim nomining USTIDA "N-bo'lim" deb
  // yozilsin, nom uzun bo'lsa esa EKRAN HAJMIGA QARAB uzunroq
  // joy egallasin.
  //
  // Shu sabab o'lchamlar qat'iy emas: harf kattaligi ham, nomga
  // ajratiladigan qatorlar soni ham kartaning O'Z kengligidan
  // hisoblanadi (`LayoutBuilder`). Kichik telefonda yozuv rasmni
  // bosib ketmaydi, kattasida esa nom to'liq ko'rinadi.
  @override
  Widget build(BuildContext context) {
    final photoUrl = season['photo_url'] as String?;
    final name = (season['nomi'] ?? '').toString();
    final bolim = int.tryParse(season['bolim_id']?.toString() ?? '') ?? 0;

    // ── KARTOCHKA BELGILARI ───────────────────────────────────
    //
    // TALAB (foydalanuvchi): "anime kartochkalarining yuqori
    // qismida reytingi va necha marta ko'rilgani yozib qo'yilsin,
    // pastroqda esa yosh chegarasi bo'lsin (17+, 18+ va hokazo)".
    //
    // Uchalasi ham SERVERDAN keladi (`season_db`) — ilovada hech
    // narsa o'ylab topilmaydi:
    //   * reyting  — `rating_sum / rating_count`;
    //   * ko'rish  — `views_total`;
    //   * yosh     — `yosh` (0 bo'lsa belgi umuman chiqmaydi).
    //
    // Baho hali berilmagan bo'lsa reyting belgisi ham chiqmaydi:
    // `0.0` deb turish "yomon anime" degan noto'g'ri taassurot
    // berardi.
    final rCount = int.tryParse('${season['rating_count'] ?? 0}') ?? 0;
    final rSum = int.tryParse('${season['rating_sum'] ?? 0}') ?? 0;
    final rating = rCount > 0 ? rSum / rCount : 0.0;
    final views = int.tryParse('${season['views_total'] ?? 0}') ?? 0;
    final yosh = int.tryParse('${season['yosh'] ?? 0}') ?? 0;

    return GlassTappable(
      onTap: onTap,
      child: Container(
        // ── SOYA OLIB TASHLANDI ──────────────────────────────
        //
        // Ikki sabab: (1) rasmdagi uslubda kartalarda soya yo'q;
        // (2) bu karta TO'RDA — ekranda bir vaqtda 6-8 tasi
        // turadi va har biri GPU dan alohida blur o'tishini
        // talab qilardi. Qora fondagi qora soya baribir
        // ko'rinmasdi ham.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: AppColors.card,
          border: Border.all(color: AppColors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Rasm
              if (photoUrl != null && photoUrl.isNotEmpty)
                CachedNetworkImage(
                  cacheManager: AppImageCache.manager,
                  imageUrl: photoUrl,
                  fit: BoxFit.cover,
                  // Katak ikki ustunli gridda ~166 dp keng — 540 px
                  // yetarli (720 dan pastga tushirildi: xotira ~44%
                  // tejaladi, ko'zga farq bilinmaydi).
                  memCacheWidth: 540,
                  // `high` (kubik) har bir kadrda qayta hisoblanadi va
                  // surish paytida GPU vaqtini yeydi. Rasm allaqachon
                  // ko'rinadigan o'lchamda dekodlangani uchun `medium`
                  // bilan farq ko'rinmaydi, lekin arzonroq.
                  filterQuality: FilterQuality.medium,
                  placeholder: (_, __) => Container(
                    color: AppColors.card,
                    child: Center(
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(AppColors.accent)),
                    ),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    color: AppColors.card,
                    child: const Center(
                        child: Icon(Icons.movie_creation_outlined,
                            size: 36, color: Colors.white38)),
                  ),
                )
              else
                Container(
                  color: AppColors.card,
                  child: const Center(
                      child: Icon(Icons.movie_creation_outlined,
                          size: 36, color: Colors.white38)),
                ),

              // ── TEPADAGI BELGILAR ──────────────────────
              //
              // Rasm ustida turadi, shu sabab har biri o'z quyuq
              // foniga ega — och kadrda ham o'qilsin.
              if (corner != null)
                Positioned(top: 8, right: 8, child: corner!),
              if (showBadges)
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (rCount > 0)
                          _CardBadge(
                            icon: Icons.star_rounded,
                            text: rating.toStringAsFixed(1),
                            iconColor: AppColors.gold,
                          ),
                        const Spacer(),
                        if (views > 0)
                          _CardBadge(
                            icon: Icons.visibility_rounded,
                            text: formatCompact(views),
                          ),
                      ],
                    ),
                    // Yosh chegarasi — talab bo'yicha PASTROQDA.
                    if (yosh > 0) ...[
                      const SizedBox(height: 6),
                      _AgeBadge(yosh: yosh),
                    ],
                  ],
                ),
              ),

              // Pastdan gradient + yozuvlar. Ikkovi bitta
              // `LayoutBuilder` ichida: gradient balandligi
              // yozuvning O'Z balandligidan kelib chiqadi.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final w = box.maxWidth;
                    // ~166 dp lik katakda 14 dp, kattaroq ekranda
                    // kattaroq — lekin hech qachon o'lchovdan
                    // chiqmaydi.
                    final nameSize = (w * 0.085).clamp(12.5, 18.0).toDouble();
                    final tagSize =
                        (nameSize * 0.78).clamp(10.0, 13.5).toDouble();
                    // Uzun nom ekran kattalashgani sari ko'proq
                    // qator oladi (kichik ekranda 2, kattasida 3).
                    final lines = name.length > 26 && w >= 150 ? 3 : 2;
                    final textHeight =
                        nameSize * 1.22 * lines + tagSize * 1.3 + 16;
                    return Container(
                      padding: const EdgeInsets.fromLTRB(10, 26, 10, 10),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.88),
                            Colors.black.withValues(alpha: 0.65),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.55, 1],
                        ),
                      ),
                      constraints: BoxConstraints(minHeight: textHeight),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (bolim > 0)
                            Text(
                              '$bolim-bo\'lim',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: tagSize,
                                color: AppColors.accent,
                                height: 1.3,
                              ),
                            ),
                          Text(
                            name,
                            maxLines: lines,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: nameSize,
                                color: Colors.white,
                                height: 1.22),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Kartochka ustidagi kichik belgi ─────────────────────────────
//
// Reyting va ko'rishlar soni uchun. Fon quyuq va biroz shaffof:
// och rangli kadrda ham yozuv o'qiladi, lekin rasmni ham
// butunlay bosib qo'ymaydi.
class _CardBadge extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? iconColor;

  const _CardBadge({
    required this.icon,
    required this.text,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: iconColor ?? Colors.white70),
          const SizedBox(width: 3),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Yosh chegarasi belgisi ──────────────────────────────────────
//
// Rang chegaraning O'ZIGA qarab o'zgaradi: 18+ qizil, 16+ to'q
// sariq, qolgani oltin. Ya'ni belgini o'qimasdan ham ko'z bilan
// ajratib olsa bo'ladi.
//
// Ilgari pastki daraja MOVIY edi — ilovaning yangi palitrasida
// (neytral qora + apelsin) u begona rang bo'lib turardi. Oltin
// esa qolgan belgilar bilan bir oilada.
class _AgeBadge extends StatelessWidget {
  final int yosh;
  const _AgeBadge({required this.yosh});

  @override
  Widget build(BuildContext context) {
    final color = yosh >= 18
        ? AppColors.danger
        : (yosh >= 16 ? AppColors.accent2 : AppColors.gold);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Text(
        '$yosh+',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
