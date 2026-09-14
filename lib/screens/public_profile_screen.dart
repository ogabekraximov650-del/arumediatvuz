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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/auth_service.dart';
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

    return SingleChildScrollView(
      physics:
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      child: Column(
        children: [
          Glass(
            borderRadius: 20,
            blur: 16,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                _Avatar(url: photo, name: name.isEmpty ? username : name),
                const SizedBox(height: 14),
                Text(
                  name.isEmpty
                      ? (username.isEmpty
                          ? 'Foydalanuvchi ${widget.userId}'
                          : '@$username')
                      : name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (username.isNotEmpty && name.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('@$username',
                      style: const TextStyle(
                          color: Color(0xFF6BC7F0), fontSize: 15)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          // ── STATISTIKA ────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _StatBox(
                  icon: Icons.movie_filter_rounded,
                  label: 'Anime',
                  value: formatCount(
                      ((d['animes'] as num?) ?? 0).toInt()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatBox(
                  icon: Icons.play_circle_outline_rounded,
                  label: 'Qism',
                  value: formatCount(
                      ((d['episodes'] as num?) ?? 0).toInt()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _StatBox(
            icon: Icons.access_time_rounded,
            label: 'Tomosha vaqti',
            value: formatHours(((d['watch_ms'] as num?) ?? 0).toInt()),
          ),

          // ── FAQAT ADMIN KO'RADI ─────────────────────────────
          //
          // TALAB (foydalanuvchi): "chatdagi profil rasmi ustiga
          // bosganda profil to'liq ko'rinsin".
          //
          // Bu qism SERVER ruxsat bergandagina keladi: oddiy
          // foydalanuvchining javobida bu maydonlar UMUMAN yo'q,
          // ya'ni ilovani o'zgartirish bilan ham ularni ko'rib
          // bo'lmaydi.
          if (d['admin_view'] == true) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StatBox(
                    icon: Icons.favorite_rounded,
                    label: 'Sevimlilar',
                    value: formatCount(
                        ((d['favorites'] as num?) ?? 0).toInt()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatBox(
                    icon: Icons.download_rounded,
                    label: 'Trafik',
                    value:
                        formatBytes(((d['traffic'] as num?) ?? 0).toInt()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _AdminBox(data: d, userId: widget.userId),
          ],
        ],
      ),
    );
  }
}

/// Admin uchun qo'shimcha ma'lumot kartasi.
class _AdminBox extends StatelessWidget {
  final Map<String, dynamic> data;
  final int userId;

  const _AdminBox({required this.data, required this.userId});

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
          _row('ID', '$userId'),
          _row('Telegram ID',
              '${((data['telegram_id'] as num?) ?? 0).toInt()}'),
          _row('Balans',
              formatSum(((data['balance'] as num?) ?? 0).toInt())),
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

  const _StatBox({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
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
