// lib/screens/stat_detail_screen.dart — BITTA STATISTIKANING OYNASI.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB (foydalanuvchi)
// ═══════════════════════════════════════════════════════════════
//
// "Anime statistikasidan tashqari qismlar, sevimlilar, bo'limlar,
// baholangan, kommentariya statistikalari ustiga bossa o'sha
// statistikaga tegishli oyna ochilishi va barchasini ko'ra olishi
// kerak. Anime statistikasini hech kim ko'ra olmaydi.
//
//  1. Kommentariya statistikaga kirsa chap tarafda anime bo'limi
//     posteri va o'ng tarafida yozgan komenti, javoblari va
//     layklari bo'lsin; javoblarni statistika oynasining o'zida
//     ochib ko'rish mumkin bo'lsin.
//  2. Bo'limlarga kirganda bosh sahifadagidek ikki qatordan
//     ko'rilgan bo'limlar chiqsin, faqat karta ustida hech narsa
//     bo'lmasin.
//  3. Sevimlilar statistikasi ham huddi bo'limlardek.
//  4. Baholangan statistikasida kartochka ustida foydalanuvchining
//     bo'limga bergan bahosi ko'rinib tursin.
//  5. Epizodlar statistikasida huddi tomosha tarixidagidek —
//     ustidagi ma'lumotlari va kelib qolgan kadrigacha, barcha
//     ko'rilgan VA tozalab tashlangan epizodlar ko'rinsin."
//
// ── BITTA EKRAN, BESH KO'RINISH ─────────────────────────────
//
// Beshtasiga alohida fayl yozish mumkin edi, lekin ular
// farqlanadigan joyi faqat BITTA QATOR qanday chizilishi.
// Sarlavha, yuklash, sahifalash, bo'sh ro'yxat, xato — hammasi
// bir xil. Shu sabab bitta ekran va `switch`.

import 'package:flutter/material.dart';

import '../widgets/emoji_text.dart';

import '../services/comments_service.dart';
import '../services/user_stats.dart';
import '../services/watch_history.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import '../widgets/poster_image.dart';
import 'history_screen.dart';
import 'home_screen.dart';

class StatDetailScreen extends StatefulWidget {
  /// Kimning statistikasi. O'ziniki ham, begona ham bo'lishi
  /// mumkin — farqi faqat "o'chirish" amallarida.
  final int userId;
  final StatKind kind;

  /// Sarlavha ostidagi kichik yozuv ("ARUmedia"). Bo'sh bo'lsa
  /// chizilmaydi.
  final String owner;

  /// O'z profilimdanmi.
  final bool isMe;

  const StatDetailScreen({
    super.key,
    required this.userId,
    required this.kind,
    this.owner = '',
    required this.isMe,
  });

  @override
  State<StatDetailScreen> createState() => _StatDetailScreenState();
}

