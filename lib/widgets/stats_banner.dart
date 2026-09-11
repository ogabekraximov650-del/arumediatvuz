// lib/widgets/stats_banner.dart — BOSH SAHIFADAGI STATISTIKA.
//
// Yuqori qismida:
//
//   Umumiy statistikani ko'rish  ›
//   Kunlik foydalanuvchilar: 1.284 ta
//   ────────────────────────────────
//   👁 Kunlik ko'rishlar: 312 ta        ← o'zi almashib turadi
//
// Pastki qator VAQTI-VAQTI BILAN o'ngdan chapga surilib almashadi
// (foydalanuvchi talabi). Uzluksiz "yuguruvchi qator" ATAYLAB
// ishlatilmadi: u har kadrda qayta chiziladi va kuchsiz telefonda
// butun sahifani sekinlashtiradi. Bu yerda esa har 4 soniyada
// bitta qisqa suzish bo'ladi, xolos.

import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/stats_screen.dart';
import '../services/format.dart';
import '../services/stats_service.dart';
import 'glass.dart';

class StatsBanner extends StatefulWidget {
  const StatsBanner({super.key});

  @override
  State<StatsBanner> createState() => _StatsBannerState();
}

class _StatsBannerState extends State<StatsBanner> {
  Timer? _timer;
  int _index = 0;

  static const Duration _every = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    StatsService.instance.loadFromDisk();
    StatsService.instance.load();
    _timer = Timer.periodic(_every, (_) {
      if (!mounted) return;
      setState(() => _index++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<({IconData icon, String text})> _items(AppStats s) {
    return [
      (
        icon: Icons.play_circle_outline_rounded,
        text: 'Kunlik ko\'rishlar: ${formatCount(s.views.daily)} ta'
      ),
      (
        icon: Icons.cloud_download_outlined,
        text: 'Kunlik trafik: ${formatBytes(s.traffic.daily)}'
      ),
      (
        icon: Icons.schedule_rounded,
        text: 'Kunlik tomosha: ${formatHours(s.watch.daily)} soat'
      ),
      (
        icon: Icons.people_outline_rounded,
        text: 'Jami foydalanuvchi: ${formatCount(s.users.total)} ta'
      ),
      (
        icon: Icons.visibility_outlined,
        text: 'Jami ko\'rishlar: ${formatCount(s.views.total)} ta'
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: StatsService.instance,
      builder: (context, _) {
        final s = StatsService.instance.stats;
        final items = _items(s);
        final item = items[_index % items.length];

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).push(
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 280),
              pageBuilder: (_, anim, __) => const StatsScreen(),
              transitionsBuilder: (_, anim, __, child) => FadeTransition(
                opacity:
                    CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                child: child,
              ),
            ),
          ),
          child: Glass(
            borderRadius: 18,
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Umumiy statistikani ko\'rish',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        color: Colors.white.withValues(alpha: 0.6), size: 22),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Kunlik foydalanuvchilar: ${formatCount(s.users.daily)} ta',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                // ── O'ZI ALMASHIB TURADIGAN QATOR ──────────────
                //
                // Eskisi chapga chiqib ketadi, yangisi o'ngdan
                // kirib keladi.
                ClipRect(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) {
                      final incoming = child.key == ValueKey<int>(_index);
                      final begin = incoming
                          ? const Offset(1, 0)
                          : const Offset(-1, 0);
                      return SlideTransition(
                        position: Tween<Offset>(begin: begin, end: Offset.zero)
                            .animate(anim),
                        child: FadeTransition(opacity: anim, child: child),
                      );
                    },
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [...previous, if (current != null) current],
                    ),
                    child: Row(
                      key: ValueKey<int>(_index),
                      children: [
                        Icon(item.icon,
                            size: 15,
                            color: Colors.white.withValues(alpha: 0.55)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.72),
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
