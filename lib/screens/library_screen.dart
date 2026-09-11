// lib/screens/library_screen.dart — KUTUBXONA.
//
// Uchta oyna:
//
//   1. Tomoshalar tarixi — ishlaydi (`HistoryTab`);
//   2. Sevimlilar       — keyingi vazifa, hozircha bo'sh;
//   3. Yuklanmalar      — keyingi vazifa, hozircha bo'sh.
//
// Oynalar `IndexedStack` bilan almashadi: bosilgan zahoti o'tadi va
// ochilgan oyna holati (masalan tarix ro'yxatining o'rni) saqlanib
// qoladi.

import 'package:flutter/material.dart';

import '../widgets/glass.dart';
import 'history_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _tab = 0;

  static const _titles = ['Tarix', 'Sevimlilar', 'Yuklanmalar'];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Row(
            children: [
              Text('Kutubxona',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: List.generate(_titles.length, (i) {
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i == _titles.length - 1 ? 0 : 8),
                  child: _TabButton(
                    label: _titles[i],
                    active: _tab == i,
                    onTap: () => setState(() => _tab = i),
                  ),
                ),
              );
            }),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            sizing: StackFit.expand,
            children: const [
              HistoryTab(),
              _SoonTab(label: 'Sevimlilar', icon: Icons.favorite_border_rounded),
              _SoonTab(label: 'Yuklanmalar', icon: Icons.download_rounded),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabButton(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: active ? AppColors.accent.withValues(alpha: 0.16) : AppColors.card,
          border: Border.all(
            color: active ? AppColors.accent : AppColors.border,
            width: 1,
          ),
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? Colors.white : Colors.white60,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Hali tayyor bo'lmagan oyna.
///
/// Bo'm-bo'sh qoldirilmaydi: foydalanuvchi tugmani bosib hech narsa
/// ko'rmasa, ilovani buzuq deb o'ylaydi.
class _SoonTab extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SoonTab({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 100),
        child: Glass(
          borderRadius: 20,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 46, color: Colors.white54),
              const SizedBox(height: 12),
              Text('$label tez orada',
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }
}
