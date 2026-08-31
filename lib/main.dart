import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'screens/root_screen.dart';
import 'services/app_keys.dart';
import 'services/rust_bridge.dart';

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

  // ── mdk-sdk global sozlamalari (litsenziya kaliti, log handler,
  // subtitr shrifti va h.k.) shu chaqiruv orqali o'rnatiladi ──────
  //
  // MUHIM: video pleyer boshqaruvi endi `package:fvp/mdk.dart`ning
  // past-darajali `Player` API'si orqali TO'G'RIDAN-TO'G'RI amalga
  // oshiriladi (lib/screens/video_player_screen.dart) — video_player
  // paketi va fvp'ning shim qatlami (`registerVideoPlayerPlatformsWith`
  // orqali yaratiladigan `VideoPlayerController`) ENDI ISHLATILMAYDI.
  // Shunga qaramay, `fvp.registerWith()` chaqiruvi SAQLANADI: u
  // mdk-sdk litsenziya kalitini (MDK_KEY) va boshqa global
  // sozlamalarni o'rnatadi — bu jarayonli-global holat bo'lib, har
  // qanday `mdk.Player` obyekti uchun amal qiladi.
  fvp.registerWith(options: {
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
