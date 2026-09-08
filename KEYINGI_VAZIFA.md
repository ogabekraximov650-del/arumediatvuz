# Loyihaning hozirgi holati va keyingi ish uchun eslatmalar

> Bu fayl **hozirgi** arxitekturani tasvirlaydi. Avvalgi versiyasi
> allaqachon bekor qilingan rejani (`fvp`/`mdk` past-darajali API'siga
> o'tish) tasvirlar edi — u yo'ldan **voz kechilgan**, pleyer rasmiy
> `video_player` (Android'da ExoPlayer/Media3) ustida ishlaydi.

## Repo va muhit

- Repo: `ogabekraximov650-del/fulutter` — Flutter ilova + Rust yadrosi
  (`rust/`) + Cloudflare Worker (`worker/`) + B2 (fayl ombori) +
  Turso (baza).
- Foydalanuvchi bilan **faqat o'zbek tilida** gaplashing; texnik
  tushunchalarni oddiy tilda tushuntiring, taxmin qilmang — kodni
  o'qib tasdiqlang.
- Ishni **alohida branch**da qiling, `main`ga to'g'ridan-to'g'ri push
  qilmang.
- APK build: `.github/workflows/build-flutter-apk.yml` — `main` va
  `claude/**` branchlariga push qilinganda **avtomatik** ishga tushadi.
  Qo'lda `workflow_dispatch` qilmang.
- Worker deploy: `.github/workflows/deploy-worker.yml` — **faqat
  `main`ga** `worker/**` o'zgarishi push qilinganda. Ya'ni feature
  branchdagi worker o'zgarishlari **deploy bo'lmaydi**.
- Commit qilishdan oldin: `rm -rf rust/target rust/Cargo.lock
  worker/target worker/Cargo.lock`.

## Tekshiruv (har bir o'zgarishdan keyin)

```
flutter analyze          # 0 muammo bo'lishi kerak
cd rust && cargo test --lib     # 11/11 o'tishi kerak
cd worker && cargo check --target wasm32-unknown-unknown
```

## PLEYER VA YUKLAB OLISH — IKKI MUSTAQIL TIZIM

Bu loyihadagi **eng muhim qoida**. Buzilsa, foydalanuvchi darhol
sezadi: video o'zi yuklab olina boshlaydi.

| Holat | Manba | Diskka yozadimi |
|---|---|---|
| Fayl **100%** diskda | Mahalliy server (`127.0.0.1`) | Yo'q (faqat o'qiydi) |
| Fayl to'liq emas | **Faqat** worker `/api/play/...` | **Yo'q** |
| Internet yo'q + fayl to'liq emas | Ijro etib bo'lmaydi | — |

**Mahalliy server (`serve()`) TARMOQQA UMUMAN CHIQMAYDI.** U:

- bo'laklarni faqat **diskdan** o'qiydi (`read_cached_chunk`);
- faylning hajmini ham faqat **diskdagi `meta.json`** dan oladi;
- bo'lak yoki `meta.json` topilmasa — **404** qaytaradi va ilova
  workerga o'tadi.

Ilgari `serve()` yetishmayotgan bo'lakni tarmoqdan olib diskka
yozardi. Natijada "videoni ko'rish" amalda "yuklab olish"ga
aylanardi: foydalanuvchi tugmani bosmagan bo'lsa ham video diskka
yozilardi; videoni o'chirgandan keyin esa u butunlay qaytadan
yuklanardi.

Qoidani **`keshdan_bir_javobda_va_sek_bosimiga_bardosh`** testi
qo'riqlaydi: mahalliy serverga yuklab olinmagan video so'ralganda
manba jurnali **bo'sh** qolishi shart.

**To'liq yuklanganlikni faqat DISK hal qiladi**
(`RustCore.videoIsComplete` — diskni skanerlaydi). Ekrandagi hisob
(`DownloadManager.statOf`) bu qarorda **ishlatilmaydi**: u bir necha
soniya eskirgan bo'ladi va aynan shu o'chirilgandan keyingi qayta
yuklanishga olib kelgan edi.

## Manba ALMASHISHI (mahalliy <-> worker)

Manba video ochilganda bir marta tanlanadi va keyin **kuzatib
boriladi** (`_checkSourceSwitch`, har 2 soniyada):

- onlayn ko'rilayotganda fayl **to'liq yuklab olinsa** — aynan
  o'sha joydan mahalliy serverga o'tadi;
- mahalliy ko'rilayotganda fayl **o'chirilsa** — aynan o'sha joydan
  workerga o'tadi.

Tekshiruv arzon: avval xotiradagi hisob (ishora) ko'riladi, faqat
u **o'zgarganda** disk skanerlanadi.

## VIDEO TEZ OCHILISHI: "keshda ko'rilgan" belgisi

Ilova ilgari HAR SAFAR `/api/warm` ga so'rov yuborib javobini
kutardi — hatto kesh tayyor bo'lganda ham. O'lchandi: bunday
"bo'sh" so'rov data-markazdan **0.26-0.63 s**, telefonda mobil
tarmoqda **1-3 s**; `/api/play` ning o'zi esa atigi **0.3 s**.

Endi isitish muvaffaqiyatli tugaganda diskka belgi yoziladi
(`w<N>.warm`, 6 soat yashaydi). Belgi yangi bo'lsa ilova
**kutmaydi**: pleyerni darhol ochadi, isitishni fon'da ishga
tushiradi. Kesh kutilmaganda o'chgan bo'lsa — pleyer xatoga chiqadi
va odatdagi tiklanish yo'li oynani isitib, o'sha joydan qayta
ochadi.

FFI: `rust_video_cache_window_seen(url, widx)`.

## Internet uzilishi

- Onlayn ijro paytida internet uzilsa pleyer **o'ldirilmaydi**;
  ekranda xabar chiqadi va joriy nuqta eslab qolinadi.
- Internet qaytishi bilan video **o'sha nuqtadan avtomatik** davom
  etadi (`_onNetworkBack`), "takroriy xato" hisoblagichi esa nolga
  tushadi — internetning yo'qligi pleyerning nosozligi emas.

## Qayerda to'xtaganini eslab qolish

`lib/services/watch_progress.dart` — barcha nuqtalar bitta JSON
ro'yxatda (`watch_positions`). Boshidagi 15 soniya va oxiridagi
30 soniya saqlanmaydi; yozish **har soniyada, darhol diskka**
(faqat telefon xotirasiga — serverga umuman yuborilmaydi).

## TANBAL (LAZY) OYNA KESHLASH — eng muhim qoida

Fayl **480 MiB**lik "oynalarga" bo'linadi (`WARM_WINDOW`; Rust va
worker'da **aynan bir xil** bo'lishi shart). Oynalar **ketma-ket
emas, faqat kerak bo'lganda** keshlanadi:

