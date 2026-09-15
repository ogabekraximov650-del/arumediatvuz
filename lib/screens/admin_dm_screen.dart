// lib/screens/admin_dm_screen.dart — ADMIN: BARCHA SHAXSIY CHATLAR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "faqat barcha shaxsiy chatlar admin panelida
// ko'rinishi kerak, ya'ni ikkala profil rasmi bitta ro'yxatda
// turadi va ustiga bossa ikkalasini yuborgan xabarlari chiqadi.
// Bu biroz noto'g'ri lekin xavfsizlik va nomaqbul hatti
// harakatlarni oldini olish uchun zarur".
//
// Shu sabab ro'yxatda IKKALA rasm yonma-yon turadi.
//
// ── ADMIN FAQAT O'QIYDI ─────────────────────────────────────
//
// Bu yerda yozish qatori YO'Q va u ataylab qo'shilmagan: admin
// boshqaning nomidan yoza olmasligi kerak. Serverda ham shunday
// — suhbat raqami har doim YOZAYOTGAN odamning o'z ID'sidan
// quriladi.
//
// Nomaqbul xabarni olib tashlash mumkin: xabarni bosib turilsa
// o'chirish chiqadi (`dm_del_message` adminni o'tkazadi).

import 'package:flutter/material.dart';

import '../services/dm_service.dart';
import '../services/format.dart';
import '../services/screen_guard.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'dm_threads_screen.dart' show DmAvatar;

class AdminDmScreen extends StatefulWidget {
  const AdminDmScreen({super.key});

  @override
  State<AdminDmScreen> createState() => _AdminDmScreenState();
}

class _AdminDmScreenState extends State<AdminDmScreen> {
  final _ctrl = AdminDmController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _ctrl.load();
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

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('Shaxsiy chatlar',
              style: TextStyle(color: Colors.white, fontSize: 18)),
          actions: [
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) => Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    '${_ctrl.total}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) => _body(),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_ctrl.isLoading) {
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
                  Icon(Icons.forum_outlined,
                      size: 46, color: Colors.white.withValues(alpha: 0.2)),
                  const SizedBox(height: 12),
                  Text(
                    _ctrl.error ?? 'Hozircha shaxsiy suhbat yo\'q',
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
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
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
          final t = _ctrl.items[i];
          return _Row(
            thread: t,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _AdminDmView(thread: t),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Ro'yxatdagi bitta suhbat — IKKALA rasm bilan.
class _Row extends StatelessWidget {
  final AdminDmThread thread;
  final VoidCallback onTap;

  const _Row({required this.thread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = thread;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassTappable(
        onTap: onTap,
        child: Glass(
          borderRadius: 16,
          blur: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // ── IKKALA RASM BITTA JOYDA ──────────────────
              //
              // Foydalanuvchi talabi: "ikkala profil rasmi
              // bitta ro'yxatda turadi". Ustma-ust qo'yilgan:
              // shunda ikkovi ham ko'rinadi va joy ham tejaladi.
              SizedBox(
                width: 62,
                height: 44,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      child: DmAvatar(
                          url: t.a.photoUrl, name: t.a.name, size: 40),
                    ),
                    Positioned(
                      left: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: AppColors.card, width: 2),
                        ),
                        child: DmAvatar(
                            url: t.b.photoUrl, name: t.b.name, size: 40),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${t.a.name}  ·  ${t.b.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          commentAgo(t.lastAt),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.38),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      t.lastBody,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${t.msgCount} ta xabar',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  BITTA SUHBATNI KO'RISH (faqat o'qish)
// ══════════════════════════════════════════════════════════════

class _AdminDmView extends StatefulWidget {
  final AdminDmThread thread;
  const _AdminDmView({required this.thread});

  @override
  State<_AdminDmView> createState() => _AdminDmViewState();
}

class _AdminDmViewState extends State<_AdminDmView>
    // Bu yerda ham skrinshot va ekran yozuvi taqiqlanadi:
    // yozishma tarkibi shaxsiy (foydalanuvchi talabi).
    with ScreenGuarded<_AdminDmView> {
  List<DmMessage> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await adminDmMessages(widget.thread.dmId);
    if (!mounted) return;
    setState(() {
      _items = rows;
      _loading = false;
    });
  }

  /// Nomaqbul xabarni o'chirish.
  ///
  /// Admin YOZA olmaydi, lekin qoidabuzar xabarni olib
  /// tashlashi kerak — shusiz shikoyat tizimining ma'nosi
  /// qolmaydi.
  Future<void> _confirmDelete(DmMessage m) async {
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
                'Bu xabar o\'chirilsinmi?',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 6),
              Text(
                'Ikkala tomondan ham o\'chadi.',
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
    if (ok != true || !mounted) return;
    final err = await adminDeleteDmMessage(m.id);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.card,
          content: Text(err, style: const TextStyle(color: Colors.white)),
        ),
      );
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.thread;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(
            '${t.a.name} · ${t.b.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
        body: SafeArea(
          top: false,
          child: _loading
              ? Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppColors.accent),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final m = _items[i];
                    // Kim yozganini `from_id` aniqlaydi: admin
                    // ikkovidan biri emas, shu sabab `mine`
                    // ishlamaydi.
                    final fromA = m.fromId == t.a.userId;
                    final who = fromA ? t.a : t.b;
                    return _AdminBubble(
                      message: m,
                      who: who,
                      left: fromA,
                      onLongPress: () => _confirmDelete(m),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _AdminBubble extends StatelessWidget {
  final DmMessage message;
  final DmPerson who;
  final bool left;
  final VoidCallback onLongPress;

  const _AdminBubble({
    required this.message,
    required this.who,
    required this.left,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final m = message;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment:
            left ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (left) ...[
            DmAvatar(url: who.photoUrl, name: who.name, size: 26),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress,
              behavior: HitTestBehavior.opaque,
              child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: left
                    ? Colors.white.withValues(alpha: 0.09)
                    : AppColors.accent.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    who.name,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    m.body,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, height: 1.35),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    commentClock(m.createdAt),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
          if (!left) ...[
            const SizedBox(width: 8),
            DmAvatar(url: who.photoUrl, name: who.name, size: 26),
          ],
        ],
      ),
    );
  }
}
