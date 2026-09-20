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

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'emoji_text.dart';
import '../services/image_cache.dart';

import '../services/auth_service.dart';
import '../services/comments_service.dart';
import '../services/format.dart';
import '../services/reports_service.dart';
import '../screens/public_profile_screen.dart';
import 'glass.dart';

class CommentsTab extends StatefulWidget {
  final CommentsController controller;

  /// ── BUTUN EKRANGA KATTALASHISH ───────────────────────────
  ///
  /// TALAB (foydalanuvchi): "foydalanuvchi izohlarni yuqoriga
  /// sursa, ya'ni pastdagi izohlarni o'qish uchun, izoh oynasi
  /// butun ekranga kattalashsin".
  ///
  /// Izohlar pleyer ekranining PASTKI qismida turadi — ya'ni
  /// ro'yxatga atigi bir necha qator joy tegadi. Ro'yxat yuqoriga
  /// surilishi bilan tepadagi hamma narsa (video, tablar, qism
  /// o'tkazish) yig'iladi va izohlar butun ekranni egallaydi.
  /// Ro'yxat eng tepasiga qaytsa — hammasi joyiga qaytadi.
  ///
  /// Qaror SHU YERDA emas, EKRANDA qabul qilinadi: yig'iladigan
  /// qismlar o'sha yerda. Bu yerda faqat "surildi" deb xabar
  /// beriladi.
  final ValueChanged<bool>? onExpanded;

  /// Hozir kattalashgan holatdami (tepadagi tugma shunga qarab
  /// yig'ish yoki yoyish ko'rinishini oladi).
  final bool expanded;

  const CommentsTab({
    super.key,
    required this.controller,
    this.onExpanded,
    this.expanded = false,
  });

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

  /// Oyna oxirgi marta qachon yig'ilgan/yoyilgan.
  ///
  /// NEGA KERAK: kattalashganda ro'yxatga ko'proq joy tegadi va
  /// qisqa ro'yxat umuman surilmaydigan bo'lib qolishi mumkin —
  /// o'shanda surish holati nolga qaytadi va oyna darhol yana
  /// yig'ilardi, barmoq ostida titrab. Shu sabab ikki o'zgarish
  /// orasida qisqa oraliq bor (jonlanish muddatidan sal uzunroq).
  DateTime _lastToggle = DateTime.fromMillisecondsSinceEpoch(0);

  /// ── SHIKOYAT YUBORILGANDAN KEYINGI XABAR ────────────────
  ///
  /// TALAB (foydalanuvchi): "shikoyatni yozib yuborgach ekranda
  /// 10 soniya 'Shikoyatingiz qabul qilindi, tez orada
  /// shikoyatingizni tekshirib chiqamiz' yozuvi chiqadi".
  ///
  /// NEGA SNACKBAR EMAS: standart xabar 4 soniyada yo'qoladi va
  /// yozish qatorining ustini to'sadi. Bu esa ro'yxatning
  /// TEPASIDA turadi, o'qishga xalaqit bermaydi va aynan 10
  /// soniya ko'rinadi.
  bool _reportDone = false;
  Timer? _reportTimer;

