import 'package:flutter/material.dart';
import '../services/image_cache.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../widgets/glass.dart';
import '../services/rust_bridge.dart';
import 'anime_detail_screen.dart';

const String API_BASE = 'https://arumediatv.uzcom.workers.dev';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _allSeasons = [];
  List<Map<String, dynamic>> _results = [];
  bool _isSearching = false;
  bool _hasSearched = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    try {
      if (_allSeasons.isEmpty) {
        final res = await http.get(Uri.parse('$API_BASE/api/seasons'));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as List;
          _allSeasons = data.cast<Map<String, dynamic>>();
        }
      }

      // Rust'dagi qidiruv funksiyasi 'name' maydonini kutadi — season_db'da
      // bu maydon 'nomi' deb ataladi, shuning uchun vaqtincha moslashtiramiz.
      final searchable =
          _allSeasons.map((s) => {...s, 'name': s['nomi'] ?? ''}).toList();
      final filtered = RustCore.instance.searchFilter(searchable, query);

      if (!mounted) return;
      setState(() {
        _results = filtered;
        _hasSearched = true;
      });
    } catch (e) {
      if (mounted) setState(() => _hasSearched = true);
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _clear() {
    _searchCtrl.clear();
    setState(() {
      _results = [];
      _hasSearched = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          Glass(
            borderRadius: 18,
            blur: 16,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.search_rounded, color: Colors.white70),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white),
                    onChanged: _search,
                    decoration: InputDecoration(
                      hintText: 'Anime qidirish...',
                      hintStyle:
                          TextStyle(color: Colors.white.withValues(alpha: 0.54)),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _searchCtrl.text.isNotEmpty
                      ? GestureDetector(
                          key: const ValueKey('clear'),
                          onTap: _clear,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            child: Icon(Icons.close_rounded,
                                size: 20, color: Colors.white.withValues(alpha: 0.7)),
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('empty')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: _isSearching
                ? Center(
                    child: CircularProgressIndicator(
                      valueColor:
                          AlwaysStoppedAnimation(Colors.white.withValues(alpha: 0.6)),
                    ),
                  )
                : _results.isEmpty && _hasSearched
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.search_off_rounded,
                                size: 48, color: Colors.white24),
                            const SizedBox(height: 12),
                            Text('Qidiruv natijalari topilmadi',
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.54))),
                          ],
                        ),
                      )
                    : _results.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.search_rounded,
                                    size: 48, color: Colors.white24),
                                const SizedBox(height: 12),
                                Text('Anime nomini yozib qidiruv qiling',
                                    style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.54))),
                              ],
                            ),
                          )
                        : GridView.builder(
                            physics: const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics()),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 14,
                              crossAxisSpacing: 14,
                              childAspectRatio: 0.68,
                            ),
                            itemCount: _results.length,
                            itemBuilder: (context, i) =>
                                _SeasonSearchCard(season: _results[i]),
                          ),
          ),
        ],
      ),
    );
  }
}

class _SeasonSearchCard extends StatelessWidget {
  final Map<String, dynamic> season;
  const _SeasonSearchCard({required this.season});

  @override
  Widget build(BuildContext context) {
    return GlassTappable(
      onTap: () {
        Navigator.of(context).push(
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 320),
            pageBuilder: (_, animation, __) => AnimeDetailScreen(anime: season),
            transitionsBuilder: (_, animation, __, child) {
              final curved = CurvedAnimation(
                  parent: animation, curve: Curves.easeOutCubic);
              return FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.1), end: Offset.zero)
                      .animate(curved),
                  child: child,
                ),
              );
            },
          ),
        );
      },
      child: GlassLite(
        borderRadius: 18,
        tint: 0.08,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(18)),
                  image: DecorationImage(
                    // Ikki ustunli katak ~166 dp keng -> 540 px.
                    image: ResizeImage(
                      appImageProvider(
                              season['photo_url'] ?? ''),
                      width: 540,
                      allowUpscaling: false,
                    ),
                    fit: BoxFit.cover,
                    onError: (_, __) {},
                  ),
                  color: Colors.white.withValues(alpha: 0.10),
                ),
                child: (season['photo_url'] == null ||
                        (season['photo_url'] as String).isEmpty)
                    ? const Center(
                        child: Icon(Icons.movie_creation_outlined,
                            size: 40, color: Colors.white70))
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    season['nomi'] ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: Colors.white),
                  ),
                  Text(
                    season['janri'] ?? '',
                    style: TextStyle(
                        fontSize: 12, color: Colors.white.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
