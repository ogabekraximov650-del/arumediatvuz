// lib/services/app_notifier.dart — BILDIRISHNOMALARNI BOSHQARISH.
//
// ═══════════════════════════════════════════════════════════════
//  NIMA UCHUN
// ═══════════════════════════════════════════════════════════════
//
// TALAB (foydalanuvchi): "xabar yoki chaqiruv kelganda ilovani
// qaysi joyida o'tirgan bo'lsam ham yuqoridan bildirishnoma
// chiqishi kerak; agar iloji bo'lsa telefon bildirishnomasida ham
// chiqishi kerak. Xabar kelganda ilova tepasida bildirishnoma 5
// soniya ko'rsatilishi kerak, ovoz chiqishi kerak va ustiga bossa
// chatga o'tishi kerak. Agar pleyerda o'tirgan bo'lsa 5 soniyaga
// video ovozi pasayib bildirishnoma ovozi eshitilishi kerak".
//
// ── BU FAYL NIMANI ULAYDI ─────────────────────────────────────
//
//   RealtimeService  →  voqealar keladi (yangi xabar, qo'ng'iroq)
//   AppNotice        →  ilova ustidagi banner
//   CallNotice       →  kelayotgan qo'ng'iroq banneri
//   CallSounds       →  ovoz (va pleyerni pasaytirish)
//   flutter_local_notifications → telefonning o'z bildirishnomasi
//
// Ularning hech biri bir-birini bilmaydi va bilmasligi ham kerak.
// Bog'lovchi — faqat mana shu fayl.
//
// ── ILOVA YOPIQ BO'LSA ────────────────────────────────────────
//
// Ilova OCHIQ yoki FONDA turganda hammasi ishlaydi: ulanish tirik
// va voqea darhol keladi.
//
// Ilova BUTUNLAY yopilganda esa Android jarayonni o'ldiradi va
// ulanish ham uziladi. Bunda xabar yetib borishi uchun push
// xizmati (FCM) kerak — u Firebase hisobi va `google-services.json`
// talab qiladi, ya'ni alohida ish. Shu sabab hozircha yopiq ilova
// qamrab olinmagan.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../screens/call_screen.dart';
import '../screens/support_chat_screen.dart';
import '../widgets/app_notice.dart';
import 'auth_service.dart';
import 'call_service.dart';
import 'call_sounds.dart';
import 'realtime_service.dart';
import 'support_service.dart';

class AppNotifier with WidgetsBindingObserver {
  AppNotifier._();
  static final AppNotifier instance = AppNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  StreamSubscription<RtEvent>? _sub;
  bool _started = false;

  /// Ilova hozir ekranda ko'rinib turibdimi.
  ///
  /// Shunga qarab hal qilinadi: ilova ichidagi banner chiqsinmi
  /// (ko'rinib turgan bo'lsa) yoki telefonning o'z bildirishnomasi
  /// (fonda bo'lsa). Ikkalasini birdan chiqarish ortiqcha
  /// shovqin bo'lardi.
  bool _foreground = true;

  /// Hozir qaysi suhbat ochiq (`null` — hech qaysi).
  ///
  /// Ochiq suhbatdagi xabar uchun banner CHIQMAYDI: odam uni
  /// allaqachon ko'rib turibdi. Telegram ham shunday qiladi.
  int? _openThread;
  bool _chatOpen = false;

