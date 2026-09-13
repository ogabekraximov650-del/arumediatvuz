import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'screens/root_screen.dart';
import 'services/app_keys.dart';
import 'services/auth_service.dart';
import 'services/billing_service.dart';
import 'services/net_meter.dart';
import 'services/offline_library.dart';
import 'services/rust_bridge.dart';
import 'services/storage_janitor.dart';
import 'services/sync_queue.dart';
import 'services/traffic_service.dart';
import 'services/video_cache_server.dart';
import 'services/watch_history.dart';

// ── HAMMA SO'ROV SANALADI ───────────────────────────────────────
//
// TALAB (foydalanuvchi): trafik faqat tarmoqdan kelgan baytdan
// hisoblansin.
//
// `runWithClient` — `package:http` ning o'z vositasi: shu zona
// ichida bajarilgan HAR QANDAY `http.get` / `http.post` va umuman
// `Client()` chaqiruvi bizning sanovchi klientimizni oladi. Ya'ni
// ilovadagi 14 ta fayldagi so'rovlarni birma-bir o'zgartirish ham,
// keyinchalik yangi so'rovni hisobga qo'shishni eslab qolish ham
// shart emas.
//
// Rasm keshi (`cached_network_image` -> `flutter_cache_manager`)
// ham oddiy `http.Client()` yaratadi — ya'ni posterlar va
// avatarlar ham shu hisobga tushadi.
//
// Video bunga kirmaydi: uni Rust yadrosi oladi va o'z hisoblagichi
// bor (`traffic_service.dart` ikkovini qo'shadi).
Future<void> main() => http.runWithClient(_main, CountingClient.new);

Future<void> _main() async {
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

  // Saqlangan hisobni (agar bo'lsa) tiklaymiz. Xavfsiz ombordan
  // o'qish tez — tarmoq kutilmaydi: sessiya haqiqiyligi keyin,
  // fon'da tekshiriladi.
  await AuthService.instance.restore();

  // Obuna muddati diskdan o'qiladi — TARMOQSIZ. Obunasi yo'q
  // odam anime ko'ra olmaydi, shu sabab bu ma'lumot ilova
  // ochilishi bilan ma'lum bo'lishi kerak, aks holda pul
  // to'lagan odam ham bir lahza to'sib qo'yilardi.
  BillingService.instance.restore();

  // Diskdagi tomosha tarixi — TARMOQSIZ o'qiladi (shifrlangan
  // nusxadan). Bosh sahifadan anime bosilganda "oxirgi ko'rilgan
  // qism" darhol ma'lum bo'lishi kerak, shu sabab bu yerda.
  WatchHistory.instance.loadFromDisk();

  // ── TRAFIK HISOBI ───────────────────────────────────────────
  // Faqat TARMOQDAN kelgan baytlar sanaladi (Rust yadrosining
  // video hisobi + yuqoridagi sanovchi klient). Bu xizmat endi
  // hech qayerga murojaat qilmaydi — yig'indini pastdagi navbat
  // paketning ichida olib ketadi. Kutilmaydi: ilova ochilishini
  // sekinlashtirmasin.
  unawaited(TrafficService.instance.start());

  // ── YAGONA YOZUV NAVBATI ────────────────────────────────────
  // Tomosha tarixi, baho, sevimlilar va trafik — hammasi avval
  // TELEFONDA yig'iladi, siqiladi va kuniga bir necha marta bitta
  // paket bo'lib yuboriladi. Kunlik so'rov 2-4 ta (qat'iy chegara
  // 50). Sabab va hisob-kitob — `sync_queue.dart` izohida.
  SyncQueue.instance.start();

  // ── OFLAYN RO'YXATLARI ──────────────────────────────────────
  // Internet bor-yo'qligini BITTA joyda kuzatadi va "qaysi qism
  // telefonda to'liq bor" indeksini yuritadi. Bosh sahifa, tomosha
  // tarixi va sevimlilar oflaynda shu indeksdan filtrlanadi
  // (offline_library.dart izohiga qarang).
  OfflineLibrary.instance.start();

  // ── VAQTINCHALIK FAYLLAR ────────────────────────────────────
  // Admin panelida tanlangan rasm/video ilovaning vaqtinchalik
  // papkasiga NUSXALANADI. Yuklash o'rtasida ilova yopilgan
  // bo'lsa, nusxa qolib ketadi va ilova hajmi o'sib boradi —
  // shu sabab eski qoldiqlar ochilishda tozalanadi.
  unawaited(StorageJanitor.sweep());

  runApp(const FulutterApp());
}

class FulutterApp extends StatelessWidget {
  const FulutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AniRaxUz',
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
