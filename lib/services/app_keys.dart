import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'rust_bridge.dart';

/// Ilovaning ASOSIY SHIFRLASH KALITINI boshqaradi.
///
/// ═══════════════════════════════════════════════════════════════
///  KALIT QAYERDA SAQLANADI
/// ═══════════════════════════════════════════════════════════════
///
///   Android Keystore (apparat himoyasi, telefon chipida)
///        └── EncryptedSharedPreferences  ← flutter_secure_storage
///              └── bizning 32 baytlik asosiy kalitimiz
///                    └── HKDF → har bir fayl uchun ALOHIDA kalit
///
/// Kalitning O'ZI hech qachon oddiy fayl sifatida diskda yotmaydi.
/// Uni o'qish uchun telefonning Keystore'iga murojaat qilish kerak,
/// bu esa faqat SHU ilova nomidan mumkin.
///
/// Kalit BIR MARTA — ilova birinchi ishga tushganda — yaratiladi va
/// keyin o'zgarmaydi. O'zgarsa, allaqachon shifrlangan barcha fayllar
/// o'qib bo'lmas holga kelardi.
class AppKeys {
  AppKeys._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _keyName = 'fulutter_master_key_v1';

  /// Ilova ishga tushganda (main() ichida, RustCore.init() dan keyin)
  /// bir marta chaqiriladi.
  ///
  /// MUHIM: bu hech qachon istisno tashlamaydi. Agar xavfsiz ombor
  /// biror sababdan ishlamasa (eski Android, buzilgan Keystore),
  /// shifrlash shunchaki YOQILMAYDI va ilova avvalgidek — ochiq
  /// holatda — ishlashda davom etadi. Ma'lumot yo'qolmaydi.
  static Future<bool> init() async {
    try {
      var hex = await _storage.read(key: _keyName);

      if (hex == null || hex.length != 64) {
        // Birinchi ishga tushish — yangi kalit yaratamiz.
        hex = RustCore.instance.generateMasterKey();
        if (hex.isEmpty) return false;
        await _storage.write(key: _keyName, value: hex);
      }

      return RustCore.instance.setMasterKey(hex);
    } catch (_) {
      // Xavfsiz ombor ishlamadi — shifrlashsiz davom etamiz.
      return false;
    }
  }
}
