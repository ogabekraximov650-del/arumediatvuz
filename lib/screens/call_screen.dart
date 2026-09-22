// lib/screens/call_screen.dart — QO'NG'IROQ OYNASI.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi Telegramning qo'ng'iroq oynasini screenshot qilib
// yubordi va ko'rinishi shunga o'xshash bo'lishini so'radi:
//
//   * to'liq ekran, ko'kdan yashilga o'tuvchi fon;
//   * chap yuqorida kichraytirish tugmasi;
//   * o'rtada katta dumaloq avatar, ostida ism, ostida holat
//     (`Kutilmoqda`, `Ulanmoqda`) yoki suhbat vaqti;
//   * pastda holat yorlig'i (`Mikrofoningiz o'chirildi`);
//   * pastda 4 ta dumaloq tugma: Karnay, Video, Mikrofon,
//     Chaqiruvni tugatish.
//
// Va alohida: "gapirayotganda iloji bo'lsa ovoz tebranishini ham
// ko'rsatadigan narsa qo'sha olasanmi" — avatar atrofidagi
// halqalar shu.

import 'package:flutter/material.dart';

import '../services/call_service.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  /// Suhbat vaqtini tikillatib turish uchun.
  ///
  /// NEGA ALOHIDA: qo'ng'iroq xizmati soniya sayin o'zgarmaydi,
  /// u faqat HOLAT o'zgarganda xabar beradi. Soat esa har soniya
  /// yangilanishi kerak.
  late final Stream<void> _tick = Stream.periodic(const Duration(seconds: 1));

  @override
  Widget build(BuildContext context) {
    final call = CallService.instance;
    return PopScope(
      // ── ORQAGA TUGMASI QO'NG'IROQNI UZMAYDI ─────────────────
      //
      // Odam orqaga bosganda oyna yopiladi, lekin suhbat DAVOM
      // ETADI — chat ustida yashil "CHAQIRUVGA QAYTISH" tasmasi
      // chiqadi. Telegram ham shunday qiladi; qo'ng'iroqni
      // tasodifan uzib qo'yish eng bezovta qiladigan xato.
      canPop: true,
      child: Scaffold(
        body: AnimatedBuilder(
          animation: call,
          builder: (context, _) => Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0E7C86), Color(0xFF1E4FA3)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _topBar(context),
                  const Spacer(flex: 2),
                  _avatar(call),
                  const SizedBox(height: 24),
                  Text(
                    call.peerName.isEmpty ? 'Qo\'ng\'iroq' : call.peerName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  _status(call),
                  const Spacer(flex: 3),
                  if (!call.micOn) _mutedChip(),
                  const SizedBox(height: 16),
                  _buttons(context, call),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) => Align(
        alignment: Alignment.topLeft,
        child: IconButton(
          // Kichraytirish — oynani yopadi, qo'ng'iroqni emas.
          icon: const Icon(Icons.close_fullscreen, color: Colors.white70),
          tooltip: 'Kichraytirish',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      );

  /// Avatar va uning atrofidagi ovoz halqalari.
  Widget _avatar(CallService call) {
    final level = call.peerLevel;
    return SizedBox(
      width: 260,
      height: 260,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ── OVOZ TEBRANISHI ─────────────────────────────────
          //
          // Ikki halqa: ichkarisi tez, tashqarisi sekinroq
          // kengayadi. Shu bilan tebranish "tirik" ko'rinadi.
          //
          // Qiymat allaqachon silliqlangan (`CallService._blend`),
          // shu sabab bu yerda qo'shimcha animatsiya kerak emas —
          // `AnimatedContainer` ham ortiqcha bo'lardi.
          _ring(160 + level * 70, 0.10),
          _ring(150 + level * 45, 0.16),
          Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black26,
              image: call.peerAvatar.isEmpty
                  ? null
                  : DecorationImage(
                      image: NetworkImage(call.peerAvatar),
                      fit: BoxFit.cover,
                    ),
            ),
            alignment: Alignment.center,
            child: call.peerAvatar.isNotEmpty
                ? null
                : Text(
                    _initial(call.peerName),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 56,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _ring(double size, double opacity) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: opacity),
        ),
      );

  /// Ismning birinchi harfi (emoji bo'lsa ham to'g'ri chiqadi).
  ///
  /// `characters` paketisiz `name[0]` emoji'ni YARMIDAN kesib
  /// qo'yardi va ekranda buzuq belgi chiqardi.
  static String _initial(String name) {
    final t = name.trim();
    if (t.isEmpty) return '?';
    return t.characters.first.toUpperCase();
  }

  /// Holat matni yoki suhbat vaqti.
  Widget _status(CallService call) {
    if (call.state == CallState.active) {
      return StreamBuilder<void>(
        stream: _tick,
        builder: (context, _) => Text(
          _elapsed(call.startedAt),
          style: const TextStyle(color: Colors.white70, fontSize: 17),
        ),
      );
    }
    return Text(
      // Uch nuqta — kutish davom etayotganini bildiradi.
      '${call.state.label} • •',
      style: const TextStyle(color: Colors.white70, fontSize: 17),
    );
  }

  static String _elapsed(DateTime? from) {
    if (from == null) return '00:00';
    final d = DateTime.now().difference(from);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Widget _mutedChip() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_off, color: Colors.white70, size: 19),
            SizedBox(width: 8),
            Text('Mikrofoningiz o\'chirildi',
                style: TextStyle(color: Colors.white, fontSize: 15)),
          ],
        ),
      );

  Widget _buttons(BuildContext context, CallService call) {
    // Kelayotgan qo'ng'iroqda boshqaruv boshqacha: qabul qilish
    // va rad etish.
    if (call.state == CallState.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _round(
            icon: Icons.call_end,
            label: 'Rad etish',
            color: const Color(0xFFD32F2F),
            onTap: call.decline,
          ),
          _round(
            icon: Icons.call,
            label: 'Qabul qilish',
            color: const Color(0xFF2E7D32),
            onTap: call.accept,
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _round(
          icon: call.speakerOn ? Icons.volume_up : Icons.volume_down,
          label: 'Karnay',
          color: call.speakerOn
              ? Colors.white.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.18),
          onTap: call.toggleSpeaker,
        ),
        // ── VIDEO HALI YO'Q ─────────────────────────────────
        //
        // Tugma joyida turadi (Telegramdagidek), lekin o'chiq:
        // hozircha faqat ovoz. Video qo'shilganda shu yerda
        // `onTap` paydo bo'ladi, qolgan ko'rinish o'zgarmaydi.
        _round(
          icon: Icons.videocam_off,
          label: 'Video',
          color: Colors.white.withValues(alpha: 0.12),
          onTap: null,
        ),
        _round(
          icon: call.micOn ? Icons.mic : Icons.mic_off,
          label: 'Mikrofon',
          color: Colors.white.withValues(alpha: 0.18),
          onTap: call.toggleMic,
        ),
        _round(
          icon: Icons.call_end,
          label: 'Chaqiruvni\ntugatish',
          color: const Color(0xFFD32F2F),
          onTap: () => call.hangUp(),
        ),
      ],
    );
  }

  Widget _round({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 64,
                height: 64,
                child: Icon(
                  icon,
                  color: onTap == null ? Colors.white38 : Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 78,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
        ],
      );
}

/// Qo'ng'iroq oynasini ochadi (agar allaqachon ochiq bo'lmasa).
///
/// NEGA BELGI: qo'ng'iroq bir necha yo'l bilan boshlanishi mumkin
/// (tugma bosildi, signal keldi, banner bosildi) va har biri
/// oynani ochishga urinadi. Belgisiz ekran ustiga ekran
/// taxlanardi va orqaga bosganda ularning hammasidan birma-bir
/// chiqishga to'g'ri kelardi.
bool _callScreenOpen = false;

Future<void> openCallScreen(BuildContext context) async {
  if (_callScreenOpen) return;
  _callScreenOpen = true;
  try {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const CallScreen(),
      ),
    );
  } finally {
    _callScreenOpen = false;
  }
}

/// Qo'ng'iroq oynasi hozir ochiqmi.
bool get isCallScreenOpen => _callScreenOpen;