  // ── ISHGA TUSHIRISH ─────────────────────────────────────────

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);

    // ── TELEFONNING O'Z BILDIRISHNOMASI ───────────────────
    //
    // Ruxsat SO'RALMAYDI: Android 13+ da uni so'rash uchun
    // to'g'ri payt kerak (ilova birinchi ochilganda emas). Bu
    // yerda faqat tayyorlanadi; ruxsat bo'lmasa tizim
    // bildirishnomani jimgina tashlab yuboradi va ilova ichidagi
    // banner baribir ishlayveradi.
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (r) => _openChat(),
      );
    } catch (e) {
      debugPrint('AppNotifier.init: $e');
    }

    _sub = RealtimeService.instance.events.listen(_onEvent);
    CallService.instance.listen();
    CallService.instance.onIncoming = _onIncomingCall;

    await connectIfLoggedIn();
  }

  /// Hisobga kirilgan bo'lsa ulanadi.
  ///
  /// Kirish va chiqishdan keyin ham chaqiriladi — ulanish
  /// hisobsiz ma'noga ega emas.
  Future<void> connectIfLoggedIn() async {
    if (AuthService.instance.sessionToken == null) {
      await RealtimeService.instance.disconnect();
      return;
    }
    await RealtimeService.instance.connect();
  }

  /// Chat ekrani ochilganda/yopilganda xabar beradi.
  ///
  /// NEGA KERAK: ochiq suhbatga kelgan xabar uchun banner
  /// ko'rsatishning ma'nosi yo'q — u allaqachon ekranda.
  void chatOpened(int? threadUser) {
    _chatOpen = true;
    _openThread = threadUser;
  }

  void chatClosed() {
    _chatOpen = false;
    _openThread = null;
    // Chat yopildi — umumiy ulanishga qaytamiz (chat ekrani uni
    // o'z suhbatiga burib qo'ygan bo'lishi mumkin).
    unawaited(connectIfLoggedIn());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      // Fondan qaytdik: ulanish uzilgan bo'lishi mumkin, holatni
      // qaytadan so'raymiz.
      RealtimeService.instance.resync();
      unawaited(connectIfLoggedIn());
    }
  }

  // ── VOQEALAR ────────────────────────────────────────────────

  void _onEvent(RtEvent e) {
    if (e.type != 'chat') return;
    if ('${e.data['action'] ?? ''}' != 'new') return;

    final msg = e.data['message'];
    if (msg is! Map) return;

    // ── O'Z XABARIM BO'LSA JIM ────────────────────────────
    //
    // Voqea IKKALA tomonga ham boradi (xabar bir necha
    // qurilmada ochiq bo'lishi mumkin), shu sabab o'z
    // xabaringiz ham qaytib keladi. Uning uchun bildirishnoma
    // chiqarish g'alati bo'lardi.
    final fromAdmin = msg['from_admin'] == true;
    final iAmAdmin = AuthService.instance.user?.isAdmin == true;
    if (fromAdmin == iAmAdmin) return;

    final threadUser = (e.data['user_id'] as num?)?.toInt();
    // Ochiq suhbatdagi xabar — banner kerak emas.
    if (_chatOpen && (_openThread == null || _openThread == threadUser)) {
      return;
    }

    // Kim yozgani — adminning bannerida aynan shu kerak
    // (suhbat ko'p, "Yangi xabar" degani hech narsa aytmaydi).
    final from = '${e.data['from_name'] ?? ''}'.trim();
    final avatar = '${e.data['from_avatar'] ?? ''}';
    final body = _preview(msg);
    // Ovoz: pleyerda bo'lsa video ovozi 5 soniyaga pasayadi
    // (`CallSounds._duck`).
    unawaited(CallSounds.instance.play(AppSound.message, duck: true));

    // Foydalanuvchi uchun suhbatdosh HAR DOIM admin, ya'ni ism
    // o'rniga ilova nomi turadi. Admin uchun esa — yozgan odam.
    final title = fromAdmin
        ? 'ARUmediaTV'
        : (from.isEmpty ? 'Yangi xabar' : from);

    if (_foreground) {
      AppNotice.show(
        title: title,
        body: body,
        avatar: fromAdmin ? '' : avatar,
        onTap: () => _openChat(threadUser: fromAdmin ? null : threadUser,
            title: title, avatar: avatar),
      );
    } else {
      unawaited(_systemNotice(title, body));
    }

    // Profil sahifasidagi nuqta ham yangilansin.
    unawaited(UnreadBadge.instance.refresh());
  }

  /// Xabarning qisqa ko'rinishi.
  static String _preview(Map msg) {
    final body = '${msg['body'] ?? ''}'.trim();
    if (body.isNotEmpty) return body;
    return switch ('${msg['media_type'] ?? ''}') {
      'voice' => 'Ovozli xabar',
      'video' => 'Video',
      'image' => 'Rasm',
      _ => 'Xabar',
    };
  }

  /// Kelayotgan qo'ng'iroq.
  void _onIncomingCall() {
    final call = CallService.instance;
    if (_foreground) {
      // ── BANNER, DARHOL OYNA EMAS ──────────────────────────
      //
      // TALAB (foydalanuvchi): "qo'ng'iroq kelganda ilova
      // tepasida chap tarafda profil rasmi, yonida nomi va
      // useri; o'ng tarafida yashil qabul qilish va qizil bekor
      // qilish trubkalari bo'lsin".
      //
      // Ya'ni odam ko'rayotgan ishini to'liq ekran bilan
      // to'satdan to'smaydi — banner chiqadi, qaror o'zi
      // qabul qiladi.
      CallNotice.show(
        name: call.peerName,
        username: call.peerUsername,
        avatar: call.peerAvatar,
        onAccept: () {
          unawaited(call.accept());
          _openCall();
        },
        onDecline: () => unawaited(call.decline()),
        onOpen: _openCall,
      );
    } else {
      unawaited(_systemNotice(
        call.peerName.isEmpty ? 'Qo\'ng\'iroq' : call.peerName,
        'Sizga qo\'ng\'iroq qilinmoqda',
        urgent: true,
      ));
    }
  }

  // ── OCHISH ──────────────────────────────────────────────────

  /// Bannerga bosilganda suhbatni ochadi.
  ///
  /// `threadUser` — ADMIN uchun: kimning suhbati. Foydalanuvchi
  /// uchun har doim `null` (uning suhbati bitta).
  void _openChat({int? threadUser, String title = '', String avatar = ''}) {
    AppNotice.hide();
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    // Chat allaqachon ochiq bo'lsa ikkinchisini ustiga qo'ymaymiz.
    if (_chatOpen) return;
    nav.push(MaterialPageRoute<void>(
      builder: (_) => SupportChatScreen(
        userId: threadUser,
        title: title.isEmpty ? 'ARUmediaTV' : title,
        photoUrl: avatar,
      ),
    ));
  }

  void _openCall() {
    CallNotice.hide();
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    unawaited(openCallScreen(ctx));
  }

  // ── TELEFONNING O'Z BILDIRISHNOMASI ─────────────────────────

  /// Ilova fonda bo'lganda tizim bildirishnomasini chiqaradi.
  ///
  /// Xatolar yutiladi: ruxsat berilmagan bo'lsa yoki kanal
  /// yaratilmagan bo'lsa ilova to'xtamasligi kerak.
  Future<void> _systemNotice(
    String title,
    String body, {
    bool urgent = false,
  }) async {
    try {
      final android = AndroidNotificationDetails(
        urgent ? 'aru_calls' : 'aru_chat',
        urgent ? 'Qo\'ng\'iroqlar' : 'Xabarlar',
        importance: urgent ? Importance.max : Importance.high,
        priority: urgent ? Priority.max : Priority.high,
        // Qo'ng'iroq — to'liq ekranga chiqishi kerak bo'lgan
        // shoshilinch bildirishnoma.
        category: urgent
            ? AndroidNotificationCategory.call
            : AndroidNotificationCategory.message,
      );
      await _plugin.show(
        urgent ? 1 : 2,
        title,
        body,
        NotificationDetails(android: android),
      );
    } catch (e) {
      debugPrint('AppNotifier._systemNotice: $e');
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }
}
