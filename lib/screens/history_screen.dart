// lib/screens/history_screen.dart — TOMOSHA TARIXI.
//
// Ikki ko'rinish bor va ular BITTA joyda yashaydi (`PageView`):
//
//   * ANIME BO'YICHA — har bir anime bitta karta: oxirgi ko'rilgan
//     qismning KADRI, tagida bo'lim nomi, "Oxirgi marta N-bo'lim
//     M-qismni ko'rdingiz" va sana. Ustiga bosilsa — shu animening
//     ko'rilgan qismlari;
//   * QISM BO'YICHA — hamma animening hamma ko'rilgan qismlari.
//
// Ikkalasida ham eng oxirgi ko'rilgani ENG TEPADA turadi.
//
// ── QO'L BILAN SURIB O'TILADI ─────────────────────────────────
//
// TALAB (foydalanuvchi): "Anime bo'yicha oynasini chapga sursa
// o'ng tarafdan qism bo'yicha oynasi surilib kelishi kerak, ya'ni
// ikkitasi bitta joyda ishlaydi".
//
// Shu sabab `PageView`: tugmalar ham o'sha sahifani suzdiradi,
// barmoq bilan ham suriladi. Ilgari ikkovi `bool` bilan darhol
// almashardi va o'sha paytda BUTUN ro'yxat bir yo'la qurilib,
// har bir qator kadr yasashni so'rardi — aynan shundan qotish
// bo'lardi. Endi kadrlar ko'rish paytida diskda tayyor bo'ladi
// (`WatchHistory._prepareThumb`), ro'yxat esa faqat ko'rinadigan
// qatorlarni quradi.
//
// Qism qatori — foydalanuvchi TO'XTAGAN JOYDAGI kadr (16:9), uning
// pastida progress chizig'i, chizig'ning USTIDA esa yozuvlar:
// chapda bo'lim nomi / qism / sana, o'ngda foiz va vaqt.
// Kadr ustiga soya yoki qorayish TUSHMAYDI (foydalanuvchi talabi) —
// yozuvlar faqat O'Z ATROFIDAGI qora soya bilan ajratiladi, shu
// sabab rasm tiniq ko'rinadi va yozuv ham o'qiladi.

import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/image_cache.dart';

import '../services/download_manager.dart';
import '../services/format.dart';
import '../services/downloads_index.dart';
import '../services/offline_library.dart';
import '../services/watch_history.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'video_player_screen.dart';

// ── UMUMIY YORDAMCHILAR ───────────────────────────────────────

/// `12:34` — joriy nuqta / umumiy davomiylik.
///
/// TALAB (foydalanuvchi): vaqt FAQAT daqiqa va soniyada
/// ko'rsatilsin — 2 soatlik video `120:00` bo'ladi. Soat
/// ajratilmaydi, daqiqa 60 dan oshaveradi. Pleyerdagi vaqt bilan
/// bir xil qoida (`video_player_screen.dart` -> `_fmt`).
String _clock(int ms) {
  final total = ms ~/ 1000;
  final m = total ~/ 60;
  final s = total % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// `12:46/01/01/2026` — soat/kun/oy/yil (foydalanuvchi ko'rsatgan
/// tartib).
String _date(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}/'
      '${two(d.day)}/${two(d.month)}/${d.year}';
}

/// `43,21%` — vergul bilan (foydalanuvchi ko'rsatgan ko'rinish).
String _percent(double value) {
  final v = value.isNaN ? 0.0 : value.clamp(0, 100).toDouble();
  return '${v.toStringAsFixed(2).replaceAll('.', ',')}%';
}

/// Tarixdagi yozuvdan pleyer uchun "bo'lim" ma'lumoti.
Map<String, dynamic> _seasonOf(HistoryItem item) => {
      'anime_id': item.animeId,
      'season_id': item.seasonId,
      'bolim_id': item.bolimId,
      'nomi': item.seasonName,
      'anime_name': item.animeName,
      'photo_url': item.seasonPhoto.isNotEmpty
          ? item.seasonPhoto
          : item.animePhoto,
    };

/// Qismni AYNAN to'xtagan joyidan ochadi (foydalanuvchi talabi:
/// "kadrning qayeriga bossam ham o'sha vaqtda ko'rilgan joyidan
/// boshlanishi kerak").
void _openEpisode(BuildContext context, HistoryItem item) {
  Navigator.of(context).push(
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, anim, __) => VideoPlayerScreen(
        season: _seasonOf(item),
        // Qism RAQAMI emas, o'zgarmas IDsi: admin raqamni
        // o'zgartirsa ham aynan shu qism ochiladi.
        startEpizodId: item.epizodId,
        startAt: Duration(milliseconds: item.positionMs),
      ),
      transitionsBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: child,
      ),
    ),
  );
}

