import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:url_launcher/url_launcher.dart';

/// QAYSI TELEGRAM BILAN OCHISH.
///
/// MUAMMO. Telefonda bir nechta Telegram bo'lishi mumkin: rasmiy
/// Telegram, Telegram X, Plus Messenger va boshqalar. `url_launcher`
/// havolani tizimning STANDART ilovasiga beradi — ya'ni foydalanuvchi
/// Telegramni ishlatsa ham, tizim Telegram X ni tanlab qo'ygan
/// bo'lsa, havola o'shanga ketadi va tanlash imkoni berilmaydi.
///
/// YECHIM. Ilovaning o'zi qaysi Telegramlar o'rnatilganini bilib
/// oladi va ANIQ paketga havola yuboradi. Bitta bo'lsa — to'g'ridan-
/// to'g'ri, bir nechta bo'lsa — foydalanuvchidan so'raydi.
///
/// MUHIM: Android 11+ da ilova boshqa ilovaning borligini faqat
/// manifestdagi `<queries>` ro'yxatidagilar uchun bila oladi. Shu
/// sabab quyidagi paketlar CI'da manifestga `<package>` sifatida
/// qo'shiladi (`build-flutter-apk.yml`). Ro'yxatga yangi ilova
/// qo'shsangiz, o'sha yerga ham qo'shing — aks holda u topilmaydi.
class TelegramApp {
  /// Android paket nomi (`org.telegram.messenger` kabi).
  final String package;

  /// Foydalanuvchiga ko'rsatiladigan nom.
  final String name;

  const TelegramApp(this.package, this.name);
}

/// Ma'lum Telegram ilovalari. Tartib muhim: ro'yxatda ham shu
/// tartibda chiqadi, ya'ni rasmiy Telegram birinchi turadi.
const List<TelegramApp> kKnownTelegramApps = [
  TelegramApp('org.telegram.messenger', 'Telegram'),
  TelegramApp('org.telegram.messenger.web', 'Telegram (Web)'),
  TelegramApp('org.telegram.messenger.beta', 'Telegram Beta'),
  TelegramApp('org.thunderdog.challegram', 'Telegram X'),
  TelegramApp('org.telegram.plus', 'Plus Messenger'),
  TelegramApp('nekox.messenger', 'NekoX'),
  TelegramApp('ir.ilmili.telegraph', 'Telegraph'),
  TelegramApp('org.forkgram.messenger', 'Forkgram'),
];

class TelegramLauncher {
  /// Telefonda o'rnatilgan Telegram ilovalari.
  ///
  /// Android'dan boshqa tizimda bo'sh ro'yxat qaytadi — u yerda
  /// odatdagi havola ochish yo'li ishlatiladi.
  static Future<List<TelegramApp>> installed(String link) async {
    if (!Platform.isAndroid) return const [];
    final found = <TelegramApp>[];
    for (final app in kKnownTelegramApps) {
      try {
        final intent = AndroidIntent(
          action: 'action_view',
          data: link,
          package: app.package,
        );
        if (await intent.canResolveActivity() ?? false) {
          found.add(app);
        }
      } catch (_) {
        // Bitta ilovani tekshirib bo'lmasa qolganlari tekshiriladi.
      }
    }
    return found;
  }

  /// Havolani ANIQ ilova bilan ochadi.
  static Future<bool> openWith(TelegramApp app, String link) async {
    try {
      await AndroidIntent(
        action: 'action_view',
        data: link,
        package: app.package,
      ).launch();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Zaxira yo'l: tizimning o'zi hal qilsin.
  ///
  /// `canLaunchUrl` ATAYLAB ishlatilmaydi — Android 11+ da u
  /// `<queries>` e'lonini talab qiladi va ochilishi mumkin bo'lgan
  /// havola uchun ham `false` qaytarishi mumkin.
  static Future<bool> openDefault(String link) async {
    try {
      return await launchUrl(Uri.parse(link),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
