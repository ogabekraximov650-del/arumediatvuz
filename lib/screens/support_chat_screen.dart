// lib/screens/support_chat_screen.dart — ADMIN BILAN YOZISHMA.
//
// ═══════════════════════════════════════════════════════════════
//  IKKI TOMON, BITTA EKRAN
// ═══════════════════════════════════════════════════════════════
//
// Bu ekran ikki joyda ishlatiladi:
//
//   * FOYDALANUVCHI — profil sahifasidagi "Admin bilan bog'lanish"
//     tugmasidan. `userId` berilmaydi, ya'ni o'z suhbati ochiladi;
//   * ADMIN — barcha suhbatlar ro'yxatidan bittasini bosganda.
//     `userId` beriladi va o'sha odamning suhbati ochiladi.
//
// Farqi faqat kimning xabari qaysi tomonda turishida: o'zining
// xabari O'NGDA, suhbatdoshiniki CHAPDA — Telegram'dagidek.

import 'package:flutter/material.dart';

import '../services/support_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

class SupportChatScreen extends StatefulWidget {
  /// Admin boshqa odamning suhbatini ochsa — o'sha odamning raqami.
  final int? userId;

  /// Sarlavhada ko'rinadigan nom.
  final String title;

  const SupportChatScreen({
    super.key,
    this.userId,
    this.title = 'Admin bilan bog\'lanish',
  });

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  late final ChatController _chat = ChatController(userId: widget.userId);
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _chat.addListener(_onData);
    _chat.load().then((_) => _toBottom(jump: true));
    // Suhbat OCHIQ turgandagina yangi xabarlar so'raladi.
    _chat.startPolling();
  }

  @override
  void dispose() {
    _chat.removeListener(_onData);
    _chat.stopPolling();
    _chat.dispose();
    _input.dispose();
    _scroll.dispose();
    // Ekran yopildi — profil sahifasidagi nuqta yangilansin.
    UnreadBadge.instance.refresh();
    super.dispose();
  }

  int _seen = 0;
  void _onData() {
    // Yangi xabar kelgan bo'lsa pastga tushamiz. Foydalanuvchi
    // yuqoriga surib eski xabarlarni o'qiyotgan bo'lsa —
    // TEGILMAYDI, aks holda ekran o'zidan o'zi sakrab ketardi.
    final n = _chat.items.length;
    if (n > _seen) {
      _seen = n;
      _toBottom();
    }
  }

  void _toBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      // Pastga yaqin bo'lsagina o'zi tushadi.
      if (!jump && _scroll.position.pixels < max - 300) return;
      if (jump) {
        _scroll.jumpTo(max);
      } else {
        _scroll.animateTo(max,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final err = await _chat.send(text);
    if (!mounted) return;
    setState(() => _sending = false);
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
    _input.clear();
    setState(() {});
    _toBottom();
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
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 17),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: AnimatedBuilder(
                  animation: _chat,
                  builder: (context, _) => _body(),
                ),
              ),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_chat.isLoading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    final items = _chat.items;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.support_agent_rounded,
                  size: 54, color: Colors.white.withValues(alpha: 0.2)),
              const SizedBox(height: 14),
              Text(
                _chat.error ??
                    (_chat.isAdminView
                        ? 'Bu odam hali yozmagan'
                        : 'Savolingiz bormi? Yozing — admin javob beradi.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final m = items[i];
        // O'z xabarim o'ngda. Admin ekranida "o'ziniki" — admin
        // yozganlari; foydalanuvchi ekranida esa aksincha.
        final mine = _chat.isAdminView ? m.fromAdmin : !m.fromAdmin;
        return _Bubble(message: m, mine: mine);
      },
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
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        // Klaviatura ochilganda qator uning ustida turadi.
        8 + MediaQuery.viewInsetsOf(context).bottom,
      ),
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
                maxLines: 5,
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
          GestureDetector(
            onTap: (_input.text.trim().isEmpty || _sending) ? null : _send,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _input.text.trim().isEmpty
                    ? Colors.white.withValues(alpha: 0.10)
                    : AppColors.accent,
              ),
              child: _sending
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(
                      Icons.send_rounded,
                      size: 19,
                      color: _input.text.trim().isEmpty
                          ? Colors.white38
                          : Colors.white,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bitta xabar puffagi.
class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;

  const _Bubble({required this.message, required this.mine});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.76,
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: mine
                    ? AppColors.accent.withValues(alpha: 0.92)
                    : Colors.white.withValues(alpha: 0.09),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 16 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 16),
                ),
                border: mine
                    ? null
                    : Border.all(
                        color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.body,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.38,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    chatTime(message.createdAt),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
