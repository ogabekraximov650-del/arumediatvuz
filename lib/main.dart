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
  //
  // MUHIM: 'buffer.range' o'zi FAQAT joriy ijro nuqtasi atrofidagi
  // BITTA sirg'anuvchi oynani boshqaradi — undan tashqariga (masalan
  // orqaga sek qilib, allaqachon ko'rilgan joyga qaytilsa) chiqilsa,
  // bu oyna yordam bermaydi va video HAR DOIM qayta tarmoqdan
  // so'raladi. Aynan shuning uchun 55 soniyalik videoda ham oldinga/
  // orqaga sek qilinganda va video tugab "play" qayta bosilganda
  // range so'rov qayta ketardi.
  // MIN (2000ms) — ijroni boshlash/davom ettirishdan oldin talab
  // qilinadigan eng kam bufer (avval 30000ms edi — shu qotishning
  // asosiy sababi edi).
  // MAX (600000ms = 10 daqiqa) — joriy nuqtadan OLDINGA qarab
  // buferlanadigan hajm chegarasi.
  // 'demux.buffer.ranges' — ANIQ MUHIM TUZATISH: demuxer darajasida
  // BIR NECHTA (bu yerda 64 tagacha) tarmoqdan olingan bayt-oralig'ini
  // xotirada saqlab qoladi — ya'ni video ichida oldinga HAM, orqaga HAM
  // sek qilinganda, agar o'sha joy avval yuklab olingan bo'lsa, qayta
  // tarmoqqa so'rov ketmaydi, xotiradagi keshdan o'qiladi (LRU bilan
  // boshqariladi). Bu aynan sizga kerak bo'lgan "bufer saqlanib qolsin"
  // xususiyati (mdk-sdk hujjati: wang-bin/mdk-sdk wiki, Player APIs).
  // 'global.cache.disk.io' — bundan tashqari, tarmoqdan o'qilgan bayt
  // oraliqlari DISKKA ham yoziladi (mdk-sdk wiki: Network Disk Cache).
  // Shu ikkalasi birgalikda: bitta epizod davomida qayerga sek
  // qilinmasin yoki video tugab qaytadan play bosilmasin — avval
  // yuklangan qism ENDI qaytadan tarmoqdan so'ralmaydi. Bufer/kesh
  // faqat epizod almashtirilganda yoki pleyerdan chiqilganda (controller
  // dispose qilinganda) tozalanadi.
  // MUHIM TUZATISH: 'lowLatency' olib tashlandi — u ASAP dekodlashga
  // undab, katta oldindan-bufer maqsadiga zid edi.
  fvp.registerWith(options: {
    'fastSeek': true,
    'player': {
      'buffer.range': '2000+600000',
      'demux.buffer.ranges': '64',
    },
    'global': {
      'cache.disk.io': 1,
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
