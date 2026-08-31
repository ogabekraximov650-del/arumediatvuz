# Vazifa: video pleyerni fvp'ning past-darajali (mdk.dart) API'siga o'tkazish

## Repo va muhit

- Repo: `ogabekraximov650-del/fulutter` (Flutter anime-striming ilovasi + Rust yadrosi + Cloudflare Worker/B2 backend)
- Ishchi branch: `claude/player-bugs-fix-yitavh` — bu branch `main`ga allaqachon merge qilingan (oxirgi commit: `552df1d`). SHU BRANCH'DAN davom et yoki undan yangi branch och: `claude/mdk-native-player`.
- **MUHIM: yangi ishni ALOHIDA branchda qil, `main`ga to'g'ridan-to'g'ri push qilma.** Faqat ishlaganini tasdiqlagandan keyin (foydalanuvchi tasdiqlaydi) mergelanadi.
- Build: GitHub Actions (`.github/workflows/build-flutter-apk.yml`) push qilinganda AVTOMATIK ishga tushadi. **HECH QACHON qo'lda workflow_dispatch trigger qilma** — push qilib, keyin natijani kuzat.
- Commit qilishdan oldin har doim: `rm -rf rust/target rust/Cargo.lock` (bular .gitignore'da bor, lekin ehtiyot chorasi sifatida).
- Foydalanuvchi bilan **faqat o'zbek tilida** gaplash.
- Foydalanuvchi juda tajribali emas — texnik tushunchalarni oddiy, aniq tilda tushuntir. Taxmin qilma, kodni o'qib tasdiqla.

## Nima uchun bu vazifa kerak (asl kontekst)

Video pleyerda oylab davom etgan muammo bor edi: **foydalanuvchi progress chizig'ini surganda yoki tez-tez sek (forward/backward) qilganda ilova qotib qolardi / crash bo'lardi.**

Ko'plab urinishlar qilindi (HTTP javoblarni cheklash, mahalliy diskka keshlash, bufer sozlamalarini o'zgartirish, "sog'liq kuzatuvchisi" taymer bilan qayta ochish, va h.k.) — ular muammoni yumshatishga yordam berdi, lekin **asl sababni yo'q qila olmadi**.

**Asl sabab manba kodidan tasdiqlangan:** `fvp` paketi (`^0.38.1`) `video_player` paketi (`^2.9.2`) uchun "shim" (moslashtiruvchi) bo'lib ishlaydi. Uning muammosi:

```dart
// fvp/lib/src/video_player_mdk.dart
Future<void> seekTo(int playerId, Duration position) async {
  return _seekToWithFlags(playerId, position, mdk.SeekFlag(_seekFlags));
}
Future<void> _seekToWithFlags(...) async {
  final player = _players[playerId];
  ...
  player.seek(position: position.inMilliseconds, flags: flags);  // ← AWAIT QILINMAYDI!
}
```

