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
import 'rust_bridge.dart';

/// Sarlavhalarni qo'shib yuboradigan klient.
class AppHttpClient extends http.BaseClient {
  final http.Client _inner;

  AppHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // ── HAR SO'ROV ALOHIDA IMZOLANADI ──────────────────────
    //
    // Ilgari bu yerda APK sertifikatining hash'i (o'zgarmas satr)
    // yuborilardi. U SIR EMAS — APK'ni ochgan har kim hisoblab
    // oladi — va O'ZGARMAYDI, ya'ni bir marta nusxa ko'chirilgach
    // abadiy ishlardi.
    //
    // Endi imzo har so'rovda qaytadan hisoblanadi va ichida VAQT,
    // METOD va YO'L bor (`RustCore.appSign` izohiga qarang):
    //   * ushlab olingan imzo 2 daqiqadan keyin o'lik;
    //   * bir yo'l uchun olingani boshqasiga yaramaydi.
    //
    // Sir Rust yadrosida turadi, Dart tomonida umuman yo'q.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sig = RustCore.instance.appSign(
      now,
      request.method,
      request.url.path,
    );
    // Yadro sirsiz yig'ilgan bo'lsa (ishlab chiqish rejimi) imzo
    // bo'sh keladi — o'shanda eski usulga qaytamiz, server ham
    // tekshiruvni o'chirgan bo'ladi.
    final value = sig.isNotEmpty ? sig : AppSignature.value;
    if (value.isNotEmpty) {
      request.headers['X-App-Sig'] = value;
    }
    if (kAppVersion.isNotEmpty) {
      request.headers['X-App-Version'] = kAppVersion;
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
