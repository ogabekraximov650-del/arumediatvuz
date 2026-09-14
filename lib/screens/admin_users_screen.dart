// lib/screens/admin_users_screen.dart — FOYDALANUVCHILAR (ADMIN).
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "bo'lim ichida oxirgi marta ro'yxatdan o'tgan va
// oxirgi marta onlayn bo'lgan vaqtiga qarab ikkita ro'yxat bo'lsin;
// yuqorida ID raqam yoki username bilan izlash joyi bo'lsin; bu
// bo'lim bilan balansni qo'lda to'ldirish, bloklash va yana boshqa
// funksiyalar bo'lsin — o'zing kerakli narsalarni qo'sh".
//
// ── QANDAY AMALLAR BOR ──────────────────────────────────────
//
// Qatorga bosilsa pastdan oyna chiqadi:
//
//   * Balansga qo'shish (qo'lda summa yozib);
//   * Balansni aynan tenglash (xato tuzatish uchun);
//   * Obuna berish (1 / 5 / 10 / 30 kun yoki olib tashlash);
//   * Bloklash / ochish;
//   * Profilini to'liq ko'rish;
//   * Yozishmani ochish.
//
// Bloklash va pul — ORTGA QAYTARIB bo'lmaydigan ishlar, shu sabab
// ikkovi ham tasdiq so'raydi.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/admin_users_service.dart';
import '../services/billing_service.dart' show formatSum;
import '../services/format.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'public_profile_screen.dart';
import 'support_chat_screen.dart';

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final _ctrl = AdminUsersController();
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// Izlash HAR HARFDA emas, yozish to'xtagach yuboriladi.
  Timer? _debounce;

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
    _debounce?.cancel();
    _ctrl.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 400), () => _ctrl.setQuery(q));
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

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('Foydalanuvchilar',
              style: TextStyle(color: Colors.white, fontSize: 18)),
        ),
        body: SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) => Column(
              children: [
                _searchBox(),
                _sortTabs(),
                Expanded(child: _list()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── IZLASH ────────────────────────────────────────────────
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
            Icon(Icons.search_rounded,
                size: 19, color: Colors.white.withValues(alpha: 0.5)),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _search,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'ID raqam yoki username',
                  hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.38),
                      fontSize: 14),
                ),
                onChanged: _onSearch,
              ),
            ),
            if (_search.text.isNotEmpty)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _search.clear();
                  _ctrl.setQuery('');
                  FocusScope.of(context).unfocus();
                },
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.close_rounded,
                      size: 17, color: Colors.white54),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── IKKI RO'YXAT ──────────────────────────────────────────
  Widget _sortTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Row(
        children: [
          for (final s in UserSort.values) ...[
            Expanded(
              child: GestureDetector(
                onTap: () => _ctrl.setSort(s),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: _ctrl.sort == s
                        ? AppColors.accent
                        : Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _ctrl.sort == s
                          ? AppColors.accent
                          : Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Text(
                    s.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _ctrl.sort == s
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.65),
                      fontSize: 13,
                      fontWeight: _ctrl.sort == s
                          ? FontWeight.w800
                          : FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            if (s != UserSort.values.last) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _list() {
    if (_ctrl.isLoading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    final rows = _ctrl.items;
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _ctrl.error ?? 'Hech kim topilmadi',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45), fontSize: 13.5),
          ),
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
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 24),
        itemCount: rows.length + 1,
        itemBuilder: (context, i) {
          if (i >= rows.length) {
            if (!_ctrl.hasMore) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  _ctrl.query.isEmpty
                      ? 'Jami ${formatCount(_ctrl.total)} ta foydalanuvchi'
                      : '${rows.length} ta topildi',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 12),
                ),
              );
            }
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
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _UserRow(
              user: rows[i],
              sort: _ctrl.sort,
              onTap: () => _openActions(rows[i]),
            ),
          );
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  AMALLAR OYNASI
  // ══════════════════════════════════════════════════════════

  Future<void> _openActions(AdminUser u) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      constraints: const BoxConstraints(),
      builder: (ctx) => _ActionSheet(
        user: u,
        onBalance: () {
          Navigator.pop(ctx);
          _askAmount(u, add: true);
        },
        onSetBalance: () {
          Navigator.pop(ctx);
          _askAmount(u, add: false);
        },
        onSub: () {
          Navigator.pop(ctx);
          _askDays(u);
        },
        onBan: () {
          Navigator.pop(ctx);
          _confirmBan(u);
        },
        onProfile: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PublicProfileScreen(userId: u.id),
            ),
          );
        },
        onChat: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SupportChatScreen(
                userId: u.id,
                title: u.name,
                photoUrl: u.photoUrl,
              ),
            ),
          );
        },
      ),
    );
  }

  /// Summa so'raydi (qo'shish yoki aynan tenglash).
  Future<void> _askAmount(AdminUser u, {required bool add}) async {
    final ctrl = TextEditingController();
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 26),
        child: Glass(
          borderRadius: 22,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                add ? 'Balansga qo\'shish' : 'Balansni tenglash',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${u.name} · hozir ${formatSum(u.balance)}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                // Qo'shishda manfiy ham bo'ladi (xato tuzatish).
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                  LengthLimitingTextInputFormatter(9),
                ],
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: add ? 'Masalan 10000' : 'Yangi balans',
                  hintStyle:
                      TextStyle(color: Colors.white.withValues(alpha: 0.35)),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.07),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Bekor'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent),
                      onPressed: () => Navigator.of(ctx)
                          .pop(int.tryParse(ctrl.text.trim())),
                      child: const Text('Tasdiqlash'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    ctrl.dispose();
    if (n == null || !mounted) return;
    final err = await _ctrl.act(
      u.id,
      add ? 'balance' : 'set_balance',
      amount: n,
    );
    _say(err ?? 'Balans yangilandi');
  }

  /// Obuna kunlarini so'raydi.
  Future<void> _askDays(AdminUser u) async {
    const days = [1, 5, 10, 30];
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Glass(
            borderRadius: 20,
            blur: 18,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Obuna berish',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Mavjud obuna ustiga qo\'shiladi',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final d in days)
                      FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: AppColors.accent),
                        onPressed: () => Navigator.of(ctx).pop(d),
                        child: Text('$d kun'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(0),
                  child: Text(
                    'Obunani olib tashlash',
                    style: TextStyle(color: Colors.red.shade300),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final err = await _ctrl.act(u.id, 'sub', days: picked);
    _say(err ??
        (picked > 0 ? '$picked kunlik obuna berildi' : 'Obuna olib tashlandi'));
  }

  Future<void> _confirmBan(AdminUser u) async {
    final ban = !u.banned;
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
              Icon(ban ? Icons.block_rounded : Icons.lock_open_rounded,
                  size: 40,
                  color: ban ? Colors.red.shade300 : Colors.green.shade300),
              const SizedBox(height: 12),
              Text(
                ban
                    ? '${u.name} bloklansinmi?'
                    : '${u.name} blokdan chiqarilsinmi?',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.4),
              ),
              if (ban) ...[
                const SizedBox(height: 6),
                Text(
                  'Barcha qurilmalaridan darhol chiqariladi.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12.5),
                ),
              ],
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
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            ban ? Colors.red.shade600 : Colors.green.shade700,
                      ),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(ban ? 'Bloklash' : 'Ochish'),
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
    final err = await _ctrl.act(u.id, ban ? 'ban' : 'unban');
    _say(err ?? (ban ? 'Bloklandi' : 'Blokdan chiqarildi'));
  }
}

