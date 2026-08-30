import 'package:flutter/material.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

class AnimeDetailScreen extends StatelessWidget {
  final Map<String, dynamic> anime;
  const AnimeDetailScreen({super.key, required this.anime});

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
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
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Glass(
                    borderRadius: 22,
                    blur: 18,
                    child: Container(
                      height: 240,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        image: DecorationImage(
                          image: NetworkImage(
                            anime['photo_url'] ?? '',
                          ),
                          fit: BoxFit.cover,
                          onError: (_, __) {},
                        ),
                        color: Colors.white.withOpacity(0.12),
                      ),
                      child: anime['photo_url'] == null
                          ? const Center(
                              child: Icon(
                                Icons.movie_creation_outlined,
                                size: 72,
                                color: Colors.white70,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Glass(
                    borderRadius: 22,
                    blur: 16,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(anime['name'] ?? '',
                            style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Chip(
                              label: Text(anime['janri'] ?? ''),
                              backgroundColor: Colors.white.withOpacity(0.12),
                              labelStyle:
                                  const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(width: 8),
                            Text(anime['davlat'] ?? '',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.6),
                                    fontSize: 13)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('Studiya: ${anime['studiya'] ?? ''}',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 13)),
                        const SizedBox(height: 20),
                        Text(
                          anime['tavsif'] ?? '',
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.6,
                            color: Colors.white.withOpacity(0.8),
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () {},
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Tomosha qilish'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );
  }
}
