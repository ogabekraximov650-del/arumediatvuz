// lib/widgets/gif_picker.dart — GIF TANLASH OYNASI.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "boshlanishiga test qilib ko'rish uchun 3 ta
// apidan ham barcha kategoriyalar va reaksiyalarni ula va GIF
// yuborishda qaysi apidan foydalanishni tanlaydigan qilib yasab
// ber — o'zim uchchalasini ham test qilib ko'raman va qaysi biri
// to'g'ri kelsa faqat shuni qilaman".
//
// Shu sabab oyna TEPASIDA uchta xizmat tugmasi turadi. Ular
// vaqtinchalik: bitta xizmat tanlangach, bu qatorni olib tashlash
// va `GifService` dan qolgan ikkovini o'chirish yetarli — boshqa
// hech narsaga tegilmaydi.
//
// ── KO'RINISHI ──────────────────────────────────────────────
//
//   [nekos.best] [otakugifs] [nekosapi]   <- qaysi xizmat
//   hug  kiss  pat  cuddle ...            <- kategoriyalar
//   ┌────┐ ┌────┐                         <- GIF'lar (2 ustun)
//
// ── NEGA IKKI USTUN ─────────────────────────────────────────
//
// GIF'lar turli nisbatda keladi. Uch ustunda ular juda kichik
// bo'lib, nima ekanini ajratib bo'lmaydi; bitta ustunda esa
// oynaga atigi ikkitasi sig'adi.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/gif_service.dart';
import 'glass.dart';

/// Oynani ochadi va tanlangan GIF manzilini qaytaradi
/// (`null` — tanlanmadi).
Future<String?> showGifPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    constraints: const BoxConstraints(),
    builder: (_) => const _GifPicker(),
  );
}

class _GifPicker extends StatefulWidget {
  const _GifPicker();

  @override
  State<_GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<_GifPicker> {
  GifSource _src = GifSource.nekosBest;
  late String _cat = GifService.categoriesOf(_src).first;

  List<GifItem> _items = const [];
  bool _loading = true;

  /// So'rov navbati: tez-tez bosilganda ESKI javob yangisining
  /// ustiga tushib qolmasin.
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = ++_reqId;
    setState(() => _loading = true);
    final rows = await GifService.fetch(_src, _cat);
    if (!mounted || id != _reqId) return;
    setState(() {
      _items = rows;
      _loading = false;
    });
  }

  void _pickSource(GifSource s) {
    if (_src == s) return;
    setState(() {
      _src = s;
      // Har xizmatning kategoriyalari boshqacha — birinchisiga
      // qaytamiz, aks holda mavjud bo'lmagan kategoriya so'ralardi.
      _cat = GifService.categoriesOf(s).first;
      _items = const [];
    });
    _load();
  }

  void _pickCategory(String c) {
    if (_cat == c) return;
    setState(() {
      _cat = c;
      _items = const [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Container(
      height: media.size.height * 0.75,
      decoration: const BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(bottom: media.padding.bottom),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),

          // ── QAYSI XIZMAT (sinov uchun) ─────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                for (final s in GifSource.values) ...[
                  if (s != GifSource.values.first) const SizedBox(width: 8),
                  Expanded(
                    child: _SourceChip(
                      source: s,
                      active: _src == s,
                      onTap: () => _pickSource(s),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),

          // ── KATEGORIYALAR ──────────────────────────────────
          SizedBox(
            height: 36,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: GifService.categoriesOf(_src).length,
              itemBuilder: (context, i) {
                final c = GifService.categoriesOf(_src)[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 7),
                  child: _CatChip(
                    label: GifService.labelOf(c),
                    active: _cat == c,
                    onTap: () => _pickCategory(c),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Divider(
            height: 1,
            color: Colors.white.withValues(alpha: 0.07),
          ),

          Expanded(child: _grid()),
        ],
      ),
    );
  }

  Widget _grid() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.gif_box_outlined,
                  size: 44, color: Colors.white.withValues(alpha: 0.2)),
              const SizedBox(height: 10),
              Text(
                'Topilmadi. Boshqa kategoriya yoki xizmatni '
                'tanlab ko\'ring.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _load,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.18)),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Qaytadan'),
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        // GIF'lar ko'pincha keng (500x260 atrofida) — shu nisbat
        // ularning ko'pchiligiga to'g'ri keladi.
        childAspectRatio: 1.35,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) => _GifTile(
        item: _items[i],
        onTap: () => Navigator.of(context).pop(_items[i].url),
      ),
    );
  }
}

/// Bitta GIF katagi.
class _GifTile extends StatelessWidget {
  final GifItem item;
  final VoidCallback onTap;

  const _GifTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.white.withValues(alpha: 0.05)),
            CachedNetworkImage(
              imageUrl: item.url,
              fit: BoxFit.cover,
              // Yuklanayotganda bo'sh katak emas — aylanma.
              placeholder: (_, __) => const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white24),
                ),
              ),
              errorWidget: (_, __, ___) => Center(
                child: Icon(Icons.broken_image_outlined,
                    size: 22, color: Colors.white.withValues(alpha: 0.25)),
              ),
            ),
            // Anime nomi (faqat nekos.best beradi).
            if (item.animeName.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(7, 10, 7, 5),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.65),
                      ],
                    ),
                  ),
                  child: Text(
                    item.animeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Xizmat tanlash tugmasi (sinov uchun).
class _SourceChip extends StatelessWidget {
  final GifSource source;
  final bool active;
  final VoidCallback onTap;

  const _SourceChip({
    required this.source,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              source.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.7),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              source.hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active
                    ? Colors.white.withValues(alpha: 0.8)
                    : Colors.white.withValues(alpha: 0.38),
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kategoriya tugmasi.
class _CatChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _CatChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.white.withValues(alpha: 0.65),
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
