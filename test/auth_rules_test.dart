// Ism va username qoidalarining testi.
//
// NEGA AYNAN SHULAR: bu ikki qoida ilovada ham, serverda ham
// takrorlanadi va ular buzilsa foydalanuvchi hisob ocha olmaydi
// yoki nomini o'zgartira olmaydi. Ikkovi ham sof funksiya —
// tarmoq ham, ekran ham kerak emas, ya'ni test bir zumda ishlaydi.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft/services/auth_service.dart';

void main() {
  group('nameProblem', () {
    test('bo\'sh ism qabul qilinmaydi', () {
      expect(AuthService.nameProblem(''), isNotNull);
      expect(AuthService.nameProblem('   '), isNotNull);
    });

    test('oddiy ism o\'tadi', () {
      expect(AuthService.nameProblem('Og\'abek'), isNull);
      expect(AuthService.nameProblem('User 1'), isNull);
    });

    test('emoji va belgilar taqiqlanmaydi', () {
      expect(AuthService.nameProblem('Ali 🐉'), isNull);
      expect(AuthService.nameProblem('★ Ali ★'), isNull);
    });

    test('$kNameMaxLength ta belgi o\'tadi, undan ortig\'i o\'tmaydi', () {
      expect(AuthService.nameProblem('a' * kNameMaxLength), isNull);
      expect(AuthService.nameProblem('a' * (kNameMaxLength + 1)), isNotNull);
    });

    test('emoji BITTA belgi bo\'lib sanaladi', () {
      // 20 ta emoji = 20 ta belgi (`String.length` bo'lsa 40 bo'lardi
      // va bu ism noo'rin rad etilardi).
      expect(AuthService.nameProblem('🐉' * kNameMaxLength), isNull);
      expect(
          AuthService.nameProblem('🐉' * (kNameMaxLength + 1)), isNotNull);
    });
  });

  group('usernameProblem', () {
    test('avtomatik beriladigan nomlar qoidaga to\'g\'ri keladi', () {
      // Server yangi hisobga aynan shunday nom qo'yadi.
      expect(AuthService.usernameProblem('user_1'), isNull);
      expect(AuthService.usernameProblem('user_12345'), isNull);
    });

    test('juda qisqa yoki juda uzun nom o\'tmaydi', () {
      expect(AuthService.usernameProblem('ab'), isNotNull);
      expect(AuthService.usernameProblem('a' * 16), isNotNull);
      expect(AuthService.usernameProblem('abc'), isNull);
      expect(AuthService.usernameProblem('a' * 15), isNull);
    });

    test('faqat harf, raqam va pastki chiziq', () {
      expect(AuthService.usernameProblem('ali_2024'), isNull);
      expect(AuthService.usernameProblem('ali 2024'), isNotNull);
      expect(AuthService.usernameProblem('ali-2024'), isNotNull);
      expect(AuthService.usernameProblem('ali🐉'), isNotNull);
    });
  });
}
