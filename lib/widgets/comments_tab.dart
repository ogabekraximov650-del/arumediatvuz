// lib/widgets/comments_tab.dart — IZOHLAR OYNASI.
//
// ═══════════════════════════════════════════════════════════════
//  KO'RINISHI — YouTube'dagidek
// ═══════════════════════════════════════════════════════════════
//
// Har bir izoh: rasm, ism, qachon yozilgani, matn, layk tugmasi
// va "Javob berish". Javoblar YIG'ILGAN holda turadi va "N ta
// javob" bosilganda ochiladi — aks holda uzun suhbat butun
// ekranni egallab, qolgan izohlar ko'rinmay qolardi.
//
// Pastda — yozish qatori. Javob yozilayotganda uning tepasida
// "Falonchiga javob" yozuvi va uni bekor qiladigan X chiqadi.
//
// ── NEGA ALOHIDA FAYL ───────────────────────────────────────
//
// `video_player_screen.dart` allaqachon juda katta. Izohlar esa
// o'zicha to'liq bir ekran: ro'yxat, javoblar, yozish qatori.
// Uni o'sha faylga qo'shish qidirishni yanada qiyinlashtirardi.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/comments_service.dart';
import '../screens/public_profile_screen.dart';
import 'glass.dart';

class CommentsTab extends StatefulWidget {
  final CommentsController controller;
  const CommentsTab({super.key, required this.controller});

  @override
  State<CommentsTab> createState() => _CommentsTabState();
}

