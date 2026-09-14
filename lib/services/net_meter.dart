// lib/services/net_meter.dart — TARMOQDAN KELGAN BAYTLAR HISOBI.
//
// ═══════════════════════════════════════════════════════════════
//  NEGA BU FAYL BOR (TOPILGAN XATO)
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "ilova trafikni xato hisoblayapti — ilova
// ICHIDA aylanayotgan trafikni ham qo'shyapti. Endi faqat internet
// yoniq vaqtda WORKER orqali kelgan baytlar sanalsin."
//
// Sabab aniq edi. Ilgari hisob Android yadrosidan olinardi
// (`TrafficStats.getUidRxBytes`) — u ilovaning UID'i ostidagi
// HAMMA soketni sanaydi. Pleyer esa videoni tarmoqdan emas,
// ilovaning O'Z kesh-serveridan (`127.0.0.1`) oladi. Natijada:
//
//   * bitta video IKKI MARTA sanalardi — bir marta Rust yadrosi
//     uni workerdan tortib olganda, ikkinchi marta o'sha baytlar
//     pleyerga mahalliy uzatilganda;
//   * ALLAQACHON yuklab olingan videoni oflayn qayta ko'rganda
//     ham trafik o'sardi — hech qanday bayt tarmoqdan kelmagan
//     bo'lsa ham.
//
// ═══════════════════════════════════════════════════════════════
//  ENDI QANDAY
// ═══════════════════════════════════════════════════════════════
//
// Hisob AYNAN tarmoqqa chiqadigan ikkita joyda olinadi:
//
//   1. VIDEO — Rust yadrosining o'z hisoblagichi
//      (`rust_video_cache_net_bytes`): u faqat workerdan HAQIQATAN
//      tortib olingan baytni sanaydi. `traffic_service.dart` shuni
//      o'qiydi.
//   2. QOLGAN HAMMASI — shu fayldagi `CountingClient`: API
//      so'rovlari, posterlar, avatarlar. Har bir javobning
//      HAQIQATDA o'qilgan tanasi sanaladi (e'lon qilingan
//      `Content-Length` emas — eski xatoning sababi aynan shu
//      edi), ustiga sarlavhalarning taxminiy hajmi.
//
// Diskdan o'qish, `127.0.0.1` uzatmasi, keshdan olingan rasm —
// UMUMAN sanalmaydi, chunki ular bu ikki joydan o'tmaydi.
//
// ── HAMMA SO'ROV QANDAY QILIB SHU KLIENTDAN O'TADI ────────────
//
// Ilovada 14 ta faylda `http.get(...)` bor va ularning har birini
// qo'lda o'zgartirish — qarz: yangi so'rov yozilganda hisobga
// qo'shishni unutish oson. Shu sabab `main()` da butun ilova
// `runWithClient` ichida ishga tushadi (`package:http` ning o'z
// vositasi): o'shanda `http.get`, `http.post` va umuman `Client()`
// chaqiruvlarining HAMMASI shu klientni oladi.
//
// Bu rasmlarni ham qamrab oladi: `cached_network_image` fayllarni
// `flutter_cache_manager` orqali oladi, u esa oddiy
// `http.Client()` yaratadi — ya'ni u ham shu zonadan o'tadi.

import 'dart:async';

import 'package:http/http.dart' as http;

/// Trafik toifalari — profil sahifasida AYNAN shu nomlar chiqadi.
///
/// TALAB (foydalanuvchi): "trafikda nimaga qancha trafik ketgani
/// aniq qilib ko'rsatilsin".
class TrafficKind {
  const TrafficKind._();

  /// Rust yadrosi workerdan tortib olgan video baytlari.
  static const String video = 'Videolar';

  /// Posterlar va avatarlar (`/api/image/...`).
  static const String image = 'Rasmlar';

  /// Qolgan hamma so'rov: tarix, statistika, kirish, ro'yxatlar.
  static const String api = 'Ma\'lumotlar';

  /// Ekrandagi tartib (rang shu tartibdan olinadi).
  static const List<String> all = [video, image, api];
}

/// Tarmoqdan qabul qilingan baytlar — TOIFALAR bo'yicha.
///
/// Ilova ishga tushganda noldan boshlanadi — `TrafficService` uni
/// FARQ bo'yicha o'qiydi, ya'ni qayta ishga tushish hisobni
/// buzmaydi.
class NetMeter {
  NetMeter._();
  static final NetMeter instance = NetMeter._();

  final Map<String, int> _byKind = {};

  /// Ilova ishga tushganidan beri tarmoqdan qabul qilingan bayt.
  int get bytes {
    var n = 0;
    for (final v in _byKind.values) {
      n += v;
    }
    return n;
  }

  /// Toifa bo'yicha hisob (shu seansda).
  int of(String kind) => _byKind[kind] ?? 0;

  void add(int n, [String kind = TrafficKind.api]) {
    if (n > 0) _byKind[kind] = (_byKind[kind] ?? 0) + n;
  }

  /// Manzil qaysi toifaga tegishli.
  ///
  /// Rasmlar worker'ning `/api/image/...` yo'lidan keladi; qolgan
  /// hamma narsa oddiy API so'rovi. Video bu yerga UMUMAN
  /// tushmaydi — uni Rust yadrosi oladi va o'z hisoblagichi bor.
  static String kindOfUrl(Uri url) {
    final path = url.path;
    // `/api/media/` — yozishmadagi rasm/video (`b2_media` izohiga
    // qarang). U ham rasm hisoblanadi, aks holda chatga yuborilgan
    // rasm statistikada "Ma'lumotlar" bo'lib chiqardi.
    if (path.contains('/api/image/') ||
        path.contains('/api/media/') ||
        path.contains('/api/avatar/')) {
      return TrafficKind.image;
    }
    return TrafficKind.api;
  }
}

/// Javob tanasini sanab o'tkazuvchi klient.
///
/// Oqimga ARALASHMAYDI: baytlar o'tib ketayotganda sanaladi,
/// hech narsa buferlanmaydi va kechiktirilmaydi.
class CountingClient extends http.BaseClient {
  /// ── ICHKI KLIENT ILDIZ ZONADA YARATILADI ────────────────────
  ///
  /// MUHIM: bu shart. Butun ilova `runWithClient` zonasida
  /// ishlaydi, ya'ni o'sha zonada `http.Client()` chaqirilsa
  /// U YANA SHU KLIENTNI qaytaradi — cheksiz rekursiya.
  ///
  /// `Zone.root.run` esa zonadagi qiymatni chetlab o'tadi va
  /// platformaning HAQIQIY klientini beradi.
  CountingClient([http.Client? inner])
      : _inner = inner ?? Zone.root.run(http.Client.new);

  final http.Client _inner;

  /// Sarlavhalar ham trafik. Aniq baytini bilib bo'lmaydi (paket
  /// darajasida siqilgan bo'lishi mumkin), shu sabab taxminiy
  /// hisob: "nom: qiymat\r\n" uzunliklari yig'indisi.
  static int _headerBytes(Map<String, String> headers) {
    var n = 0;
    headers.forEach((k, v) => n += k.length + v.length + 4);
    return n;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final kind = NetMeter.kindOfUrl(request.url);
    final res = await _inner.send(request);
    NetMeter.instance.add(_headerBytes(res.headers), kind);
    final counted = res.stream.map((chunk) {
      NetMeter.instance.add(chunk.length, kind);
      return chunk;
    });
    return http.StreamedResponse(
      counted,
      res.statusCode,
      contentLength: res.contentLength,
      request: res.request,
      headers: res.headers,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
      reasonPhrase: res.reasonPhrase,
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
