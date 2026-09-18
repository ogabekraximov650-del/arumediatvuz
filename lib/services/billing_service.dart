// lib/services/billing_service.dart — BALANS, OBUNA VA TO'LOVLAR.
//
// ═══════════════════════════════════════════════════════════════
//  PUL BILAN BOG'LIQ HAR BIR QAROR SERVERDA
// ═══════════════════════════════════════════════════════════════
//
// Bu yerda hech qanday narx, hech qanday hisob-kitob YO'Q. Ilova
// faqat so'raydi va ko'rsatadi:
//
//   * tariflar ro'yxati va narxi — SERVERDAN keladi
//     (`worker/src/lib.rs` -> `PLANS`);
//   * balans va obuna muddati — serverdan;
//   * to'lov haqiqatan bo'lganini tezchek.uz tasdiqlaydi, worker
//     esa balansni BIR MARTA oshiradi.
//
// Ya'ni o'zgartirilgan ilova bilan ham 30 kunlik obunani 1 so'mga
// olib bo'lmaydi.
//
// ── NEGA `SyncQueue` GA TUSHMAYDI ────────────────────────────
//
// Qolgan hamma yozuv (tarix, baho, sevimlilar) telefonda yig'ilib,
// kuniga bir necha marta paket bo'lib ketadi. Pul esa BOSHQACHA:
//
//   * to'lov havolasi DARHOL kerak (foydalanuvchi kutib turibdi);
//   * "Tekshirish" ham darhol javob berishi kerak;
//   * obuna sotib olinganda balans shu zahoti kamayishi kerak.
//
// Ustiga bu so'rovlar kamdan-kam bo'ladi (oyiga bir necha marta),
// ya'ni kunlik so'rov chegarasiga sezilarli ta'sir qilmaydi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'rust_bridge.dart';

/// Bitta obuna tarifi.
@immutable
class SubPlan {
  final int days;
  final int price;
  const SubPlan(this.days, this.price);

  /// Necha oylik (30 kun = 1 oy). 365 kun — 12 oy deb olinadi.
  int get months => days >= 365 ? 12 : (days / 30).round();
}

/// Tarif nomi: "1 oylik", "3 oylik", ...
///
/// O'ZGARDI (foydalanuvchi talabi): tariflar endi OYLIK
/// (kunlik mayda tariflar olib tashlandi). Kutilmagan kunlik
/// qiymat kelsa — eski ko'rinishga qaytadi.
String planLabel(int days) {
  if (days >= 365) return '12 oylik';
  if (days > 0 && days % 30 == 0) return '${days ~/ 30} oylik';
  return '$days kunlik';
}

/// Faol to'lov havolasi.
@immutable
class PayLink {
  final String orderId;
  final int amount;
  final String url;

  /// Havola qachon o'ladi (Unix ms).
  final int expiresAt;

  const PayLink({
    required this.orderId,
    required this.amount,
    required this.url,
    required this.expiresAt,
  });

  /// Qancha vaqt qoldi.
  Duration get left {
    final ms = expiresAt - DateTime.now().millisecondsSinceEpoch;
    return ms <= 0 ? Duration.zero : Duration(milliseconds: ms);
  }

  bool get alive => left > Duration.zero;
}

/// Tarix oynasidagi bitta yozuv.
@immutable
class BillingEntry {
  /// `topup` — balans to'ldirildi, `subscription` — obuna olindi.
  final String kind;

  /// So'mda. To'ldirishda musbat, obunada manfiy.
  final int amount;

  /// Obuna kunlari (to'ldirishda 0).
  final int days;
  final String note;
  final int createdAt;

  const BillingEntry({
    required this.kind,
    required this.amount,
    required this.days,
    required this.note,
    required this.createdAt,
  });

  bool get isTopUp => kind == 'topup';
}

class BillingService extends ChangeNotifier {
  BillingService._();
  static final BillingService instance = BillingService._();

  int _balance = 0;
  int _until = 0;
  List<SubPlan> _plans = const [];
  List<PayLink> _links = const [];
  List<BillingEntry> _history = const [];
  bool _loading = false;
  bool _loaded = false;
  String? _error;

  int get balance => _balance;

  /// Obuna qachon tugaydi (Unix ms). 0 — obuna yo'q.
  int get until => _until;

  bool get active =>
      _until > DateTime.now().millisecondsSinceEpoch;

  /// Obunaga necha kun qolgan (faol bo'lmasa 0).
  int get daysLeft {
    final ms = _until - DateTime.now().millisecondsSinceEpoch;
    if (ms <= 0) return 0;
    return (ms / 86400000).ceil();
  }

  /// Obunaga qancha vaqt qolgani — ANIQ.
  ///
  /// TALAB (foydalanuvchi): "obuna tugash vaqti kun, soat, daqiqa
  /// va sekundda ko'rsatilsin".
  Duration get left {
    final ms = _until - DateTime.now().millisecondsSinceEpoch;
    return ms <= 0 ? Duration.zero : Duration(milliseconds: ms);
  }

