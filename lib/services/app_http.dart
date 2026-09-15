// lib/services/app_http.dart — HAR SO'ROVGA ILOVA BELGISI.
//
// ═══════════════════════════════════════════════════════════════
//  TALAB
// ═══════════════════════════════════════════════════════════════
//
// Foydalanuvchi: "Workerni faqat ilovaga javob beradigan qil,
// tashqi so'rovlar rad etilsin va hujumlarga chidamli qil" hamda
// "Worker shu va shundan katta versiyalarda ishlaydi, agar
// versiya past bo'lsa ishlamaydi".
//
// ── NEGA SHU YERDA, HAR SERVISDA EMAS ───────────────────────
//
// Ilovada o'nlab joyda `http.get` / `http.post` bor. Har biriga
// qo'lda sarlavha qo'shish — bittasini unutib qo'yish demakdir,
// va o'sha bitta so'rov server tomonidan rad etilardi.
//
// `runWithClient` butun ilovani O'RAB oladi: undan keyin
// `package:http` ning BARCHA chaqiruvlari shu klientdan o'tadi
// va sarlavhalar o'z-o'zidan qo'shiladi. Servislarga umuman
// tegilmaydi.
//
// Rust yadrosi (video yuklash) bu yo'ldan O'TMAYDI — u o'z
// so'rovlarini o'zi yuboradi. Shu sabab serverda video yo'llari
// tekshiruvdan ozod (`needs_app_check` izohiga qarang).

import 'package:http/http.dart' as http;

import 'app_build.dart';

/// Sarlavhalarni qo'shib yuboradigan klient.
class AppHttpClient extends http.BaseClient {
  final http.Client _inner;

  AppHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // Imzo yoki versiya berilmagan bo'lsa sarlavha ham
    // qo'shilmaydi — server bunday holatda tekshiruvni o'chirib
    // qo'ygan bo'lsa ilova baribir ishlaydi.
    final sig = AppSignature.value;
    if (sig.isNotEmpty) {
      request.headers['X-App-Sig'] = sig;
    }
    if (kAppVersion.isNotEmpty) {
      request.headers['X-App-Version'] = kAppVersion;
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
