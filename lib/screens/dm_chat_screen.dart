// lib/screens/dm_chat_screen.dart — DO'ST BILAN YOZISHMA.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "bu tizimni o'zing Telegramdek qilib yasab ber,
// ya'ni yuborilgan xabarga shikoyat qilish, reaksiya bildirish,
// ovozli, rasm va video xabar yuborish, yuborgan xabarini
// o'chirish va hokazo".
//
// ── BU BOSQICHDA NIMA BOR ───────────────────────────────────
//
//   * matnli yozishma, xabar DARHOL ko'rinadi (serverni
//     kutmasdan) va ~1 soniyada yetib boradi;
//   * xabarni bosib turganda: REAKSIYA, o'z xabarini
//     O'CHIRISH, begona xabarga SHIKOYAT;
//   * ✓ / ✓✓ belgilari;
//   * skrinshot va ekran yozuvi taqiqlangan (foydalanuvchi
//     talabi — `screen_guard.dart`).
//
// Rasm, video va ovozli xabar KEYINGI qadamda: ular B2'ga
// yuklashni talab qiladi va o'sha kod hozircha admin
// yozishmasiga bog'langan (`support_chat_screen.dart`).
// Yarim ishlaydigan yuklash qo'shgandan ko'ra, uni alohida va
// to'g'ri qilgan ma'qul.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/billing_service.dart';
import '../services/dm_service.dart';
import '../services/format.dart';
import '../services/reports_service.dart';
import '../services/screen_guard.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'dm_threads_screen.dart' show DmAvatar;
import 'public_profile_screen.dart';

/// Xabarga qo'yiladigan reaksiyalar.
///
/// Ro'yxat YOPIQ va u serverdagi ro'yxat bilan bir xil
/// (`dm_react`): ixtiyoriy matn kelsa u reaksiya emas, yozuv
/// bo'lib qolardi.
const kDmReactions = <String>['❤️', '👍', '👎', '😂', '😮', '😢', '🔥', '🎉'];

class DmChatScreen extends StatefulWidget {
  final DmPerson other;
  const DmChatScreen({super.key, required this.other});

  @override
  State<DmChatScreen> createState() => _DmChatScreenState();
}

