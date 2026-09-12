// lib/screens/favorites_screen.dart — SEVIMLILAR.
//
// Pleyerdagi "Sevimlilarga qo'shish" (yurakcha) bosilgan bo'limlar
// AYNAN shu yerda ko'rinadi. Kartochka bosilsa — o'sha bo'lim
// pleyerda ochiladi (oxirgi ko'rilgan qismidan).
//
// Ro'yxat serverdan bitta so'rov bilan keladi (`GET /api/favorites`)
// va diskka shifrlangan holda yoziladi — oflaynda ham ko'rinadi.

import 'package:flutter/material.dart';

import '../services/offline_library.dart';
import '../services/season_info.dart';
import '../widgets/glass.dart';
import 'home_screen.dart';
import 'video_player_screen.dart';

class FavoritesTab extends StatefulWidget {
  const FavoritesTab({super.key});

  @override
  State<FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends State<FavoritesTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Diskdagi nusxa darhol, tarmoq esa Kutubxona tugmasi
    // bosilganda (`RootScreen`) yangilaydi.
    FavoritesService.instance.loadFromDisk();
  }

  void _open(Map<String, dynamic> season) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, anim, __) => VideoPlayerScreen(season: season),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge(
          [FavoritesService.instance, OfflineLibrary.instance]),
      builder: (context, _) {
        final fav = FavoritesService.instance;
        final lib = OfflineLibrary.instance;
        var rows = fav.items;
        // ── OFLAYNDA — FAQAT YUKLAB OLINGANLARI ─────────────
        //
        // TALAB (foydalanuvchi): "oflayn vaqtda ... saqlangan
        // animelardan faqatgina yuklab olingan epizodi borlari
        // ko'rinsin, qolganlari esa yashirilsin lekin xotirada
        // tursin".
        //
        // Ro'yxatning o'zi tegilmaydi — u diskda to'liq turaveradi.
        if (lib.isOffline && lib.ready) {
          rows = rows.where((s) {
            final a = int.tryParse('${s['anime_id'] ?? ''}') ?? 0;
            final sid = int.tryParse('${s['season_id'] ?? ''}') ?? 0;
            return lib.hasSeason(a, sid);
          }).toList();
        }

        return RefreshIndicator(
          color: AppColors.accent,
          backgroundColor: AppColors.card,
          onRefresh: () => fav.load(force: true),
          child: rows.isEmpty
              ? _EmptyFavorites(loading: fav.isLoading)
              : GridView.builder(
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
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
                      onTap: () => _open(rows[i]),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _EmptyFavorites extends StatelessWidget {
  final bool loading;
  const _EmptyFavorites({required this.loading});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      children: [
        const SizedBox(height: 90),
        Center(
          child: Glass(
            borderRadius: 20,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white70),
                  )
                else
                  const Icon(Icons.favorite_border_rounded,
                      size: 46, color: Colors.white54),
                const SizedBox(height: 12),
                Text(
                  loading
                      ? 'Yuklanmoqda...'
                      : 'Hali sevimli bo\'lim qo\'shilmagan',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                if (!loading) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Pleyerdagi yurakchani bosing',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
