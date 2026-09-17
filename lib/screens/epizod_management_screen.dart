import 'package:flutter/material.dart';
import '../services/image_cache.dart';

import '../services/rust_bridge.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_background.dart';
import '../widgets/glass.dart';
import 'add_epizod_screen.dart';

const String _apiBase = 'https://arumediatv.uzcom.workers.dev';

/// Bitta bo'limga tegishli epizodlarni ADMIN boshqarish sahifasi.
/// Faqat admin uchun: qo'shish / tahrirlash / o'chirish.
/// Karta ustiga bosish → tahrirlash oynasi ochiladi.
class EpizodManagementScreen extends StatefulWidget {
  final Map<String, dynamic> anime;
  final Map<String, dynamic> season;
  const EpizodManagementScreen(
      {super.key, required this.anime, required this.season});

  @override
  State<EpizodManagementScreen> createState() => _EpizodManagementScreenState();
}

class _EpizodManagementScreenState extends State<EpizodManagementScreen> {
  List<Map<String, dynamic>> _epizodlar = [];
  bool _isLoading = true;
  String? _errorMsg;

  String get _animeId => widget.anime['id'].toString();
  String get _seasonId => widget.season['season_id'].toString();

  @override
  void initState() {
    super.initState();
    _loadEpizodlar();
  }

  /// Diskdagi kalit — pleyer ishlatadigan kalit BILAN BIR XIL.
  ///
  /// Ya'ni admin qismlarni ochsa pleyer ham tayyor ro'yxatdan
  /// foydalanadi va aksincha — bitta ro'yxat ikki marta
  /// saqlanmaydi.
  String get _diskKey => 'eps_${_animeId}_$_seasonId';

