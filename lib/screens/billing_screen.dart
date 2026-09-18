// lib/screens/billing_screen.dart — OBUNA, TO'LDIRISH VA TARIX.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB (foydalanuvchi)
// ═══════════════════════════════════════════════════════════════
//
// "Profil sahifasidagi profil ma'lumotlari va shaxsiy statistika
//  orasiga 'Obuna olish va Balans to'ldirish' degan eniga
//  cho'zilgan bitta uzun tugma qo'sh. Tugmani bosganda yuqorida
//  3 ta tugma bo'lsin: To'ldirish, Obuna, Tarix.
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
  /// Qaysi oynadan boshlansin: 0 — To'ldirish, 1 — Obuna, 2 — Tarix.
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
                  children: [
                    // ── TARTIB ALMASHTIRILDI ────────────────
                    //
                    // TALAB (foydalanuvchi): "Obuna sotib olish va
                    // Balans to'ldirish oynasini almashtir".
                    //
                    // Endi birinchi o'rinda To'ldirish turadi —
                    // obuna balansdan olinadi, ya'ni ko'pchilik
                    // baribir avval balansni to'ldiradi.
                    //
                    // To'lov tasdiqlangan zahoti Tarix oynasiga
                    // o'tiladi: havola ro'yxatdan yo'qoladi va
                    // yozuv tarixda ko'rinadi (foydalanuvchi
                    // talabi: "to'lov tekshiruvdan o'tganda
                    // to'lov oynasidan olib tashlanib tarix
                    // oynasiga yozilishi kerak").
                    _TopUpPage(onPaid: () => _goTo(2)),
                    const _SubscribePage(),
                    const _HistoryPage(),
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
                    // Kun, soat, daqiqa va sekund — har soniyada
                    // yangilanadi (`SubCountdown` izohiga qarang).
                    SubCountdown(
                      style: TextStyle(
                        color: b.active
                            ? AppColors.success
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

  static const _labels = ['To\'ldirish', 'Obuna', 'Tarix'];

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
        // ── OBUNASI BOR ODAM YANGISINI OLA OLMAYDI ────────────
        //
        // TALAB (foydalanuvchi): "Obuna sotib olgan odam obunasi
        // tugamaguncha obuna sotib ola olmaydi".
        //
        // Tugmalar shunchaki o'chiriladi va sababi yoziladi —
        // foydalanuvchi nega bosa olmayotganini ko'rib tursin.
        // Haqiqiy to'siq SERVERDA (`billing_subscribe`), bu yer
        // faqat tushuntirish uchun.
        final locked = b.active;
        return ListView(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          children: [
            if (locked) ...[
              const _ActiveSubNote(),
              const SizedBox(height: 12),
            ],
            for (final p in b.plans) ...[
              _PlanTile(
                plan: p,
                locked: locked,
                discountPercent: _discountOf(p, b.plans),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 4),
            Text(
              locked
                  ? 'Obunangiz tugagach yangi tarif tanlay olasiz.'
                  : 'Obuna balansdan yechiladi.',
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

/// Tarifning eng qisqasiga (1 oylik) nisbatan tejash foizi.
///
/// Hisob kun narxi bo'yicha: uzoq tarifning bir kuni qanchaga
/// tushishini 1 oylik tarifning bir kuni bilan solishtiradi.
/// Ro'yxat bo'sh yoki baza topilmasa — 0.
int _discountOf(SubPlan plan, List<SubPlan> all) {
  if (all.isEmpty || plan.days <= 0) return 0;
  var base = all.first;
  for (final p in all) {
    if (p.days > 0 && p.days < base.days) base = p;
  }
  if (base.days <= 0 || base.price <= 0 || plan.days <= base.days) return 0;
  final basePerDay = base.price / base.days;
  final perDay = plan.price / plan.days;
  final saved = ((1 - perDay / basePerDay) * 100).round();
  return saved < 0 ? 0 : saved;
}

/// "Sizda faol obuna bor" izohi.
class _ActiveSubNote extends StatelessWidget {
  const _ActiveSubNote();

  @override
  Widget build(BuildContext context) {
    return Glass(
      borderRadius: 16,
      blur: 12,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          const Icon(Icons.verified_rounded,
              color: AppColors.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Obunangiz faol',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(
                      'Yana ',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontSize: 12,
                      ),
                    ),
                    Flexible(
                      child: SubCountdown(
                        expired: 'tugadi',
                        style: const TextStyle(
                          color: AppColors.success,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Tugagach yangi tarif tanlay olasiz.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11.5,
                    height: 1.35,
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

class _PlanTile extends StatefulWidget {
  final SubPlan plan;

  /// Obuna hali faol — tugma bosilmaydi.
  final bool locked;

  /// Eng qisqa (1 oylik) tarifga nisbatan tejash foizi.
  final int discountPercent;

  const _PlanTile({
    required this.plan,
    this.locked = false,
    this.discountPercent = 0,
  });

  @override
  State<_PlanTile> createState() => _PlanTileState();
}

class _PlanTileState extends State<_PlanTile> {
  bool _busy = false;

  Future<void> _buy() async {
    final b = BillingService.instance;
    if (widget.locked) {
      _say('Sizda faol obuna bor — u tugagach yangisini olasiz');
      return;
    }
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
          '${planLabel(widget.plan.days)} obuna — '
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
                Row(
                  children: [
                    Text(
                      '+ ${planLabel(widget.plan.days)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    // ── CHEGIRMA BELGISI ────────────────────
                    //
                    // 1 oylik narxga nisbatan hisoblanadi
                    // (3 oy ~13%, 6 oy ~27%, 12 oy ~33%). Faqat
                    // sezilarli (>=5%) bo'lsa ko'rsatiladi.
                    if (widget.discountPercent >= 5) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.success
                              .withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          '${widget.discountPercent}% chegirma',
                          style: const TextStyle(
                            color: AppColors.success,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
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
            onPressed: (_busy || widget.locked) ? null : _buy,
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
  /// To'lov tasdiqlanganda chaqiriladi (Tarix oynasiga o'tish).
  final VoidCallback onPaid;
  const _TopUpPage({required this.onPaid});

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

  /// Summani yozgach — DARHOL to'lov sahifasiga.
  ///
  /// TALAB (foydalanuvchi): "balans to'ldirishda turmoqchi bo'lgan
  /// summani yozgach to'g'ri havolaga yo'naltirilsin va avtomatik
  /// ravishda pul hisobiga tushsin".
  ///
  /// Ilgari uch qadam bor edi: summani yozish -> havola qatorini
  /// kutish -> "To'lash" tugmasini bosish. Endi bitta: summa
  /// yoziladi va brauzer o'zi ochiladi.
  ///
  /// Pul esa hisobga O'ZI tushadi — `_LinkTileState` izohiga
  /// qarang (webhook + ilova tomonidagi kuzatuvchi).
  Future<void> _create() async {
    if (_busy) return;
    final n = int.tryParse(_amount.text.replaceAll(RegExp(r'[^0-9]'), ''));
    if (n == null || n <= 0) {
      _say('Summani yozing');
      return;
    }
    setState(() => _busy = true);
    final r = await BillingService.instance.createLink(n);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.error != null) {
      _say(r.error!);
      return;
    }
    _amount.clear();
    FocusScope.of(context).unfocus();

    final url = r.url == null ? null : Uri.tryParse(r.url!);
    if (url == null) {
      // Havola yaratildi, lekin manzil kelmadi — qator baribir
      // ro'yxatda turadi, odam undan ocha oladi.
      _say('Havola tayyor — pastdagi "To\'lash" tugmasini bosing');
      return;
    }
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        _say('Brauzer ochilmadi — pastdagi "To\'lash" tugmasini bosing');
      }
    }
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
                        // Tugma endi havola YARATMAYDI — u
                        // to'g'ridan-to'g'ri to'lov sahifasini
                        // ochadi, shu sabab nomi ham shunga mos.
                        : const Text('To\'lashga o\'tish',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (links.isEmpty)
              Text(
                'Summani yozing — to\'lov sahifasi o\'zi ochiladi.\n'
                'Pul hisobingizga avtomatik tushadi, havola esa\n'
                '1 soat faol turadi.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12,
                  height: 1.5,
                ),
              )
            else
              for (final l in links) ...[
                _LinkTile(link: l, onPaid: widget.onPaid),
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
  final VoidCallback onPaid;
  const _LinkTile({required this.link, required this.onPaid});

  @override
  State<_LinkTile> createState() => _LinkTileState();
}

class _LinkTileState extends State<_LinkTile> with WidgetsBindingObserver {
  bool _busy = false;

  // ══════════════════════════════════════════════════════════
  //  PUL O'ZI TUSHADI — TUGMA BOSILMAYDI
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "ilovani ham tekshirishsiz avto pul
  // tushadigan qilish kerak".
  //
  // Ikki tomondan qaralgan:
  //
  //   1. SERVER. tezcheck.uz pul tushishi bilan worker'ga xabar
  //      yuboradi (webhook) va balans o'sha zahoti oshadi —
  //      ilova umuman qatnashmaydi.
  //
  //   2. ILOVA. Bu yerdagi kuzatuvchi balansni o'zi so'rab
  //      turadi, ya'ni raqam ko'z oldida yangilanadi. Webhook
  //      sozlanmagan bo'lsa ham pul shu yo'l bilan tushadi.
  //
  // "Tekshirish" tugmasi OLIB TASHLANMADI: ikkala yo'l ham
  // tarmoqqa bog'liq va odam baribir qo'lda turtish imkoniga ega
  // bo'lishi kerak.
  //
  // ── NEGA TEZLIK O'ZGARIB TURADI ──────────────────────────
  //
  // Havola bir soat yashaydi. Har 5 soniyada so'rov yuborilsa —
  // bitta to'lov uchun 720 ta so'rov, ya'ni bekorga yoqilgan
  // trafik va server yuki.
  //
  // Amalda odam Click/Payme'ga o'tib, 1-2 daqiqada qaytadi. Shu
  // sabab: boshida tez-tez, keyin siyraklashib boradi. Eng
  // muhim payt esa — ILOVAGA QAYTGAN LAHZA: o'shanda taymerni
  // kutmasdan DARHOL tekshiriladi (`didChangeAppLifecycleState`).
  static const List<(Duration, Duration)> _pollPlan = [
    // (shu vaqtgacha, shu oraliqda)
    (Duration(minutes: 2), Duration(seconds: 4)),
    (Duration(minutes: 10), Duration(seconds: 15)),
    (Duration(hours: 2), Duration(seconds: 60)),
  ];

  Timer? _poll;

  /// Kuzatuv boshlangan payt — oraliqni tanlash uchun.
  DateTime _watchFrom = DateTime.now();

  /// So'rov ayni damda ketyaptimi (ikkitasi bir vaqtda ketmasin).
  bool _checking = false;

  /// To'lov topildi — kuzatish tugadi.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _armPoll();
  }

  @override
  void didUpdateWidget(_LinkTile old) {
    super.didUpdateWidget(old);
    if (old.link.orderId != widget.link.orderId) {
      _done = false;
      _watchFrom = DateTime.now();
      _armPoll();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Odam bank ilovasidan/brauzerdan QAYTDI — eng ehtimolli
    // payt. Taymer nechada turganidan qat'i nazar darhol
    // tekshiramiz va sanoqni boshidan boshlaymiz (yana bir necha
    // marta tez-tez so'raladi).
    if (state != AppLifecycleState.resumed || _done) return;
    _watchFrom = DateTime.now();
    unawaited(_silentCheck());
    _armPoll();
  }

  /// Keyingi so'rovgacha qancha kutiladi.
  Duration get _gap {
    final since = DateTime.now().difference(_watchFrom);
    for (final (until, gap) in _pollPlan) {
      if (since < until) return gap;
    }
    return _pollPlan.last.$2;
  }

  void _armPoll() {
    _poll?.cancel();
    if (_done || !mounted) return;
    _poll = Timer(_gap, () async {
      await _silentCheck();
      _armPoll();
    });
  }

  /// Jimgina tekshiradi: xato bo'lsa ekranga HECH NARSA
  /// chiqarilmaydi (odam so'ramagan — xabar ham kerak emas).
  Future<void> _silentCheck() async {
    if (_checking || _done || !mounted) return;
    _checking = true;
    try {
      final r = await BillingService.instance.check(widget.link.orderId);
      if (!mounted || !r.paid) return;
      _done = true;
      _poll?.cancel();
      widget.onPaid();
    } catch (_) {
      // Tarmoq yo'q — keyingi urinishda.
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

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
    if (_busy) return;
    setState(() => _busy = true);
    final r = await BillingService.instance.check(widget.link.orderId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.error != null) {
      _say(r.error!);
      return;
    }
    if (!r.paid) {
      _say('Hozircha to\'lov ko\'rinmadi');
      return;
    }
    // Havola SERVERDA `paid` ga o'tdi, ya'ni `load()` dan keyin u
    // faol havolalar ro'yxatida umuman qaytmaydi va o'rniga
    // tarixda "Balans to'ldirildi" yozuvi paydo bo'ladi.
    _done = true;
    _poll?.cancel();
    _say('To\'lov qabul qilindi — balans yangilandi');
    widget.onPaid();
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
                                ? AppColors.success
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
                            ? AppColors.success
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
                                : '${planLabel(e.days)} obuna',
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
                            ? AppColors.success
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
