// lib/widgets/app_notice.dart — ILOVA USTIDAGI BILDIRISHNOMA.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "xabar yoki chaqiruv kelganda ilovani qaysi
// joyida o'tirgan bo'lsam ham yuqoridan bildirishnoma chiqishi
// kerak... xabar kelganda ilova tepasida bildirishnoma 5 soniya
// ko'rsatilishi kerak, ovoz chiqishi kerak va ustiga bossa chatga
// o'tishi kerak".
//
// ── NEGA `SnackBar` EMAS ──────────────────────────────────────
//
// `SnackBar` pastda chiqadi va eng yaqin `Scaffold` ga bog'langan
// — ya'ni u ekran almashganda yo'qoladi va pleyer to'liq ekranda
// bo'lsa umuman ko'rinmaydi.
//
// Bu yerdagisi esa butun ilovaning USTIDA turadi (`Overlay`), shu
// sabab foydalanuvchi qayerda bo'lishidan qat'i nazar ko'rinadi.
//
// ── NEGA ALOHIDA FAYL ─────────────────────────────────────────
//
// Uni chaqiradigan joy ko'p: yangi xabar keldi, qo'ng'iroq keldi,
// ulanish uzildi. Ularning hech biri bir-birini bilmasligi kerak.

import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/glass.dart';

/// Bannerni ko'rsatish uchun ilovaga kerak bo'ladigan kalit.
///
/// `MaterialApp.navigatorKey` ga beriladi va shu orqali istalgan
/// joydan `Overlay` ga yetib boriladi — `BuildContext` ni qo'lda
/// uzatib yurish shart emas.
final GlobalKey<NavigatorState> appNavigatorKey =
    GlobalKey<NavigatorState>();

/// Ilova ustidagi bildirishnoma.
class AppNotice {
  AppNotice._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  /// Bannerni ko'rsatadi.
  ///
  /// `title`   — qalin qator (odatda ism);
  /// `body`    — ostidagi matn;
  /// `avatar`  — dumaloq rasm manzili (bo'sh bo'lishi mumkin);
  /// `onTap`   — bosilganda;
  /// `seconds` — necha soniya tursin (odatda 5).
  ///
  /// Yangisi eskisini ALMASHTIRADI: ketma-ket kelgan ikki xabar
  /// uchun ikkita banner taxlanib qolmasin.
  static void show({
    required String title,
    String body = '',
    String avatar = '',
    VoidCallback? onTap,
    int seconds = 5,
    IconData icon = Icons.chat_bubble_rounded,
  }) {
    final nav = appNavigatorKey.currentState;
    final overlay = nav?.overlay;
    if (overlay == null) return;

    hide();
    final entry = OverlayEntry(
      builder: (context) => _NoticeCard(
        title: title,
        body: body,
        avatar: avatar,
        icon: icon,
        onTap: () {
          hide();
          onTap?.call();
        },
        onClose: hide,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(Duration(seconds: seconds), hide);
  }

  /// Bannerni darhol olib tashlaydi.
  static void hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }

  /// Hozir banner ko'rinib turibdimi.
  static bool get visible => _entry != null;
}

class _NoticeCard extends StatefulWidget {
  final String title;
  final String body;
  final String avatar;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _NoticeCard({
    required this.title,
    required this.body,
    required this.avatar,
    required this.icon,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<_NoticeCard> createState() => _NoticeCardState();
}

class _NoticeCardState extends State<_NoticeCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8,
      left: 10,
      right: 10,
      child: SlideTransition(
        // Tepadan siljib tushadi — Telegram va tizim
        // bildirishnomalari ham shunday chiqadi.
        position: Tween<Offset>(
          begin: const Offset(0, -1.2),
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic)),
        child: Material(
          color: Colors.transparent,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            // Yuqoriga surib yuborish — yopish.
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < 0) widget.onClose();
            },
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.10)),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  _avatarOrIcon(),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (widget.body.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.72),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        size: 18, color: Colors.white38),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _avatarOrIcon() {
    if (widget.avatar.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          widget.avatar,
          width: 38,
          height: 38,
          fit: BoxFit.cover,
          // Rasm kelmasa banner buzilmasin — belgi chiziladi.
          errorBuilder: (_, __, ___) => _iconBox(),
        ),
      );
    }
    return _iconBox();
  }

  Widget _iconBox() => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.accent.withValues(alpha: 0.18),
        ),
        child: Icon(widget.icon, color: AppColors.accent, size: 20),
      );
}

// ═══════════════════════════════════════════════════════════════
//  KELAYOTGAN QO'NG'IROQ BANNERI
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "qo'ng'iroq kelganda ilova tepasida chap
// tarafda foydalanuvchi profil rasmi, yonida Nomi va useri; o'ng
// tarafida yashil rangda qabul qilish va qizil rangda bekor
// qilish uchun trubkalar bo'lsin".

class CallNotice {
  CallNotice._();

  static OverlayEntry? _entry;

  /// Kelayotgan qo'ng'iroq bannerini ko'rsatadi.
  ///
  /// Xabar bannerdan farqli o'laroq O'ZI YO'QOLMAYDI: qo'ng'iroq
  /// javob kutadi. U faqat qabul qilinganda, rad etilganda yoki
  /// chaqiruvchi go'shakni qo'yganda ketadi.
  static void show({
    required String name,
    String username = '',
    String avatar = '',
    required VoidCallback onAccept,
    required VoidCallback onDecline,
    VoidCallback? onOpen,
  }) {
    final overlay = appNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    hide();
    // Xabar banneri qo'ng'iroq bannerini to'sib qo'ymasin.
    AppNotice.hide();

    final entry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.paddingOf(context).top + 8,
        left: 10,
        right: 10,
        child: Material(
          color: Colors.transparent,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.10)),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 20,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // ── CHAP TOMON: RASM, ISM, @USER ────────────
                  ClipOval(
                    child: avatar.isEmpty
                        ? Container(
                            width: 42,
                            height: 42,
                            color: AppColors.accent.withValues(alpha: 0.18),
                            child: Icon(Icons.person_rounded,
                                color: AppColors.accent, size: 22),
                          )
                        : Image.network(
                            avatar,
                            width: 42,
                            height: 42,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 42,
                              height: 42,
                              color:
                                  AppColors.accent.withValues(alpha: 0.18),
                              child: Icon(Icons.person_rounded,
                                  color: AppColors.accent, size: 22),
                            ),
                          ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name.isEmpty ? 'Qo\'ng\'iroq' : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          username.isEmpty
                              ? 'Qo\'ng\'iroq qilmoqda'
                              : '@$username',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // ── O'NG TOMON: IKKI TRUBKA ─────────────────
                  _handset(
                    color: const Color(0xFFD32F2F),
                    icon: Icons.call_end_rounded,
                    onTap: () {
                      hide();
                      onDecline();
                    },
                  ),
                  const SizedBox(width: 8),
                  _handset(
                    color: const Color(0xFF2E7D32),
                    icon: Icons.call_rounded,
                    onTap: () {
                      hide();
                      onAccept();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static Widget _handset({
    required Color color,
    required IconData icon,
    required VoidCallback onTap,
  }) =>
      Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: Colors.white, size: 21),
          ),
        ),
      );

  static void hide() {
    _entry?.remove();
    _entry = null;
  }

  static bool get visible => _entry != null;
}