class _CommentsTabState extends State<CommentsTab> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  /// Hozir kimga javob yozilyapti (`null` — oddiy izoh).
  Comment? _replyTo;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.controller.load();
    // Pastga yetganda keyingi sahifa o'zi so'raladi.
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final left = _scroll.position.maxScrollExtent - _scroll.position.pixels;
      if (left < 400) widget.controller.loadMore();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
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

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (!AuthService.instance.isLoggedIn) {
      _say('Izoh yozish uchun hisobingizga kiring');
      return;
    }
    setState(() => _sending = true);
    final err = await widget.controller
        .add(text, parentId: _replyTo?.id ?? '');
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      _say(err);
      return;
    }
    _input.clear();
    setState(() => _replyTo = null);
    _focus.unfocus();
  }

  void _startReply(Comment c) {
    setState(() => _replyTo = c);
    _focus.requestFocus();
  }

  Future<void> _confirmDelete(Comment c) async {
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
                'Izoh o\'chirilsinmi?',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.4),
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
    final err = await widget.controller.remove(c.id);
    if (err != null) _say(err);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        return Column(
          children: [
            Expanded(child: _list(c)),
            _composer(),
          ],
        );
      },
    );
  }

  Widget _list(CommentsController c) {
    if (c.isLoading && c.items.isEmpty) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    if (c.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => c.load(force: true),
        color: AppColors.accent,
        backgroundColor: AppColors.card,
        child: ListView(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          children: [
            SizedBox(
              height: 220,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.mode_comment_outlined,
                        size: 46, color: Colors.white.withValues(alpha: 0.2)),
                    const SizedBox(height: 12),
                    Text(
                      c.error ?? 'Hali izoh yo\'q — birinchi bo\'ling',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => c.load(force: true),
      color: AppColors.accent,
      backgroundColor: AppColors.card,
      child: ListView.builder(
        controller: _scroll,
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        // Oxirgi element — "yana yuklanmoqda" aylanasi.
        itemCount: c.items.length + (c.hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= c.items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
                ),
              ),
            );
          }
          final item = c.items[i];
          return _CommentBlock(
            comment: item,
            controller: c,
            onReply: _startReply,
            onDelete: _confirmDelete,
            onLikeError: _say,
          );
        },
      ),
    );
  }

  // ── PASTDAGI YOZISH QATORI ───────────────────────────────
  Widget _composer() {
    final replying = _replyTo;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      // ── KLAVIATURA JOYINI `Scaffold` O'ZI OCHADI ──────────
      //
      // TOPILGAN XATO (foydalanuvchi: "yozadigan oyna judayam
      // yuqoriga ko'tarilib ketgan").
      //
      // `Scaffold` standart holatda `resizeToAvoidBottomInset:
      // true` bilan ishlaydi, ya'ni klaviatura ochilganda TANANI
      // o'zi qisqartiradi. Bu yerda esa ustiga YANA klaviatura
      // balandligi qo'shilardi — natijada qator ikki barobar
      // yuqoriga sakrab, ekranning tepasiga chiqib ketardi.
      //
      // Shu sabab bu yerda klaviaturaga umuman tegilmaydi.
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replying != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(Icons.reply_rounded,
                      size: 15, color: Colors.white.withValues(alpha: 0.5)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${replying.name}ga javob',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _replyTo = null),
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          size: 16, color: Colors.white54),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 1000,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      counterText: '',
                      isDense: true,
                      hintText: replying == null
                          ? 'Izoh yozing...'
                          : 'Javob yozing...',
                      hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.38),
                          fontSize: 14),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SendButton(
                busy: _sending,
                enabled: _input.text.trim().isNotEmpty,
                onTap: _send,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  const _SendButton({
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final on = enabled && !busy;
    return GestureDetector(
      onTap: on ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on
              ? AppColors.accent
              : Colors.white.withValues(alpha: 0.10),
        ),
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : Icon(
                Icons.send_rounded,
                size: 19,
                color: on ? Colors.white : Colors.white38,
              ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  BITTA IZOH VA UNING JAVOBLARI
// ══════════════════════════════════════════════════════════════

class _CommentBlock extends StatelessWidget {
  final Comment comment;
  final CommentsController controller;
  final void Function(Comment) onReply;
  final Future<void> Function(Comment) onDelete;
  final void Function(String) onLikeError;

  const _CommentBlock({
    required this.comment,
    required this.controller,
    required this.onReply,
    required this.onDelete,
    required this.onLikeError,
  });

  @override
  Widget build(BuildContext context) {
    final open = controller.isOpen(comment.id);
    final replies = controller.repliesOf(comment.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CommentRow(
            comment: comment,
            controller: controller,
            onReply: onReply,
            onDelete: onDelete,
            onLikeError: onLikeError,
          ),
          // ── "N TA JAVOB" ────────────────────────────────────
          if (comment.replyCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 46, top: 2),
              child: GestureDetector(
                onTap: () => controller.toggleReplies(comment.id),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (controller.isLoadingReplies(comment.id))
                        const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white38),
                        )
                      else
                        Icon(
                          open
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: AppColors.accent,
                        ),
                      const SizedBox(width: 5),
                      Text(
                        open
                            ? 'Javoblarni yashirish'
                            : '${comment.replyCount} ta javob',
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: 34, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final r in replies)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _CommentRow(
                        comment: r,
                        controller: controller,
                        onReply: onReply,
                        onDelete: onDelete,
                        onLikeError: onLikeError,
                        small: true,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  final Comment comment;
  final CommentsController controller;
  final void Function(Comment) onReply;
  final Future<void> Function(Comment) onDelete;
  final void Function(String) onLikeError;
  final bool small;

  const _CommentRow({
    required this.comment,
    required this.controller,
    required this.onReply,
    required this.onDelete,
    required this.onLikeError,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = comment;
    final size = small ? 26.0 : 34.0;
    final mine = AuthService.instance.user?.id == c.userId;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── PROFILGA O'TISH ────────────────────────────────────
        //
        // TALAB (foydalanuvchi): "izoh yozgan odamning profiliga
        // bosib profilni ko'rsa bo'ladigan qil".
        //
        // Rasm ham, ism ham bosiladi — odam qaysinisini bossa ham
        // ishlaydi.
        GestureDetector(
          onTap: () => _openProfile(context, c.userId),
          behavior: HitTestBehavior.opaque,
          child: _Avatar(url: c.photoUrl, size: size, name: c.name),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: GestureDetector(
                      onTap: () => _openProfile(context, c.userId),
                      behavior: HitTestBehavior.opaque,
                      child: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: small ? 12 : 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // ── QANCHA VAQT OLDIN VA AYNAN QACHON ────────
                  //
                  // TALAB (foydalanuvchi): "izoh yozganda vaqti ham
                  // ko'rsatilsin". "7 daqiqa oldin" — tez o'qish
                  // uchun, yonidagi soat esa aniq vaqt uchun.
                  Flexible(
                    child: Text(
                      '${commentAgo(c.createdAt)} · '
                      '${commentClock(c.createdAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.38),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                c.deleted ? 'Izoh o\'chirilgan' : c.body,
                style: TextStyle(
                  color: c.deleted
                      ? Colors.white.withValues(alpha: 0.35)
                      : Colors.white.withValues(alpha: 0.86),
                  fontSize: small ? 13 : 13.5,
                  height: 1.38,
                  fontStyle: c.deleted ? FontStyle.italic : null,
                ),
              ),
              if (!c.deleted) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    _LikeButton(
                      comment: c,
                      onTap: () async {
                        final err = await controller.toggleLike(c.id);
                        if (err != null) onLikeError(err);
                      },
                    ),
                    const SizedBox(width: 14),
                    _TextButton(
                      label: 'Javob berish',
                      onTap: () => onReply(c),
                    ),
                    if (mine) ...[
                      const SizedBox(width: 14),
                      _TextButton(
                        label: 'O\'chirish',
                        color: Colors.red.shade300,
                        onTap: () => onDelete(c),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Izoh muallifining profilini ochadi.
void _openProfile(BuildContext context, int userId) {
  if (userId <= 0) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PublicProfileScreen(userId: userId),
    ),
  );
}

class _LikeButton extends StatelessWidget {
  final Comment comment;
  final VoidCallback onTap;

  const _LikeButton({required this.comment, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // Bosish maydoni yozuvdan kengroq — barmoq tegmay qolmasin.
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              comment.liked
                  ? Icons.thumb_up_rounded
                  : Icons.thumb_up_outlined,
              size: 15,
              color: comment.liked
                  ? AppColors.accent
                  : Colors.white.withValues(alpha: 0.55),
            ),
            if (comment.likes > 0) ...[
              const SizedBox(width: 5),
              Text(
                '${comment.likes}',
                style: TextStyle(
                  color: comment.liked
                      ? AppColors.accent
                      : Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TextButton extends StatelessWidget {
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _TextButton({required this.label, this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        child: Text(
          label,
          style: TextStyle(
            color: color ?? Colors.white.withValues(alpha: 0.55),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Foydalanuvchi rasmi. Rasm kelmasa — ismning birinchi harfi.
class _Avatar extends StatelessWidget {
  final String url;
  final double size;
  final String name;

  const _Avatar({required this.url, required this.size, required this.name});

  @override
  Widget build(BuildContext context) {
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
          fontSize: size * 0.42,
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
                // Rasm kichkina — xotirada ham kichik tursin.
                memCacheWidth: (size * 3).round(),
                placeholder: (_, __) => fallback,
                errorWidget: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}