// ══════════════════════════════════════════════════════════════
//  RO'YXATDAGI BITTA QATOR
// ══════════════════════════════════════════════════════════════

class _UserRow extends StatelessWidget {
  final AdminUser user;
  final UserSort sort;
  final VoidCallback onTap;

  const _UserRow({
    required this.user,
    required this.sort,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final u = user;
    // Ro'yxat qaysi vaqt bo'yicha terilgan bo'lsa, o'sha vaqt
    // ko'rsatiladi — aks holda tartib tushunarsiz bo'lardi.
    final when = sort == UserSort.registered ? u.createdAt : u.lastLoginAt;

    return GlassTappable(
      onTap: onTap,
      child: Glass(
        borderRadius: 16,
        blur: 12,
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          children: [
            _Avatar(url: u.photoUrl, name: u.name, banned: u.banned),
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
                          u.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: u.banned
                                ? Colors.white.withValues(alpha: 0.5)
                                : Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            decoration:
                                u.banned ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'ID ${u.id}',
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
                      Icon(
                        sort == UserSort.registered
                            ? Icons.person_add_alt_rounded
                            : Icons.schedule_rounded,
                        size: 12,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          formatMoment(when),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                      if (u.balance > 0)
                        Text(
                          formatSum(u.balance),
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
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
  final bool banned;

  const _Avatar({
    required this.url,
    required this.name,
    required this.banned,
  });

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
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
          fontSize: 17,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipOval(
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
        ),
        // Bloklangani BIR QARASHDA ko'rinsin.
        if (banned)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.red.shade600,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.card, width: 1.5),
              ),
              child: const Icon(Icons.block_rounded,
                  size: 10, color: Colors.white),
            ),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  AMALLAR OYNASI
// ══════════════════════════════════════════════════════════════

class _ActionSheet extends StatelessWidget {
  final AdminUser user;
  final VoidCallback onBalance;
  final VoidCallback onSetBalance;
  final VoidCallback onSub;
  final VoidCallback onBan;
  final VoidCallback onProfile;
  final VoidCallback onChat;

  const _ActionSheet({
    required this.user,
    required this.onBalance,
    required this.onSetBalance,
    required this.onSub,
    required this.onBan,
    required this.onProfile,
    required this.onChat,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottom = mq.viewPadding.bottom > mq.padding.bottom
        ? mq.viewPadding.bottom
        : mq.padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottom + 14),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
        child: Glass(
          borderRadius: 22,
          blur: 18,
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      Text(
                        user.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'ID ${user.id} · ${formatSum(user.balance)}'
                        '${user.banned ? ' · bloklangan' : ''}',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _tile(Icons.add_card_rounded, 'Balansga qo\'shish', onBalance),
                _tile(Icons.edit_rounded, 'Balansni tenglash', onSetBalance),
                _tile(Icons.workspace_premium_rounded, 'Obuna berish', onSub),
                _tile(Icons.forum_rounded, 'Yozishmani ochish', onChat),
                _tile(Icons.person_rounded, 'Profilini ko\'rish', onProfile),
                _tile(
                  user.banned ? Icons.lock_open_rounded : Icons.block_rounded,
                  user.banned ? 'Blokdan chiqarish' : 'Bloklash',
                  onBan,
                  danger: !user.banned,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap,
      {bool danger = false}) {
    return ListTile(
      leading: Icon(icon,
          color: danger ? Colors.red.shade300 : Colors.white70, size: 21),
      title: Text(
        label,
        style: TextStyle(
          color: danger ? Colors.red.shade300 : Colors.white,
          fontSize: 14.5,
        ),
      ),
      onTap: onTap,
    );
  }
}