  Future<void> _loadEpizodlar() async {
    // 1) DISK — ekran darhol to'ladi (`disk_cache.dart` izohi).
    if (_epizodlar.isEmpty) {
      final cached = RustCore.instance.getCachedList(_diskKey);
      if (cached != null && cached.isNotEmpty) {
        setState(() => _epizodlar = cached);
      }
    }
    setState(() {
      _isLoading = _epizodlar.isEmpty;
      _errorMsg = null;
    });
    try {
      final res = await http
          .get(Uri.parse('$_apiBase/api/epizods/$_animeId/$_seasonId'));
      // Ekran yopilib ketgan bo'lsa `setState` chaqirish
      // istisno tashlaydi ("setState() called after dispose()") —
      // shu sabab har bir kutishdan keyin tekshiriladi.
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        final rows = data.cast<Map<String, dynamic>>();
        RustCore.instance.saveListCache(_diskKey, rows);
        setState(() => _epizodlar = rows);
      } else {
        throw 'Epizodlar yuklab olib bo\'lmadi';
      }
    } catch (e) {
      if (mounted) setState(() => _errorMsg = 'Xato: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _navigateToAddEpizod({Map<String, dynamic>? epizod}) async {
    final result = await Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, animation, __) => AddEpizodScreen(
          animeId: _animeId,
          seasonId: _seasonId,
          initialEpizod: epizod,
        ),
        transitionsBuilder: (_, animation, __, child) {
          final curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position:
                  Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                      .animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    if (result == true) _loadEpizodlar();
  }

  Future<void> _deleteEpizod(Map<String, dynamic> e) async {
    final label =
        'Ep ${e['epizod_number'] ?? '?'}${(e['epizod_name'] ?? '').isNotEmpty ? ' — ${e['epizod_name']}' : ''}';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.cardAlt,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Epizodni o\'chirish?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '"$label" epizodini rostanxam o\'chirmoqchisiz?\nBarcha fayl linklari ham o\'chadi.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Yo\'q',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Ha, o\'chirish'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final res = await http.delete(Uri.parse(
          '$_apiBase/api/epizods/$_animeId/$_seasonId/${e['epizod_id']}'));
      if (res.statusCode == 200) {
        if (mounted) _loadEpizodlar();
      } else {
        throw 'O\'chirishda xato';
      }
    } catch (ex) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Xato: $ex')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final seasonName = widget.season['nomi'] ?? '';
    final seasonPhoto = widget.season['photo_url'] as String?;
    final bolimId =
        widget.season['bolim_id'] ?? widget.season['season_id'] ?? '?';

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: Padding(
          padding: const EdgeInsets.only(bottom: 80),
          child: FloatingActionButton(
            onPressed: () => _navigateToAddEpizod(),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            backgroundColor: Colors.white.withValues(alpha: 0.18),
            foregroundColor: Colors.white,
            child: const Icon(Icons.add_rounded, size: 28),
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Glass(
                  borderRadius: 20,
                  blur: 16,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(
                    children: [
                      GlassTappable(
                        onTap: () => Navigator.of(context).pop(),
                        child: const Glass(
                          borderRadius: 14,
                          blur: 14,
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.arrow_back_rounded,
                              color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          image: seasonPhoto != null && seasonPhoto.isNotEmpty
                              ? DecorationImage(
                                  // 48 dp -> 144 px.
                                  image: ResizeImage(
                                    appImageProvider(
                              seasonPhoto),
                                    width: 144,
                                    allowUpscaling: false,
                                  ),
                                  fit: BoxFit.cover,
                                  onError: (_, __) {},
                                )
                              : null,
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                        child: seasonPhoto == null || seasonPhoto.isEmpty
                            ? const Icon(Icons.movie_creation_outlined,
                                color: Colors.white54, size: 20)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$bolimId-bo\'lim${seasonName.isNotEmpty ? ' — $seasonName' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                            Text(
                              'Epizodlarni boshqarish',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.5)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation(
                              Colors.white.withValues(alpha: 0.6)),
                        ),
                      )
                    : _errorMsg != null
                        ? Center(
                            child: Text(_errorMsg!,
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7))),
                          )
                        : _epizodlar.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                        Icons.play_circle_outline_rounded,
                                        size: 52,
                                        color: Colors.white24),
                                    const SizedBox(height: 12),
                                    Text('Hali epizod qo\'shilmagan',
                                        style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.45))),
                                    const SizedBox(height: 4),
                                    Text('Pastdagi + tugmasi orqali qo\'sh',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                Colors.white.withValues(alpha: 0.3))),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 4, 16, 120),
                                itemCount: _epizodlar.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (ctx, i) {
                                  final ep = _epizodlar[i];
                                  return _AdminEpizodCard(
                                    epizod: ep,
                                    onTap: () =>
                                        _navigateToAddEpizod(epizod: ep),
                                    onDelete: () => _deleteEpizod(ep),
                                  );
                                },
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminEpizodCard extends StatelessWidget {
  final Map<String, dynamic> epizod;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _AdminEpizodCard(
      {required this.epizod, required this.onTap, required this.onDelete});

  String get _qualities {
    final q = <String>[];
    if ((epizod['url_360p'] ?? '').isNotEmpty) q.add('360p');
    if ((epizod['url_480p'] ?? '').isNotEmpty) q.add('480p');
    if ((epizod['url_720p'] ?? '').isNotEmpty) q.add('720p');
    if ((epizod['url_1080p'] ?? '').isNotEmpty) q.add('1080p');
    return q.isEmpty ? 'Fayl yo\'q' : q.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final num = epizod['epizod_number'] ?? '?';
    final name = epizod['epizod_name'] ?? '';
    return GlassTappable(
      onTap: onTap,
      child: Glass(
        borderRadius: 16,
        blur: 14,
        tint: 0.10,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.25)),
              ),
              child: Center(
                child: Text('$num',
                    style: TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                        fontSize: 15)),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.isNotEmpty ? name : 'Epizod $num',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14),
                  ),
                  const SizedBox(height: 3),
                  Text(_qualities,
                      style: TextStyle(
                          fontSize: 11, color: Colors.white.withValues(alpha: 0.5))),
                ],
              ),
            ),
            const Icon(Icons.edit_rounded, color: Colors.white38, size: 18),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded,
                  color: Colors.redAccent, size: 20),
              splashRadius: 22,
            ),
          ],
        ),
      ),
    );
  }
}