  List<SubPlan> get plans => _plans;
  List<PayLink> get links => _links;
  List<BillingEntry> get history => _history;
  bool get isLoading => _loading;
  bool get hasData => _loaded;
  String? get error => _error;

  Map<String, String> _headers({bool json = false}) {
    final t = AuthService.instance.sessionToken;
    return {
      if (t != null) 'Authorization': 'Bearer $t',
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// Hisob almashganda yoki chiqilganda — XOTIRA bo'shatiladi.
  ///
  /// Diskka HECH NARSA yozilmaydi. Sabab: bu chaqiruv papka
  /// allaqachon YANGI hisobga almashtirilgandan keyin sodir
  /// bo'ladi (`account_data.dart` -> `switchTo`), ya'ni bu yerda
  /// saqlash yangi hisobning obunasini nolga tushirib yuborardi.
  /// Yangi hisobning yozuvi keyin `restore()` bilan o'qiladi.
  void clear() {
    _balance = 0;
    _until = 0;
    _links = const [];
    _history = const [];
    _loaded = false;
    _error = null;
    notifyListeners();
  }

  // ── OBUNA MUDDATI TELEFONDA HAM SAQLANADI ───────────────────
  //
  // NEGA KERAK: obunasi yo'q odam anime ko'ra olmaydi. Agar
  // obuna muddati FAQAT serverdan kelsa, interneti uzilgan
  // PUL TO'LAGAN odam ham yuklab olingan animesini ocha olmay
  // qolardi — ya'ni to'siq noto'g'ri odamga tushardi.
  //
  // Shu sabab muddat oxirgi marta serverdan kelgan holida
  // hisobning o'z papkasiga yoziladi va ilova ochilganda darhol
  // o'qiladi. Bu xavfsizlikni bo'shashtirmaydi: muddat baribir
  // SERVER bergan sana, ilova uni o'zi cho'za olmaydi, va
  // o'tib ketgan sana hech qanday holatda faol hisoblanmaydi.
  static const String _cacheKey = 'billing';

  /// Diskdagi oxirgi ma'lum holatni o'qiydi (tarmoqsiz).
  void restore() {
    try {
      final rows = RustCore.instance.getCachedList(_cacheKey);
      if (rows == null || rows.isEmpty) return;
      final m = rows.first;
      _balance = ((m['balance'] as num?) ?? 0).toInt();
      _until = ((m['until'] as num?) ?? 0).toInt();
      notifyListeners();
    } catch (_) {}
  }

  void _saveLocal() {
    try {
      RustCore.instance.saveListCache(_cacheKey, [
        {'balance': _balance, 'until': _until},
      ]);
    } catch (_) {}
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    if (AuthService.instance.sessionToken == null) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await http
          .get(Uri.parse('$kApiBase/api/billing'), headers: _headers())
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        _apply(jsonDecode(r.body) as Map<String, dynamic>);
        _loaded = true;
      } else {
        _error = 'Ma\'lumot olinmadi (${r.statusCode})';
      }
    } catch (_) {
      _error = 'Internet yo\'q';
    }
    _loading = false;
    notifyListeners();
  }

  void _apply(Map<String, dynamic> j) {
    _balance = ((j['balance'] as num?) ?? 0).toInt();
    _until = ((j['subscription_until'] as num?) ?? 0).toInt();
    _plans = ((j['plans'] as List?) ?? [])
        .map((e) => SubPlan(
              ((e['days'] as num?) ?? 0).toInt(),
              ((e['price'] as num?) ?? 0).toInt(),
            ))
        .where((p) => p.days > 0)
        .toList();
    _links = ((j['links'] as List?) ?? [])
        .map((e) => PayLink(
              orderId: '${e['order_id'] ?? ''}',
              amount: ((e['amount'] as num?) ?? 0).toInt(),
              url: '${e['pay_url'] ?? ''}',
              expiresAt: ((e['expires_at'] as num?) ?? 0).toInt(),
            ))
        .where((l) => l.url.isNotEmpty)
        .toList();
    _history = ((j['history'] as List?) ?? [])
        .map((e) => BillingEntry(
              kind: '${e['kind'] ?? ''}',
              amount: ((e['amount'] as num?) ?? 0).toInt(),
              days: ((e['days'] as num?) ?? 0).toInt(),
              note: '${e['note'] ?? ''}',
              createdAt: ((e['created_at'] as num?) ?? 0).toInt(),
            ))
        .toList();
    _saveLocal();
  }

