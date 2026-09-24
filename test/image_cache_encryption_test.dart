// Rasm keshi diskda SHIFRLANGAN holda saqlanishini tekshiradi.
//
// Haqiqiy Rust yadrosi bilan ishlaydi: host uchun yig'ilgan
// `librust_core.so` jarayonga `LD_PRELOAD` qilinadi (Linux'da
// `RustCore` kutubxonani `DynamicLibrary.process()` dan oladi):
//
//   cd rust && cargo build --release
//   LD_PRELOAD=$PWD/rust/target/release/librust_core.so \
//     flutter test test/image_cache_encryption_test.dart
//
// Kutubxona yuklanmagan bo'lsa (oddiy `flutter test`) — o'tkazib
// yuboriladi.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft/services/image_cache.dart';
import 'package:soft/services/rust_bridge.dart';

bool _hasCore() {
  try {
    DynamicLibrary.process().lookup('rust_seal_bytes');
    return true;
  } catch (_) {
    return false;
  }
}

/// `needle` baytlar ketma-ketligi `hay` ichida bormi.
bool _contains(Uint8List hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  final skip = _hasCore() ? null : 'librust_core.so yuklanmagan (LD_PRELOAD)';

  HttpServer? server;
  late Uint8List image;

  setUpAll(() async {
    if (skip != null) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    // Sinov muhiti HTTP'ni soxtalashtiradi (hamma so'rov 400) —
    // bizga haqiqiy mahalliy server kerak.
    HttpOverrides.global = null;
    // path_provider — vaqtinchalik papkaga.
    final tmp = await Directory.systemTemp.createTemp('aru_img_');
    final support = Directory('${tmp.path}/files')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    await RustCore.instance.init();
    expect(RustCore.instance.setMasterKey(RustCore.instance.generateMasterKey()),
        isTrue);
    await AppImageCache.init();
    // "Rasm": tanib olinadigan belgi bilan.
    image = Uint8List.fromList([
      ...'ARU-POSTER-SIGNATURE'.codeUnits,
      ...List<int>.generate(200000, (i) => i % 251),
    ]);
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server = srv;
    srv.listen((req) {
      req.response.headers.contentType = ContentType('image', 'jpeg');
      req.response.add(image);
      req.response.close();
    });
  });

  tearDownAll(() async {
    await server?.close(force: true);
  });

  test('yuklab olingan rasm diskda shifrlangan, o\'qilganda asl holida',
      () async {
    final url = 'http://127.0.0.1:${server!.port}/poster_1.jpg';
    {
      final file = await AppImageCache.manager.getSingleFile(url);
      // Kesh orqali o'qilganda — asl baytlar.
      expect(await file.readAsBytes(), equals(image));
      // Diskdagi xom fayl — shifrlangan: belgi ko'rinmaydi.
      final raw = await File(file.path).readAsBytes();
      expect(raw.length, image.length + 28);
      expect(_contains(raw, 'ARU-POSTER-SIGNATURE'.codeUnits), isFalse);
    }
  }, skip: skip);

  test('putFile ham shifrlaydi; URL ro\'yxati ham ochiq emas', () async {
    const url = 'https://example.invalid/anime/poster_2.jpg';
    await AppImageCache.manager.putFile(url, image, fileExtension: 'jpg');
    final info = await AppImageCache.manager.getFileFromCache(url);
    expect(info, isNotNull);
    expect(await info!.file.readAsBytes(), equals(image));
    final raw = await File(info.file.path).readAsBytes();
    expect(_contains(raw, 'ARU-POSTER-SIGNATURE'.codeUnits), isFalse);

    // Ro'yxat fayli yozilishini kutamiz (kesh uni 3 s dan keyin yozadi).
    await Future<void>.delayed(const Duration(seconds: 4));
    final index = Directory(File(info.file.path).parent.parent.path)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('v2.index'))
        .toList();
    expect(index, isNotEmpty, reason: 'URL ro\'yxati fayli topilmadi');
    final idx = await index.first.readAsBytes();
    expect(_contains(idx, 'example.invalid'.codeUnits), isFalse,
        reason: 'URL ro\'yxati ochiq holda yozilgan');
    // ...lekin kalit bilan ochiladi (ilova qayta ochilganda o'qiladi).
    final opened = RustCore.instance.openBytes('img:v2.index', idx);
    expect(opened, isNotNull, reason: 'ro\'yxat qayta ochilmadi');
    expect(String.fromCharCodes(opened!), contains('poster_2.jpg'));
  }, skip: skip);

  test('buzilgan fayl o\'qilmaydi va o\'chiriladi', () async {
    const url = 'https://example.invalid/anime/poster_3.jpg';
    await AppImageCache.manager.putFile(url, image, fileExtension: 'jpg');
    final info = await AppImageCache.manager.getFileFromCache(url);
    final path = info!.file.path;
    final raw = await File(path).readAsBytes();
    raw[100] ^= 1;
    await File(path).writeAsBytes(raw);
    await expectLater(info.file.readAsBytes(), throwsA(isA<FileSystemException>()));
    expect(File(path).existsSync(), isFalse);
  }, skip: skip);
}