class _DmChatScreenState extends State<DmChatScreen>
    // Skrinshot va ekran yozuvi taqiqlanadi (foydalanuvchi
    // talabi — `screen_guard.dart` izohiga qarang).
    with ScreenGuarded<DmChatScreen> {
  late final DmController _chat = DmController(otherId: widget.other.userId);
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _chat.loadFromDisk();
    _chat.load();
    _chat.startPolling();
    _chat.addListener(_onData);
    // Suhbat ochildi — nuqta darhol o'chsin.
    unawaited(DmBadge.instance.refresh());
  }

  @override
  void dispose() {
    _chat.removeListener(_onData);
    _chat.stopPolling();
    _chat.dispose();
    _input.dispose();
    _scroll.dispose();
    // Ekran yopildi — nuqta yangilansin.
    unawaited(DmBadge.instance.refresh());
    super.dispose();
  }

  int _seen = 0;
  void _onData() {
    // Yangi xabar kelgan bo'lsa pastga tushamiz. Odam yuqoriga
    // surib eski xabarlarni o'qiyotgan bo'lsa TEGILMAYDI — aks
    // holda ekran o'zidan o'zi sakrab ketardi.
    final n = _chat.items.length;
    if (n > _seen) {
      _seen = n;
      WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    }
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
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
    // Obuna tekshiruvi SERVERDA ham bor — bu yerdagisi faqat
    // tushunarli xabar berish uchun (bekorga so'rov ketmasin).
    if (!BillingService.instance.active) {
      _say('Xabar yuborish uchun obuna kerak');
      return;
    }
    setState(() => _sending = true);
    _input.clear();
    final err = await _chat.send(body: text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      // Yuborilmadi — matn qaytariladi, odam qaytadan yozmasin.
      _input.text = text;
      _say(err);
    }
  }

  // ── XABARNI BOSIB TURGANDA ────────────────────────────────
  Future<void> _openActions(DmMessage m) async {
    final action = await showModalBottomSheet<String>(
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
              // ── REAKSIYALAR (Telegramdagidek) ──────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  children: [
                    for (final e in kDmReactions)
                      GestureDetector(
                        onTap: () => Navigator.of(ctx).pop('react:$e'),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: m.myReaction == e
                                ? AppColors.accent.withValues(alpha: 0.25)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 22)),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(
                  height: 1, color: Colors.white.withValues(alpha: 0.07)),
              if (m.mine)
                ListTile(
                  leading: Icon(Icons.delete_outline_rounded,
                      color: Colors.red.shade300, size: 21),
                  title: Text(
                    'O\'chirish',
                    style: TextStyle(
                      color: Colors.red.shade300,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('delete'),
                )
              else
                ListTile(
                  leading: Icon(Icons.flag_outlined,
                      color: Colors.red.shade300, size: 21),
                  title: Text(
                    'Shikoyat qilish',
                    style: TextStyle(
                      color: Colors.red.shade300,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop('report'),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;

    if (action.startsWith('react:')) {
      final err = await _chat.react(m.id, action.substring(6));
      if (err != null && mounted) _say(err);
      return;
    }
    if (action == 'delete') {
      final err = await _chat.remove(m.id);
      if (err != null && mounted) _say(err);
      return;
    }
    if (action == 'report') await _report(m);
  }

  Future<void> _report(DmMessage m) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      constraints: const BoxConstraints(),
      builder: (_) => _DmReportSheet(message: m, other: widget.other),
    );
    if (sent == true && mounted) {
      _say('Shikoyatingiz qabul qilindi. Tez orada tekshiramiz.');
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
          titleSpacing: 0,
          title: GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    PublicProfileScreen(userId: widget.other.userId),
              ),
            ),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                DmAvatar(
                  url: widget.other.photoUrl,
                  name: widget.other.name,
                  size: 34,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.other.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700),
                      ),
                      if (widget.other.username.isNotEmpty)
                        Text(
                          '@${widget.other.username}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF6BC7F0), fontSize: 11.5),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: AnimatedBuilder(
                  animation: _chat,
                  builder: (context, _) => _list(),
                ),
              ),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list() {
    if (_chat.isLoading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    if (_chat.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined,
                  size: 44, color: Colors.white.withValues(alpha: 0.2)),
              const SizedBox(height: 12),
              Text(
                _chat.error ?? 'Birinchi xabarni yozing',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      itemCount: _chat.items.length,
      itemBuilder: (context, i) => _Bubble(
        message: _chat.items[i],
        onLongPress: () => _openActions(_chat.items[i]),
      ),
    );
  }

  Widget _composer() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      // Klaviatura joyini `Scaffold` o'zi ochadi — bu yerda
      // unga tegilmaydi (`comments_tab.dart` dagi bilan bir xil
      // sabab).
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  counterText: '',
                  isDense: true,
                  hintText: 'Xabar yozing...',
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
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  XABAR PUFFAGI
// ══════════════════════════════════════════════════════════════

class _Bubble extends StatelessWidget {
  final DmMessage message;
  final VoidCallback onLongPress;

  const _Bubble({required this.message, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final m = message;
    final reactions = m.reactions;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment:
            m.mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment:
                    m.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 9),
                    decoration: BoxDecoration(
                      color: m.mine
                          ? AppColors.accent.withValues(alpha: 0.85)
                          : Colors.white.withValues(alpha: 0.09),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(m.mine ? 16 : 4),
                        bottomRight: Radius.circular(m.mine ? 4 : 16),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            m.body,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              commentClock(m.createdAt),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 10,
                              ),
                            ),
                            // ── ✓ / ✓✓ ─────────────────────────
                            //
                            // Faqat O'Z xabarimda: suhbatdosh
                            // o'qiganini bilish uchun.
                            if (m.mine) ...[
                              const SizedBox(width: 4),
                              Icon(
                                m.pending
                                    ? Icons.access_time_rounded
                                    : (m.seen
                                        ? Icons.done_all_rounded
                                        : Icons.done_rounded),
                                size: 13,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  // ── REAKSIYALAR ────────────────────────────
                  if (reactions.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final e in reactions.entries)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: m.myReaction == e.key
                                  ? AppColors.accent.withValues(alpha: 0.3)
                                  : Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              e.value > 1 ? '${e.key} ${e.value}' : e.key,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11.5),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
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
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? AppColors.accent : Colors.white.withValues(alpha: 0.10),
        ),
        child: busy
            ? const SizedBox(
                width: 18,
                height: 18,
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
//  SHIKOYAT OYNASI
// ══════════════════════════════════════════════════════════════

class _DmReportSheet extends StatefulWidget {
  final DmMessage message;
  final DmPerson other;

  const _DmReportSheet({required this.message, required this.other});

  @override
  State<_DmReportSheet> createState() => _DmReportSheetState();
}

class _DmReportSheetState extends State<_DmReportSheet> {
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
    final err = await sendDmReport(
      messageId: widget.message.id,
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
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.88),
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
                      widget.other.name,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.message.body,
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
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.09)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: TextField(
                  controller: _text,
                  autofocus: true,
                  minLines: 5,
                  maxLines: 9,
                  maxLength: kReportMaxLength,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() => _error = null),
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
                Text(_error!,
                    style: TextStyle(
                        color: Colors.red.shade300, fontSize: 12.5)),
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
                          : const Text('Yuborish',
                              style: TextStyle(fontWeight: FontWeight.w700)),
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
