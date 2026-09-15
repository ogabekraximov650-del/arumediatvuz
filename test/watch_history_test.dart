// Tomosha tarixi qoidalarining testi.
//
// NEGA AYNAN SHULAR: ikkovi ham foydalanuvchi KO'RGAN xatolarni
// qo'riqlaydi va ikkovi ham sof funksiya — tarmoq ham, ekran ham
// kerak emas, ya'ni test bir zumda ishlaydi.
//
//   * chegaralar qism uzunligiga bog'liq. Qat'iy 15/30 soniya
//     bo'lganda 17 soniyalik qism tarixga UMUMAN tushmasdi va har
//     safar boshidan ochilardi;
//   * kadr kaliti ANIQ millisekundga bog'langan. Ilgari 10
//     soniyaga yaxlitlanardi va tarixdagi rasm to'xtagan joydan
//     bir necha soniya narida bo'lardi.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft/services/watch_history.dart';
import 'package:soft/services/watch_progress.dart';

void main() {
  group('chegaralar qism uzunligiga bog\'liq', () {
    test('uzun qismda eski qiymatlar saqlanadi', () {
      const uzun = Duration(minutes: 24);
      expect(WatchProgress.minPositionFor(uzun), const Duration(seconds: 15));
      expect(WatchProgress.endMarginFor(uzun), const Duration(seconds: 30));
    });

    test('17 soniyalik qism ham eslab qolinadi', () {
      const qisqa = Duration(seconds: 17);
      final min = WatchProgress.minPositionFor(qisqa);
      final end = WatchProgress.endMarginFor(qisqa);
      // Chegaralar qismning ichiga sig'ishi SHART — aks holda
      // saqlanadigan oraliq umuman qolmaydi.
      expect(min.inMilliseconds, lessThan(qisqa.inMilliseconds ~/ 2));
      expect(end.inMilliseconds, lessThan(qisqa.inMilliseconds ~/ 2));
      expect(min + end, lessThan(qisqa));
    });

    test('55 soniyalik qismda ham saqlanadigan oraliq bor', () {
      const q = Duration(seconds: 55);
      expect(WatchProgress.minPositionFor(q) + WatchProgress.endMarginFor(q),
          lessThan(q));
    });
  });

  group('HistoryItem', () {
    HistoryItem item({
      String seasonName = 'Birinchi bo\'lim',
      String animeName = 'Anime nomi',
      int bolimId = 1,
      int seasonId = 7,
      int position = 12345,
      int duration = 100000,
      String url = 'https://x.example/video/ep1_720p.mp4?token=abc',
    }) =>
        HistoryItem.fromJson({
          'anime_id': 3,
          'season_id': seasonId,
          'bolim_id': bolimId,
          // Kalit — qismning O'ZGARMAS IDsi; raqam faqat
          // ko'rsatish uchun.
          'epizod_id': 42,
          'epizod_number': 2,
          'anime_name': animeName,
          'season_name': seasonName,
          'anime_photo': '',
          'season_photo': '',
          'video_url': url,
          'position_ms': position,
          'duration_ms': duration,
          'updated_at': 1767200760000,
        });

    test('sarlavha — BO\'LIM nomi, anime nomi emas', () {
      expect(item().title, 'Birinchi bo\'lim');
    });

    test('bo\'lim nomi bo\'lmasa anime nomiga tushadi', () {
      expect(item(seasonName: '').title, 'Anime nomi');
      expect(item(seasonName: '', animeName: '').title, 'Anime');
    });

    test('bo\'lim raqami yo\'q bo\'lsa season_id ishlatiladi', () {
      expect(item().bolimNumber, 1);
      expect(item(bolimId: 0).bolimNumber, 7);
    });

    test('foiz ko\'rilgan ulushdan hisoblanadi', () {
      expect(item(position: 25000, duration: 100000).percent, 25.0);
      // Buzilgan yozuv ham foizni chalkashtirmaydi.
      expect(item(position: 10, duration: 0).percent, 0);
    });

    test('kadr kaliti ANIQ millisekundga bog\'langan', () {
      final a = item(position: 12345);
      final b = item(position: 12999);
      expect(a.thumbKey, isNot(b.thumbKey),
          reason: 'yaxlitlash qaytib kelgan — kadr noto\'g\'ri joydan olinadi');
      expect(a.thumbKey.endsWith('_12345'), isTrue);
      // Bitta video uchun kalit bir xil boshlanadi (eskisini
      // o'chirish shunga tayanadi).
      expect(a.videoKey, b.videoKey);
    });

    test('bir xil qism RAQAM emas, ID bo\'yicha tanib olinadi', () {
      expect(item().sameEpisode(3, 7, 42), isTrue);
      expect(item().sameEpisode(3, 7, 43), isFalse);
      expect(item().sameEpisode(4, 7, 42), isFalse);
      // Qism RAQAMI bilan izlash endi topmaydi — aynan shu
      // tuzatildi: admin raqamni o'zgartirsa yozuv yo'qolmasin.
      expect(item().sameEpisode(3, 7, 2), isFalse);
    });

    test('oxirgi ko\'rilgan sifat o\'qiladi', () {
      expect(item().lastQuality, '');
      final withQ = HistoryItem.fromJson({
        'anime_id': 3,
        'season_id': 7,
        'epizod_id': 42,
        'epizod_number': 2,
        'last_quality': '720p',
        'video_url': '',
        'position_ms': 0,
        'duration_ms': 1,
        'updated_at': 1,
      });
      expect(withQ.lastQuality, '720p');
    });
  });
}
