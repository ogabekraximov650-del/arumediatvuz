// lib/screens/history_screen.dart — TOMOSHA TARIXI.
//
// Ikki ko'rinish bor:
//
//   * ANIME BO'YICHA — har bir anime bitta qator: o'ngda rasmi,
//     chapida nomi va "Oxirgi marta N-qismni ko'rdingiz". Ustiga
//     bosilsa — shu animening ko'rilgan qismlari;
//   * QISM BO'YICHA — hamma animening hamma ko'rilgan qismlari.
//
// Ikkalasida ham eng oxirgi ko'rilgani ENG TEPADA turadi.
//
// Qism qatori — foydalanuvchi TO'XTAGAN JOYDAGI kadr (16:9), uning
// pastida progress chizig'i, o'ng tomonda esa kichik yozuvlar.
// Kadr ustiga soya yoki qorayish TUSHMAYDI (foydalanuvchi talabi) —
// yozuvlar faqat O'Z ATROFIDAGI qora soya bilan ajratiladi, shu
// sabab rasm tiniq ko'rinadi va yozuv ham o'qiladi.

import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/watch_history.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  /// `true` — anime bo'yicha, `false` — qism bo'yicha.
  bool _byAnime = true;

  // ── BU YERDA `initState` DA YUKLASH YO'Q ──────────────────
  //
  // Kutubxona sahifasi ilova ochilganda BIRGA quriladi
  // (`RootScreen` dagi `IndexedStack`), ya'ni bu yerda yuklasak
  // foydalanuvchi kutubxonani ochmasa ham serverga so'rov ketardi.
  //
  // Shu sabab yuklash `RootScreen` da — aynan Kutubxona tugmasi
  // bosilganda — boshlanadi. Ro'yxat 60 soniya "yangi" hisoblanadi,
  // ya'ni oynalar orasida yurganda qayta so'ralmaydi.

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: WatchHistory.instance,
      builder: (context, _) {
        final h = WatchHistory.instance;
        final rows = _byAnime ? h.byAnime : h.items;

        return Column(
          children: [
            _Switcher(
              byAnime: _byAnime,
              onChanged: (v) => setState(() => _byAnime = v),
            ),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.accent,
                backgroundColor: AppColors.card,
                onRefresh: () => h.load(force: true),
                child: rows.isEmpty
                    ? _EmptyState(loading: h.isLoading)
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics()),
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final item = rows[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _byAnime
                                ? AnimeRow(
                                    item: item,
                                    onTap: () => _openAnime(context, item),
                                  )
                                : EpisodeRow(item: item),
                          );
                        },
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _openAnime(BuildContext context, HistoryItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimeHistoryScreen(
          animeId: item.animeId,
          title: item.animeName,
        ),
      ),
    );
  }
}

// ── Anime bo'yicha / Qism bo'yicha ────────────────────────────

class _Switcher extends StatelessWidget {
  final bool byAnime;
  final ValueChanged<bool> onChanged;
  const _Switcher({required this.byAnime, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _SwitchButton(
              label: 'Anime bo\'yicha',
              active: byAnime,
              onTap: () => onChanged(true),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _SwitchButton(
              label: 'Qism bo\'yicha',
              active: !byAnime,
              onTap: () => onChanged(false),
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
            style: TextStyle(
              color: active ? Colors.white : Colors.white60,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ── ANIME QATORI ──────────────────────────────────────────────
//
// O'ngda rasm, chapida nomi va oxirgi ko'rilgan qism.

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
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.animeName.isEmpty ? 'Anime' : item.animeName,
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
                    'Oxirgi marta ${item.epizodNumber}-qismni ko\'rdingiz',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.62),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 62,
                height: 78,
                child: item.poster.isEmpty
                    ? Container(color: Colors.white10)
                    : CachedNetworkImage(
                        imageUrl: item.poster,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(color: Colors.white10),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.white10),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── QISM QATORI (to'xtagan kadr + progress) ───────────────────

class EpisodeRow extends StatelessWidget {
  final HistoryItem item;
  const EpisodeRow({super.key, required this.item});

  static String _clock(int ms) {
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  static String _date(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)}/'
        '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Frame(item: item),

            // ── YOZUVLAR ──────────────────────────────────────
            //
            // O'ng tomonda, progress chizig'ining tepasida.
            // Kadrning kichik qismini egallaydi va ustiga hech
            // qanday qorayish tushmaydi — o'qilishi faqat
            // yozuvning O'Z soyasi bilan ta'minlanadi.
            Positioned(
              right: 8,
              left: 8,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ShadowText(
                    item.animeName.isEmpty ? 'Anime' : item.animeName,
                    size: 11.5,
                    weight: FontWeight.w700,
                  ),
                  _ShadowText(
                    '${item.bolimId > 0 ? item.bolimId : item.seasonId}-bo\'lim'
                    '  ${item.epizodNumber}-qism',
                    size: 10.5,
                  ),
                  _ShadowText(
                    'sana: ${_date(item.updatedAt)}',
                    size: 10,
                    alpha: 0.85,
                  ),
                  _ShadowText(
                    '${_clock(item.positionMs)}/${_clock(item.durationMs)}',
                    size: 10.5,
                    weight: FontWeight.w600,
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
    _load();
  }

  @override
  void didUpdateWidget(covariant _Frame old) {
    super.didUpdateWidget(old);
    if (old.item.thumbKey != widget.item.thumbKey) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final data = await WatchHistory.instance.thumbnail(widget.item);
    if (!mounted || data == null) return;
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

  Widget _poster() {
    final url = widget.item.poster;
    if (url.isEmpty) return Container(color: AppColors.cardAlt);
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
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

  const _ShadowText(
    this.text, {
    required this.size,
    this.weight = FontWeight.w500,
    this.alpha = 1,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
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
            animation: WatchHistory.instance,
            builder: (context, _) {
              final rows = WatchHistory.instance.episodesOf(animeId);
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
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
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
