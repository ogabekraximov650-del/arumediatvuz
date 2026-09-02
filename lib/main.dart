import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/root_screen.dart';
import 'services/app_keys.dart';
import 'services/rust_bridge.dart';
import 'services/video_cache_server.dart';

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

  // Rust yadrosi (kesh, qidiruv, shifrlash) shu yerda yuklanadi.
  await RustCore.instance.init();

  // Shifrlash kalitini Keystore'dan olib Rust'ga uzatamiz.
  // Muvaffaqiyatsiz bo'lsa ilova shifrlashsiz, avvalgidek ishlaydi.
  await AppKeys.init();

  // Mahalliy video kesh-serveri SHU YERDA ishga tushadi (avval u faqat
  // birinchi video ochilganda ishga tushardi). Shu sabab endi
  // foydalanuvchi videoni umuman ochmasdan ham "yuklab olish"ni bosa
  // oladi — kesh tizimi ilova ochilishi bilan tayyor turadi.
  await VideoCacheServer.instance.ensureStarted();

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
