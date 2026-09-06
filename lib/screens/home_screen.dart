import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/glass.dart';
import '../services/rust_bridge.dart';
import 'video_player_screen.dart';

const String API_BASE = 'https://aniraxuzapp.ogabekraximov650.workers.dev';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _seasons = [];
  bool _isLoading = true;
  bool _isOffline = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _wasOffline = false;

  @override
  void initState() {
    super.initState();
    _loadData();
    _listenConnectivity();
  }

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
        if (mounted) setState(() => _isOffline = true);
      } else if (_wasOffline) {
        _wasOffline = false;
        if (mounted) setState(() => _isOffline = false);
        _fetchFromApi(force: true);
      }
    });
  }

  // MUHIM: kesh MUDDATIDAN QAT'IY NAZAR har doim darhol ko'rsatiladi.
  Future<void> _loadData() async {
    final cached = RustCore.instance.getCachedAnimes();
    if (cached != null && mounted) {
      setState(() {
        _seasons = cached;
        _isLoading = false;
      });
      if (!RustCore.instance.isCacheFresh()) {
        _fetchFromApi();
      }
      return;
    }
    await _fetchFromApi(showLoading: true);
  }

  Future<void> _fetchFromApi(
      {bool force = false, bool showLoading = false}) async {
    if (showLoading && mounted) setState(() => _isLoading = true);
    try {
      final res = await http
          .get(Uri.parse('$API_BASE/api/seasons'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && mounted) {
        final data =
            (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
        RustCore.instance.saveAnimesCache(data);
        setState(() {
          _seasons = data;
          _isLoading = false;
          _isOffline = false;
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _isLoading = false;
          _isOffline = true;
        });
    }
  }

  Future<void> _onRefresh() async {
    RustCore.instance.clearCache();
    await _fetchFromApi(force: true);
  }

  @override
  Widget build(BuildContext context) {
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
                      const Text('Fulutter',
                          style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -0.5)),
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
          else if (_seasons.isEmpty)
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
                            ? 'Internet yo\'q · yuqoriga torting'
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
                      season: _seasons[index],
                      onTap: () => Navigator.of(context).push(
                        PageRouteBuilder(
                          transitionDuration: const Duration(milliseconds: 300),
                          pageBuilder: (_, anim, __) =>
                              VideoPlayerScreen(season: _seasons[index]),
                          transitionsBuilder: (_, anim, __, child) =>
                              FadeTransition(
                            opacity: CurvedAnimation(
                                parent: anim, curve: Curves.easeOutCubic),
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  ),
                  childCount: _seasons.length,
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

// ── Season kartochkasi ──────────────────────────────────────────────────────
class SeasonCard extends StatelessWidget {
  final Map<String, dynamic> season;
  final VoidCallback onTap;
  const SeasonCard({super.key, required this.season, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final photoUrl = season['photo_url'] as String?;

    return GlassTappable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: AppColors.card,
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.32),
                blurRadius: 14,
                offset: const Offset(0, 6)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Rasm
              if (photoUrl != null && photoUrl.isNotEmpty)
                CachedNetworkImage(
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

              // Pastdan gradient
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 90,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.transparent
                      ],
                    ),
                  ),
                ),
              ),

              // Nomi
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Text(
                  season['nomi'] ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: Colors.white,
                      height: 1.2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