class _StatDetailScreenState extends State<StatDetailScreen> {
  late final UserStatsList _list =
      UserStatsList(userId: widget.userId, kind: widget.kind);
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _list.refresh();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _list.dispose();
    super.dispose();
  }

  /// Ro'yxat oxiriga yaqinlashganda keyingi sahifa so'raladi.
  ///
  /// Chegara ataylab 400 dp: qator chizilishidan OLDIN so'rov
  /// ketsin, aks holda odam bo'sh joyni ko'rib qolardi.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final left = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (left < 400) _list.loadMore();
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
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.kind.label,
                  style: const TextStyle(color: Colors.white, fontSize: 18)),
              if (widget.owner.trim().isNotEmpty)
                Text(
                  widget.owner.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                ),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: _list,
            builder: (context, _) {
              final rows = _list.items;
              if (rows.isEmpty) {
                return _Empty(
                  loading: _list.isLoading,
                  message: _list.error ?? 'Hozircha bo\'sh',
                );
              }
              return RefreshIndicator(
                color: AppColors.accent,
                backgroundColor: AppColors.card,
                onRefresh: _list.refresh,
                child: _body(rows),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _body(List<Map<String, dynamic>> rows) {
    // Oxiriga "yuklanmoqda" aylanasi qo'shiladi.
    final extra = _list.isLoading ? 1 : 0;

    switch (widget.kind) {
      // ── QISMLAR — TOMOSHA TARIXIDAGIDEK ────────────────────
      case StatKind.episodes:
        return ListView.builder(
          controller: _scroll,
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          itemCount: rows.length + extra,
          itemBuilder: (context, i) {
            if (i >= rows.length) return const _Spinner();
            final item = HistoryItem.fromJson(rows[i]);
            // Tarixdan tozalangan qism ham chiqadi (foydalanuvchi
            // talabi) — u bazada `deleted_at` bilan turadi. Belgi
            // qo'yamiz, aks holda ikkovi bir xil ko'rinardi.
            final cleared =
                ((rows[i]['deleted_at'] as num?) ?? 0).toInt() != 0;
            return RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Stack(
                  children: [
                    EpisodeRow(item: item, readOnly: !widget.isMe),
                    if (cleared)
                      const Positioned(
                        top: 8,
                        right: 8,
                        child: _Tag(text: 'Tarixdan tozalangan'),
                      ),
                  ],
                ),
              ),
            );
          },
        );

      // ── IZOHLAR ────────────────────────────────────────────
      case StatKind.comments:
        return ListView.builder(
          controller: _scroll,
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          itemCount: rows.length + extra,
          itemBuilder: (context, i) {
            if (i >= rows.length) return const _Spinner();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _CommentRow(row: rows[i]),
            );
          },
        );

      // ── BO'LIMLAR / SEVIMLILAR / BAHOLANGAN ────────────────
      //
      // Uchalasi ham bosh sahifadagi kartochka, ikki ustunda.
      // Farqi: baholanganda kartochka ustida O'Z bahosi turadi.
      default:
        return GridView.builder(
          controller: _scroll,
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.65,
          ),
          itemCount: rows.length + extra,
          itemBuilder: (context, i) {
            if (i >= rows.length) return const _Spinner();
            final season = rows[i];
            final stars = ((season['my_stars'] as num?) ?? 0).toInt();
            return SeasonCard(
              season: season,
              // Talab: "karta ustida hech narsa bo'lmasin".
              showBadges: false,
              corner: widget.kind == StatKind.rated && stars > 0
                  ? _StarBadge(stars: stars)
                  : null,
              // Bosh sahifadagi bilan BIR XIL yo'l: kartochka
              // bosilsa pleyer ochiladi.
              onTap: () => openSeasonFromAnywhere(context, season),
            );
          },
        );
    }
  }
}

// ══════════════════════════════════════════════════════════════
//  IZOH QATORI
// ══════════════════════════════════════════════════════════════
//
// Chapda bo'lim posteri, o'ngda izoh matni, layk va javoblar
// soni (foydalanuvchi talabi). "Javoblar" tugmasi bosilganda
// javoblar SHU YERDA ochiladi — boshqa oynaga o'tilmaydi.

class _CommentRow extends StatefulWidget {
  final Map<String, dynamic> row;
  const _CommentRow({required this.row});

  @override
  State<_CommentRow> createState() => _CommentRowState();
}

class _CommentRowState extends State<_CommentRow> {
  bool _open = false;
  bool _loading = false;
  List<Comment> _replies = const [];
  String? _error;

  int get _animeId => ((widget.row['anime_id'] as num?) ?? 0).toInt();
  int get _seasonId => ((widget.row['season_id'] as num?) ?? 0).toInt();
  String get _id => '${widget.row['id'] ?? ''}';
  int get _replyCount => ((widget.row['reply_count'] as num?) ?? 0).toInt();

