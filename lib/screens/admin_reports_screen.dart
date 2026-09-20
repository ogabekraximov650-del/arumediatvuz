// lib/screens/admin_reports_screen.dart — SHIKOYATLAR BO'LIMI.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "admin panelida shikoyatlar bo'limida shikoyat
// qayerdan kelgani (masalan izohdan), shikoyat qilingan izoh va
// shikoyat qiluvchining xabari tursin. Tagida esa Tekshirish,
// Xabar yuborish va Tozalash degan tugma bo'ladi.
//
// Tekshirish tugmasi orqali shikoyat qilingan izohni ochadi,
// xabar yuborish orqali shikoyat qiluvchiga support chatdan
// xabar yuboradi, tozalash orqali kelgan shikoyatni bazadan
// tozalaydi".
//
// ── UCHTA TUGMA NIMA QILADI ─────────────────────────────────
//
//   TEKSHIRISH    — izohni to'liq ko'rsatadi: muallifi, matni va
//                   hozir ham turgani. O'sha yerdan muallifning
//                   profiliga o'tish va izohni o'chirish mumkin.
//   XABAR YUBORISH — shikoyat QILUVCHI bilan yozishmani ochadi
//                   (o'sha support chat, admin tomoni).
//   TOZALASH      — shikoyatni bazadan butunlay o'chiradi.
//
// ── NEGA IZOH NUSXASI KO'RSATILADI ──────────────────────────
//
// Shikoyat kelgan paytdagi matn bazada saqlanadi. Izohni egasi
// o'chirib yuborsa ham admin nimadan shikoyat qilinganini
// ko'radi — aks holda ro'yxatda bo'sh qator turardi.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../widgets/emoji_text.dart';
import '../services/image_cache.dart';

import '../services/format.dart';
import '../services/reports_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'public_profile_screen.dart';
import 'support_chat_screen.dart';

