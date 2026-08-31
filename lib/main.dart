import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'screens/root_screen.dart';
import 'services/app_keys.dart';
import 'services/rust_bridge.dart';

// ═══════════════════════════════════════════════════════════════════
//  PLEYER (mdk-sdk) SOZLAMALARI
// ═══════════════════════════════════════════════════════════════════
const Map<String, String> _playerOpts = {
  // ── Bufer: 1s..5s, 8 ta bayt-oralig'i ────────────────────────────
  // TARIX (saboq): bir bosqichda buni 0.5s..2s va 2 oraliqqa
  // tushirgan edim — natija TESKARI bo'ldi. Kichik bufer bilan
  // mdk-sdk uni doim tugatib, har safar yangi so'rov yuborardi;
  // orqaga sek qilinganda esa yaqinda o'qilgan oraliqlar allaqachon
  // tashlangani uchun hammasi qaytadan o'qilardi. Asl muammo buferda
  // emas, serverda edi (video_cache.rs, `contiguous_cached_end`).
  'buffer.range': '1000+5000',
  'demux.buffer.ranges': '8',

  // ── Format aniqlash ─────────────────────────────────────────────
  // Standart qiymatlar (~5 MB / ~5s) bilan pleyer deyarli butun
  // videoni o'qib bo'lmaguncha initialize() ni yakunlay olmasdi.
  // Bir bo'lak hajmi (1 MiB) formatni aniqlash uchun yetarli.
  'avformat.probesize': '1048576',
  'avformat.analyzeduration': '1000000',
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Tizim navigatsiya panelini shaffof qilamiz — aks holda pleyer
  // fullscreen'dan qaytganda pastda vaqtincha qora to'rtburchak
  // ko'rinib qolardi.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.light,
  ));
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // ── Tekstura o'lchamini ekran bilan cheklash ────────────────────
  // mdk standart holatda videoning TO'LIQ o'lchamidagi tekstura
  // yaratadi. Ekranda baribir shundan ko'p piksel ko'rsatilmaydi,
  // ya'ni ortiqcha xotira va GPU ishi bekorga ketardi.
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final screen = view.physicalSize;
  final maxSide = screen.longestSide.round().clamp(720, 3840);
  final minSide = screen.shortestSide.round().clamp(480, 2160);

  fvp.registerWith(options: {
    'fastSeek': true,
    'maxWidth': maxSide,
    'maxHeight': minSide,
    'player': _playerOpts,
    'global': {'cache.disk.io': 0},
  });

  // Rust yadrosi (kesh, qidiruv, shifrlash) shu yerda yuklanadi.
  await RustCore.instance.init();

  // Shifrlash kalitini Keystore'dan olib Rust'ga uzatamiz.
  // Muvaffaqiyatsiz bo'lsa ilova shifrlashsiz, avvalgidek ishlaydi.
  await AppKeys.init();

  runApp(const FulutterApp());
}

class FulutterApp extends StatelessWidget {
  const FulutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fulutter Anime',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE94560),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const RootScreen(),
    );
  }
}
