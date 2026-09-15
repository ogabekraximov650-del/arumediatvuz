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
// ── BITTA BO'LIM ────────────────────────────────────────────
//
// TALAB (foydalanuvchi): "foydalanuvchi boshqaruvini barcha
// suhbatlarga ulay olasanmi, ya'ni bitta bo'lim orqali ishlash
// qulayroq bo'lar edi".
//
// Shu sabab yozishmalar ro'yxati ham SHU EKRANDA, uchinchi
// varaq bo'lib turadi. Admin panelida endi bitta tugma:
// odam ham, u bilan yozishma ham shu yerdan topiladi.
//
// ── QANDAY AMALLAR BOR ──────────────────────────────────────
//
// Qatorga bosilsa pastdan oyna chiqadi:
//
//   * Balansga summa qo'shish yoki AYIRISH (qo'lda yoziladi);
//   * Obunaga kun qo'shish yoki AYIRISH (qo'lda yoziladi);
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
import '../services/support_service.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'public_profile_screen.dart';
import 'support_chat_screen.dart';

/// Ekrandagi uchta varaq.
///
/// Birinchi ikkitasi FOYDALANUVCHILAR ro'yxati (qaysi vaqt
/// bo'yicha terilishi bilan farq qiladi), uchinchisi esa
/// YOZISHMALAR.
enum _Tab {
  registered('Yangi'),
  online('Onlayn'),
  chats('Suhbatlar');

