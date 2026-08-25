import 'package:flutter/material.dart';

/// ------------------------------------------------------------
/// DATA MODEL
/// ------------------------------------------------------------
class Anime {
  final String title;
  final String genre;
  final double rating;
  final Color color;

  const Anime({
    required this.title,
    required this.genre,
    required this.rating,
    required this.color,
  });
}

const List<Anime> dummyAnimeList = [
  Anime(title: 'Shadow Blade', genre: 'Action', rating: 4.8, color: Color(0xFF7B2CBF)),
  Anime(title: 'Sky Wanderer', genre: 'Fantasy', rating: 4.6, color: Color(0xFF3A86FF)),
  Anime(title: 'Cherry Blossom', genre: 'Romance', rating: 4.7, color: Color(0xFFFF5C8A)),
  Anime(title: 'Iron Fist', genre: 'Sport', rating: 4.3, color: Color(0xFFFB8500)),
  Anime(title: 'Neon City', genre: 'Sci-Fi', rating: 4.9, color: Color(0xFF06D6A0)),
  Anime(title: 'Silent Forest', genre: 'Mystery', rating: 4.5, color: Color(0xFF8338EC)),
];

const List<String> genres = [
  'Action', 'Fantasy', 'Romance', 'Sport', 'Sci-Fi', 'Mystery', 'Comedy', 'Drama',
];
