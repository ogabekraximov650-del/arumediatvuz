// Trafik hisobi: FAQAT tarmoqdan kelgan baytlar sanalishi kerak.
//
// NEGA BU TEST: hisob uch marta noto'g'ri bo'ldi (worker sanadi,
// `Content-Length` sanaldi, yadro hisoblagichi ilova ICHIDAGI
// uzatmani ham sanadi). Shu sabab endi sanovchi klientning o'zi
// test bilan qo'riqlanadi.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft/services/net_meter.dart';
import 'package:http/http.dart' as http;

/// Tarmoqqa umuman chiqmaydigan soxta klient.
class _FakeClient extends http.BaseClient {
  _FakeClient(this.body);

  final String body;
  int sent = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent++;
    final bytes = utf8.encode(body);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([bytes]),
      200,
      contentLength: bytes.length,
      request: request,
      headers: const {'content-type': 'text/plain'},
    );
  }
}

void main() {
  test('javob tanasi HAQIQATDA o\'qilgani bo\'yicha sanaladi', () async {
    final before = NetMeter.instance.bytes;
    final fake = _FakeClient('salom dunyo');
    final client = CountingClient(fake);

    final res = await client.get(Uri.parse('https://x.example/api'));

    expect(res.statusCode, 200);
    expect(fake.sent, 1);
    final grew = NetMeter.instance.bytes - before;
    // Tana 11 bayt; ustiga sarlavhalarning taxminiy hajmi.
    expect(grew, greaterThanOrEqualTo(11));
    // Lekin hisob shishib ketmasligi kerak — sarlavha kichik.
    expect(grew, lessThan(200));
  });

  test('hisob kamaymaydi va manfiy qiymat qo\'shilmaydi', () {
    final before = NetMeter.instance.bytes;
    NetMeter.instance.add(-5);
    NetMeter.instance.add(0);
    expect(NetMeter.instance.bytes, before);
    NetMeter.instance.add(7);
    expect(NetMeter.instance.bytes, before + 7);
  });

  test('runWithClient zonasida `http.get` sanovchi klientni oladi', () async {
    // MUHIM: `CountingClient` ning ichki klienti `Zone.root.run`
    // bilan yaratiladi. Aks holda u zonadan yana o'zini olib,
    // cheksiz rekursiyaga tushardi — bu test aynan shuni
    // qo'riqlaydi (rekursiya bo'lsa test stek toshib yiqiladi).
    final fake = _FakeClient('{"ok":true}');
    final before = NetMeter.instance.bytes;

    final body = await http.runWithClient(
      () => http.read(Uri.parse('https://x.example/api')),
      () => CountingClient(fake),
    );

    expect(body, '{"ok":true}');
    expect(fake.sent, 1);
    expect(NetMeter.instance.bytes, greaterThan(before));
  });
}
