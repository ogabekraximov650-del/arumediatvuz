import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'add_season_screen.dart';
import 'epizod_management_screen.dart';

const String API_BASE = 'https://aniraxuzapp.ogabekraximov650.workers.dev';

/// Bitta anime'ga tegishli bo'limlarni (season_db) boshqarish sahifasi.
/// Yuqorida doim anime rasmi va nomi ko'rinib turadi (sticky header).
class SeasonManagementScreen extends StatefulWidget {
  final Map<String, dynamic> anime;
  const SeasonManagementScreen({super.key, required this.anime});

  @override
  State<SeasonManagementScreen> createState() => _SeasonManagementScreenState();
}

class _SeasonManagementScreenState extends State<SeasonManagementScreen> {
  List<Map<String, dynamic>> _seasons = [];
  bool _isLoading = true;
  String? _errorMsg;

  String get _animeId => widget.anime['id'].toString();

  @override
  void initState() {
    super.initState();
    _loadSeasons();
  }

  Future<void> _loadSeasons() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });
    try {
      final res = await http.get(Uri.parse('$API_BASE/api/seasons/anime/$_animeId'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        setState(() => _seasons = data.cast<Map<String, dynamic>>());
      } else {
        throw 'Bo\'limlar yuklab olib bo\'lmadi';
      }
    } catch (e) {
      setState(() => _errorMsg = 'Xato: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _navigateToAddSeason({Map<String, dynamic>? season}) async {
    final result = await Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        opaque: false,
        barrierColor: Colors.black54,
        pageBuilder: (_, animation, __) => AddSeasonScreen(
          animeId: _animeId,
          initialSeason: season,
        ),
        transitionsBuilder: (_, animation, __, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
                  .animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    if (result == true) _loadSeasons();
  }

  void _navigateToEpizodlar(Map<String, dynamic> season) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, animation, __) => EpizodManagementScreen(
          anime: widget.anime,
          season: season,
        ),
        transitionsBuilder: (_, animation, __, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                  .animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  // MUHIM: season_db'da alohida "id" ustuni yo'q — o'chirish/tahrirlash
  // uchun anime_id + season_id juftligi ishlatiladi
  // (/api/seasons/:animeId/:seasonId).
  Future<void> _deleteSeason(int seasonId, String nomi) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Bo\'limni o\'chirish?', style: TextStyle(color: Colors.white)),
        content: Text(
          '"$nomi" bo\'limini rostanxam o\'chirmoqchisiz?',
          style: TextStyle(color: Colors.white.withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Yo\'q', style: TextStyle(color: Colors.white.withOpacity(0.5))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Ha, o\'chirish'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final res = await http.delete(Uri.parse('$API_BASE/api/seasons/$_animeId/$seasonId'));
      if (res.statusCode == 200) {
        if (mounted) _loadSeasons();
      } else {
        throw 'O\'chirishda xato';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Xato: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final animePhoto = widget.anime['photo_url'] as String?;
    final animeName = widget.anime['name'] ?? '';

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // + tugmasi — pastki O'NG tarafda (anime_management_screen bilan bir xil)
        floatingActionButton: Padding(
          padding: const EdgeInsets.only(bottom: 80),
          child: FloatingActionButton(
            onPressed: () => _navigateToAddSeason(),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            backgroundColor: Colors.white.withOpacity(0.18),
            foregroundColor: Colors.white,
            child: const Icon(Icons.add_rounded, size: 28),
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        body: SafeArea(
          child: Column(
            children: [
              // ── Sticky header: anime rasmi + nomi — doim ko'rinadi ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Glass(
                  borderRadius: 20,
                  blur: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(
                    children: [
                      GlassTappable(
                        onTap: () => Navigator.of(context).pop(),
                        child: const Glass(
                          borderRadius: 14,
                          blur: 14,
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.arrow_back_rounded, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          image: DecorationImage(
                            image: NetworkImage(animePhoto ?? ''),
                            fit: BoxFit.cover,
                            onError: (_, __) {},
                          ),
                          color: Colors.white.withOpacity(0.10),
                        ),
                        child: animePhoto == null
                            ? const Icon(Icons.movie_creation_outlined,
                                color: Colors.white54, size: 20)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              animeName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            Text(
                              'Bo\'limni boshqarish',
                              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Bo'limlar ro'yxati ──
              Expanded(
                child: _isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation(Colors.white.withOpacity(0.6)),
                        ),
                      )
                    : _errorMsg != null
                        ? Center(
                            child: Text(_errorMsg!,
                                style: TextStyle(color: Colors.white.withOpacity(0.7))),
                          )
                        : _seasons.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.video_library_outlined,
                                        size: 52, color: Colors.white24),
                                    const SizedBox(height: 12),
                                    Text('Hali bo\'lim qo\'shilmagan',
                                        style: TextStyle(color: Colors.white.withOpacity(0.45))),
                                    const SizedBox(height: 4),
                                    Text('Pastdagi + tugmasi orqali qo\'sh',
                                        style: TextStyle(
                                            fontSize: 12, color: Colors.white.withOpacity(0.3))),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                                itemCount: _seasons.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 10),
                                itemBuilder: (context, i) {
                                  final s = _seasons[i];
                                  return RepaintBoundary(
                                    child: GestureDetector(
                                      onTap: () => _navigateToEpizodlar(s),
                                      child: Glass(
                                        borderRadius: 18,
                                        blur: 14,
                                        tint: 0.10,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 12),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 64,
                                              height: 64,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(12),
                                                image: DecorationImage(
                                                  image:
                                                      NetworkImage(s['photo_url'] ?? ''),
                                                  fit: BoxFit.cover,
                                                  onError: (_, __) {},
                                                ),
                                                color: Colors.white.withOpacity(0.10),
                                              ),
                                              child: s['photo_url'] == null
                                                  ? const Icon(Icons.movie_creation_outlined,
                                                      color: Colors.white54, size: 22)
                                                  : null,
                                            ),
                                            const SizedBox(width: 14),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    '${s['bolim_id'] ?? s['season_id'] ?? '?'}-bo\'lim — ${s['nomi'] ?? ''}',
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        color: Colors.white,
                                                        fontWeight: FontWeight.w600,
                                                        fontSize: 14),
                                                  ),
                                                  const SizedBox(height: 3),
                                                  Wrap(
                                                    spacing: 6,
                                                    children: [
                                                      if ((s['turi'] ?? '').toString().isNotEmpty)
                                                        _tag(s['turi']),
                                                      if ((s['holati'] ?? '').toString().isNotEmpty)
                                                        _tag(s['holati']),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    'Epizodlarni ko\'rish →',
                                                    style: TextStyle(
                                                        fontSize: 11,
                                                        color: AppColors.accent.withOpacity(0.8)),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            IconButton(
                                              onPressed: () => _navigateToAddSeason(season: s),
                                              icon: const Icon(Icons.edit_rounded,
                                                  color: Colors.white54, size: 20),
                                              splashRadius: 22,
                                            ),
                                            IconButton(
                                              onPressed: () => _deleteSeason(
                                                  s['season_id'], s['nomi'] ?? ''),
                                              icon: const Icon(Icons.delete_outline_rounded,
                                                  color: Colors.redAccent, size: 20),
                                              splashRadius: 22,
                                            ),
                                          ],
                                        ),
                                      ),
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

  Widget _tag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10, color: AppColors.accent, fontWeight: FontWeight.w600)),
    );
  }
}
