import 'package:flutter/material.dart';
import '../services/image_cache.dart';

import '../services/disk_cache.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'add_anime_screen.dart';
import 'season_management_screen.dart';

const String API_BASE = 'https://arumediatv.uzcom.workers.dev';

class AnimeManagementScreen extends StatefulWidget {
  const AnimeManagementScreen({super.key});

  @override
  State<AnimeManagementScreen> createState() => _AnimeManagementScreenState();
}

class _AnimeManagementScreenState extends State<AnimeManagementScreen> {
  List<Map<String, dynamic>> _animes = [];
  bool _isLoading = true;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _loadAnimes();
  }

  /// Diskdagi kalit.
  ///
  /// TALAB (foydalanuvchi): "admin panelidagi ma'lumotlar ham
  /// diskda saqlansin, keyingi safar sekin ochilmasligi uchun".
  static const String _diskKey = 'admin_anime';

  Future<void> _loadAnimes() async {
    // 1) DISK — tarmoq umuman kutilmaydi, ekran darhol to'ladi.
    if (_animes.isEmpty) {
      final cached = DiskCache.read(_diskKey);
      if (cached != null) setState(() => _animes = cached);
    }
    setState(() {
      // Diskda nusxa bo'lsa aylana ko'rsatilmaydi — ro'yxat
      // allaqachon ekranda.
      _isLoading = _animes.isEmpty;
      _errorMsg = null;
    });
    try {
      final res = await http.get(Uri.parse('$API_BASE/api/anime'));
      // Ekran yopilib ketgan bo'lsa `setState` chaqirish
      // istisno tashlaydi ("setState() called after dispose()") —
      // shu sabab har bir kutishdan keyin tekshiriladi.
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        final rows = data.cast<Map<String, dynamic>>();
        DiskCache.write(_diskKey, rows);
        setState(() => _animes = rows);
      } else {
        throw 'Animelar yuklab olib bo\'lmadi';
      }
    } catch (e) {
      if (mounted) setState(() => _errorMsg = 'Xato: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _navigateToAddAnime({Map<String, dynamic>? anime}) async {
    final result = await Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, animation, __) => AddAnimeScreen(initialAnime: anime),
        transitionsBuilder: (_, animation, __, child) {
          final curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position:
                  Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                      .animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    if (result == true) _loadAnimes();
  }

  void _navigateToSeasonManagement(Map<String, dynamic> anime) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, animation, __) => SeasonManagementScreen(anime: anime),
        transitionsBuilder: (_, animation, __, child) {
          final curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position:
                  Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                      .animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Future<void> _deleteAnime(int id, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.cardAlt,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Animeni o\'chirish?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '"$name" animeni rostanxam o\'chirmoqchisiz?',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Yo\'q',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
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
      final res = await http.delete(Uri.parse('$API_BASE/api/anime/$id'));
      if (res.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Anime o\'chirildi'),
              backgroundColor: Colors.green.withValues(alpha: 0.8),
            ),
          );
          _loadAnimes();
        }
      } else {
        throw 'O\'chirishda xato';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Xato: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: Padding(
          padding: const EdgeInsets.only(bottom: 80),
          child: FloatingActionButton(
            onPressed: () => _navigateToAddAnime(),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            backgroundColor: Colors.white.withValues(alpha: 0.18),
            foregroundColor: Colors.white,
            child: const Icon(Icons.add_rounded, size: 28),
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Glass(
                  borderRadius: 20,
                  blur: 16,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  child: Row(
                    children: [
                      GlassTappable(
                        onTap: () => Navigator.of(context).pop(),
                        child: const Glass(
                          borderRadius: 14,
                          blur: 14,
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.arrow_back_rounded,
                              color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Text(
                          'Animelarni boshqarish',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation(
                              Colors.white.withValues(alpha: 0.6)),
                        ),
                      )
                    : _errorMsg != null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.error_outline,
                                    size: 48, color: Colors.red),
                                const SizedBox(height: 12),
                                Text(_errorMsg!,
                                    style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.7))),
                                const SizedBox(height: 16),
                                FilledButton(
                                  onPressed: _loadAnimes,
                                  child: const Text('Qayta urinish'),
                                ),
                              ],
                            ),
                          )
                        : _animes.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.movie_creation_outlined,
                                        size: 52, color: Colors.white24),
                                    const SizedBox(height: 12),
                                    Text('Hali anime qo\'shilmagan',
                                        style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.45))),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 4, 16, 120),
                                itemCount: _animes.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, i) {
                                  final anime = _animes[i];
                                  return RepaintBoundary(
                                    child: Glass(
                                      borderRadius: 18,
                                      blur: 14,
                                      tint: 0.10,
                                      padding: EdgeInsets.zero,
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          // Rasm/nomi ustiga bosilganda —
                                          // shu animega tegishli "Bo'limni
                                          // boshqarish" sahifasi ochiladi.
                                          onTap: () =>
                                              _navigateToSeasonManagement(
                                                  anime),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 12),
                                            child: Row(
                                              children: [
                                                // Rasm — kattaroq qilindi (56 → 76)
                                                Container(
                                                  width: 76,
                                                  height: 76,
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            14),
                                                    image: DecorationImage(
                                                      // 76 dp -> 228 px.
                                                      image: ResizeImage(
                                                        appImageProvider(
                              
                                                            anime['photo_url'] ??
                                                                ''),
                                                        width: 228,
                                                        allowUpscaling: false,
                                                      ),
                                                      fit: BoxFit.cover,
                                                      onError: (_, __) {},
                                                    ),
                                                    color: Colors.white
                                                        .withValues(alpha: 0.10),
                                                  ),
                                                  child: anime['photo_url'] ==
                                                          null
                                                      ? const Icon(
                                                          Icons
                                                              .movie_creation_outlined,
                                                          color: Colors.white54,
                                                          size: 26)
                                                      : null,
                                                ),
                                                const SizedBox(width: 14),

                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(anime['name'] ?? '',
                                                          style:
                                                              const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  fontSize:
                                                                      15)),
                                                      Text(anime['janri'] ?? '',
                                                          style: TextStyle(
                                                              color: Colors
                                                                  .white
                                                                  .withValues(alpha: 
                                                                      0.5),
                                                              fontSize: 12)),
                                                    ],
                                                  ),
                                                ),

                                                // Tahrirlash — oddiy IconButton,
                                                // birinchi bosishdayoq ishlaydi
                                                IconButton(
                                                  onPressed: () =>
                                                      _navigateToAddAnime(
                                                          anime: anime),
                                                  icon: const Icon(
                                                      Icons.edit_rounded,
                                                      color: Colors.white54,
                                                      size: 20),
                                                  splashRadius: 22,
                                                ),

                                                // O'chirish
                                                IconButton(
                                                  onPressed: () => _deleteAnime(
                                                      anime['id'],
                                                      anime['name']),
                                                  icon: const Icon(
                                                      Icons
                                                          .delete_outline_rounded,
                                                      color: Colors.redAccent,
                                                      size: 20),
                                                  splashRadius: 22,
                                                ),
                                              ],
                                            ),
                                          ),
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
}