| Qachon | Nima bo'ladi |
|---|---|
| Video ochilganda | Faqat **#0** oyna keshlanadi. Foydalanuvchi shuni kutadi. |
| Ijro oyna chegarasiga 64 MiB qolganda | Keyingi oyna **fon'da** keshlanadi (kutish sezilmaydi). |
| Hali keshlanmagan joyga sek qilinganda | Avval o'sha oyna keshlanadi, **keyin** sek bajariladi. |
| Foydalanuvchi oxiriga bormasa | Oxirgi oyna B2'dan **hech qachon** o'qilmaydi. |

**B2'ga so'rov faqat isitish (`/api/warm`) paytida, oynasiga bir
marta ketadi.** Boshqa hech qaysi yo'l B2'ga chiqmaydi. Yangi kod
yozganda bu qoidani buzmang.

Tegishli FFI (`rust/src/video_cache.rs` → `lib/services/rust_bridge.dart`):

- `rust_video_cache_prepare` / `_prepare_status` — #0 oynani tayyorlash;
- `rust_video_cache_warm_window(url, widx)` — oynani fon'da keshlash;
- `rust_video_cache_window_status(url, widx)` — 0 ketyapti / 1 tayyor /
  2 yiqildi / 3 boshlanmagan;
- `rust_video_cache_total(url)`, `rust_video_cache_window_size()` —
  ilova oyna chegarasini shular bilan hisoblaydi.

Test: `cargo test --lib tanbal` →
`tanbal_keshlash_faqat_kerakli_oynani_oladi`.

## NEGA BUFER TOZALANMASLIGI MUHIM

