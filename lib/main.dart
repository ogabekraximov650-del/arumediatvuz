import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'screens/root_screen.dart';
import 'services/rust_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // MUHIM: tizim navigatsiya panelini shaffof qilib qo'yamiz.
  // Aks holda video pleyer fullscreen rejimidan (immersiveSticky)
  // oddiy rejimga (edgeToEdge) qaytganda pastki panel orqasida
  // vaqtincha qora to'rtburchak ko'rinib qolishi mumkin edi.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.light,
  ));
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // fvp: video_player uchun ichki pleyer mexanizmi (decoding/render).
  // API o'zgarmaydi — bitta VideoPlayerController orqali ishlaydi.
  // MUHIM: 'buffer.range' — "minMs+maxMs" formatida. Video ijro
  // boshlanishidan oldin kamida 30000ms (30 soniya) buferlanishini
  // kutadi, maksimal buferlangan hajm 300000ms (300 soniya) bilan
  // cheklanadi (mdk backend player property "buffer"/"buffer.range").
  // MUHIM TUZATISH: 'lowLatency' olib tashlandi — u ASAP dekodlashga
  // undab, katta oldindan-bufer maqsadiga zid edi.
  fvp.registerWith(options: {
    'fastSeek': true,
    'player': {
      'buffer.range': '30000+300000',
    },
  });
  // Ichki mexanizm (kesh, qidiruv, validatsiya) shu yerda yuklanadi —
  // undan keyin butun ilova Rust yadrosiga murojaat qila oladi.
  await RustCore.instance.init();
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