  /// To'lov havolasi yaratadi.
  ///
  /// Qaytaradi: xato matni (bo'lsa) va TO'LOV HAVOLASI.
  ///
  /// ── NEGA HAVOLA HAM QAYTADI ─────────────────────────────
  ///
  /// TALAB (foydalanuvchi): "balans to'ldirishda turmoqchi
  /// bo'lgan summani yozgach to'g'ri havolaga yo'naltirilsin".
  ///
  /// Ilgari bu metod faqat xatoni qaytarardi: havola ro'yxatga
  /// tushar, odam esa uni ko'rib, ustidagi "To'lash" tugmasini
  /// ALOHIDA bosishi kerak edi — ya'ni bitta ortiqcha qadam.
  /// Endi ekran havolani shu yerdan olib, brauzerni o'zi ochadi.
  ///
  /// Havola ro'yxatda baribir qoladi: brauzer ochilmay qolsa yoki
  /// odam uni yopib yuborsa, qaytadan ochish imkoni bo'lishi
  /// kerak.
  Future<({String? error, String? url})> createLink(int amount) async {
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/billing/create'),
            headers: _headers(json: true),
            body: jsonEncode({'amount': amount}),
          )
          .timeout(const Duration(seconds: 25));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return (error: '${j['error'] ?? 'Havola yaratilmadi'}', url: null);
      }
      final url = '${j['pay_url'] ?? ''}';
      // Ro'yxat yangilansin — yangi havola darhol ko'rinadi.
      await load(force: true);
      return (error: null, url: url.isEmpty ? null : url);
    } catch (_) {
      return (
        error: 'Internet yo\'q — qaytadan urinib ko\'ring',
        url: null,
      );
    }
  }

  /// To'lov bo'ldimi? `true` — pul tushdi va balans oshdi.
  Future<({bool paid, String? error})> check(String orderId) async {
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/billing/check'),
            headers: _headers(json: true),
            body: jsonEncode({'order_id': orderId}),
          )
          .timeout(const Duration(seconds: 25));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return (paid: false, error: '${j['error'] ?? 'Tekshirib bo\'lmadi'}');
      }
      final paid = j['status'] == 'paid';
      if (paid) await load(force: true);
      return (paid: paid, error: null);
    } catch (_) {
      return (paid: false, error: 'Internet yo\'q');
    }
  }

  /// Obuna sotib oladi. Xato bo'lsa matn qaytadi.
  Future<String?> subscribe(int days) async {
    try {
      final r = await http
          .post(
            Uri.parse('$kApiBase/api/billing/subscribe'),
            headers: _headers(json: true),
            body: jsonEncode({'days': days}),
          )
          .timeout(const Duration(seconds: 25));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return '${j['error'] ?? 'Obuna olinmadi'}';
      }
      await load(force: true);
      return null;
    } catch (_) {
      return 'Internet yo\'q — qaytadan urinib ko\'ring';
    }
  }
}

/// Qolgan vaqt: `2 kun 05:12:33` yoki `05:12:33`.
///
/// TALAB (foydalanuvchi): "obuna tugash vaqti kun, soat, daqiqa va
/// sekundda ko'rsatilsin".
///
/// Kun bo'lmasa u yozilmaydi — `0 kun 05:12:33` ortiqcha va
/// chalkashtiradi.
String formatLeft(Duration d) {
  if (d <= Duration.zero) return 'tugadi';
  String two(int n) => n.toString().padLeft(2, '0');
  final days = d.inDays;
  final h = d.inHours % 24;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final clock = '${two(h)}:${two(m)}:${two(s)}';
  return days > 0 ? '$days kun $clock' : clock;
}

/// Qisqa ko'rinish (tor joylar uchun): `2 kun` yoki `05:12:33`.
String formatLeftShort(Duration d) {
  if (d <= Duration.zero) return 'tugadi';
  if (d.inDays > 0) return '${d.inDays} kun';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

/// Summani `15 000 so'm` ko'rinishida yozadi.
String formatSum(int amount) {
  final n = amount.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < n.length; i++) {
    if (i > 0 && (n.length - i) % 3 == 0) buf.write(' ');
    buf.write(n[i]);
  }
  return '$buf so\'m';
}

/// Obuna qolgan vaqtini HAR SONIYADA yangilab turadigan widget.
///
/// TALAB (foydalanuvchi): "obuna tugash vaqti kun, soat, daqiqa va
/// sekundda ko'rsatilsin".
///
/// ── NEGA ALOHIDA WIDGET ─────────────────────────────────────
///
/// Sekund har soniyada o'zgaradi, ya'ni kimdir har soniyada qayta
/// chizishi kerak. Agar buni butun sahifa qilsa — profil, trafik
/// jadvali, statistika, hammasi har soniyada qaytadan chizilardi.
///
/// Shu sabab taymer AYNAN shu kichkina widgetning ichida: faqat
/// yozuvning o'zi yangilanadi, qolgan ekran tegilmaydi.
class SubCountdown extends StatefulWidget {
  /// Qisqa ko'rinish (tor joylar uchun).
  final bool short;
  final TextStyle? style;

  /// Obuna yo'q bo'lsa nima yozilsin.
  final String expired;

  const SubCountdown({
    super.key,
    this.short = false,
    this.style,
    this.expired = 'Yo\'q',
  });

  @override
  State<SubCountdown> createState() => _SubCountdownState();
}

class _SubCountdownState extends State<SubCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BillingService.instance,
      builder: (context, _) {
        final d = BillingService.instance.left;
        final text = d <= Duration.zero
            ? widget.expired
            : (widget.short ? formatLeftShort(d) : formatLeft(d));
        return Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        );
      },
    );
  }
}
