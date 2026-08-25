// widgets/glass.dart
// Blur yo'q — faqat BoxShadow + gradient + border.
// GPU yuki 0 ga yaqin — istalgan telefondan 60fps+.

import 'package:flutter/material.dart';

// ── Rang konstantlari ─────────────────────────────────────────
class AppColors {
  static const bg = Color(0xFF0A0A14);
  static const surface = Color(0xFF141420);
  static const card = Color(0xFF1C1C2E);
  static const cardAlt = Color(0xFF12122A);
  static const accent = Color(0xFFFF375F);
  static const accent2 = Color(0xFF6C63FF);
  static const accent3 = Color(0xFF00D4FF);
  static const border = Color(0x18FFFFFF);
  static const borderBright = Color(0x28FFFFFF);
}

// ── Card (Glass o'rniga) ──────────────────────────────────────
class Glass extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double blur; // saqlab qolindi — boshqa fayllar uzadi, ignore qilinadi
  final double tint;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final List<BoxShadow>? shadows;

  const Glass({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.blur = 0,
    this.tint = 0.12,
    this.padding,
    this.color,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: color ?? AppColors.card,
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: shadows ??
            [
              BoxShadow(
                color: AppColors.accent2.withOpacity(0.10),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: padding != null ? Padding(padding: padding!, child: child) : child,
      ),
    );
  }
}

// ── GlassLite (ro'yxat elementlari uchun — yengil) ───────────
class GlassLite extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double tint;
  final EdgeInsetsGeometry? padding;

  const GlassLite({
    super.key,
    required this.child,
    this.borderRadius = 18,
    this.tint = 0.10,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: AppColors.cardAlt,
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: padding != null ? Padding(padding: padding!, child: child) : child,
      ),
    );
  }
}

// ── Accent card (rangli shadow bilan) ─────────────────────────
class AccentCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final Color accentColor;
  final EdgeInsetsGeometry? padding;

  const AccentCard({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.accentColor = AppColors.accent2,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: AppColors.card,
        border: Border.all(color: accentColor.withOpacity(0.25), width: 1),
        boxShadow: [
          BoxShadow(
            color: accentColor.withOpacity(0.18),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: padding != null ? Padding(padding: padding!, child: child) : child,
      ),
    );
  }
}

// ── Tappable (spring scale animatsiya) ────────────────────────
class GlassTappable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const GlassTappable({super.key, required this.child, required this.onTap});

  @override
  State<GlassTappable> createState() => _GlassTappableState();
}

class _GlassTappableState extends State<GlassTappable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
    lowerBound: 0.0,
    upperBound: 0.05,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) => Transform.scale(scale: 1 - _ctrl.value, child: child),
        child: widget.child,
      ),
    );
  }
}
