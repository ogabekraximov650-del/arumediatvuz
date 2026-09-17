// lib/screens/public_profile_screen.dart — BOSHQA ODAMNING PROFILI.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "izoh yozgan odamning profiliga bosib profilni
// ko'rsa bo'ladigan qil — FAQAT profil nomi, username, rasm va
// statistikasi" va keyin "chatdagi profil rasmi ustiga bosganda
// profil to'liq ko'rinsin".
//
// ── IKKI XIL KO'RINISH ──────────────────────────────────────
//
// ODDIY FOYDALANUVCHI (izohdan kiradi) faqat ism, username,
// rasm va uchta statistikani ko'radi.
//
// ADMIN (yozishmadan kiradi) qo'shimcha ravishda ID, Telegram
// raqami, balans, obuna holati va kirish sanalarini ham ko'radi
// — qo'llab-quvvatlash ishi uchun.
//
// FARQNI SERVER HAL QILADI, ilova emas. Oddiy foydalanuvchining
// javobida bu maydonlar UMUMAN yo'q (`public_profile` izohiga
// qarang), ya'ni ilovani o'zgartirish bilan ularni ko'rib
// bo'lmaydi.

import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/auth_service.dart';
import '../services/image_cache.dart';
import '../services/user_stats.dart';
import 'stat_detail_screen.dart';
import '../services/billing_service.dart' show formatSum;
import '../services/disk_cache.dart';
import '../services/format.dart';
import '../theme/app_background.dart';
import '../widgets/glass.dart';

class PublicProfileScreen extends StatefulWidget {
  final int userId;
  const PublicProfileScreen({super.key, required this.userId});

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  /// Diskdagi kalit.
  String get _diskKey => 'profile_${widget.userId}';

  @override
  void initState() {
    super.initState();
    // 1) DISK — ekran darhol to'ladi, tarmoq kutilmaydi
    //    (`disk_cache.dart` izohiga qarang).
    final cached = DiskCache.readOne(_diskKey);
    if (cached != null) {
      _data = cached;
      _loading = false;
    }
    _load();
  }

