// lib/screens/dm_threads_screen.dart — SUHBATLAR.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "balans to'ldirish tugmasi tagiga suhbatlar degan
// tugma qo'sh ... bitta foydalanuvchi boshqa do'stlari bilan
// gaplasha olsin" va "foydalanuvchi profil sahifasidan suhbatlar
// oynasiga o'tganda tepada username bilan izlash uchun lupa
// bo'lsin (ism bilan izlab bo'lmaydi)".
//
// ── NEGA FAQAT USERNAME ─────────────────────────────────────
//
// Ism takrorlanadi ("User 7" ko'p) va uni izlash begona
// odamlarni chiqarib yuborardi. Username esa noyob va odam uni
// o'zi aytadi — ya'ni izlash faqat TANISH odamni topadi.
// Tekshiruv serverda ham shunday (`dm_search`).

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/billing_service.dart';
import '../services/dm_service.dart';
import '../services/format.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'dm_chat_screen.dart';

class DmThreadsScreen extends StatefulWidget {
  const DmThreadsScreen({super.key});

  @override
  State<DmThreadsScreen> createState() => _DmThreadsScreenState();
}

class _DmThreadsScreenState extends State<DmThreadsScreen> {
  final _ctrl = DmThreadsController();
  final _search = TextEditingController();

  /// Izlash oynasi ochiqmi (lupa bosilganda ochiladi).
  bool _searching = false;

  /// Izlash natijalari.
  List<DmPerson> _found = const [];
  bool _finding = false;

  /// Izlash HAR HARFDA emas, yozish to'xtagach yuboriladi.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _ctrl.loadFromDisk();
    _ctrl.load();
    // Yangi xabar ro'yxatda darhol ko'rinsin.
    _ctrl.startWatching();
    unawaited(DmBadge.instance.refresh());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.stopWatching();
    _ctrl.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      setState(() => _finding = true);
      final rows = await searchByUsername(q);
      if (!mounted) return;
      setState(() {
        _found = rows;
        _finding = false;
      });
    });
  }

  Future<void> _open(DmPerson p) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DmChatScreen(other: p)),
    );
    if (!mounted) return;
    // Qaytilganda: o'qilganlar va tartib o'zgargan bo'lishi
    // mumkin.
    await _ctrl.load(force: true);
    unawaited(DmBadge.instance.refresh());
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
          title: const Text('Suhbatlar',
              style: TextStyle(color: Colors.white, fontSize: 18)),
          actions: [
            // ── LUPA (foydalanuvchi talabi) ──────────────────
            IconButton(
              tooltip: 'Username bo\'yicha izlash',
              icon: Icon(
                _searching ? Icons.close_rounded : Icons.search_rounded,
                color: Colors.white,
              ),
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _search.clear();
                  _found = const [];
                }
              }),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (_searching) _searchBox(),
              // Obuna tugagan bo'lsa ogohlantirish: eski
              // yozishmalar ochiq qoladi, lekin yozib
              // bo'lmaydi (qoida serverda).
              const _SubNotice(),
              Expanded(
                child: _searching && _search.text.trim().length >= 2
                    ? _foundList()
                    : AnimatedBuilder(
                        animation: _ctrl,
                        builder: (context, _) => _threadList(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(Icons.alternate_email_rounded,
                size: 19, color: Colors.white.withValues(alpha: 0.5)),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _search,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  // Ism bilan izlab bo'lmasligi shu yerda ham
                  // aytiladi — odam bekorga urinmasin.
                  hintText: 'Username (ism bilan emas)',
                  hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.38),
                      fontSize: 14),
                ),
                onChanged: (q) {
                  setState(() {});
                  _onSearch(q);
                },
              ),
            ),
            if (_finding)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white38),
              ),
          ],
        ),
      ),
    );
  }

  Widget _foundList() {
    if (_found.isEmpty && !_finding) {
      return _empty(
        Icons.person_search_rounded,
        'Bunday username topilmadi',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      itemCount: _found.length,
      itemBuilder: (context, i) {
        final p = _found[i];
        return _PersonRow(person: p, onTap: () => _open(p));
      },
    );
  }

  Widget _threadList() {
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
            const SizedBox(height: 100),
            _empty(
              Icons.forum_outlined,
              _ctrl.error ??
                  'Hali suhbat yo\'q.\nYuqoridagi lupa orqali '
                      'username bilan do\'stingizni toping.',
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
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        itemCount: _ctrl.items.length,
        itemBuilder: (context, i) {
          final t = _ctrl.items[i];
          return _ThreadRow(thread: t, onTap: () => _open(t.other));
        },
      ),
    );
  }

  Widget _empty(IconData icon, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: Colors.white.withValues(alpha: 0.2)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Obuna tugagan bo'lsa chiqadigan eslatma.
///
/// TALAB (foydalanuvchi): "bu funksiya obunasi bor vaqtda
/// ishlaydi".
///
/// Yozishmalar YO'QOLMAYDI: odam ularni o'qiy oladi, faqat
/// yangi xabar yubora olmaydi. Qoida serverda (`dm_send`).
class _SubNotice extends StatelessWidget {
  const _SubNotice();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        if (BillingService.instance.active) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.workspace_premium_rounded,
                    size: 19, color: AppColors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Xabar yuborish uchun obuna kerak. Eski '
                    'yozishmalaringiz joyida qoladi.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 12,
                      height: 1.35,
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

/// Izlashda topilgan odam.
class _PersonRow extends StatelessWidget {
  final DmPerson person;
  final VoidCallback onTap;

  const _PersonRow({required this.person, required this.onTap});

  @override
  Widget build(BuildContext context) {
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
              DmAvatar(url: person.photoUrl, name: person.name, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      person.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (person.username.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '@${person.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(0xFF6BC7F0), fontSize: 12.5),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

/// Suhbatlar ro'yxatidagi bitta qator.
class _ThreadRow extends StatelessWidget {
  final DmThread thread;
  final VoidCallback onTap;

  const _ThreadRow({required this.thread, required this.onTap});

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
              DmAvatar(url: t.other.photoUrl, name: t.other.name, size: 46),
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
                            t.other.name,
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
                          commentAgo(t.lastAt),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.38),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        // O'zim yozgan bo'lsam oldida "Siz:".
                        if (t.lastMine)
                          Text(
                            'Siz: ',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
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
                                  alpha: t.unread > 0 ? 0.9 : 0.5),
                              fontSize: 12.5,
                              fontWeight: t.unread > 0
                                  ? FontWeight.w600
                                  : FontWeight.normal,
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
      ),
    );
  }
}

/// Foydalanuvchi rasmi. Rasm kelmasa — ismning birinchi harfi.
class DmAvatar extends StatelessWidget {
  final String url;
  final String name;
  final double size;

  const DmAvatar({
    super.key,
    required this.url,
    required this.name,
    required this.size,
  });

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
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    if (url.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}
