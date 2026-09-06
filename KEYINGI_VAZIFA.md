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
cd rust && cargo test --lib     # 15/15 o'tishi kerak
cd worker && cargo check --target wasm32-unknown-unknown
```

## Videoni ko'rsatish: uch yo'l

1. **Fayl telefonda TO'LIQ bor** → mahalliy Rust kesh-serveri
   (`127.0.0.1`, `rust/src/video_cache.rs`). Tarmoqqa umuman
   chiqilmaydi.
2. **Fayl to'liq emas + internet bor** → to'g'ridan-to'g'ri worker:
   `/api/play/<fayl>`. Bu yo'l **faqat Cloudflare keshidan** xizmat
   qiladi va **B2'ga hech qachon chiqmaydi**.
3. **Fayl to'liq emas + internet yo'q** → ijro etib bo'lmaydi, aniq
   xabar ko'rsatiladi.

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
- bo'laklar 1 MiB, so'rovlar 8 MiB'lik guruh bilan (`GROUP_CHUNKS`),
  worker chegarasi bilan aynan mos (`RANGE_MAX`);
- server chegarasi (`SERVER_SPAN_MAX`) 5 daqiqada unutiladi — bitta
  noxush javob ilovani abadiy sekinlashtirmaydi.

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
