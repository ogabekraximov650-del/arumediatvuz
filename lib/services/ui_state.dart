// lib/services/ui_state.dart — QAYERDA EDIK.
//
// ═══════════════════════════════════════════════════════════════
//  NEGA KERAK (TOPILGAN XATO)
// ═══════════════════════════════════════════════════════════════
//
// Admin panelidan rasm yoki video tanlashga o'tilganda Android
// galereya ilovasini oldinga chiqaradi. Xotirasi kam telefonda
// tizim shu paytda ILOVANI BUTUNLAY YOPIB QO'YADI. Foydalanuvchi
// qaytganda ilova noldan ochiladi — ya'ni admin panelidan "otilib
// chiqib ketgan" bo'ladi.
//
// Buni ilova ichidagi hech qanday `Navigator` hiyla-nayrangi
// to'xtatolmaydi: jarayonning o'zi o'ldiriladi. Yagona yechim —
// "men admin panelida, fayl tanlayapman" degan belgini DISKKA
// yozib qo'yish va ilova qaytadan ochilganda o'sha joyni tiklash.
//
// Belgi AYNAN fayl tanlashdan oldin qo'yiladi va tanlash tugashi
// bilan olib tashlanadi. Shu sabab foydalanuvchi ilovani O'ZI
// yopsa (yoki orqaga qaytsa), admin paneli qayta ochilmaydi.

import 'rust_bridge.dart';

class UiState {
  const UiState._();

  static const String _key = 'ui_state';
  static const String _pickerField = 'admin_picker';

  static Map<String, dynamic> _read() {
    try {
      final rows = RustCore.instance.getCachedList(_key);
      if (rows != null && rows.isNotEmpty) return rows.first;
    } catch (_) {}
    return <String, dynamic>{};
  }

  static void _write(Map<String, dynamic> data) {
    try {
      RustCore.instance.saveListCache(_key, [data]);
    } catch (_) {
      // Yozilmasa ham ilova ishlayveradi — faqat tiklash bo'lmaydi.
    }
  }

  /// Admin panelida fayl tanlash oynasi ochilgan.
  static bool get adminPicking => _read()[_pickerField] == true;

  static void setAdminPicking(bool value) {
    final data = _read();
    if ((data[_pickerField] == true) == value) return;
    data[_pickerField] = value;
    _write(data);
  }

  /// Ilova ochilganda bir marta so'raladi: admin panelini qaytadan
  /// ochish kerakmi? Javob "ha" bo'lsa, belgi darhol tozalanadi —
  /// bu takrorlanmasligi kerak.
  static bool takeAdminRestore() {
    if (!adminPicking) return false;
    setAdminPicking(false);
    return true;
  }
}
