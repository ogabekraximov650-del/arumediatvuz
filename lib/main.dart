import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:path_provider/path_provider.dart';
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
  // 'demux.buffer.ranges' — demuxer darajasida BIR NECHTA (bu yerda 64
  // tagacha) tarmoqdan olingan bayt-oralig'ini XOTIRADA saqlab qoladi
  // (LRU bilan boshqariladi). Bu faqat controller yashab turgan davrga
  // tegishli — epizod almashtirilganda yoki pleyerdan chiqilganda
  // (controller dispose qilinganda) tozalanadi.
  //
  // 'global.cache.disk.io' — BUTUNLAY BOSHQA, doimiy DISK keshi
  // (mdk-sdk wiki: Network Disk Cache). Tarmoqdan bir marta o'qilgan
  // bayt-oralig'i haqiqiy faylga yoziladi va faqat KESHDA YO'Q bo'lgan
  // baytlar qayta tarmoqdan so'raladi — mavjud baytlar to'g'ridan-to'g'ri
  // diskdan o'qiladi. Bu kesh controller dispose bo'lganda HAM, epizod
  // almashtirilganda HAM, hatto ilova qayta ishga tushirilganda HAM
  // saqlanib qoladi (foydalanuvchi ilova ma'lumotlarini qo'lda
  // tozalamaguncha) — chunki u alohida kesh papkasidagi fayllarga
  // asoslangan, controller xotirasiga emas.
  // 'cache.disk.io.dir' — standart $AppCacheDir/mdk/io o'rniga, OS
  // tomonidan bosim ostida tozalanishi mumkin bo'lgan vaqtinchalik
  // "cache" papkasi emas, path_provider'ning DOIMIY ilova papkasi
  // (Application Support) ostiga aniq yo'naltiramiz.
  // 'cache.disk.io.expire' — -1 = hech qachon muddati tugamaydi.
  // MUHIM TUZATISH: 'lowLatency' olib tashlandi — u ASAP dekodlashga
  // undab, katta oldindan-bufer maqsadiga zid edi.
  final appSupportDir = await getApplicationSupportDirectory();
  final videoCacheDir = Directory('${appSupportDir.path}/video_disk_cache');
  await videoCacheDir.create(recursive: true);

  fvp.registerWith(options: {
    'fastSeek': true,
    'player': {
      'buffer.range': '2000+600000',
      'demux.buffer.ranges': '64',
    },
    'global': {
      'cache.disk.io': 1,
      'cache.disk.io.dir': videoCacheDir.path,
      'cache.disk.io.expire': -1,
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
