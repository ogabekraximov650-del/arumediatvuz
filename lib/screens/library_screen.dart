// lib/screens/library_screen.dart — KUTUBXONA.
//
// Uchta oyna:
//
//   1. Tomoshalar tarixi — ishlaydi (`HistoryTab`);
//   2. Sevimlilar       — ishlaydi (`FavoritesTab`): pleyerda
//      yurakcha bosilgan bo'limlar shu yerda turadi;
//
// "Yuklanmalar" ILGARI shu yerda uchinchi oyna edi; endi u tomosha
// tarixining uchinchi sahifasi (foydalanuvchi talabi).
//
// Oynalar `IndexedStack` bilan almashadi: bosilgan zahoti o'tadi va
// ochilgan oyna holati (masalan tarix ro'yxatining o'rni) saqlanib
// qoladi.

import 'package:flutter/material.dart';

import '../widgets/glass.dart';
import 'favorites_screen.dart';
import 'history_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _tab = 0;

  // ── "YUKLANMALAR" BU YERDA EMAS ────────────────────────────
  //
  // TALAB (foydalanuvchi): "Kutubxona sahifasidagi yuklanmalar
  // oynasini olib tashlab, tarix oynasiga qism bo'yicha oynasining
  // o'ng tarafiga qo'sh".
  //
  // Endi u `HistoryTab` ning uchinchi sahifasi (`DownloadsList`) —
  // ya'ni barmoq bilan surib o'tiladi.
  static const _titles = ['Tarix', 'Sevimlilar'];

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
              FavoritesTab(),
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