  Future<void> _toggle() async {
    if (_open) {
      setState(() => _open = false);
      return;
    }
    setState(() => _open = true);
    if (_replies.isNotEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    // Javoblar mavjud izohlar yo'li bilan keladi — alohida
    // manzil yasash shart emas.
    final rows = await fetchCommentReplies(
        animeId: _animeId, seasonId: _seasonId, parentId: _id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (rows == null) {
        _error = 'Javoblar kelmadi';
      } else {
        _replies = rows;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final photo = '${widget.row['photo_url'] ?? ''}';
    final season = '${widget.row['season_name'] ?? ''}'.trim();
    final anime = '${widget.row['anime_name'] ?? ''}'.trim();
    final body = '${widget.row['body'] ?? ''}';
    final likes = ((widget.row['likes'] as num?) ?? 0).toInt();
    final at = ((widget.row['created_at'] as num?) ?? 0).toInt();

    return Glass(
      borderRadius: 18,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── CHAP TARAF: BO'LIM POSTERI ───────────────
              GestureDetector(
                onTap: _animeId <= 0
                    ? null
                    : () => openSeasonFromAnywhere(context, {
                          'anime_id': _animeId,
                          'season_id': _seasonId,
                          'nomi': widget.row['season_name'],
                          'photo_url': widget.row['photo_url'],
                        }),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 62,
                    height: 88,
                    child: PosterImage(url: photo),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // ── O'NG TARAF: IZOHNING O'ZI ────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      season.isNotEmpty ? season : (anime.isNotEmpty ? anime : 'Bo\'lim'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    // Emoji alpha tufayli qoramtir bo'lmasin
                    // (`emoji_text.dart` izohiga qarang).
                    EmojiText(
                      body,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.favorite_rounded,
                            size: 14, color: AppColors.accent),
                        const SizedBox(width: 4),
                        Text('$likes',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        const SizedBox(width: 14),
                        if (_replyCount > 0)
                          GestureDetector(
                            onTap: _toggle,
                            behavior: HitTestBehavior.opaque,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _open
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  size: 18,
                                  color: AppColors.accent3,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  '$_replyCount ta javob',
                                  style: TextStyle(
                                      color: AppColors.accent3, fontSize: 12),
                                ),
                              ],
                            ),
                          )
                        else
                          const Text('Javob yo\'q',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 12)),
                        const Spacer(),
                        Text(
                          _shortDate(at),
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          // ── JAVOBLAR SHU YERDA OCHILADI ──────────────────
          if (_open) ...[
            const SizedBox(height: 10),
            Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
            const SizedBox(height: 10),
            if (_loading)
              const _Spinner()
            else if (_error != null)
              Text(_error!,
                  style: const TextStyle(color: Colors.white54, fontSize: 12))
            else
              for (final r in _replies) _ReplyRow(reply: r),
          ],
        ],
      ),
    );
  }
}

class _ReplyRow extends StatelessWidget {
  final Comment reply;
  const _ReplyRow({required this.reply});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox(
              width: 26,
              height: 26,
              child: PosterImage(url: reply.photoUrl),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        reply.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.favorite_rounded,
                        size: 12, color: AppColors.accent),
                    const SizedBox(width: 3),
                    Text('${reply.likes}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 2),
                EmojiText(
                  reply.body,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 12.5,
                    height: 1.3,
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

// ══════════════════════════════════════════════════════════════
//  KICHIK BO'LAKLAR
// ══════════════════════════════════════════════════════════════

/// Kartochka burchagidagi baho ("★ 9").
class _StarBadge extends StatelessWidget {
  final int stars;
  const _StarBadge({required this.stars});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.borderBright),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 13, color: AppColors.gold),
          const SizedBox(width: 3),
          Text('$stars',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white70, fontSize: 10.5)),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.accent),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final bool loading;
  final String message;
  const _Empty({required this.loading, required this.message});

  @override
  Widget build(BuildContext context) {
    if (loading) return const _Spinner();
    return ListView(
      physics:
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      children: [
        const SizedBox(height: 120),
        Center(
          child: Text(message,
              style: const TextStyle(color: Colors.white54, fontSize: 14)),
        ),
      ],
    );
  }
}

/// "12.03.2026" ko'rinishidagi qisqa sana.
String _shortDate(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${two(d.day)}.${two(d.month)}.${d.year}';
}
