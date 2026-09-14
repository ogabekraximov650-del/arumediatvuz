// lib/screens/admin_chats_screen.dart — BARCHA SUHBATLAR (ADMIN).
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "admin paneliga barcha chatlar bilan bog'langan
// bo'lim qo'sh, huddi animelarni boshqarish bo'limiga kirgandek.
// Bo'limga kirsa huddi Telegram chatidek yangi xabar yuqorida
// tursin va profil rasmi bilan ko'rinib tursin".
//
// ── TARTIB SERVERDA ─────────────────────────────────────────
//
// "Yangi xabar yuqorida" tartibi ilovada emas, SERVERDA
// hisoblanadi (`chat_threads.last_at DESC`). Sabab: ilova faqat
// 200 tasini oladi, ya'ni saralash ilovada bo'lsa 201-suhbatdagi
// yangi xabar ro'yxatga umuman tushmasdi.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/support_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'support_chat_screen.dart';

class AdminChatsScreen extends StatefulWidget {
  const AdminChatsScreen({super.key});

  @override
  State<AdminChatsScreen> createState() => _AdminChatsScreenState();
}

class _AdminChatsScreenState extends State<AdminChatsScreen> {
  final _threads = ChatThreadsController();

  @override
  void initState() {
    super.initState();
    _threads.load();
  }

  @override
  void dispose() {
    _threads.dispose();
    super.dispose();
  }

  Future<void> _open(ChatThread t) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SupportChatScreen(userId: t.userId, title: t.name),
      ),
    );
    // Qaytilganda ro'yxat yangilanadi: o'qilmaganlar soni
    // o'zgargan va tartib ham siljigan bo'lishi mumkin.
    if (mounted) {
      await _threads.load(force: true);
      await UnreadBadge.instance.refresh();
    }
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
          title: const Text('Barcha suhbatlar',
              style: TextStyle(color: Colors.white, fontSize: 18)),
        ),
        body: SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: _threads,
            builder: (context, _) => _body(),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_threads.isLoading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    final rows = _threads.items;
    return RefreshIndicator(
      onRefresh: () => _threads.load(force: true),
      color: AppColors.accent,
      backgroundColor: AppColors.card,
      child: rows.isEmpty
          ? ListView(
              physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics()),
              children: [
                SizedBox(
                  height: 320,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.forum_outlined,
                            size: 52,
                            color: Colors.white.withValues(alpha: 0.2)),
                        const SizedBox(height: 12),
                        Text(
                          _threads.error ?? 'Hali hech kim yozmagan',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 13.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : ListView.builder(
              physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics()),
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
              itemCount: rows.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ThreadRow(
                  thread: rows[i],
                  onTap: () => _open(rows[i]),
                ),
              ),
            ),
    );
  }
}

/// Telegram'dagidek bitta qator: rasm, ism, oxirgi xabar, vaqt
/// va o'qilmaganlar soni.
class _ThreadRow extends StatelessWidget {
  final ChatThread thread;
  final VoidCallback onTap;

  const _ThreadRow({required this.thread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = thread;
    return GlassTappable(
      onTap: onTap,
      child: Glass(
        borderRadius: 16,
        blur: 12,
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          children: [
            _Avatar(url: t.photoUrl, name: t.name),
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
                          t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        chatTime(t.lastAt),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.42),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      // Oxirgi xabarni admin yozgan bo'lsa —
                      // "Siz:" (Telegram ham shunday qiladi).
                      if (t.lastFromAdmin)
                        Text(
                          'Siz: ',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.42),
                            fontSize: 12.5,
                          ),
                        ),
                      Expanded(
                        child: Text(
                          t.lastBody,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(
                                alpha: t.unread > 0 ? 0.88 : 0.55),
                            fontSize: 12.5,
                            fontWeight: t.unread > 0
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (t.unread > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          constraints: const BoxConstraints(minWidth: 20),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${t.unread}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
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

class _Avatar extends StatelessWidget {
  final String url;
  final String name;

  const _Avatar({required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    const size = 46.0;
    final letter = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: AppColors.cardAlt,
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.7),
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? fallback
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 140,
                placeholder: (_, __) => fallback,
                errorWidget: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}
