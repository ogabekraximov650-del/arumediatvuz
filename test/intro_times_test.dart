// Opening vaqtlari: bazada ham, ekranda ham AYNAN bir xil matn.
//
// NEGA BU TEST: bu qoida ikki joyda kerak (admin oynasi va
// pleyer). Nusxa ko'chirilsa ikkovi bir kun ajralib qolardi —
// shu sabab qoida bitta faylda va u test bilan qo'riqlanadi.
//
// Ustiga: pleyer admin YOZGAN matnga ishonmaydi. Xato yozuv
// oraliqni shunchaki "belgilanmagan" qiladi, ijroga tegmaydi.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft/services/intro_times.dart';

void main() {
  group('introMs', () {
    test('daqiqa:soniya', () {
      expect(introMs('5:14'), 314000);
      expect(introMs('6:44'), 404000);
      expect(introMs('05:14'), 314000);
      // Bo'shliq bilan yozilgan bo'lsa ham tushuniladi.
      expect(introMs(' 5 : 14 '), 314000);
    });

    test('soat bilan ham', () {
      expect(introMs('1:02:03'), (3600 + 123) * 1000);
    });

    test('yalang son — soniya (eski yozuvlar)', () {
      expect(introMs('314'), 314000);
      expect(introMs(314), 314000);
    });

    test('bo\'sh yoki xato yozuv — 0', () {
      expect(introMs(''), 0);
      expect(introMs(null), 0);
      expect(introMs('0'), 0);
      expect(introMs('salom'), 0);
      expect(introMs('5:ab'), 0);
      expect(introMs('1:2:3:4'), 0);
      expect(introMs('-5'), 0);
    });
  });

  group('introText', () {
    test('matn o\'z holicha qoladi', () {
      expect(introText('5:14'), '5:14');
    });

    test('eski soniya yozuvi 5:14 ga o\'giriladi', () {
      expect(introText(314), '5:14');
      expect(introText('404'), '6:44');
      // Soniya ikki xonali bo'lib to'ldiriladi.
      expect(introText(65), '1:05');
    });

    test('bo\'sh qoladigan holatlar', () {
      expect(introText(null), '');
      expect(introText(''), '');
      expect(introText('0'), '');
    });
  });

  group('normalizeIntroInput', () {
    test('ikki nuqta bilan yozilgan matn tegilmaydi', () {
      expect(normalizeIntroInput('5:14'), '5:14');
      expect(normalizeIntroInput(' 6:44 '), '6:44');
    });

    test('ikki nuqtasiz yozilgan raqam to\'g\'rilanadi', () {
      // Oxirgi ikki raqam — soniya.
      expect(normalizeIntroInput('514'), '5:14');
      expect(normalizeIntroInput('644'), '6:44');
      expect(normalizeIntroInput('12345'), '123:45');
      expect(normalizeIntroInput('44'), '0:44');
      expect(normalizeIntroInput('7'), '0:07');
    });

    test('bo\'sh va ma\'nosiz yozuv — bo\'sh satr', () {
      expect(normalizeIntroInput(''), '');
      expect(normalizeIntroInput('   '), '');
      expect(normalizeIntroInput('0'), '');
      expect(normalizeIntroInput('abc'), '');
    });

    test('to\'g\'rilangan matn keyin o\'qib bo\'ladi', () {
      // Yozish -> saqlash -> pleyer o'qishi: zanjir buzilmasin.
      expect(introMs(normalizeIntroInput('514')), 314000);
    });
  });

  group('introRangesOf', () {
    test('faqat TO\'G\'RI juftliklar olinadi', () {
      final ranges = introRangesOf({
        'intro_1': '5:14', 'intro_2': '6:44', // to'g'ri
        'intro_3': '', 'intro_4': '', // bo'sh
        'intro_5': '3:00', 'intro_6': '2:00', // oxiri boshidan kichik
        'intro_7': '10:00', 'intro_8': '', // yarim to'ldirilgan
        'intro_9': '20:00', 'intro_10': '21:30', // to'g'ri
      });
      expect(ranges.length, 2);
      expect(ranges[0], (314000, 404000));
      expect(ranges[1], (1200000, 1290000));
    });

    test('qism yo\'q bo\'lsa bo\'sh ro\'yxat', () {
      expect(introRangesOf(null), isEmpty);
      expect(introRangesOf(const {}), isEmpty);
    });

    test('5 tagacha oraliq qabul qilinadi', () {
      final ep = <String, dynamic>{};
      for (var i = 0; i < kIntroRows; i++) {
        ep['intro_${i * 2 + 1}'] = '${i + 1}:00';
        ep['intro_${i * 2 + 2}'] = '${i + 1}:30';
      }
      expect(introRangesOf(ep).length, kIntroRows);
    });
  });
}