  final String label;
  const _Tab(this.label);
}

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final _ctrl = AdminUsersController();
  final _threads = ChatThreadsController();
  final _search = TextEditingController();

  // ── HAR VARAQQA O'Z SURISH NAZORATCHISI ─────────────────
  //
  // "Yangi" va "Onlayn" endi bir vaqtda daraxtda turadi
  // (`PageView`), ya'ni BITTA nazoratchini ikkovi ham
  // ishlatolmaydi — Flutter buni xato deb qaytaradi. Ustiga
  // ikkovining surish joyi alohida bo'lgani to'g'ri ham:
  // varaq almashganda ro'yxat boshiga sakramaydi.
  final _scrollNew = ScrollController();
  final _scrollOnline = ScrollController();

  _Tab _tab = _Tab.registered;

  // ── VARAQLARNI QO'LDA SURIB O'TKAZISH ───────────────────
  //
  // TALAB (foydalanuvchi): "oynalarni qo'lda surib o'tkazsa
  // bo'ladigan qil".
  //
  // Tugma bosilganda ham, surilganda ham bitta manba
  // (`_tab`) o'zgaradi — ya'ni tugma bilan ko'rinayotgan
  // oyna hech qachon bir-biriga zid bo'lib qolmaydi.
  late final PageController _pages =
      PageController(initialPage: _tab.index);

  /// Admin varaqni O'ZI tanladimi.
  ///
  /// TALAB (foydalanuvchi): "foydalanuvchi bo'limidan support
  /// chatga xabar kelganda xabar oynasi birinchi chiqishi
  /// kerak".
  ///
  /// Yozishmalar ro'yxati tarmoqdan biroz keyin keladi, ya'ni
  /// "o'qilmagan bormi" degan savolga javob ekran ochilgandan
  /// SO'NG ma'lum bo'ladi. Shu sabab o'tish keyinroq ham
  /// bo'lishi mumkin — lekin admin o'zi boshqa varaqqa
  /// o'tgan bo'lsa, uni zo'rlab qaytarib olib kelmaydi.
  bool _tabPicked = false;

  /// Izlash HAR HARFDA emas, yozish to'xtagach yuboriladi.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Avval DISK (darhol), keyin tarmoq.
    _ctrl.loadFromDisk();
    _ctrl.load();
    // Yozishmalar ham shu ekranda — varaq ochilishini kutmasdan
    // yuklanadi, chunki ustidagi o'qilmaganlar soni darhol
    // kerak bo'ladi.
    _threads.loadFromDisk();
    // Diskdagi nusxada allaqachon o'qilmagan bo'lsa — darhol
    // yozishmalar varag'ida ochiladi (tarmoq kutilmaydi).
    _jumpToChatsIfUnread(initial: true);
    unawaited(_threads.load().then((_) {
      if (mounted) _jumpToChatsIfUnread();
    }));
    // Yangi xabar DARHOL yuqorida paydo bo'lsin (uzoq kutish —
    // `ChatThreadsController._watchLoop` izohiga qarang).
    _threads.startWatching();
    for (final c in [_scrollNew, _scrollOnline]) {
      c.addListener(() {
        if (!c.hasClients) return;
        final left = c.position.maxScrollExtent - c.position.pixels;
        if (left < 400) _ctrl.loadMore();
      });
    }
  }

  /// O'qilmagan xabar bo'lsa yozishmalar varag'ini ochadi.
  ///
  /// `initial` — `initState` dan chaqirilgan: ekran hali
  /// qurilmagan, ya'ni `setState` ham, `PageController` ham
  /// kerak emas (boshlang'ich varaq `_pages` yaratilganda
  /// `_tab` dan olinadi).
  void _jumpToChatsIfUnread({bool initial = false}) {
    if (_tabPicked || _tab == _Tab.chats) return;
    final unread = _threads.items.fold<int>(0, (n, t) => n + t.unread);
    if (unread <= 0) return;
    if (initial) {
      _tab = _Tab.chats;
      return;
    }
    _goToTab(_Tab.chats, fromSwipe: false);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pages.dispose();
    _ctrl.dispose();
    _threads.stopWatching();
    _threads.dispose();
    _search.dispose();
    _scrollNew.dispose();
    _scrollOnline.dispose();
    super.dispose();
  }

  /// Tugma bosildi.
  void _setTab(_Tab t) {
    _tabPicked = true;
    _goToTab(t, fromSwipe: false);
  }

  /// Varaqni almashtiradi.
  ///
  /// `fromSwipe` — surish natijasida chaqirilgan bo'lsa
  /// `PageController` allaqachon to'g'ri joyda, ya'ni unga
  /// qayta tegilmaydi (aks holda surish o'rtasida sakrash
  /// bo'lardi).
  void _goToTab(_Tab t, {required bool fromSwipe}) {
    if (_tab == t) return;
    setState(() => _tab = t);
    if (!fromSwipe && _pages.hasClients) {
      _pages.animateToPage(
        t.index,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
    switch (t) {
      case _Tab.registered:
        _ctrl.setSort(UserSort.registered);
      case _Tab.online:
        _ctrl.setSort(UserSort.online);
      case _Tab.chats:
        _threads.load(force: true);
    }
  }

  /// Yozishmani ochadi va qaytilganda ro'yxatni yangilaydi.
  Future<void> _openChat(int userId, String name, String photo) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SupportChatScreen(
          userId: userId,
          title: name,
          photoUrl: photo,
        ),
      ),
    );
    // O'qilmaganlar soni o'zgargan va tartib siljigan bo'lishi
    // mumkin.
    if (!mounted) return;
    await _threads.load(force: true);
    await UnreadBadge.instance.refresh();
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
            animation: Listenable.merge([_ctrl, _threads]),
            builder: (context, _) => Column(
              children: [
                // Izlash faqat ODAMLAR ro'yxatida mantiqli.
                if (_tab != _Tab.chats) _searchBox(),
                _sortTabs(),
                Expanded(
                  // Varaqlar qo'lda suriladi (foydalanuvchi
                  // talabi). Tartib `_Tab` dagidek:
                  // Yangi | Onlayn | Suhbatlar.
                  child: PageView(
                    controller: _pages,
                    // `Clamping` — chetda cho'zilishning ma'nosi
                    // yo'q va har cho'zilish qo'shni varaqni
                    // ham qaytadan chizardi.
                    physics: const ClampingScrollPhysics(),
                    onPageChanged: (i) {
                      _tabPicked = true;
                      _goToTab(_Tab.values[i], fromSwipe: true);
                    },
                    children: [
                      // Birinchi ikkovi BITTA ro'yxat, faqat
                      // tartibi boshqacha — `_ctrl.setSort`
                      // varaq almashganda chaqiriladi.
                      _list(_scrollNew),
                      _list(_scrollOnline),
                      _chatList(),
                    ],
                  ),
                ),
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

  // ── UCHTA VARAQ ───────────────────────────────────────────
  //
  // Ikkita odamlar ro'yxati va bitta yozishmalar ro'yxati.
  // Suhbatlar varag'ining yonida o'qilmagan xabarlar soni
  // turadi — admin qaysi varaqda bo'lsa ham ko'rinadi.
  Widget _sortTabs() {
    final unread = _threads.items.fold<int>(0, (n, t) => n + t.unread);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Row(
        children: [
          for (final t in _Tab.values) ...[
            Expanded(
              child: GestureDetector(
                onTap: () => _setTab(t),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: _tab == t
                        ? AppColors.accent
                        : Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _tab == t
                          ? AppColors.accent
                          : Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          t.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _tab == t
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.65),
                            fontSize: 13,
                            fontWeight: _tab == t
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (t == _Tab.chats && unread > 0) ...[
                        const SizedBox(width: 5),
                        Container(
                          constraints: const BoxConstraints(minWidth: 17),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: _tab == t
                                ? Colors.white
                                : AppColors.accent,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            '$unread',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _tab == t
                                  ? AppColors.accent
                                  : Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (t != _Tab.values.last) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  // ── YOZISHMALAR RO'YXATI ──────────────────────────────────
  //
  // Tartib SERVERDA hisoblanadi (`chat_threads.last_at DESC`),
  // ilovada emas: ilova 200 tasini oladi, saralash ilovada bo'lsa
  // 201-suhbatdagi yangi xabar ro'yxatga umuman tushmasdi.
  Widget _chatList() {
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
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 24),
              itemCount: rows.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ThreadRow(
                  thread: rows[i],
                  onTap: () =>
                      _openChat(rows[i].userId, rows[i].name, rows[i].photoUrl),
                  // Uzoq bosilsa — butun yozishma o'chiriladi.
                  onLongPress: () => _confirmDeleteThread(rows[i]),
                ),
              ),
            ),
    );
  }

  /// Butun yozishmani o'chirish (tasdiq bilan).
  Future<void> _confirmDeleteThread(ChatThread t) async {
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
              Icon(Icons.delete_forever_rounded,
                  size: 42, color: Colors.red.shade300),
              const SizedBox(height: 12),
              Text(
                '${t.name} bilan butun yozishma o\'chirilsinmi?',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 6),
              Text(
                'Bu amalni ortga qaytarib bo\'lmaydi.',
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
                      child: const Text('O\'chirish'),
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
    final err = await _threads.removeThread(t.userId);
    if (!mounted) return;
    if (err != null) {
      _say(err);
      return;
    }
    await UnreadBadge.instance.refresh();
  }

  Widget _list(ScrollController scroll) {
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
        controller: scroll,
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
          _askAmount(u);
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
          _openChat(u.id, u.name, u.photoUrl);
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  //  QO'LDA SUMMA / KUN KIRITISH
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "foydalanuvchi balansidan qo'lda
  // summani kiritib olib tashlash yoki qo'shish mumkin bo'lsin,
  // hozirgidek tahrirlash emas. Obuna ham shunaqa bo'lsin —
  // qo'lda necha kunligini yozadi va xohlasa kun qo'shadi,
  // xohlasa olib tashlaydi".
  //
  // Ya'ni bitta oyna: son yoziladi, keyin QO'SHISH yoki AYIRISH
  // tugmasi bosiladi. Manfiy son yozish shart emas va "yangi
  // qiymatga tenglash" degan chalkash amal ham yo'q.

  /// Son so'raydigan umumiy oyna. Qaytaradi: (son, qo'shilsinmi).
  Future<(int, bool)?> _askNumber({
    required String title,
    required String subtitle,
    required String hint,
    required String addLabel,
    required String subLabel,
    Widget? extra,
  }) async {
    final ctrl = TextEditingController();
    final res = await showDialog<(int, bool)>(
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
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
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
                // Faqat musbat son: yo'nalishni TUGMA hal qiladi.
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(9),
                ],
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: hint,
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
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        final n = int.tryParse(ctrl.text.trim()) ?? 0;
                        if (n > 0) Navigator.of(ctx).pop((n, false));
                      },
                      icon: const Icon(Icons.remove_rounded, size: 18),
                      label: Text(subLabel,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade300,
                        side: BorderSide(color: Colors.red.shade300),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent),
                      onPressed: () {
                        final n = int.tryParse(ctrl.text.trim()) ?? 0;
                        if (n > 0) Navigator.of(ctx).pop((n, true));
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(addLabel,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
              if (extra != null) ...[
                const SizedBox(height: 8),
                extra,
              ],
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Bekor'),
              ),
            ],
          ),
        ),
      ),
    );
    ctrl.dispose();
    return res;
  }

  /// Balansga summa qo'shadi yoki ayiradi.
  Future<void> _askAmount(AdminUser u) async {
    final res = await _askNumber(
      title: 'Balansni o\'zgartirish',
      subtitle: '${u.name} · hozir ${formatSum(u.balance)}',
      hint: 'Masalan 10000',
      addLabel: 'Qo\'shish',
      subLabel: 'Ayirish',
    );
    if (res == null || !mounted) return;
    final (n, add) = res;
    final err = await _ctrl.act(u.id, 'balance', amount: add ? n : -n);
    if (!mounted) return;
    _say(err ??
        (add
            ? '${formatSum(n)} qo\'shildi'
            : '${formatSum(n)} yechib olindi'));
  }

  /// Obunaga kun qo'shadi yoki ayiradi.
  Future<void> _askDays(AdminUser u) async {
    final left = u.subDaysLeft;
    final res = await _askNumber(
      title: 'Obuna muddati',
      subtitle: left > 0
          ? '${u.name} · hozir $left kun qolgan'
          : '${u.name} · obunasi yo\'q',
      hint: 'Necha kun',
      addLabel: 'Kun qo\'shish',
      subLabel: 'Kun ayirish',
      // Butunlay bekor qilish alohida turadi: u kun bilan emas,
      // BIR YO'LA ishlaydi.
      extra: left > 0
          ? TextButton(
              onPressed: () => Navigator.of(context).pop((0, false)),
              child: Text(
                'Obunani butunlay bekor qilish',
                style: TextStyle(color: Colors.red.shade300, fontSize: 13),
              ),
            )
          : null,
    );
    if (res == null || !mounted) return;
    final (n, add) = res;
    if (n == 0) {
      final err = await _ctrl.act(u.id, 'sub_clear');
      if (!mounted) return;
      _say(err ?? 'Obuna bekor qilindi');
      return;
    }
    final err = await _ctrl.act(u.id, 'sub', days: add ? n : -n);
    if (!mounted) return;
    _say(err ?? (add ? '$n kun qo\'shildi' : '$n kun olib tashlandi'));
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
  final VoidCallback onSub;
  final VoidCallback onBan;
  final VoidCallback onProfile;
  final VoidCallback onChat;

  const _ActionSheet({
    required this.user,
    required this.onBalance,
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
                        '${user.hasSub ? ' · obuna ${user.subDaysLeft} kun' : ''}'
                        '${user.banned ? ' · bloklangan' : ''}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _tile(Icons.account_balance_wallet_rounded,
                    'Balansni o\'zgartirish', onBalance),
                _tile(Icons.workspace_premium_rounded,
                    'Obuna muddati', onSub),
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

// ══════════════════════════════════════════════════════════════
//  YOZISHMALAR RO'YXATIDAGI BITTA QATOR
// ══════════════════════════════════════════════════════════════
//
// Telegram'dagidek: rasm, ism, oxirgi xabar, vaqti va
// o'qilmaganlar soni. Rasmga bosilsa profil ochiladi.

class _ThreadRow extends StatelessWidget {
  final ChatThread thread;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ThreadRow({
    required this.thread,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final t = thread;
    return GestureDetector(
      onLongPress: onLongPress,
      child: GlassTappable(
        onTap: onTap,
        child: Glass(
          borderRadius: 16,
          blur: 12,
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PublicProfileScreen(userId: t.userId),
                  ),
                ),
                child: _Avatar(url: t.photoUrl, name: t.name, banned: false),
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
      ),
    );
  }
}