  Future<void> _load() async {
    try {
      // Sessiya yuboriladi: admin bo'lsa server qo'shimcha
      // maydonlarni ham qaytaradi (`public_profile` izohiga
      // qarang). Oddiy foydalanuvchi uchun javob o'zgarmaydi.
      final t = AuthService.instance.sessionToken;
      final r = await http
          .get(
            Uri.parse('$kApiBase/api/user/${widget.userId}'),
            headers: {if (t != null) 'Authorization': 'Bearer $t'},
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        DiskCache.writeOne(_diskKey, j);
        setState(() {
          _data = j;
          _loading = false;
        });
      } else {
        setState(() {
          // Diskdagi nusxa bor bo'lsa u joyida qoladi — xato
          // faqat hech narsa bo'lmaganda ko'rsatiladi.
          if (_data == null) _error = 'Foydalanuvchi topilmadi';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          if (_data == null) _error = 'Internet yo\'q';
          _loading = false;
        });
      }
    }
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
          title: const Text('Profil',
              style: TextStyle(color: Colors.white, fontSize: 18)),
        ),
        body: SafeArea(top: false, child: _body()),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(AppColors.accent),
        ),
      );
    }
    final d = _data;
    if (d == null) {
      return Center(
        child: Text(
          _error ?? 'Ma\'lumot yo\'q',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
        ),
      );
    }

    final first = '${d['first_name'] ?? ''}'.trim();
    final last = '${d['last_name'] ?? ''}'.trim();
    final name = '$first $last'.trim();
    final username = '${d['username'] ?? ''}'.trim();
    final photo = '${d['photo_url'] ?? ''}';
    final premium = d['premium'] == true;
    final shown = name.isEmpty
        ? (username.isEmpty ? 'Foydalanuvchi ${widget.userId}' : '@$username')
        : name;

    // ── QAYSI KATAK KO'RINADI ─────────────────────────────────
    //
    // Egasi yashirgan statistika javobga UMUMAN qo'shilmaydi
    // (`public_profile` izohiga qarang). Ya'ni "maydon bormi"
    // degan savol — "ko'rinadimi" degan savolning O'ZI.
    bool has(String key) => d[key] != null;
    int n(String key) => ((d[key] as num?) ?? 0).toInt();

    void open(StatKind kind) {
      if (!kind.openable) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StatDetailScreen(
            userId: widget.userId,
            kind: kind,
            owner: shown,
            isMe: AuthService.instance.user?.id == widget.userId,
          ),
        ),
      );
    }

    // ── KO'RINADIGAN KATAKLAR ─────────────────────────────────
    //
    // TALAB (foydalanuvchi): "pastida yashirilmagan statistikalar
    // ko'rinib tursin va boshqa foydalanuvchi ko'ringan
    // statistikani bemalol account egasidek ochib ko'rishi mumkin
    // bo'lsin — bu majburiy".
    final tiles = <Widget>[
      if (has('animes'))
        _StatBox(
            icon: Icons.movie_filter_rounded,
            label: StatKind.anime.label,
            value: formatCount(n('animes'))),
      if (has('episodes'))
        _StatBox(
            icon: Icons.play_circle_outline_rounded,
            label: StatKind.episodes.label,
            value: formatCount(n('episodes')),
            onTap: () => open(StatKind.episodes)),
      if (has('seasons'))
        _StatBox(
            icon: Icons.grid_view_rounded,
            label: StatKind.seasons.label,
            value: formatCount(n('seasons')),
            onTap: () => open(StatKind.seasons)),
      if (has('favorites'))
        _StatBox(
            icon: Icons.bookmark_rounded,
            label: StatKind.favorites.label,
            value: formatCount(n('favorites')),
            onTap: () => open(StatKind.favorites)),
      if (has('rated'))
        _StatBox(
            icon: Icons.star_rounded,
            label: StatKind.rated.label,
            value: formatCount(n('rated')),
            onTap: () => open(StatKind.rated)),
      if (has('comments'))
        _StatBox(
            icon: Icons.mode_comment_rounded,
            label: StatKind.comments.label,
            value: formatCount(n('comments')),
            onTap: () => open(StatKind.comments)),
      if (has('watch_ms'))
        _StatBox(
            icon: Icons.schedule_rounded,
            label: StatKind.watch.label,
            value: '${formatHours(n('watch_ms'))} soat'),
    ];

    return SingleChildScrollView(
      physics:
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── TEPA: RASM | ISM, USERNAME, ID ──────────────────
          //
          // TALAB (foydalanuvchi): "chap tarafda rasm, ustida
          // obunasi bor bo'lsa premium belgisi; o'ng tarafda ism,
          // username va nusxalasa bo'ladigan id raqam bo'lsin" —
          // ya'ni AYNAN o'z profilidagi ko'rinish.
          Glass(
            borderRadius: 20,
            blur: 16,
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.topCenter,
                  children: [
                    _Avatar(url: photo, name: name.isEmpty ? username : name),
                    if (premium)
                      const Positioned(top: -8, child: _PremiumTag()),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        shown,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (username.isNotEmpty && name.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text('@$username',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textDim, fontSize: 15)),
                      ],
                      const SizedBox(height: 10),
                      _IdPill(id: widget.userId),
                      // Balans FAQAT adminga (`public_profile`
                      // izohiga qarang) — oddiy odamning javobida
                      // bu maydon umuman yo'q.
                      if (d['admin_view'] == true) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Balans: '
                          '${formatSum(((d['balance'] as num?) ?? 0).toInt())}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ── STATISTIKA ──────────────────────────────────────
          if (tiles.isEmpty)
            Glass(
              borderRadius: 18,
              blur: 14,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
              child: Column(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 30, color: Colors.white.withValues(alpha: 0.3)),
                  const SizedBox(height: 10),
                  Text(
                    'Bu foydalanuvchi statistikasini yashirgan',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            )
          else
            // Ikkitadan qator. Toq son bo'lsa oxirgisi yolg'iz
            // qoladi va butun enni egallamaydi — shu sabab bo'sh
            // joy qo'shiladi.
            for (var i = 0; i < tiles.length; i += 2) ...[
              Row(
                children: [
                  Expanded(child: tiles[i]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: i + 1 < tiles.length
                        ? tiles[i + 1]
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],

          // ── FAQAT ADMIN KO'RADI ─────────────────────────────
          //
          // Bu qism SERVER ruxsat bergandagina keladi: oddiy
          // foydalanuvchining javobida bu maydonlar UMUMAN yo'q.
          if (d['admin_view'] == true) ...[
            _StatBox(
              icon: Icons.download_rounded,
              label: 'Trafik',
              value: formatBytes(((d['traffic'] as num?) ?? 0).toInt()),
            ),
            const SizedBox(height: 12),
            _AdminBox(data: d),
          ],
        ],
      ),
    );
  }
}

/// Rasm ustidagi "PREMIUM" belgisi — obunasi faol bo'lsa.
class _PremiumTag extends StatelessWidget {
  const _PremiumTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: const LinearGradient(
          colors: [AppColors.gold, AppColors.accent2],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.gold.withValues(alpha: 0.35),
            blurRadius: 12,
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium_rounded, size: 12, color: Colors.black87),
          SizedBox(width: 3),
          Text(
            'PREMIUM',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 9.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Nusxalasa bo'ladigan ID raqam.
///
/// TALAB (foydalanuvchi): "o'ng tarafda ism, username va
/// nusxalasa bo'ladigan id raqam bo'lsin".
class _IdPill extends StatelessWidget {
  final int id;
  const _IdPill({required this.id});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: '$id'));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.card,
            content: const Text('ID nusxalandi',
                style: TextStyle(color: Colors.white)),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ID: $id',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 7),
            Icon(Icons.copy_rounded,
                size: 14, color: Colors.white.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }
}

/// Admin uchun qo'shimcha ma'lumot kartasi.
class _AdminBox extends StatelessWidget {
  final Map<String, dynamic> data;
  const _AdminBox({required this.data});

  @override
  Widget build(BuildContext context) {
    final until = ((data['subscription_until'] as num?) ?? 0).toInt();
    final now = DateTime.now().millisecondsSinceEpoch;
    final active = until > now;
    final left = active ? ((until - now) / 86400000).ceil() : 0;

    return Glass(
      borderRadius: 16,
      blur: 14,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.admin_panel_settings_rounded,
                  size: 17, color: AppColors.accent),
              const SizedBox(width: 7),
              Text(
                'Admin uchun',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ID va Balans endi YUQORIDAGI kartada (foydalanuvchi
          // talabi) — bu yerda takrorlanmaydi.
          _row('Telegram ID',
              '${((data['telegram_id'] as num?) ?? 0).toInt()}'),
          _row('Obuna', active ? 'Faol · yana $left kun' : 'Yo\'q'),
          _row('Ro\'yxatdan o\'tgan',
              formatMoment(((data['created_at'] as num?) ?? 0).toInt())),
          _row('Oxirgi kirish',
              formatMoment(((data['last_login_at'] as num?) ?? 0).toInt())),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12.5,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String url;
  final String name;
  const _Avatar({required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    const size = 96.0;
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
          fontSize: 38,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? fallback
            : CachedNetworkImage(
                cacheManager: AppImageCache.manager,
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 300,
                placeholder: (_, __) => fallback,
                errorWidget: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  /// Bo'sh bo'lsa oddiy raqam (Anime, Tomosha vaqti, Trafik).
  /// Aks holda bosilganda o'sha statistikaning oynasi ochiladi.
  final VoidCallback? onTap;

  const _StatBox({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = _box();
    if (onTap == null) return box;
    return GlassTappable(onTap: onTap!, child: box);
  }

  Widget _box() {
    return Glass(
      borderRadius: 16,
      blur: 14,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: AppColors.accent),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