`player.seek()` (bu `fvp/lib/src/player.dart`dagi mdk-sdk'ning Player klassi) **haqiqiy** `Future<int>` qaytaradi — bu Future native (C++ mdk-sdk) javob bergandagina hal bo'ladi (`Completer<int> _seeked` orqali, `NativeApi.postCObject` bilan). LEKIN `_seekToWithFlags` bu Future'ni **hech qachon await qilmaydi** — "fire-and-forget" tarzda chaqirib, darhol qaytadi.

Buning ustiga, rasmiy `video_player` paketining o'zi (`package:video_player/video_player.dart`):
```dart
Future<void> seekTo(Duration position) async {
  ...
  await _videoPlayerPlatform.seekTo(_playerId, position);  // yuqoridagi sabab bilan DEYARLI DARHOL qaytadi
  _updatePosition(position);  // ← pozitsiyani NATIVE JAVOBNI KUTMASDAN, OPTIMISTIK o'rnatadi!
}
```

**Xulosa:** `await controller.seekTo(target)` chaqiruvi HAQIQIY sek tugashini bildirmaydi — faqat "buyruq yuborildi"ni bildiradi. `controller.value.position` ham sekdan keyin darhol "maqsadga yetdi" deb ko'rsatadi, garchi native tomonda sek hali tugamagan yoki hatto qotib qolgan bo'lsa ham. **Shu sabab Dart tomonida "sek tugadimi, qotib qoldimi" degan savolga standart `video_player` API orqali ISHONCHLI javob berib bo'lmaydi.**

## Yechim: `package:fvp/mdk.dart` — past-darajali API

`fvp` paketi ikkita ochiq API beradi:

```
package:fvp/fvp.dart   → video_player uchun "shim" (HOZIR ISHLATILAYOTGAN, muammoli qatlam)
package:fvp/mdk.dart   → mdk-sdk'ning TO'G'RIDAN-TO'G'RI, past-darajali API'si (export 'src/player.dart', 'src/global.dart', 'src/media_info.dart')
```

`mdk.dart`dagi `Player` klassi (`fvp/lib/src/player.dart`, paket manba kodi `~/.pub-cache/hosted/pub.dev/fvp-0.38.1/lib/src/player.dart` da, yoki loyihada `flutter pub get` dan keyin paydo bo'ladi) quyidagilarni beradi — BULARNI O'QIB TASDIQLA, men faqat topganlarimni yozayapman:

- `Future<int> prepare({...})` — video ochish
- `set media(String value)` — manba URL/yo'lini o'rnatish
- `Future<int> seek({required int position, SeekFlag flags})` — **HAQIQIY** Future, native javob bergandagina hal bo'ladi
- `int get position` — to'g'ridan-to'g'ri native'dan o'qiladi (`_player.ref.position`), OPTIMISTIK EMAS
- `set state(PlaybackState value)` / `PlaybackState get state`
- `MediaStatus get mediaStatus`
- `onMediaStatus` — real native hodisalar oqimi (buffering/buffered/loaded holatlari)
- `onEvent` — boshqa native hodisalar
- `Future<int> updateTexture({...})` — `textureId` (`ValueNotifier<int?>`) ni yangilaydi, Flutter'ning `Texture` vidjeti orqali ko'rsatiladi
- `bool waitFor(PlaybackState state, {int timeout = -1})`
- `List<DurationRange> bufferedTimeRanges()`
- `setBufferRange(min, max, drop)`
- `dispose()`

Bu qatlamda pozitsiya va holat **haqiqiy native signal**lardan keladi — Dart tomonida taxmin qilish yo'q. Shuning uchun sek/surish paytidagi qotib qolishni **ishonchli aniqlash va oldini olish** mumkin bo'ladi.

## Nimani saqlab qolish SHART

`lib/screens/video_player_screen.dart` (hozir ~1800+ qator) da quyidagi funksionallik bor va **hammasi saqlanishi kerak**, faqat pastki pleyer boshqaruv qatlami almashadi:

1. **Mahalliy kesh-server orqali ijro** — `VideoCacheServer.instance.proxyUri(url)` `http://127.0.0.1:PORT/v?u=<encoded>` qaytaradi. Bu Rust yadrosidagi mahalliy HTTP proksi (`rust/src/video_cache.rs`) — video baytlarini diskka 1 MiB bo'laklarga bo'lib keshlaydi, yetishmayotganini worker'dan yuklaydi, to'liq yig'ilgan faylni (`full.enc`) shifrlangan holda saqlaydi va so'rov kelganda shifrni o'zi ochib beradi. **Bu qatlamga UMUMAN TEGMA** — u sinovdan o'tgan (8 ta Rust testi bor, `cargo test --lib`).
   - Yangi Player'ga video manzili sifatida shu proksi URL beriladi: `player.media = proxied.toString();`
2. **Epizod/mavsum ro'yxati** — offline kesh bilan (`RustCore.instance.getCachedList/saveListCache`), bunga tegilmaydi.
3. **Sek gestlar**: ekranning chap/o'ng yarmiga ikki marta bosib ±5s sek, o'rtada play/pause tugmasi atrofida "o'lik zona".
4. **Progress chizig'i (Slider)**: sudrab surganda faqat vizual holat yangilanadi, qo'l qo'yib yuborilganda (`onChangeEnd`) bitta sek yuboriladi.
5. **Play/pause, fullscreen, sifat (HQ) tanlash tugmalari.**
6. **Video tugagach avtomatik boshidan boshlash** (loop).
7. **Bufer sozlamalari**: hozir `main.dart`dagi `_playerOpts` Map orqali (`buffer.range`, `demux.buffer.ranges`, `avformat.probesize`, `avformat.analyzeduration`) — bularni yangi `Player`ga qanday uzatish kerakligini `player.dart`dan top (ehtimol `setProperty(key, value)` metodi bor, tasdiqla).
8. **"Foydalanuvchi nima qilsa ham, qancha tez sek qilsa ham — crash bo'lmasin"** — bu ENG MUHIM talab. Yangi arxitekturada bu ancha oson bajariladi, chunki `seek()` Future'i endi HAQIQIY, shu sabab sek navbati (queue) mantiqi ancha soddalashadi va ishonchli bo'ladi.

## Nimani olib tashlash mumkin (eski "aylanma yo'llar")

Hozirgi `_runSeek`, `_settleAfterSeek`, `_startHealthWatchdog` (umumiy "qotish" qismi), `_recoverPlayer` kabi funksiyalar — bularning barchasi standart `video_player` API'sining ishonchsizligini "aylanib o'tish" uchun yozilgan murakkab ish-atrofi (workaround) kodlari edi. Yangi arxitekturada `seek()`ning HAQIQIY Future'i va `position`/`state`/`onMediaStatus`ning HAQIQIY signal berishi tufayli bu workaround'larning katta qismi **keraksiz bo'lib qoladi yoki ancha soddalashadi**. Buni kodni o'qib, mantiqan qayta loyihalashtirib qil — eskisini sinab ko'rmasdan olib tashlama, avval yangi Player API bilan qanday ishlashini tushunib ol.

## Texnik eslatmalar

- `panic = "abort"` Rust `Cargo.toml`da o'rnatilgan — bu vazifaga bevosita aloqasi yo'q, lekin eslab qo'y: Rust tomonida panic bo'lsa butun ilova process'i o'ladi (shu sabab Rust kodi juda ehtiyotkorlik bilan yozilgan, tegma).
- `pubspec.yaml`da: `video_player: ^2.9.2`, `fvp: ^0.38.1`, `flutter_secure_storage: ^9.2.4` bor.
- CI workflow endi **bitta APK** yasaydi (split-per-abi emas), `x86_64` chiqarib tashlangan, mdk-sdk GitHub Actions keshiga saqlanadi (SourceForge'dan qayta-qayta yuklamaslik uchun — bu avval build'ni bir necha marta yiqitgan edi).
- Flutter SDK va Dart SDK lokal muhitda `/tmp/claude-0/.../scratchpad/flutter` da bor edi (agar shu konteynerda davom etilsa) — `flutter analyze` va `cargo test`/`cargo build` bilan HAR BIR o'zgarishdan keyin tekshirib borish kerak, push qilishdan oldin.
- Rust papkasiga tegilmasa ham, `cargo test --lib` ni bir marta ishga tushirib, hech narsa buzilmaganini tasdiqlash foydali (8/8 test o'tishi kerak).

## Ish tartibi (tavsiya)

1. `lib/screens/video_player_screen.dart`, `lib/main.dart`, `lib/services/video_cache_server.dart`, `lib/services/rust_bridge.dart` fayllarini to'liq o'qib chiq.
2. `fvp/lib/src/player.dart` va `fvp/mdk.dart` manba kodini to'liq o'qib, aniq API'ni tasdiqla (yuqoridagi ro'yxat mening taxminim, sen tekshirasan).
3. Yangi branch och (`claude/mdk-native-player` yoki shunga o'xshash).
4. Pleyer boshqaruv qatlamini `Player` (mdk.dart) + `Texture` vidjeti asosida qayta yoz. UI/gestlar/progress-slider/kesh-server chaqiruvlari o'zgarishsiz qoladi — faqat ularning ORQASIDAGI controller almashadi.
5. `flutter analyze` xatosiz bo'lishi kerak.
6. Push qil, CI build natijasini kuzat (avtomatik ishga tushadi).
7. Foydalanuvchiga APK'ni qurilmada sinab ko'rishni so'ra — ayniqsa: tez-tez sek qilish, progress chizig'ini bir necha marta ketma-ket surish, video tugagach qayta boshlanishi.
8. Faqat foydalanuvchi tasdiqlagandan keyin `main`ga merge taklif qil — o'zing hal qilma.

## Muvaffaqiyat mezoni

Foydalanuvchi progress chizig'ini xohlagancha tez-tez sursin, video ichida istalgan joyga sek qilsin — ilova HECH QACHON qotib qolmasligi yoki crash bo'lmasligi kerak. Bu asosiy, hal qiluvchi talab.
