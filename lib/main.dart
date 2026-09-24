import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'screens/root_screen.dart';
import 'widgets/glass.dart';
import 'services/app_build.dart';
import 'services/app_http.dart';
import 'services/app_keys.dart';
import 'services/auth_service.dart';
import 'services/image_cache.dart';
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
// ── ILOVA BELGISI HAM SHU YERDA QO'SHILADI ──────────────────
//
// TALAB (foydalanuvchi): "Workerni faqat ilovaga javob beradigan
// qil, tashqi so'rovlar rad etilsin".
//
// `AppHttpClient` har so'rovga ulanish kaliti va ilova versiyasini
// qo'yadi, keyin sanovchi klientga uzatadi. Ikkovi ham SHU BITTA
// joyda o'raladi — ya'ni servislarga umuman tegilmaydi va yangi
// so'rov qo'shilganda ham sarlavha o'z-o'zidan boradi
// (`app_http.dart` izohiga qarang).
Future<void> main() =>
    http.runWithClient(_main, () => AppHttpClient(CountingClient()));

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── ILOVANING IMZOSI ────────────────────────────────────────
  //
  // TALAB (foydalanuvchi): "worker ilovaning haqiqiyligini
  // tekshirishi kerak".
  //
  // Tizimdan BIR MARTA o'qiladi va har so'rovga qo'shiladi
  // (`app_build.dart` va `app_http.dart` izohlariga qarang).
  // Birinchi so'rovdan OLDIN bo'lishi shart, shu sabab bu yerda
  // kutiladi — u bir necha millisekund oladi.
  await AppSignature.load();

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
  // Yadro video va rasm so'rovlarini O'ZI yuboradi, shu sabab
  // versiyani ham o'zi qo'yishi kerak (`setAppVersion` izohi).
  RustCore.instance.setAppVersion(kAppVersion);

  // Shifrlash kalitini Keystore'dan olib Rust'ga uzatamiz.
  // Muvaffaqiyatsiz bo'lsa ilova shifrlashsiz, avvalgidek ishlaydi.
  await AppKeys.init();

  // Rasm keshi (shifrlangan) — kalit o'rnatilgandan KEYIN va
  // birinchi rasm chizilishidan OLDIN (`image_cache.dart`).
  await AppImageCache.init();

  // Mahalliy video kesh-serveri SHU YERDA ishga tushadi (avval u faqat
  // birinchi video ochilganda ishga tushardi). Shu sabab endi
  // foydalanuvchi videoni umuman ochmasdan ham "yuklab olish"ni bosa
  // oladi — kesh tizimi ilova ochilishi bilan tayyor turadi.
  await VideoCacheServer.instance.ensureStarted();

  // Saqlangan hisobni (agar bo'lsa) tiklaymiz. Xavfsiz ombordan
  // o'qish tez — tarmoq kutilmaydi: sessiya haqiqiyligi keyin,
  // fon'da tekshiriladi.
  await AuthService.instance.restore();

  // ── BIR MARTALIK TOZALASH (foydalanuvchi talabi) ────────────
  //
  // TALAB: "anime rasmi va video fayllari va Turso'dagi anime
  // ma'lumotlaridan boshqa hamma narsani tozalab tashla".
  //
  // Serverda bu `worker/src/lib.rs` -> `wipe_all_v4` da bajariladi.
  // Telefonda esa anime ro'yxatining KESHI eskirib qoladi: undagi
  // ko'rishlar va reyting raqamlari nollanishdan OLDINGI holat
  // bo'lardi va ekranda eski son turib qolardi.
  //
  // Shu sabab kesh bir marta tashlanadi. Belgi qo'yilgani uchun
  // bu faqat BIR MARTA bo'ladi — keyingi ochilishlarda ilova
  // avvalgidek keshdan darhol to'ladi.
  //
  // Shaxsiy ma'lumotlar (tarix, sevimlilar, trafik) alohida
  // tozalanmaydi: serverda hisoblar o'chirilgani uchun odam
  // qaytib kirganda YANGI raqam oladi va u bilan birga toza
  // papka ochiladi (`account_data.dart` -> `switchTo`).
  if (RustCore.instance.getCachedList('wipe_v4') == null) {
    RustCore.instance.clearCache();
    RustCore.instance.saveListCache('wipe_v4', [
      {'at': DateTime.now().millisecondsSinceEpoch}
    ]);
  }

  // ── STATISTIKA BIR MARTA TOZALANADI (v5) ────────────────────
  //
  // TALAB: "statistikani butunlay tozalab tashla — kim qaysi
  // animeni yoki epizodni ko'rgani, baho bergani, saqlagani va
  // hokazo barchasini".
  //
  // Serverda bu `worker/src/lib.rs` -> `wipe_stats_v5` da
  // bajariladi. Faqat serverni tozalash YETARLI EMAS: telefonda
  //
  //   * tomosha tarixi va sevimlilar nusxasi diskda yotadi —
  //     ekranda eski ro'yxat turib qolardi;
  //   * YUBORILMAGAN NAVBAT (`sync_queue`) ham yotadi — u
  //     keyingi ulanishda serverga ketib, endigina tozalangan
  //     ma'lumotni QAYTA TIKLAB qo'yardi.
  //
  // Shu sabab ikkovi ham shu yerda bo'shatiladi. Belgi qo'yilgani
  // uchun bu faqat BIR MARTA bo'ladi.
  if (RustCore.instance.getCachedList('stats_wipe_v5') == null) {
    final uid = AuthService.instance.user?.id ?? 0;
    for (final key in [
      'watch_history_$uid',
      'favorites',
      'my_stats',
      'app_stats',
      'sync_queue',
      'sync_state',
    ]) {
      RustCore.instance.saveListCache(key, const <Map<String, dynamic>>[]);
    }
    RustCore.instance.saveListCache('stats_wipe_v5', [
      {'at': DateTime.now().millisecondsSinceEpoch}
    ]);
  }

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
      title: 'ARUmediaTV',
      debugShowCheckedModeBanner: false,
      // ── MAVZU HAM O'SHA PALITRADAN ─────────────────────────
      //
      // TOPILGAN XATO: bu yerda urug' rang ALOHIDA yozilgan edi
      // (`#E94560` — pushti). Ya'ni ilovaning o'z kartalari bir
      // rangda, Flutter'ning O'Z widgetlari (kursor, tanlangan
      // matn, kalit tugmachalar, yuklanish aylanasi, dialog,
      // bildirishnoma pasti) esa BUTUNLAY boshqa rangda chiqardi.
      //
      // Endi urug' ham `AppColors.accent` — palitra bitta joyda
      // (`lib/widgets/glass.dart`).
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.dark,
        ).copyWith(
          primary: AppColors.accent,
          secondary: AppColors.accent2,
          surface: AppColors.card,
          error: AppColors.danger,
          onPrimary: AppColors.onAccent,
          onSurface: AppColors.text,
        ),
        // Matn kiritish: kursor va tanlov ham apelsin.
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: AppColors.accent,
          selectionHandleColor: AppColors.accent,
        ),
        progressIndicatorTheme:
            const ProgressIndicatorThemeData(color: AppColors.accent),
        // ── TEZLIK: BOSISH TO'LQINI YENGILLASHTIRILDI ────────
        //
        // Material 3 ning Android'dagi boshlang'ich to'lqini —
        // `InkSparkle`, va u FRAGMENT SHEYDER bilan chiziladi.
        // Arzon telefonlarda har bosish bir kadrni yeb qo'yadi.
        // `InkRipple` esa oddiy chizma — ko'rinishi deyarli o'sha,
        // narxi esa bir necha barobar past.
        splashFactory: InkRipple.splashFactory,
        useMaterial3: true,
      ),
      home: const RootScreen(),
    );
  }
}

