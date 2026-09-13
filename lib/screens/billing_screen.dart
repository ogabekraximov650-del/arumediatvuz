// lib/screens/billing_screen.dart — OBUNA, TO'LDIRISH VA TARIX.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB (foydalanuvchi)
// ═══════════════════════════════════════════════════════════════
//
// "Profil sahifasidagi profil ma'lumotlari va shaxsiy statistika
//  orasiga 'Obuna olish va Balans to'ldirish' degan eniga
//  cho'zilgan bitta uzun tugma qo'sh. Tugmani bosganda yuqorida
//  3 ta tugma bo'lsin: Obuna, To'ldirish, Tarix.
//
//  Agar foydalanuvchi balansida pul bo'lsa obuna oynasi ochiladi,
//  agar yo'q bo'lsa to'ldirish oynasi ochiladi.
//
//  Bu oynalarni qo'lda surib o'tkazsa bo'ladigan bo'lsin —
//  kutubxonadagi oynalardek."
//
// ═══════════════════════════════════════════════════════════════
//  PUL — HAMMASI SERVERDA
// ═══════════════════════════════════════════════════════════════
//
// Bu faylda birorta narx YO'Q. Tariflar, balans va obuna muddati
// serverdan keladi (`billing_service.dart` izohiga qarang).
// To'lovni tezchek.uz tasdiqlaydi, balansni worker oshiradi.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/billing_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

class BillingScreen extends StatefulWidget {
  /// Qaysi oynadan boshlansin: 0 — Obuna, 1 — To'ldirish, 2 — Tarix.
  final int startPage;

  const BillingScreen({super.key, this.startPage = 0});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  late final PageController _pages =
      PageController(initialPage: widget.startPage);
  late int _page = widget.startPage;