/// "Rostdan ham bu tarixni o'chirib tashlaysizmi?"
Future<void> _confirmRemove(BuildContext context, HistoryItem item) async {
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
            const Icon(Icons.delete_outline_rounded,
                size: 42, color: Colors.white70),
            const SizedBox(height: 12),
            Text(
              'Rostdan ham bu tarixni o\'chirib tashlaysizmi?',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white, fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 6),
            Text(
              '${item.title} · ${item.bolimNumber}-bo\'lim '
              '${item.epizodNumber}-qism',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 12.5),
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
                    child: const Text('Ha, o\'chirilsin'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (ok == true) {
    await WatchHistory.instance.remove(item);
  }
}

// ══════════════════════════════════════════════════════════════
//  TARIX OYNASI
// ══════════════════════════════════════════════════════════════

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  // ── BU YERDA `initState` DA YUKLASH YO'Q ──────────────────
  //
  // Kutubxona sahifasi ilova ochilganda BIRGA quriladi
  // (`RootScreen` dagi `IndexedStack`), ya'ni bu yerda yuklasak
  // foydalanuvchi kutubxonani ochmasa ham serverga so'rov ketardi.
  //
  // Shu sabab yuklash `RootScreen` da — aynan Kutubxona tugmasi
  // bosilganda — boshlanadi. Ro'yxat 60 soniya "yangi" hisoblanadi,
  // ya'ni oynalar orasida yurganda qayta so'ralmaydi.

  final PageController _pages = PageController();

  /// 0 — anime bo'yicha, 1 — qism bo'yicha.
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    if (i == _page) return;
    // Sahifa SUZIB keladi — tugma bosilganda ham, barmoq bilan
    // surilganda ham bir xil harakat.
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Switcher(page: _page, onChanged: _goTo),
        Expanded(
          // ── SURISH SILLIQ, KADRLAR ESA DARHOL ───────────────
          //
          // Bu yerda ilgari "surish paytida kadr yuklanmasin"
          // degan qulf bor edi. U qotishni oldini oldi, lekin
          // rasmlar kechikib chiqadigan bo'ldi (foydalanuvchi:
          // "juda sekin yangilanyapti").
          //
          // Endi qulf YO'Q: kadrlar ro'yxat o'qilishi bilan
          // fon'da xotiraga ko'chiriladi
          // (`WatchHistory._warmThumbs`), ya'ni surish paytida
          // bajariladigan ish umuman qolmaydi — ham silliq, ham
          // darhol.
          child: PageView(
            controller: _pages,
            physics: const BouncingScrollPhysics(),
            // Qo'shni oyna OLDINDAN quriladi — surish paytida
            // qurish ishi qolmaydi.
            allowImplicitScrolling: true,
            onPageChanged: (i) => setState(() => _page = i),
            children: const [
              _HistoryList(byAnime: true),
              _HistoryList(byAnime: false),
              // TALAB (foydalanuvchi): "Kutubxona sahifasidagi
              // yuklanmalar oynasini olib tashlab, tarix oynasiga
              // qism bo'yicha oynasining o'ng tarafiga qo'sh".
              DownloadsList(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Bitta ro'yxat (anime bo'yicha yoki qism bo'yicha).
///
/// `AutomaticKeepAliveClientMixin` — surish paytida sahifa QAYTA
/// QURILMAYDI. Busiz kuchsiz telefonda barmoq bilan surganda
/// ro'yxat har kadrda qaytadan yig'ilardi va aynan shu qotishga
/// olib kelardi.
class _HistoryList extends StatefulWidget {
  final bool byAnime;
  const _HistoryList({required this.byAnime});

  @override
  State<_HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<_HistoryList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // ══════════════════════════════════════════════════════════
  //  OFLAYNDA — FAQAT YUKLAB OLINGAN QISMLAR
  // ══════════════════════════════════════════════════════════
  //
  // TALAB (foydalanuvchi): "oflayn vaqtda tomosha tarixi va
  // saqlangan animelardan faqatgina yuklab olingan epizodi
  // borlari ko'rinsin, qolganlari esa yashirilsin LEKIN
  // XOTIRADA TURSIN".
  //
  // Ya'ni yozuvlar o'chirilmaydi — internet yoqilishi bilan
  // hammasi qaytadi. Bu yerda faqat ro'yxat filtrlanadi.
  //
  // "Anime bo'yicha" oynasida tekshiruv BO'LIM darajasida:
  // animening kamida bitta qismi yuklangan bo'lsa karta
  // ko'rinadi, ichiga kirilganda esa yana qism darajasida
  // filtrlanadi.
  List<HistoryItem> _visible(List<HistoryItem> rows, bool byAnime) {
    final lib = OfflineLibrary.instance;
    // Indeks hali yig'ilmagan bo'lsa hech narsa yashirilmaydi —
    // aks holda ro'yxat bir lahzaga bo'm-bo'sh ko'rinardi.
    if (!lib.isOffline || !lib.ready) return rows;
    return rows
        .where((e) => byAnime
            ? lib.hasSeason(e.animeId, e.seasonId)
            : lib.hasEpisode(e.animeId, e.seasonId, e.epizodId))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final byAnime = widget.byAnime;
    return AnimatedBuilder(
      animation:
          Listenable.merge([WatchHistory.instance, OfflineLibrary.instance]),
      builder: (context, _) {
        final h = WatchHistory.instance;
        final rows = _visible(byAnime ? h.byAnime : h.items, byAnime);

        // ── YANGILASH DOIRASI QOTIB QOLMASIN ────────────────
        //
        // TOPILGAN XATO (foydalanuvchi rasmi): kadr ustida yarim
        // chizilgan doira qotib qolardi. Bu `RefreshIndicator`
        // edi: ro'yxat `BouncingScrollPhysics` bilan cho'zilganda
        // (va ayniqsa barmoq yonga — qo'shni oynaga — og'ib
        // ketganda) u tortish tugaganini bilmay, doirani ekranda
        // qoldirardi. Endi ro'yxat Android'ning odatdagi
        // (`Clamping`) harakatida — doira tortish bilan to'g'ri
        // yopiladi. Yangilash ham 25 soniyadan oshmaydi: tarmoq
        // osilib qolsa ham doira abadiy aylanmaydi.
        return RefreshIndicator(
          color: AppColors.accent,
          backgroundColor: AppColors.card,
          onRefresh: () => h
              .load(force: true)
              .timeout(const Duration(seconds: 25), onTimeout: () {}),
          child: rows.isEmpty
              ? _EmptyState(loading: h.isLoading)
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(
                      parent: ClampingScrollPhysics()),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final item = rows[i];
                    return RepaintBoundary(
                      child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: byAnime
                          ? AnimeRow(
                              item: item,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => AnimeHistoryScreen(
                                    animeId: item.animeId,
                                    title: item.title,
                                  ),
                                ),
                              ),
                            )
                          : EpisodeRow(item: item),
                    ),
                    );
                  },
                ),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  YUKLANMALAR
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "Kutubxona sahifasidagi yuklanmalar
// oynasini olib tashlab, tarix oynasiga qism bo'yicha oynasining
// o'ng tarafiga qo'sh.
//
// Ro'yxat oxirgi marta yuklab olingan bo'lak vaqtiga qarab
// chiqadi; ko'rinishi huddi qism bo'yicha oynasidagidek —
// to'xtab qolgan joydagi kadr, kadr ustida progress chizig'i va
// vaqti. O'ng tarafda esa faqat anime nomi, nechanchi bo'lim va
// qismligi, va 0.00% necha foiz yuklangani; o'ng taraf yuqori
// qismida tozalash tugmasi.
//
// Yuklanmalar oynasida video onlayn va oflayn vaqtda ham, to'liq
// yuklansa ham, ozgina yuklansa ham ko'rsatiladi. Faqat to'liq
// yuklanmagan kadr ustiga bossa animeni ko'rish uchun to'liq
// yuklab olishini so'raydi."

class DownloadsList extends StatefulWidget {
  const DownloadsList({super.key});

  @override
  State<DownloadsList> createState() => _DownloadsListState();
}

class _DownloadsListState extends State<DownloadsList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Ro'yxat diskdan yig'iladi — tarmoq kerak emas, ya'ni oflayn
    // ham darhol chiqadi.
    unawaited(DownloadsIndex.instance.refresh());
    // ── REAL VAQTDA YANGILANISH ────────────────────────────
    //
    // TALAB (foydalanuvchi): "yuklab olish foizi real vaqtda o'zi
    // yangilansin — qo'lda tortib yangilash kerak bo'lyapti".
    //
    // Har soniyada FAQAT raqamlar yangilanadi (`refreshStats` —
    // bitta xotira o'qishi). To'liq skanerlash (`refresh`) esa
    // 10 soniyada bir marta: yangi qism qo'shilgani ham
    // ko'rinsin, lekin disk bekorga tinmasin.
    var n = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      DownloadsIndex.instance.refreshStats();
      if (++n % 10 == 0) unawaited(DownloadsIndex.instance.refresh());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    DownloadManager.instance.unwatch(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      // Kadrlar tomosha tarixidan keladi — o'sha yerdagi
      // yangilanish shu ro'yxatda ham DARHOL ko'rinishi kerak
      // (foydalanuvchi: "kadr tarix oynasidagidek tez
      // yangilanmayapti"). Ilgari faqat `DownloadsIndex`
      // eshitilardi, shu sabab kadr eskirib turardi.
      // `DownloadManager` ham tinglanadi: progress chizig'i va
      // tezlik AYNAN o'sha yerdan keladi va yuklash ketayotganda
      // u har 0.5 soniyada yangilanadi — ya'ni chiziq soniyalik
      // taymerni kutib turmaydi.
      animation: Listenable.merge([
        DownloadsIndex.instance,
        WatchHistory.instance,
        DownloadManager.instance,
      ]),
      builder: (context, _) {
        final idx = DownloadsIndex.instance;
        final rows = idx.items;
        // Ro'yxatdagi hamma sifat kuzatuvga qo'yiladi — tezlik va
        // chiziq uchun holat kerak.
        DownloadManager.instance.watch(this, {
          for (final r in rows) ...r.allUrls,
        });
        return RefreshIndicator(
          color: AppColors.accent,
          backgroundColor: AppColors.card,
          onRefresh: () => idx
              .refresh()
              .timeout(const Duration(seconds: 25), onTimeout: () {}),
          child: rows.isEmpty
              ? _EmptyDownloads(loading: !idx.ready)
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(
                      parent: ClampingScrollPhysics()),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                  itemCount: rows.length,
                  itemBuilder: (context, i) => RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _DownloadRow(item: rows[i]),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _DownloadRow extends StatelessWidget {
  final DownloadItem item;
  const _DownloadRow({required this.item});

  /// Shu qismning tomosha tarixidagi yozuvi (kadr va to'xtagan
  /// joy shundan olinadi). Ko'rilmagan bo'lsa `null`.
  HistoryItem? get _watched => WatchHistory.instance
      .findEpisode(item.animeId, item.seasonId, item.epizodId);

  Future<void> _open(BuildContext context) async {
    final h = _watched;
    if (!item.complete) {
      await _askFullDownload(context);
      return;
    }
    if (h != null) {
      if (!context.mounted) return;
      _openEpisode(context, h);
      return;
    }
    // Hech qachon ko'rilmagan — qism boshidan ochiladi.
    if (!context.mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, anim, __) => VideoPlayerScreen(
          season: {
            'anime_id': item.animeId,
            'season_id': item.seasonId,
            'bolim_id': item.bolimId,
            'nomi': item.title,
            'photo_url': item.poster,
          },
          startEpizodId: item.epizodId,
        ),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          child: child,
        ),
      ),
    );
  }

  /// To'liq yuklanmagan qism — avval yuklab olish so'raladi.
  Future<void> _askFullDownload(BuildContext context) async {
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
              const Icon(Icons.download_rounded,
                  size: 42, color: Colors.white70),
              const SizedBox(height: 12),
              const Text(
                'Bu qism to\'liq yuklab olinmagan',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 6),
              Text(
                'Ko\'rish uchun avval to\'liq yuklab olinsinmi?\n'
                'Hozir ${_percent(item.ratio * 100)} yuklangan.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12.5,
                    height: 1.4),
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
                      child: const Text('Yuklab olish'),
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
    DownloadManager.instance.download(item.url);
    // Foiz o'sib borishi ko'rinsin.
    unawaited(DownloadsIndex.instance.refresh());
  }

  /// Tozalash oynasi — har bir sifat alohida yoki hammasi birdan.
  ///
  /// TALAB (foydalanuvchi): "Tozalash tugmasini bosganda har bitta
  /// sifatni alohida tozalaydigan va hammasini bittada
  /// tozalaydigan qilib yasab ber".
  Future<void> _confirmDelete(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      constraints: const BoxConstraints(),
      builder: (_) => _ClearSheet(item: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = _watched;
    return GestureDetector(
      onTap: () => _open(context),
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── CHAP: KADR (tarix oynasidagidek) ────────────────
          Expanded(
            flex: 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (h != null)
                      _Frame(item: h)
                    else if (item.poster.isNotEmpty)
                      CachedNetworkImage(
                        cacheManager: AppImageCache.manager,
                        imageUrl: item.poster,
                        fit: BoxFit.cover,
                        // Qator 16:9 va ekran kengligining yarmi —
                        // 540 px yetib ortadi.
                        memCacheWidth: 540,
                        placeholder: (_, __) =>
                            Container(color: AppColors.cardAlt),
                        errorWidget: (_, __, ___) =>
                            Container(color: AppColors.cardAlt),
                      )
                    else
                      Container(color: AppColors.cardAlt),

                    // To'xtagan joyning vaqti — kadr ustida.
                    if (h != null)
                      Positioned(
                        left: 6,
                        right: 6,
                        bottom: 7,
                        child: _ShadowText(
                          '${_clock(h.positionMs)}/${_clock(h.durationMs)}',
                          size: 10,
                          weight: FontWeight.w600,
                          align: TextAlign.right,
                        ),
                      ),

                    // Tomosha progressi (tarixdagi bilan bir xil).
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SizedBox(
                        height: 3.5,
                        child: Stack(
                          children: [
                            Container(color: Colors.white24),
                            FractionallySizedBox(
                              widthFactor: h?.progress ?? 0,
                              alignment: Alignment.centerLeft,
                              child: Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      AppColors.accent,
                                      AppColors.accent2
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // ── O'NG: NOM, QISM, SIFAT, HAJM, FOIZ ──────────────
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.title.isEmpty ? 'Anime' : item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ),
                    // ── IKKI TUGMA: YUKLAB OLISH VA TOZALASH ──
                    //
                    // TALAB (foydalanuvchi): "tozalash tugmasini
                    // biroz kattalashtir va bosganda aniq
                    // ishlaydigan qil" hamda "kadr yoniga yuklab
                    // olish ikonini qo'y — bosganda mavjud
                    // sifatlar, hajmlari va har birining
                    // to'g'risida yuklab olish tugmasi chiqsin".
                    //
                    // Ikkovi ham 40x40 nuqta bosish maydoniga ega
                    // (Android tavsiyasi 48, ro'yxat zich bo'lgani
                    // uchun 40) — ilgari ikonka 17 nuqta edi va
                    // barmoq ko'pincha tegmasdan qolardi.
                    _RowIconButton(
                      icon: Icons.download_rounded,
                      onTap: () => _openQualities(context),
                    ),
                    _RowIconButton(
                      icon: Icons.cleaning_services_rounded,
                      onTap: () => _confirmDelete(context),
                    ),
                  ],
                ),
                Text(
                  '${item.bolimNumber}-bo\'lim ${item.epizodNumber}-qism',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(height: 5),
                // Sifat va hajm — foydalanuvchi talabi: "qanaqa
                // sifatda, qancha MB va qancha foiz yuklab
                // olgani yozilib turilsin".
                Row(
                  children: [
                    if (item.quality.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(
                          item.quality,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        item.total > 0
                            ? '${formatBytes(item.downloaded)} / '
                                '${formatBytes(item.total)}'
                            : formatBytes(item.downloaded),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // ── PROGRESS CHIZIG'I ─────────────────────────
                //
                // TALAB (foydalanuvchi): "foizni admin panelidagi
                // video yuklashdagidek real vaqt rejimida aniq va
                // progress chizig'i bilan ko'rsatsin".
                //
                // Tugagan qismda chiziq ko'rsatilmaydi — u yerda
                // yashil foiz o'zi yetarli.
                if (!item.complete) ...[
                  _ProgressBar(
                    value: item.total > 0 ? item.ratio : null,
                    color: AppColors.accent,
                  ),
                  const SizedBox(height: 5),
                ],
                Row(
                  children: [
                    Text(
                      _percent(item.ratio * 100),
                      style: TextStyle(
                        color: item.complete
                            ? AppColors.success
                            : AppColors.accent,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    if (!item.complete) ...[
                      Builder(builder: (context) {
                        final st = DownloadManager.instance.statOf(item.url);
                        final label = st.queued
                            ? 'navbatda'
                            : st.retrying
                                ? 'qayta ulanmoqda...'
                                : st.speedLabel;
                        if (label.isEmpty) return const SizedBox.shrink();
                        return Text(
                          label,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 10.5,
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Sifatlar oynasi — har bir sifat, hajmi va "Yuklab olish".
  Future<void> _openQualities(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      // `isScrollControlled` — oyna ekranning 85 foizigacha
      // cho'zila olsin; balandlik va surish `_SheetShell` da
      // (o'sha yerdagi "80 foizi chiqdi" izohiga qarang).
      isScrollControlled: true,
      // Standart chegara oynani ekranning 9/16 qismiga siqadi —
      // aynan shu tarkibni kesardi.
      constraints: const BoxConstraints(),
      builder: (_) => _QualitySheet(item: item),
    );
  }
}

/// Ro'yxat qatoridagi ikonka tugmasi — BOSISH MAYDONI KENG.
class _RowIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _RowIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // `opaque` — ikonka atrofidagi bo'sh joy ham tapni oladi.
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(icon, size: 20, color: Colors.white70),
      ),
    );
  }
}

/// ── SIFATLAR OYNASI ─────────────────────────────────────────
///
/// TALAB (foydalanuvchi): "mavjud sifatlar va hajmlari va har
/// bittasining to'g'risida yuklab olish degan tugma chiqsin".
///
/// Hajm ikki manbadan olinadi: yuklab olingan sifat uchun
/// DISKDAGI hisobdan (tarmoq kerak emas), qolganlari uchun bir
/// baytlik `Range` so'rovidan (javobdagi `Content-Range` da to'liq
/// hajm bor). Ya'ni oyna ochilganda eng ko'pi bir necha kichik
/// so'rov ketadi.
class _QualitySheet extends StatefulWidget {
  final DownloadItem item;
  const _QualitySheet({required this.item});

  @override
  State<_QualitySheet> createState() => _QualitySheetState();
}

class _QualitySheetState extends State<_QualitySheet> {
  /// manzil -> hajm (bayt). Yo'q bo'lsa hali o'lchanmagan.
  final Map<String, int> _sizes = {};

  /// Foydalanuvchi endigina bosgan, lekin yadro hali xabar
  /// bermagan sifatlar. Tugma SHU ZAHOTI o'zgarishi uchun.
  final Set<String> _justStarted = {};

  @override
  void initState() {
    super.initState();
    _measure();
    // ── FOIZ REAL VAQTDA YANGILANADI ────────────────────────
    //
    // TOPILGAN XATO (foydalanuvchi: "har bitta sifat yonidagi
    // yuklab olish tugmasini bosganda sekin ishlayapti va foiz
    // real vaqtda yangilanmayapti").
    //
    // SABAB: bu oyna `DownloadsIndex` ni tinglardi, foizni esa
    // `DownloadManager` dan o'qirdi. Ya'ni tugma bosilganda
    // `DownloadManager.notifyListeners()` bu oynaga UMUMAN
    // yetib kelmasdi — ekran faqat sekundlik taymer
    // `DownloadsIndex` ni qo'zg'atgandagina yangilanardi. Shundan
    // "sekin ishlayapti" degan tuyg'u chiqqan.
    //
    // Ustiga oyna hech qachon `watch()` chaqirmasdi, ya'ni
    // yadrodan bu manzillarning holati so'ralmasligi ham mumkin
    // edi.
    //
    // Endi ikkovi ham to'g'ri: oyna `DownloadManager` ni
    // BEVOSITA tinglaydi va shu manzillarni kuzatuvga qo'yadi —
    // yuklash ketayotganda holat har 0.5 soniyada yangilanadi.
    DownloadManager.instance.watch(this, widget.item.allUrls.toSet());
  }

  @override
  void dispose() {
    DownloadManager.instance.unwatch(this);
    super.dispose();
  }

  Future<void> _measure() async {
    for (final url in widget.item.allUrls) {
      final n = await DownloadsIndex.instance.sizeOf(url);
      if (!mounted) return;
      if (n > 0) setState(() => _sizes[url] = n);
    }
  }

  @override
  Widget build(BuildContext context) {
    final urls = _sortedQualities(widget.item);
    return _SheetShell(
      title: widget.item.title.isEmpty ? 'Anime' : widget.item.title,
      subtitle: '${widget.item.bolimNumber}-bo\'lim '
          '${widget.item.epizodNumber}-qism',
      child: AnimatedBuilder(
        // IKKALA manba ham tinglanadi (yuqoridagi izohga qarang).
        animation: Listenable.merge(
            [DownloadsIndex.instance, DownloadManager.instance]),
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final url in urls) ...[
              _QualityRow(
                url: url,
                size: _sizes[url] ?? 0,
                starting: _justStarted.contains(url),
                onDownload: () => _start(url),
                onPause: () => _pause(url),
              ),
              if (url != urls.last) const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  void _start(String url) {
    // Tugma DARHOL o'zgaradi — yadrodan javob kutilmaydi.
    setState(() => _justStarted.add(url));
    DownloadManager.instance.download(url);
    DownloadsIndex.instance.refreshStats();
    unawaited(DownloadsIndex.instance.refresh());
  }

  /// Yuklashni pauza qiladi (foydalanuvchi talabi).
  ///
  /// Olingan bo'laklar diskda QOLADI — "Davom ettirish" xuddi shu
  /// joydan davom etadi, hech narsa qaytadan yuklanmaydi.
  ///
  /// `_justStarted` dan ham chiqariladi: aks holda tugma
  /// "endigina bosilgan" deb hisoblanib "To'xtatish" holicha
  /// qolib ketardi.
  void _pause(String url) {
    setState(() => _justStarted.remove(url));
    DownloadManager.instance.pause(url);
    DownloadsIndex.instance.refreshStats();
    unawaited(DownloadsIndex.instance.refresh());
  }
}

/// Sifatlarni yuqori sifatdan pastga qarab tartiblaydi.
List<String> _sortedQualities(DownloadItem item) {
  int px(String u) => int.tryParse(qualityOf(u).replaceAll('p', '')) ?? 0;
  return [...item.allUrls]..sort((a, b) => px(b).compareTo(px(a)));
}

/// ── PASTDAN CHIQADIGAN OYNANING UMUMIY QOBIG'I ──────────────
///
/// TOPILGAN XATO (foydalanuvchi: "pastdan chiqadigan oyna to'liq
/// chiqmay qoldi, 80 foizi chiqdi").
///
/// Oyna tarkibi `Column(mainAxisSize: min)` edi va hech qanday
/// balandlik chegarasi yo'q edi. Tarkib ekranga sig'masa (uzun
/// nom, to'rtta sifat, ustiga tizim paneli chekinishi) pastki
/// qismi shunchaki KESILARDI — ekranda esa oyna "to'liq
/// chiqmagandek" ko'rinardi.
///
/// Endi:
///   * balandlik ekranning 85 foizi bilan CHEGARALANGAN;
///   * tarkib `SingleChildScrollView` ichida — sig'masa suriladi,
///     ya'ni pastki tugmalar HAR DOIM ochib olinadi;
///   * pastdagi chekinish tizim tugmalari balandligidan olinadi,
///     shu sabab oxirgi qator telefon tugmalari ortida qolmaydi.
class _SheetShell extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _SheetShell({
    required this.title,
    required this.subtitle,
    required this.child,
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
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
              const SizedBox(height: 14),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 14),
              // Sig'magan tarkib suriladi — kesilmaydi.
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ── YUKLAB OLISH CHIZIG'I ───────────────────────────────────
///
/// TALAB (foydalanuvchi): "foizni admin panelidagi video
/// yuklashdagidek real vaqt rejimida aniq va progress chizig'i
/// bilan ko'rsatsin".
///
/// Chiziq `LinearProgressIndicator` emas: unda burchaklar to'g'ri
/// va balandlikni boshqarish noqulay. Bu yerda ikkita `Container`
/// — orqa fon va ustidagi o'sib boruvchi qism.
class _ProgressBar extends StatelessWidget {
  /// 0..1 oralig'ida. Umumiy hajm hali noma'lum bo'lsa `null` —
  /// u holda cheksiz (aylanuvchi) ko'rinish beriladi.
  final double? value;
  final Color color;

  const _ProgressBar({required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        child: value == null
            ? LinearProgressIndicator(
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                color: color,
                minHeight: 6,
              )
            : LayoutBuilder(
                builder: (context, c) => Stack(
                  children: [
                    Container(color: Colors.white.withValues(alpha: 0.12)),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      width: c.maxWidth * value!.clamp(0.0, 1.0),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Sifatlar oynasidagi bitta qator.
class _QualityRow extends StatelessWidget {
  final String url;
  final int size;

  /// Tugma endigina bosildi — yadro hali javob bermadi.
  final bool starting;
  final VoidCallback onDownload;

  /// ── TO'XTATISH ──────────────────────────────────────────
  ///
  /// TALAB (foydalanuvchi): "yuklab olish yoki davom etish
  /// tugmasini bosganda to'xtatish degan tugma chiqsin yuklab
  /// olishni pauza qilish uchun".
  ///
  /// Ilgari yuklash ketayotganda tugma "Yuklanmoqda" deb
  /// O'CHIRILARDI — ya'ni boshlangan yuklashni to'xtatishning
  /// hech qanday yo'li yo'q edi. Endi o'sha joyda "To'xtatish"
  /// turadi. Olingan qism joyida qoladi: keyin "Davom ettirish"
  /// xuddi shu joydan davom etadi.
  final VoidCallback onPause;

  const _QualityRow({
    required this.url,
    required this.size,
    required this.starting,
    required this.onDownload,
    required this.onPause,
  });

  @override
  Widget build(BuildContext context) {
    final st = DownloadManager.instance.statOf(url);
    final done = st.total > 0 && st.downloaded >= st.total;
    final started = st.downloaded > 0 || st.downloading || starting;
    final total = st.total > 0 ? st.total : size;
    final busy = !done && (st.downloading || starting);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _QualityChip(url: url),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                // Yuklash ketayotganda "qancha / qancha" ko'rinadi
                // — foydalanuvchi talabi: "qancha MB yuklab
                // olgani yozilib turilsin".
                started && total > 0
                    ? '${formatBytes(st.downloaded)} / ${formatBytes(total)}'
                    : (total > 0
                        ? formatBytes(total)
                        : 'hajmi aniqlanmoqda...'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (done)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.check_circle_rounded,
                    size: 22, color: AppColors.success),
              )
            else
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 38),
                  // To'xtatish — IKKILAMCHI tugma: u qizil
                  // "Yuklab olish" bilan bir xil ko'rinsa,
                  // boshlash va to'xtatish bir-biriga o'xshab
                  // ketardi va xato bosilardi.
                  backgroundColor: busy
                      ? Colors.white.withValues(alpha: 0.14)
                      : AppColors.accent,
                ),
                onPressed: busy ? onPause : onDownload,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy) ...[
                      const Icon(Icons.pause_rounded, size: 15),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      busy
                          ? 'To\'xtatish'
                          : (started ? 'Davom ettirish' : 'Yuklab olish'),
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
          ],
        ),
        // ── CHIZIQ VA ANIQ FOIZ ────────────────────────────────
        if (started && !done) ...[
          const SizedBox(height: 7),
          _ProgressBar(
            // Umumiy hajm hali noma'lum bo'lsa cheksiz ko'rinish:
            // soxta foiz ko'rsatmaymiz.
            value: st.total > 0 ? st.ratio : null,
            color: AppColors.accent,
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                st.total > 0 ? _percent(st.ratio * 100) : 'boshlanmoqda...',
                style: const TextStyle(
                  color: AppColors.accent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (st.queued)
                Text(
                  'navbatda',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                )
              else if (st.retrying)
                Text(
                  'qayta ulanmoqda...',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                )
              else if (st.speedLabel.isNotEmpty)
                Text(
                  st.speedLabel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// "720p" yorlig'i.
class _QualityChip extends StatelessWidget {
  final String url;
  const _QualityChip({required this.url});

  @override
  Widget build(BuildContext context) {
    final q = qualityOf(url);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        q.isEmpty ? '—' : q,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// ── TOZALASH OYNASI ─────────────────────────────────────────
///
/// TALAB (foydalanuvchi): "Tozalash tugmasini bosganda har bitta
/// sifatni alohida tozalaydigan va hammasini bittada tozalaydigan
/// qilib yasab ber".
///
/// Ro'yxatda FAQAT telefonda biror qismi bor sifatlar chiqadi —
/// yuklab olinmagan sifatni "tozalash"ning ma'nosi yo'q.
class _ClearSheet extends StatefulWidget {
  final DownloadItem item;
  const _ClearSheet({required this.item});

  @override
  State<_ClearSheet> createState() => _ClearSheetState();
}

class _ClearSheetState extends State<_ClearSheet> {
  @override
  void initState() {
    super.initState();
    DownloadManager.instance.watch(this, widget.item.allUrls.toSet());
  }

  @override
  void dispose() {
    DownloadManager.instance.unwatch(this);
    super.dispose();
  }

  /// Telefonda biror bayti bor sifatlar.
  List<String> get _present {
    final out = <String>[];
    for (final u in _sortedQualities(widget.item)) {
      if (DownloadManager.instance.statOf(u).downloaded > 0) out.add(u);
    }
    return out;
  }

  Future<void> _ask(String text, Future<void> Function() run) async {
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
              const Icon(Icons.cleaning_services_rounded,
                  size: 42, color: Colors.white70),
              const SizedBox(height: 12),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
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
    await run();
    if (!mounted) return;
    setState(() {});
    // Hech narsa qolmagan bo'lsa oyna o'zi yopiladi.
    if (_present.isEmpty && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      title: widget.item.title.isEmpty ? 'Anime' : widget.item.title,
      subtitle: '${widget.item.bolimNumber}-bo\'lim '
          '${widget.item.epizodNumber}-qism',
      child: AnimatedBuilder(
        animation: Listenable.merge(
            [DownloadsIndex.instance, DownloadManager.instance]),
        builder: (context, _) {
          final present = _present;
          if (present.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                'Bu qismdan telefonda hech narsa qolmadi.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final url in present) ...[
                _ClearRow(
                  url: url,
                  onClear: () => _ask(
                    '${qualityOf(url)} sifati o\'chirilsinmi?',
                    () async {
                      DownloadManager.instance.delete(url);
                      await DownloadsIndex.instance.refresh();
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 6),
              // ── HAMMASINI BITTADA ──────────────────────────
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    minimumSize: const Size(0, 46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  onPressed: () => _ask(
                    'Bu qismning hamma sifatlari o\'chirilsinmi?',
                    () => DownloadsIndex.instance.remove(widget.item),
                  ),
                  icon: const Icon(Icons.delete_sweep_rounded, size: 20),
                  label: const Text(
                    'Hammasini tozalash',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Tozalash oynasidagi bitta sifat qatori.
class _ClearRow extends StatelessWidget {
  final String url;
  final VoidCallback onClear;

  const _ClearRow({required this.url, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final st = DownloadManager.instance.statOf(url);
    return Row(
      children: [
        _QualityChip(url: url),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            st.total > 0
                ? '${formatBytes(st.downloaded)} / ${formatBytes(st.total)}'
                : formatBytes(st.downloaded),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            minimumSize: const Size(0, 38),
            side: BorderSide(color: Colors.red.shade400),
          ),
          onPressed: onClear,
          child: Text(
            'Tozalash',
            style: TextStyle(
              fontSize: 12.5,
              color: Colors.red.shade300,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyDownloads extends StatelessWidget {
  final bool loading;
  const _EmptyDownloads({required this.loading});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics()),
      children: [
        const SizedBox(height: 90),
        Center(
          child: Glass(
            borderRadius: 20,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white70),
                  )
                else
                  const Icon(Icons.download_rounded,
                      size: 46, color: Colors.white54),
                const SizedBox(height: 12),
                Text(
                  loading
                      ? 'Yuklanmoqda...'
                      : 'Hali hech narsa yuklab olinmagan',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Anime bo'yicha / Qism bo'yicha ────────────────────────────

class _Switcher extends StatelessWidget {
  final int page;
  final ValueChanged<int> onChanged;
  const _Switcher({required this.page, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _SwitchButton(
              label: 'Anime bo\'yicha',
              active: page == 0,
              onTap: () => onChanged(0),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _SwitchButton(
              label: 'Qism bo\'yicha',
              active: page == 1,
              onTap: () => onChanged(1),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _SwitchButton(
              label: 'Yuklanmalar',
              active: page == 2,
              onTap: () => onChanged(2),
            ),
          ),
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
            // Uchta tugma tor ekranga ham sig'ishi kerak.
            style: TextStyle(
              color: active ? Colors.white : Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  ANIME QATORI
// ══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): oxirgi marta ko'rilgan epizod RASMI,
// rasm tagida BO'LIM NOMI (anime nomi emas), tagida esa
// "Oxirgi marta 1-bo'lim 1-qismni ko'rdingiz" va sana.

class AnimeRow extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onTap;
  const AnimeRow({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Glass(
        borderRadius: 18,
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _Frame(item: item),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Oxirgi marta ${item.bolimNumber}-bo\'lim '
              '${item.epizodNumber}-qismni ko\'rdingiz',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.68),
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Sana: ${_date(item.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.52),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  QISM QATORI (to'xtagan kadr + progress)
// ══════════════════════════════════════════════════════════════
//
// Yozuvlar PROGRESS CHIZIG'INING USTIDA (foydalanuvchi talabi):
//
//   chapda:  bo'lim nomi
//            N-bo'lim M-qism
//            sana: 12:34/01/01/2026
//   o'ngda:  43,21% | 12:34/56:12
//
// Kadrga bosilsa — o'sha qism AYNAN o'sha joydan ochiladi.
// Uzoq bosilsa — tarixdan o'chirish so'raladi.

class EpisodeRow extends StatelessWidget {
  final HistoryItem item;

  /// BOSHQA odamning ro'yxatimi.
  ///
  /// TALAB (foydalanuvchi): boshqa foydalanuvchining "Qismlar"
  /// statistikasi ham aynan shu ko'rinishda ochiladi. Lekin u
  /// yerda:
  ///   * uzoq bosib O'CHIRIB bo'lmaydi — yozuv begona;
  ///   * kadr (`_Frame`) yasalmaydi — kadrlar FAQAT shu telefonda
  ///     ko'rilgan qismlar uchun bor, begona qism uchun esa ilova
  ///     videoni yuklab kadr yasashga urinardi. Poster yetarli.
  final bool readOnly;

  const EpisodeRow({
    super.key,
    required this.item,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _openEpisode(context, item),
      onLongPress: readOnly ? null : () => _confirmRemove(context, item),
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (readOnly) _Poster(url: item.poster) else _Frame(item: item),

              // ── YOZUVLAR ────────────────────────────────────
              //
              // Progress chizig'ining ustida. Kadr ustiga hech
              // qanday qorayish tushmaydi — o'qilishi yozuvning
              // O'Z soyasi bilan ta'minlanadi.
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Chap tomon — bo'lim nomi, qism, sana.
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ShadowText(
                            item.title,
                            size: 11.5,
                            weight: FontWeight.w700,
                            align: TextAlign.left,
                          ),
                          _ShadowText(
                            '${item.bolimNumber}-bo\'lim '
                            '${item.epizodNumber}-qism',
                            size: 10.5,
                            align: TextAlign.left,
                          ),
                          _ShadowText(
                            'sana: ${_date(item.updatedAt)}',
                            size: 10,
                            alpha: 0.85,
                            align: TextAlign.left,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // O'ng tomon — faqat foiz va vaqt.
                    _ShadowText(
                      '${_percent(item.percent)} | '
                      '${_clock(item.positionMs)}/${_clock(item.durationMs)}',
                      size: 10.5,
                      weight: FontWeight.w600,
                      align: TextAlign.right,
                    ),
                  ],
                ),
              ),

              // ── PROGRESS CHIZIG'I ─────────────────────────────
              //
              // `FractionallySizedBox` ishlatiladi: u ulushni
              // to'g'ridan-to'g'ri oladi va 0 yoki 1 bo'lganda ham
              // to'g'ri ishlaydi (`Expanded(flex: 0)` esa bo'sh
              // `Container`ni butun enga yoyib yuborardi).
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(
                  height: 3.5,
                  child: Stack(
                    children: [
                      Container(color: Colors.white24),
                      FractionallySizedBox(
                        widthFactor: item.progress,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [AppColors.accent, AppColors.accent2],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kadr: tayyor bo'lsa — to'xtagan joydagi kadr, aks holda poster.
class _Frame extends StatefulWidget {
  final HistoryItem item;
  const _Frame({required this.item});

  @override
  State<_Frame> createState() => _FrameState();
}

class _FrameState extends State<_Frame> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    // ── REAL VAQTDA YANGILANISH ──────────────────────────────
    //
    // Kadr tayyor bo'lishi bilan `WatchHistory` xabar beradi va
    // qator o'sha zahoti yangi rasmga o'tadi — boshqa oynaga
    // kirib chiqishni kutish shart emas (foydalanuvchi talabi:
    // "ikkala oynada ham real vaqt rejimida yangilansin").
    WatchHistory.instance.addListener(_onHistoryChanged);
    _load();
  }

  @override
  void dispose() {
    WatchHistory.instance.removeListener(_onHistoryChanged);
    super.dispose();
  }

  void _onHistoryChanged() {
    if (!mounted) return;
    final h = WatchHistory.instance;
    final fresh = h.peekThumb(widget.item.thumbKey);
    // Haqiqiy kadr hali yo'q (yoki faqat vaqtinchasi bor) —
    // yasash davom etsin. Takroriy chaqiruv arzon: ish ketayotgan
    // yoki yaqinda yiqilgan bo'lsa hech narsa qilinmaydi.
    if (!h.hasThumb(widget.item.thumbKey)) h.ensureThumb(widget.item);
    if (fresh == null || identical(fresh, _bytes)) return;
    setState(() => _bytes = fresh);
  }

  @override
  void didUpdateWidget(covariant _Frame old) {
    super.didUpdateWidget(old);
    if (old.item.thumbKey != widget.item.thumbKey) {
      // Eski kadr ekranda qolaveradi (bo'sh joy ko'rinmasin) —
      // yangisi tayyor bo'lishi bilan almashadi.
      _load();
    }
  }

  Future<void> _load() async {
    final key = widget.item.thumbKey;
    final ready = WatchHistory.instance.peekThumb(key);
    if (ready != null) {
      if (mounted && !identical(ready, _bytes)) {
        setState(() => _bytes = ready);
      }
      // Faqat VAQTINCHA (eski nuqtadagi) rasm bo'lsa — haqiqiysini
      // so'rashni to'xtatmaymiz, aks holda eski rasm qotib qolardi.
      if (WatchHistory.instance.hasThumb(key)) return;
    }
    final data = await WatchHistory.instance.thumbnail(widget.item);
    // Kutish davomida qator boshqa qismga o'tgan bo'lishi mumkin.
    if (!mounted || data == null || key != widget.item.thumbKey) return;
    setState(() => _bytes = data);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // Filtrlashni o'chirmaymiz: kadr ekran kengligidan kichik
        // bo'lishi mumkin va silliq cho'zilgani tiniqroq ko'rinadi.
        errorBuilder: (_, __, ___) => _poster(),
      );
    }
    return _poster();
  }

  Widget _poster() => _Poster(url: widget.item.poster);
}

/// Bo'lim posteri — kadr yo'q bo'lgan (yoki kerak bo'lmagan) holat.
class _Poster extends StatelessWidget {
  final String url;
  const _Poster({required this.url});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return Container(color: AppColors.cardAlt);
    return CachedNetworkImage(
      cacheManager: AppImageCache.manager,
      imageUrl: url,
      fit: BoxFit.cover,
      // Tarix qatoridagi poster — kichik. To'liq o'lchamda ochish
      // xotirani bekorga yeydi (`PosterImage` izohiga qarang).
      memCacheWidth: 540,
      placeholder: (_, __) => Container(color: AppColors.cardAlt),
      errorWidget: (_, __, ___) => Container(color: AppColors.cardAlt),
    );
  }
}

/// Kadr ustidagi yozuv — atrofida qora soya bilan.
///
/// Qorayish (scrim) ATAYLAB YO'Q: foydalanuvchi kadr tiniq
/// ko'rinishini va ustiga soya tushmasligini so'ragan. Shu sabab
/// o'qilishi yozuvning O'Z soyasi bilan ta'minlanadi — u atigi bir
/// necha piksel joyni egallaydi va rasmni berkitmaydi.
class _ShadowText extends StatelessWidget {
  final String text;
  final double size;
  final FontWeight weight;
  final double alpha;
  final TextAlign align;

  const _ShadowText(
    this.text, {
    required this.size,
    this.weight = FontWeight.w500,
    this.alpha = 1,
    this.align = TextAlign.right,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: TextStyle(
        color: Colors.white.withValues(alpha: alpha),
        fontSize: size,
        fontWeight: weight,
        height: 1.35,
        shadows: const [
          // To'rt tomonga qisqa soya — harf chetlari yorug'
          // kadrda ham ajralib turadi.
          Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0, 1)),
          Shadow(color: Colors.black87, blurRadius: 2, offset: Offset(1, 0)),
          Shadow(color: Colors.black87, blurRadius: 2, offset: Offset(-1, 0)),
          Shadow(color: Colors.black87, blurRadius: 2, offset: Offset(0, -1)),
        ],
      ),
    );
  }
}

// ── Bitta animening qismlari ──────────────────────────────────

class AnimeHistoryScreen extends StatelessWidget {
  final int animeId;
  final String title;
  const AnimeHistoryScreen(
      {super.key, required this.animeId, required this.title});

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: AnimatedBuilder(
            animation: Listenable.merge(
                [WatchHistory.instance, OfflineLibrary.instance]),
            builder: (context, _) {
              final lib = OfflineLibrary.instance;
              var rows = WatchHistory.instance.episodesOf(animeId);
              // Oflaynda faqat yuklab olingan qismlar (qolganlari
              // yashiriladi, xotirada esa turaveradi).
              if (lib.isOffline && lib.ready) {
                rows = rows
                    .where((e) =>
                        lib.hasEpisode(e.animeId, e.seasonId, e.epizodId))
                    .toList();
              }
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          behavior: HitTestBehavior.opaque,
                          child: const Glass(
                            borderRadius: 14,
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.arrow_back_rounded,
                                color: Colors.white),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            title.isEmpty ? 'Tomosha tarixi' : title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: rows.isEmpty
                        ? const _EmptyState(loading: false)
                        : ListView.builder(
                            physics: const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics()),
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                            itemCount: rows.length,
                            itemBuilder: (context, i) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: EpisodeRow(item: rows[i]),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool loading;
  const _EmptyState({required this.loading});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics()),
      children: [
        const SizedBox(height: 90),
        Center(
          child: Glass(
            borderRadius: 20,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white70),
                  )
                else
                  const Icon(Icons.history_rounded,
                      size: 46, color: Colors.white54),
                const SizedBox(height: 12),
                Text(
                  loading ? 'Yuklanmoqda...' : 'Hali hech narsa ko\'rilmagan',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
