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
  // 'demux.buffer.ranges' — demuxer darajasida BIR NECHTA (bu yerda 64
  // tagacha) tarmoqdan olingan bayt-oralig'ini XOTIRADA saqlab qoladi
  // (LRU bilan boshqariladi). Bu faqat controller yashab turgan davrga
  // tegishli — epizod almashtirilganda yoki pleyerdan chiqilganda
  // (controller dispose qilinganda) tozalanadi.
  //
  // MUHIM: doimiy, bayt-darajasidagi DISK keshi endi mdk-sdk'ning o'z
  // ('global.cache.disk.io') mexanizmi orqali EMAS, balki
  // lib/services/video_cache_server.dart'dagi o'zimizning mahalliy
  // (127.0.0.1) HTTP kesh-proksimiz orqali amalga oshiriladi — u video
  // pleyerga uzatiladigan URL'ni almashtirib, har bir videoni ilovaning
  // shaxsiy papkasida 1 MiB'lik bo'laklarga bo'lib saqlaydi va faqat
  // keshda YO'Q bo'lgan bo'laklarnigina worker'dan yuklaydi (bu tizim
  // ustidan to'liq nazorat beradi va kelajakdagi bo'lak-darajasidagi
  // AES shifrlash rejasiga tayyor). Shu sabab mdk-sdk'ning o'z disk
  // keshi ATAYLAB o'chirilgan — ikkinchi (keraksiz, ikki barobar joy
  // egallovchi) kesh qatlami bo'lib qolmasligi uchun.
  // MUHIM TUZATISH: 'lowLatency' olib tashlandi — u ASAP dekodlashga
  // undab, katta oldindan-bufer maqsadiga zid edi.
  //
  // MUHIM TUZATISH (qurilmada aniqlangan sekin ishga tushish sababi):
  // FFmpeg standart holatda formatni aniqlash uchun 'avformat.probesize'
  // (standart ~5 MB) va 'avformat.analyzeduration' (standart ~5s)
  // miqdorida ma'lumot o'qishga urinadi. Bizning videolarimiz ko'pincha
  // bir necha MB bo'lgani uchun, bu standart qiymatlar bilan pleyer
  // deyarli BUTUN VIDEONI (barcha bo'laklarni tarmoqdan) yuklab
  // bo'lmaguncha initialize() yakunlana olmasdi — garchi har bir bo'lak
  // o'zi tez yuklansa ham, buning yig'indisi 15 soniyalik oynadan
  // oshib ketardi. Bu qiymatlarni kichraytirish (mos ravishda 1 MiB va
  // 1 soniya — bitta bo'lak hajmimiz bilan mos) formatni aniqlash uchun
  // yetarli, lekin ortiqcha ma'lumot talab qilmaydi.
  //
  // ENG MUHIM TUZATISH (tez-tez sek qilganda ilovaning o'chib qolishi):
  // avvalgi 'buffer.range' MAX qiymati 600000ms (10 daqiqa) va
  // 'demux.buffer.ranges' 64 edi. Bu mdk-sdk'ga joriy nuqtadan 10
  // daqiqagacha ma'lumotni XOTIRADA saqlashga va bundan tashqari 64
  // tagacha alohida bayt-oralig'ini ham xotirada ushlab turishga ruxsat
  // berardi. Har bir sek YANGI oraliq hosil qilgani uchun, 5-6 marta
  // ketma-ket sek qilinganda xotira sarfi tez o'sib, Android ilovani
  // o'ldirardi — aynan foydalanuvchi kuzatgan holat.
  //
  // Endi bu qiymatlar keskin kamaytirildi: 1.5s min, 20s max bufer va
  // 8 ta oraliq. Bu XOTIRA sarfini bir necha barobar kamaytiradi va
  // ijro sifatiga ta'sir qilmaydi — chunki baytlar allaqachon MAHALLIY
  // DISKDA (Rust kesh-serveri) tayyor turadi, ya'ni mdk-sdk ularni
  // xotirada ushlab turishi shart emas: kerak bo'lganda diskdan
  // millisekundlarda qayta o'qiydi. Aksincha, kichik bufer sek
  // qilishni ham TEZLASHTIRADI (kamroq ma'lumot qayta yig'iladi).
  fvp.registerWith(options: {
    'fastSeek': true,
    'player': {
      'buffer.range': '1500+20000',
      'demux.buffer.ranges': '8',
      'avformat.probesize': '1048576',
      'avformat.analyzeduration': '1000000',
    },
    'global': {
      'cache.disk.io': 0,
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