class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  final _ctrl = AdminReportsController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _ctrl.load();
    // Pastga yetganda keyingi sahifa o'zi so'raladi.
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final left = _scroll.position.maxScrollExtent - _scroll.position.pixels;
      if (left < 400) _ctrl.loadMore();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card,
        content: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  // ── TEKSHIRISH ──────────────────────────────────────────────
  Future<void> _inspect(AdminReport r) async {
    final deleted = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      constraints: const BoxConstraints(),
      builder: (_) => _InspectSheet(report: r),
    );
    if (deleted == true && mounted) {
      // Izoh o'chdi — serverda unga kelgan shikoyatlar ham o'chdi,
      // ya'ni ro'yxat qaytadan so'raladi.
      await _ctrl.load(force: true);
      if (mounted) _say('Izoh o\'chirildi');
    }
  }

  // ── XABAR YUBORISH ──────────────────────────────────────────
  Future<void> _message(AdminReport r) async {
    if (r.reporter.id <= 0) {
      _say('Shikoyat qiluvchi topilmadi');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SupportChatScreen(
          userId: r.reporter.id,
          title: r.reporter.name,
          photoUrl: r.reporter.photoUrl,
        ),
      ),
    );
  }

  // ── TOZALASH ────────────────────────────────────────────────
  Future<void> _clear(AdminReport r) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Glass(
          borderRadius: 22,
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Shikoyat bazadan o\'chirilsinmi?',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 6),
              Text(
                'Izohning o\'ziga tegilmaydi.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12.5),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Yo\'q'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade600),
                      child: const Text('Ha'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    final err = await _ctrl.remove(r.id);
    if (err != null) _say(err);
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
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
                        child: Text('Shikoyatlar',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                      ),
                      AnimatedBuilder(
                        animation: _ctrl,
                        builder: (context, _) => Text(
                          '${_ctrl.total}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, _) => _body(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_ctrl.isLoading && _ctrl.items.isEmpty) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    if (_ctrl.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _ctrl.load(force: true),
        color: AppColors.accent,
        backgroundColor: AppColors.card,
        child: ListView(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          children: [
            const SizedBox(height: 120),
            Center(
              child: Column(
                children: [
                  Icon(Icons.flag_outlined,
                      size: 46, color: Colors.white.withValues(alpha: 0.2)),
                  const SizedBox(height: 12),
                  Text(
                    _ctrl.error ?? 'Hozircha shikoyat yo\'q',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _ctrl.load(force: true),
      color: AppColors.accent,
      backgroundColor: AppColors.card,
      child: ListView.builder(
        controller: _scroll,
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
        itemCount: _ctrl.items.length + (_ctrl.hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= _ctrl.items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white38),
                ),
              ),
            );
          }
          final r = _ctrl.items[i];
          return _ReportCard(
            report: r,
            onInspect: () => _inspect(r),
            onMessage: () => _message(r),
            onClear: () => _clear(r),
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  BITTA SHIKOYAT KARTOCHKASI
// ══════════════════════════════════════════════════════════════

class _ReportCard extends StatelessWidget {
  final AdminReport report;
  final VoidCallback onInspect;
  final VoidCallback onMessage;
  final VoidCallback onClear;

  const _ReportCard({
    required this.report,
    required this.onInspect,
    required this.onMessage,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final r = report;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Glass(
        borderRadius: 18,
        blur: 14,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── QAYERDAN KELGAN VA QACHON ────────────────────
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.shade400.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.flag_rounded,
                          size: 13, color: Colors.red.shade300),
                      const SizedBox(width: 5),
                      Text(
                        r.sourceLabel,
                        style: TextStyle(
                          color: Colors.red.shade300,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  commentAgo(r.createdAt),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 11),

            // ── SHIKOYAT QILINGAN IZOH ───────────────────────
            _Section(
              label: 'Shikoyat qilingan izoh',
              person: r.author,
              body: r.targetBody.isEmpty ? '(matn yo\'q)' : r.targetBody,
              note: r.targetAlive ? null : 'Izoh o\'chirilgan',
            ),
            const SizedBox(height: 10),

            // ── SHIKOYAT QILUVCHINING XABARI ─────────────────
            _Section(
              label: 'Shikoyat qiluvchi xabari',
              person: r.reporter,
              body: r.reason,
            ),
            const SizedBox(height: 12),

            // ── UCHTA TUGMA (foydalanuvchi talabi) ───────────
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    icon: Icons.search_rounded,
                    label: 'Tekshirish',
                    onTap: onInspect,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionButton(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: 'Xabar yuborish',
                    onTap: onMessage,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionButton(
                    icon: Icons.cleaning_services_rounded,
                    label: 'Tozalash',
                    color: Colors.red.shade300,
                    onTap: onClear,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Kartochka ichidagi bitta bo'lak: sarlavha, odam va matn.
class _Section extends StatelessWidget {
  final String label;
  final ReportPerson person;
  final String body;

  /// Qo'shimcha eslatma (masalan "Izoh o'chirilgan").
  final String? note;

  const _Section({
    required this.label,
    required this.person,
    required this.body,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              _Avatar(url: person.photoUrl, name: person.name, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (note != null)
                Text(
                  note!,
                  style: TextStyle(
                    color: Colors.orange.shade300,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // Shikoyat matni ham foydalanuvchi yozgani — emoji
          // bo'lishi mumkin (`emoji_text.dart` izohiga qarang).
          EmojiText(
            body,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white.withValues(alpha: 0.8);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 62,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: c),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 2,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  TEKSHIRISH OYNASI
// ══════════════════════════════════════════════════════════════
//
// Shikoyat qilingan izohni to'liq ko'rsatadi va shu yerdan ikki
// amal bajariladi: muallifning profiliga o'tish va izohni
// o'chirish.
//
// Yopilganda `true` qaytaradi — izoh o'chirilgan degani.

class _InspectSheet extends StatefulWidget {
  final AdminReport report;
  const _InspectSheet({required this.report});

  @override
  State<_InspectSheet> createState() => _InspectSheetState();
}

class _InspectSheetState extends State<_InspectSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await deleteReportedComment(widget.report.targetId);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final media = MediaQuery.of(context);
    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
      decoration: const BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.fromLTRB(18, 10, 18, 16 + media.padding.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Shikoyat qilingan izoh',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              label: 'Muallif va matn',
              person: r.author,
              body: r.targetBody.isEmpty ? '(matn yo\'q)' : r.targetBody,
              note: r.targetAlive ? null : 'Izoh o\'chirilgan',
            ),
            const SizedBox(height: 10),
            Text(
              '${r.animeId}-anime · ${r.seasonId}-bo\'lim · '
              '${commentClock(r.createdAt)}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 11.5,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(
                      color: Colors.red.shade300, fontSize: 12.5)),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: r.author.id <= 0
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              PublicProfileScreen(userId: r.author.id),
                        ),
                      ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 46),
                foregroundColor: Colors.white70,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
              ),
              icon: const Icon(Icons.person_outline_rounded, size: 19),
              label: const Text('Muallif profili'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              // Izoh allaqachon o'chgan bo'lsa tugma o'chiq.
              onPressed: (_busy || !r.targetAlive) ? null : _delete,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 46),
                backgroundColor: Colors.red.shade600,
              ),
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.delete_outline_rounded, size: 19),
              label: Text(r.targetAlive
                  ? 'Izohni o\'chirish'
                  : 'Izoh allaqachon o\'chirilgan'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Foydalanuvchi rasmi. Rasm kelmasa — ismning birinchi harfi.
class _Avatar extends StatelessWidget {
  final String url;
  final String name;
  final double size;

  const _Avatar({required this.url, required this.name, required this.size});

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.12),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.75),
          fontSize: size * 0.45,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    if (url.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        cacheManager: AppImageCache.manager,
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Rasm kichkina — xotirada ham kichik tursin.
        memCacheWidth: (size * 3).round(),
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}
