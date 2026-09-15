// test/sync_queue_test.dart — NAVBAT SIQILISHI.
//
// Bu qoidalar butun yozuv tizimining asosi: agar siqish buzilsa,
// Turso xarajati bir necha barobar oshadi; agar "birinchi ko'rish"
// belgisi yo'qolsa, ko'rishlar hisobi kam chiqadi.
//
// RustCore bu yerda ishga tushirilmagan, ya'ni disk yozuvi
// jimgina o'tkazib yuboriladi — navbatning O'ZI xotirada
// tekshiriladi.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft/services/sync_queue.dart';

Map<String, dynamic> ep(int e, {int watched = 0, bool newView = false}) => {
      'anime_id': 1,
      'season_id': 2,
      'epizod_id': e,
      'video_url': 'v$e.mp4',
      'last_quality': '720p',
      'position_ms': 1000,
      'duration_ms': 600000,
      'watched_ms': watched,
      'new_view': newView,
    };

void main() {
  final q = SyncQueue.instance;

  setUp(() => q.wipe());

  test('bir qismning ko\'p yozuvi BITTA qatorga siqiladi', () {
    for (var i = 0; i < 50; i++) {
      q.putHistory(ep(7, watched: i * 1000));
    }
    expect(q.pendingCount, 1);
  });

  test('har xil qism — alohida qator', () {
    q.putHistory(ep(1));
    q.putHistory(ep(2));
    q.putHistory(ep(3));
    expect(q.pendingCount, 3);
  });

  test('"birinchi ko\'rish" belgisi siqilganda YO\'QOLMAYDI', () {
    q.putHistory(ep(9, newView: true));
    q.putHistory(ep(9, watched: 5000)); // new_view: false
    final pend = q.pendingHistory();
    expect(pend.length, 1);
    // Belgi saqlanib qolgani — ko'rish hisobi kam chiqmasligi uchun.
    expect(pend['1:2:9'], isFalse); // yashirilmagan
  });

  test('tarixdan yashirish o\'sha kalitning ustiga yoziladi', () {
    q.putHistory(ep(4));
    q.hideHistory(1, 2, 4);
    expect(q.pendingCount, 1);
    expect(q.pendingHistory()['1:2:4'], isTrue);
  });

  test('baho va sevimli alohida kalitlar, lekin o\'zi siqiladi', () {
    q.putRating(1, 2, 5);
    q.putRating(1, 2, 9);
    q.putFavorite(1, 2, true);
    q.putFavorite(1, 2, false);
    q.putFavorite(1, 3, true);
    // baho 1 ta + sevimli 2 ta (2:2 va 2:3)
    expect(q.pendingCount, 3);
    expect(q.pendingFavorites()['1:2'], isFalse);
    expect(q.pendingFavorites()['1:3'], isTrue);
  });

  test('noto\'g\'ri yozuv navbatga tushmaydi', () {
    q.putRating(1, 2, 0);
    q.putRating(1, 2, 11);
    q.putRating(0, 2, 5);
    q.putHistory({'anime_id': 0, 'season_id': 1, 'epizod_id': 1});
    q.hideHistory(0, 0, 0);
    expect(q.pendingCount, 0);
  });

  test('kunlik chegara 50 dan oshmaydi', () {
    // Foydalanuvchi qo'ygan shart.
    expect(SyncQueue.hardPerDay, lessThanOrEqualTo(50));
    expect(SyncQueue.normalPerDay, lessThan(SyncQueue.hardPerDay));
  });

  test('navbat cheksiz o\'smaydi', () {
    for (var i = 1; i <= SyncQueue.maxQueueRows + 120; i++) {
      q.putHistory(ep(i));
    }
    expect(q.pendingCount, SyncQueue.maxQueueRows);
  });
}