`/api/play` keshda yo'q joy so'ralganda **503** qaytaradi. ExoPlayer
uchun bu **qaytarib bo'lmaydigan** xato: pleyerni butunlay qaytadan
ochishga to'g'ri keladi va **yig'ilgan butun bufer yo'qoladi**
(foydalanuvchi buni "sek qilsam video qaytadan sekin ochiladi" deb
ko'radi).

Shu sabab `lib/screens/video_player_screen.dart` da:

- ilova pleyerdan **oldinda yuradi** (`_startWindowPrefetch`,
  `_ensureWindowFor`) — 503 umuman yuz bermaydi;
- qotish belgisida avval **yengil turtki** (`_nudgePlayer`:
  `seekTo` + `play`) sinaladi — bufer saqlanadi;
- pleyerni qaytadan ochish (`_recoverPlayer`) — **oxirgi chora**, va
  undan oldin `_handleFatalError` kerakli oynani keshga oldiradi.

Yangi "tuzatish" qo'shayotganda pleyerni qaytadan ochish yo'lini
kengaytirmang — avval oldini olishga harakat qiling.

## 480 MiB'dan katta fayllar

`worker/src/lib.rs` → `stitched_response`: javob bir nechta oynadan
**oqim bilan** ulanadi (uzunlik oldindan to'g'ri e'lon qilinadi).
Busiz ExoPlayer javobning tugashini "fayl tugadi" deb tushunadi va
video 480 MiB'da to'xtab qolardi. Keyingi oyna hali keshda bo'lmasa
javob **kutadi** (B2'ga chiqmaydi).

## Yuklab olish

- Navbat diskda saqlanadi (`download_queue.json`) — ilova o'ldirilsa
  ham yuklash o'zi davom etadi;
- internet qaytganda kutish darhol bekor qilinadi
  (`DownloadManager._resumeActive`);
- diskdagi bo'lak **1 MiB** (foiz va "to'xtagan joydan davom" shunga
  tayanadi), workerga so'rov esa **64 MiB** bilan ketadi
  (`DL_REQUEST_CHUNKS = 64`, worker'dagi `RANGE_MAX` bilan bir xil).
  166 MB'lik qism uchun so'rovlar soni 11 -> 6;
- **ish YO'LAKLARGA bo'linadi** (`Lane`): oynadagi yetishmayotgan
  bo'laklar 6 ta teng yo'lakka bo'linadi, har bir oqim faqat o'z
  yo'lagini oladi. Yo'lagi tugagan oqim BO'SH TURMAYDI — eng ko'p
  ish qolgan yo'lakning orqa yarmini o'ziga oladi (`steal_locked`),
  va bu chegara hech qachon HOZIR HAVODA turgan so'rovdan berini
  kesmaydi (`hold`), ya'ni bitta bayt ham ikki marta olinmaydi.
  Yo'laklar bitta qulf ostida — poyga imkonsiz;
- **NEGA**: ilgari navbat "guruh" birligida edi va navbat tugagan
  oqim butunlay chiqib ketardi. 166 MB = 11 guruh, 6 oqim: oxirgi
  guruh YOLG'IZ qolardi va tezlik 6 barobar tushardi (5 MB/s ->
  800 KB/s — foydalanuvchi aynan shu raqamlarni aytdi). Endi
  oxirgi baytgacha 6 oqim ham band. Buni
  `yuklab_olish_oxirigacha_parallel_ketadi` (tezlik) va
  `yuklab_olish_yolaklar_bilan_takrorsiz_ketadi` (qoplama) testlari
  qo'riqlaydi;
- worker keshdan 64 MiB beradi, B2'dan esa 8 MiB (`B2_RANGE_MAX`) —
  xotira uchun. Xotiradan beriladigan javoblar `X-Cache: MISS` yoki
  `HIT-RANGE` bilan keladi va ilova ulardan chegara "o'rganmaydi";
- server chegarasi (`SERVER_SPAN_MAX`) 5 daqiqada unutiladi — bitta
  noxush javob ilovani abadiy sekinlashtirmaydi.

## Javob uzunligi E'LON QILINISHI SHART (`fixed_length_stream`)

`Response::from_stream` javobni `Transfer-Encoding: chunked` bilan
yuboradi va qo'lda yozilgan `Content-Length`ni runtime tashlab
yuboradi. Jonli o'lchovda bu og'ir nuqsonga olib kelgani aniqlandi:
bitta 16 MiB so'rovning javobi **10 urinishdan 5-6 tasida
0.6-1.5 MB da jimgina uzilib** qolardi — na xato, na belgi. Ilova
esa buni "shuncha ekan" deb qabul qilib, qolganini qayta-qayta
so'rardi.

Shu sabab **keshdan kesib beriladigan HAR BIR javob**
`fixed_length_stream` quvuridan o'tkaziladi (`play_from_warm_cache`,
`b2_proxy_range`ning ikkala kesh yo'li, `b2_proxy_full`). Shunda
runtime `Content-Length`ni o'zi qo'yadi va javob erta uzilsa mijoz
buni DARHOL xato deb ko'radi. Xotiraga hech narsa yig'ilmaydi.

Ilova tomoni baribir bardoshli: uzilgan javobdan olingani diskda
qoladi va keyingi urinish aynan o'sha joydan davom etadi — buni
`javob_yarmida_uzilsa_ham_yuklash_tugaydi` testi qo'riqlaydi.

## Miqyos (yuz minglab foydalanuvchi)

- `ensure_db` — jadval yaratish buyruqlari izolyat umrida **bir
  marta** (avval har bir so'rovda 10 ta DDL Turso'ga ketardi);
- ro'yxat so'rovlari (`/api/anime`, `/api/seasons/...`,
  `/api/epizods/...`) chekkada **30 soniya** keshlanadi, yozishdan
  keyin darhol tozalanadi (`purge_list_cache`).

**Hali hal qilinmagan:** Cloudflare keshi har bir data-markazda
alohida. Ya'ni bitta epizodni ko'p mamlakatdan ko'rishsa, oyna har
bir data-markaz uchun B2'dan alohida o'qiladi. Buni butunlay yo'q
qilish uchun Cache Reserve yoki R2 kerak bo'ladi — bu arxitektura
o'zgarishi, foydalanuvchi bilan kelishilmagan.

## Tegilmaydigan joylar

- `rust/src/video_cache.rs` ning bo'lak-keshlash va shifrlash qismi
  (sinovdan o'tgan, 15 ta test);
- `rust/Cargo.toml` dagi `panic = "abort"` — Rust tomonida panic
  bo'lsa butun ilova o'ladi, shu sabab Rust kodi juda ehtiyotkorlik
  bilan yozilgan.