  void _showReportDone() {
    _reportTimer?.cancel();
    setState(() => _reportDone = true);
    _reportTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _reportDone = false);
    });
  }

  void _setExpanded(bool v) {
    if (widget.expanded == v) return;
    final now = DateTime.now();
    if (now.difference(_lastToggle).inMilliseconds < 400) return;
    _lastToggle = now;
    widget.onExpanded?.call(v);
  }

  @override
  void initState() {
    super.initState();
    // Avval DISK (darhol), keyin tarmoq (`disk_cache.dart` izohi).
    widget.controller.loadFromDisk();
    widget.controller.load();
    // Pastga yetganda keyingi sahifa o'zi so'raladi.
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final left = pos.maxScrollExtent - pos.pixels;
      if (left < 400) widget.controller.loadMore();

      // ── SURILDI -> KATTALASHDI ────────────────────────────
      //
      // Chegara ataylab kichik (24 nuqta): odam ro'yxatni endi
      // surishi bilanoq joy ochilsin. Eng tepaga qaytganda esa
      // hammasi joyiga tushadi. Ikki chegara BIR XIL emas —
      // aks holda oyna chegaraning aynan ustida turib, ochilib
      // yopilib titrardi.
      if (pos.pixels > 24) {
        _setExpanded(true);
      } else if (pos.pixels <= 2) {
        _setExpanded(false);
      }
    });
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
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

  // ── UCH NUQTA -> SHIKOYAT QILISH ─────────────────────────
  //
  // TALAB (foydalanuvchi): "izohning o'ng chetiga 3ta nuqta
  // qo'y va nuqtani bosganda 'shikoyat qilish' degan yozuv
  // bo'lsin; ustiga bosganda pastdan shikoyat yozish oynasi
  // chiqsin".
  //
  // Ikki bosqich ataylab: uch nuqta darhol shikoyat oynasini
  // ochsa, tasodifan tekkan barmoq odamni shikoyat yozayotgan
  // holatga tashlab qo'yardi.
  Future<void> _openMenu(Comment c) async {
    final wantReport = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18)),
                leading: Icon(Icons.flag_outlined,
                    color: Colors.red.shade300, size: 22),
                title: Text(
                  'Shikoyat qilish',
                  style: TextStyle(
                    color: Colors.red.shade300,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    if (wantReport != true || !mounted) return;
    await _openReport(c);
  }

  /// Shikoyat yozish oynasi.
  Future<void> _openReport(Comment c) async {
    if (!AuthService.instance.isLoggedIn) {
      _say('Shikoyat yuborish uchun hisobingizga kiring');
      return;
    }
    final sent = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      // Klaviatura ochilganda oyna uning ustida qolsin va
      // tarkibi kesilmasin.
      isScrollControlled: true,
      constraints: const BoxConstraints(),
      builder: (_) => _ReportSheet(comment: c),
    );
    if (sent == true && mounted) _showReportDone();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        return Column(
          children: [
            _sortBar(c),
            // Shikoyat yuborilganini tasdiqlovchi xabar — 10
            // soniya ko'rinadi (`_showReportDone` izohiga qarang).
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: _reportDone
                  ? const _ReportAcceptedBanner()
                  : const SizedBox(width: double.infinity),
            ),
            Expanded(child: _list(c)),
            _composer(),
          ],
        );
      },
    );
  }

  // ── TEPADAGI TARTIB PANELI ───────────────────────────────
  //
  // TALAB (foydalanuvchi): "o'ng yuqori qismida yangilar,
  // layklar, javoblar degan tugma bo'lsin. Yangini bossa barcha
  // izohlar chiqadi va yangilari tepada turadi; layklarda
  // layklar soni bo'yicha, javoblarda javob berishlar soni
  // bo'yicha tepada turadi".
  //
  // Tartiblash SERVERDA bo'ladi (`comment_order` izohiga
  // qarang): ro'yxat sahifalab keladi, shu sabab ilovada
  // tartiblansa faqat YUKLANGAN sahifa tartiblanardi.
  //
  // Chapdagi tugma — oynani qo'lda yig'ish/yoyish. Izoh kam
  // bo'lsa ro'yxat surilmaydi, ya'ni surish orqali
  // kattalashtirib bo'lmasdi.
  Widget _sortBar(CommentsController c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              // Qo'lda bosilgan — kutish oralig'i qo'llanmaydi.
              _lastToggle = DateTime.now();
              widget.onExpanded?.call(!widget.expanded);
            },
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 34,
              height: 34,
              child: Icon(
                widget.expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                size: 22,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ),
          const Spacer(),
          for (final s in CommentSort.values) ...[
            if (s != CommentSort.values.first) const SizedBox(width: 6),
            _SortChip(
              label: s.label,
              active: c.sort == s,
              onTap: () => c.setSort(s),
            ),
          ],
        ],
      ),
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
            onMenu: _openMenu,
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

  /// O'ng chetdagi uch nuqta bosildi (shikoyat menyusi).
  final Future<void> Function(Comment) onMenu;
  final void Function(String) onLikeError;

  const _CommentBlock({
    required this.comment,
    required this.controller,
    required this.onReply,
    required this.onDelete,
    required this.onMenu,
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
            onMenu: onMenu,
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
                        onMenu: onMenu,
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
  final Future<void> Function(Comment) onMenu;
  final void Function(String) onLikeError;
  final bool small;

  const _CommentRow({
    required this.comment,
    required this.controller,
    required this.onReply,
    required this.onDelete,
    required this.onMenu,
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
              // `EmojiText` — oddiy `Text` ning o'rnida: matn xira
              // qoladi (alpha o'z joyida), EMOJI esa to'liq rangda
              // chiqadi. Sababi `emoji_text.dart` boshida.
              EmojiText(
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
              // ── LAYK · JAVOB · O'CHIRISH ────────────────────────
              //
              // TOPILGAN XATO (foydalanuvchi: "layk bosib, javob
              // qaytarib bo'lmayapti, o'z izohimni o'chirib
              // bo'lmayapti"). Bu amal qatori qatordan tushib
              // qolgan edi — tugmalar umuman chizilmasdi.
              if (!c.deleted) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    _LikeButton(
                      comment: c,
                      onTap: () async {
                        final err = await controller.toggleLike(c.id);
                        if (err != null) onLikeError(err);
                      },
                    ),
                    const SizedBox(width: 4),
                    _TextButton(
                      label: 'Javob berish',
                      onTap: () => onReply(c),
                    ),
                    if (mine)
                      _TextButton(
                        label: 'O\'chirish',
                        color: Colors.red.shade300,
                        onTap: () => onDelete(c),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        // ── O'NG CHETDAGI UCH NUQTA ────────────────────────────
        //
        // TALAB (foydalanuvchi): "izohning to'g'risini o'ng
        // chetiga 3ta nuqta qo'y".
        //
        // O'Z izohida ko'rinmaydi: u yerda "O'chirish" allaqachon
        // bor va o'z izohiga shikoyat qilishning ma'nosi yo'q
        // (server ham rad etadi).
        if (!mine && !c.deleted)
          GestureDetector(
            onTap: () => onMenu(c),
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 34,
              height: 34,
              child: Icon(
                Icons.more_vert_rounded,
                size: 19,
                color: Colors.white.withValues(alpha: 0.45),
              ),
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

// ══════════════════════════════════════════════════════════════
//  SHIKOYAT
// ══════════════════════════════════════════════════════════════

/// Shikoyat yuborilganini tasdiqlovchi xabar.
///
/// TALAB (foydalanuvchi): "shikoyatni yozib yuborgach ekranda 10
/// soniya 'Shikoyatingiz qabul qilindi, tez orada shikoyatingizni
/// tekshirib chiqamiz' yozuvi chiqadi".
class _ReportAcceptedBanner extends StatelessWidget {
  const _ReportAcceptedBanner();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.success.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                size: 20, color: AppColors.success),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Shikoyatingiz qabul qilindi.\n'
                'Tez orada shikoyatingizni tekshirib chiqamiz.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pastdan chiqadigan shikoyat yozish oynasi.
///
/// TALAB (foydalanuvchi): "'Iltimos shikoyat sababi haqida
/// batafsil ma'lumot bering, shikoyatni iloji boricha tezroq
/// ko'rib chiqishga harakat qilamiz' degan yozuv va tagida
/// kattaroq yozadigan oyna bo'lsin".
///
/// Yopilganda `true` qaytaradi — ya'ni shikoyat HAQIQATAN
/// yuborilgan. Chaqiruvchi shunga qarab 10 soniyalik xabarni
/// ko'rsatadi.
class _ReportSheet extends StatefulWidget {
  final Comment comment;
  const _ReportSheet({required this.comment});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _text = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final err = await sendCommentReport(
      commentId: widget.comment.id,
      reason: _text.text,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _sending = false;
        _error = err;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      // Klaviatura ochilganda oyna uning USTIDA qoladi.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.88),
        decoration: const BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(
            18, 10, 18, 16 + media.padding.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Tortish belgisi — oyna pastdan chiqqani bilinsin.
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
              Row(
                children: [
                  Icon(Icons.flag_outlined,
                      color: Colors.red.shade300, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Shikoyat qilish',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Iltimos, shikoyat sababi haqida batafsil ma\'lumot '
                'bering. Shikoyatni iloji boricha tezroq ko\'rib '
                'chiqishga harakat qilamiz.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              // ── QAYSI IZOH ─────────────────────────────────
              //
              // Odam nimaga shikoyat qilayotganini ko'rib tursin:
              // ro'yxat uzun bo'lsa xato izohga bosib qo'yish
              // oson.
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.comment.name,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    EmojiText(
                      widget.comment.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // ── KATTAROQ YOZADIGAN OYNA (foydalanuvchi talabi) ──
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.09)),
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 6),
                child: TextField(
                  controller: _text,
                  autofocus: true,
                  minLines: 6,
                  maxLines: 10,
                  maxLength: kReportMaxLength,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) {
                    // Tugmaning yonishi uchun.
                    if (_error != null) {
                      setState(() => _error = null);
                    } else {
                      setState(() {});
                    }
                  },
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14, height: 1.4),
                  decoration: InputDecoration(
                    hintText: 'Shikoyat sababini yozing...',
                    hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 14),
                    border: InputBorder.none,
                    counterStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 11),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                      color: Colors.red.shade300, fontSize: 12.5),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _sending ? null : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        foregroundColor: Colors.white70,
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.18)),
                      ),
                      child: const Text('Bekor qilish'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      // Matn juda qisqa bo'lsa tugma o'chiq turadi
                      // — server ham qabul qilmaydi, bekorga
                      // so'rov yuborilmasin.
                      onPressed: _sending ||
                              _text.text.trim().length < kReportMinLength
                          ? null
                          : _send,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        backgroundColor: Colors.red.shade600,
                      ),
                      child: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text(
                              'Yuborish',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tartib tugmasi (Yangilar / Layklar / Javoblar).
class _SortChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SortChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active
                ? Colors.white
                : Colors.white.withValues(alpha: 0.6),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// ── LAYK TUGMASI ────────────────────────────────────────────
///
/// TALAB (foydalanuvchi): "layk bosish tugmasini kattalashtir va
/// tez ishlaydigan qil".
///
/// KATTALASHDI: ilgari ikonka 15 nuqta edi va bosish maydoni
/// atigi 25 nuqta balandlikda — barmoq ko'pincha tegmay qolardi.
/// Endi ikonka 20, bosish maydoni esa 40 nuqta (Android
/// tavsiyasi) va bosilganda fon yonib turadi.
///
/// TEZLASHDI: bu yerda emas, `CommentsController.toggleLike` da
/// — har bosish ekranda darhol ko'rinadi va so'rov ketayotganda
/// bosilgan keyingi bosishlar ham yo'qolmaydi (o'sha yerdagi
/// izohga qarang).
class _LikeButton extends StatelessWidget {
  final Comment comment;
  final VoidCallback onTap;

  const _LikeButton({required this.comment, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = comment.liked;
    final color =
        on ? AppColors.accent : Colors.white.withValues(alpha: 0.6);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: on
              ? AppColors.accent.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
              size: 20,
              color: color,
            ),
            if (comment.likes > 0) ...[
              const SizedBox(width: 6),
              Text(
                '${comment.likes}',
                style: TextStyle(
                  color: color,
                  fontSize: 13,
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
      // Bo'yi layk tugmasi bilan bir xil (40) — qator tekis
      // ko'rinsin va barmoq bemalol tegsin.
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          label,
          style: TextStyle(
            color: color ?? Colors.white.withValues(alpha: 0.6),
            fontSize: 12.5,
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
                cacheManager: AppImageCache.manager,
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