  @override
  void initState() {
    super.initState();
    // Ekran ochilganda eng yangi holat olinadi.
    unawaited(BillingService.instance.load(force: true));
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    if (i == _page) return;
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
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
          title: const Text('Obuna va balans',
              style: TextStyle(color: Colors.white, fontSize: 18)),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              const _BalanceBar(),
              _Switcher(page: _page, onChanged: _goTo),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: const [
                    _SubscribePage(),
                    _TopUpPage(),
                    _HistoryPage(),
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
//  TEPADAGI BALANS VA OBUNA HOLATI
// ══════════════════════════════════════════════════════════════

class _BalanceBar extends StatelessWidget {
  const _BalanceBar();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        final b = BillingService.instance;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Glass(
            borderRadius: 18,
            blur: 14,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Balans',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatSum(b.balance),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Obuna',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      b.active ? '${b.daysLeft} kun qoldi' : 'Yo\'q',
                      style: TextStyle(
                        color: b.active
                            ? const Color(0xFF7BD88F)
                            : Colors.white.withValues(alpha: 0.7),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  UCHTA TUGMA
// ══════════════════════════════════════════════════════════════

class _Switcher extends StatelessWidget {
  final int page;
  final ValueChanged<int> onChanged;
  const _Switcher({required this.page, required this.onChanged});

  static const _labels = ['Obuna', 'To\'ldirish', 'Tarix'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          for (var i = 0; i < _labels.length; i++) ...[
            Expanded(
              child: _SwitchButton(
                label: _labels[i],
                active: page == i,
                onTap: () => onChanged(i),
              ),
            ),
            if (i != _labels.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _SwitchButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _SwitchButton(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: active
              ? const LinearGradient(
                  colors: [AppColors.accent, AppColors.accent2],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: active ? null : AppColors.card,
          border: Border.all(
              color: active ? Colors.transparent : AppColors.border, width: 1),
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? Colors.white : Colors.white60,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  1) OBUNA
// ══════════════════════════════════════════════════════════════

class _SubscribePage extends StatelessWidget {
  const _SubscribePage();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        final b = BillingService.instance;
        if (b.plans.isEmpty) {
          return _Placeholder(
            loading: b.isLoading,
            text: b.error ?? 'Tariflar yuklanmoqda...',
          );
        }
        return ListView(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          children: [
            for (final p in b.plans) ...[
              _PlanTile(plan: p),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 4),
            Text(
              'Obuna balansdan yechiladi. Muddati tugamagan obuna '
              'ustiga yangi tarif qo\'shiladi.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlanTile extends StatefulWidget {
  final SubPlan plan;
  const _PlanTile({required this.plan});

  @override
  State<_PlanTile> createState() => _PlanTileState();
}

class _PlanTileState extends State<_PlanTile> {
  bool _busy = false;

  Future<void> _buy() async {
    final b = BillingService.instance;
    if (b.balance < widget.plan.price) {
      _say('Balansda mablag\' yetarli emas — avval to\'ldiring');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Obunani tasdiqlang',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Text(
          '${widget.plan.days} kunlik obuna — '
          '${formatSum(widget.plan.price)}.\n'
          'Summa balansingizdan yechiladi.',
          style: const TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Bekor qilish'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sotib olish',
                style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final err = await BillingService.instance.subscribe(widget.plan.days);
    if (!mounted) return;
    setState(() => _busy = false);
    _say(err ?? 'Obuna faollashtirildi');
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
    return Glass(
      borderRadius: 16,
      blur: 12,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${widget.plan.days} kunlik',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  formatSum(widget.plan.price),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed: _busy ? null : _buy,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Sotib olish',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  2) TO'LDIRISH
// ══════════════════════════════════════════════════════════════

class _TopUpPage extends StatefulWidget {
  const _TopUpPage();

  @override
  State<_TopUpPage> createState() => _TopUpPageState();
}

class _TopUpPageState extends State<_TopUpPage> {
  final _amount = TextEditingController();
  bool _busy = false;

  /// Havolalardagi "qolgan vaqt" har soniyada yangilanadi.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final n = int.tryParse(_amount.text.replaceAll(RegExp(r'[^0-9]'), ''));
    if (n == null || n <= 0) {
      _say('Summani yozing');
      return;
    }
    setState(() => _busy = true);
    final err = await BillingService.instance.createLink(n);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _say(err);
      return;
    }
    _amount.clear();
    FocusScope.of(context).unfocus();
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
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        final links =
            BillingService.instance.links.where((l) => l.alive).toList();
        return ListView(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          children: [
            Glass(
              borderRadius: 16,
              blur: 12,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Summani yozing',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      hintText: '10000',
                      hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.25)),
                      suffixText: 'so\'m',
                      suffixStyle:
                          TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.06),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: _busy ? null : _create,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('To\'lov havolasi yaratish',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (links.isEmpty)
              Text(
                'Faol havola yo\'q. Summani yozib, havola yarating —\n'
                'har bir havola 1 soat faol turadi.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12,
                  height: 1.5,
                ),
              )
            else
              for (final l in links) ...[
                _LinkTile(link: l),
                const SizedBox(height: 10),
              ],
          ],
        );
      },
    );
  }
}

/// Bitta to'lov havolasi: summa, qolgan vaqt va ikkita tugma.
class _LinkTile extends StatefulWidget {
  final PayLink link;
  const _LinkTile({required this.link});

  @override
  State<_LinkTile> createState() => _LinkTileState();
}

class _LinkTileState extends State<_LinkTile> {
  bool _busy = false;

  String get _left {
    final d = widget.link.left;
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _pay() async {
    final uri = Uri.tryParse(widget.link.url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      _say('Brauzer ochilmadi');
    }
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final r = await BillingService.instance.check(widget.link.orderId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.error != null) {
      _say(r.error!);
      return;
    }
    _say(r.paid
        ? 'To\'lov qabul qilindi — balans yangilandi'
        : 'Hozircha to\'lov ko\'rinmadi');
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
    return Glass(
      borderRadius: 16,
      blur: 12,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                formatSum(widget.link.amount),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Icon(Icons.timer_outlined,
                  size: 14, color: Colors.white.withValues(alpha: 0.5)),
              const SizedBox(width: 4),
              Text(
                'Qolgan vaqt $_left daqiqa',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    minimumSize: const Size(0, 42),
                  ),
                  onPressed: _pay,
                  child: const Text('To\'lov qilish',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 42),
                    side: const BorderSide(color: AppColors.border),
                  ),
                  onPressed: _busy ? null : _check,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white70),
                        )
                      : const Text('Tekshirish',
                          style: TextStyle(
                              fontSize: 13,
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  3) TARIX
// ══════════════════════════════════════════════════════════════

class _HistoryPage extends StatelessWidget {
  const _HistoryPage();

  static String _when(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}  '
        '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        final b = BillingService.instance;
        if (b.history.isEmpty) {
          return _Placeholder(
            loading: b.isLoading,
            text: b.error ?? 'Hozircha yozuv yo\'q',
          );
        }
        return ListView.builder(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          itemCount: b.history.length,
          itemBuilder: (context, i) {
            final e = b.history[i];
            final up = e.isTopUp;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                borderRadius: 14,
                blur: 10,
                padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: (up
                                ? const Color(0xFF7BD88F)
                                : AppColors.accent)
                            .withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        up
                            ? Icons.add_card_rounded
                            : Icons.workspace_premium_rounded,
                        size: 18,
                        color: up
                            ? const Color(0xFF7BD88F)
                            : AppColors.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            up
                                ? 'Balans to\'ldirildi'
                                : '${e.days} kunlik obuna',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _when(e.createdAt),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${up ? '+' : '−'}${formatSum(e.amount)}',
                      style: TextStyle(
                        color: up
                            ? const Color(0xFF7BD88F)
                            : Colors.white.withValues(alpha: 0.8),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  final bool loading;
  final String text;
  const _Placeholder({required this.loading, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                  strokeWidth: 2.2, color: Colors.white54),
            )
          else
            Icon(Icons.receipt_long_rounded,
                size: 40, color: Colors.white.withValues(alpha: 0.25)),
          const SizedBox(height: 14),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
