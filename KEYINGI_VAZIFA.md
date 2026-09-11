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
  qilmang. **Istisno:** foydalanuvchi aniq so'rasa (masalan worker
  o'zgarishi darhol deploy bo'lishi kerak bo'lsa) — `main`ga.
- APK build: `.github/workflows/build-flutter-apk.yml` — `main` va
  `claude/**` branchlariga push qilinganda **avtomatik** ishga tushadi.
  Qo'lda `workflow_dispatch` qilmang.
- Worker deploy: `.github/workflows/deploy-worker.yml` — **faqat
  `main`ga** `worker/**` o'zgarishi push qilinganda. Ya'ni feature
  branchdagi worker o'zgarishlari **deploy bo'lmaydi**.
- Commit qilishdan oldin: `rm -rf rust/target rust/Cargo.lock
  worker/target worker/Cargo.lock`.

## BREND: ARU / AniRaxUz

Ilova nomi — **AniRaxUz**, logotipi — **ARU**. (`fulutter` faqat
repo/papka nomi va Android paket nomi: `uz.fulutter.fulutter`.)

| Qayerda | Nima |
|---|---|
| Telefondagi belgi | `branding/android-res/mipmap-*/ic_launcher.png` |
| Yumaloq belgi | `ic_launcher_round.png` — MIUI/One UI aynan shuni oladi |
| Moslashuvchan belgi | `mipmap-anydpi-v26/ic_launcher.xml` (qora fon + oq harflar) |
| Belgi ostidagi yozuv | CI manifestga `android:label="AniRaxUz"` yozadi |
| Ochilish ekrani | qora fon + ARU logotipi (`drawable*/launch_background.xml`) |
| Ilova ichida | `lib/widgets/aru_logo.dart` -> `assets/aru-mark.png` |

### "Telefonda hali ham Flutter belgisi turibdi"

Build 162 APK'si **ochib tekshirildi**: `android:icon` ->
`mipmap/ic_launcher`, ichidagi 11 ta rasmning hammasi ARU
(ko'k piksel 0%), `application-label:'ARU'`. Ya'ni APK to'g'ri
edi — telefon ESKI belgini keshdan ko'rsatayotgan edi (yorliq
yangilangan, rasm esa yo'q — bu aynan kesh belgisi).

Shu sabab `ic_launcher_round` qo'shildi: bu resurs ilgari umuman
mavjud bo'lmagan, ya'ni uning eski keshlangan nusxasi ham yo'q.
Kesh baribir qolsa — ilovani **butunlay o'chirib**, qaytadan
o'rnatish kifoya.

**TOPILGAN XATO (tuzatildi).** `build-flutter-apk.yml` ning
`paths:` filtrida `branding/**` yo'q edi — ya'ni logotipni
o'zgartirgan commit'lar **umuman APK yig'masdi** va telefonda eski,
belgisiz APK turaverardi.

Endi qo'shimcha himoya ham bor: tayyor APK ochilib, ichidagi belgi
rasmi **ochib ko'riladi**. Ko'k piksel topilsa (Flutter'ning
standart belgisi) build ataylab yiqiladi. Bayt solishtirilmaydi,
chunki `aapt2` PNG'larni qayta siqadi.

## PASTKI PANEL TIZIM TUGMALARI ORTIDA QOLMASIN

Pleyer to'liq ekranda `immersiveSticky` rejimini yoqadi va o'shanda
`MediaQuery.padding.bottom` **nolga tushadi**. Pleyerdan
chiqilganda MIUI yangilangan `padding` ni kechikib yuboradi —
`SafeArea` esa aynan `padding` ga tayanadi, shu sabab panel tizim
tugmalari ortida qolib ketardi.

Yechim: `MediaQuery.viewPaddingOf(context).bottom`. `viewPadding`
tizim paneli yashiringan bo'lsa ham **jismoniy** chekinishni
ko'rsatib turadi, ya'ni nolga tushmaydi.

## PASTKI TUGMA SUZISHI — SAHIFA DARHOL, TUGMA SEKIN

Foydalanuvchi talabi (aynan shunday): "bosishim bilan o'sha
sahifaga o'tishi kerak, lekin tugmani kattalashtiradigan narsa
birozgina sekinroq va silliq, ketma-ket tugmalarni
kattalashtirib o'tishi kerak".

Ya'ni ikkovi BIR-BIRIDAN MUSTAQIL:

| Nima | Qanday |
|---|---|
| Sahifa | bosilgan **zahoti** (`IndexedStack` indeksi) |
| Pushti tugma | o'z yo'lini **sekin** bosib o'tadi (~280 ms/oraliq) |

### Ikkita sabab bor edi

**1. Sahifa aynan suzish paytida qurilardi.** `PageView` +
`jumpToPage` sahifani BIRINCHI marta o'tilgan damda quradi
(`initState`, ro'yxatlar, rasm vidjetlari) va kuchsiz telefonda
bu bir necha kadr qotish beradi.

Endi **`IndexedStack`**: barcha sahifalar ilova ochilganda bir
marta quriladi, keyin faqat qaysi biri ko'rinishi almashadi —
tugma bosilganda quriladigan ish umuman qolmaydi. Bosh
sahifadan boshqa to'rttasi yengil (hech biri `initState` da
tarmoqqa chiqmaydi), shu sabab ilova ochilishiga sezilarli
ta'sir qilmaydi. `sizing: StackFit.expand` SHART — aks holda
sahifalar butun ekranni egallamaydi.

**2. Animatsiya vaqtni haqiqiy soat bo'yicha o'lchardi.**
`AnimationController` shunday ishlaydi: bitta kadr 300 ms
chizilsa, keyingi kadrda u darhol o'sha 300 ms ga **sakraydi** —
qisqa suzish esa butunlay yeb ketiladi. Aynan shu sabab kuchsiz
telefonda suzish umuman ko'rinmasdi.

Endi `AnimationController` YO'Q. Uning o'rniga oddiy `Ticker`
(`_onNavTick`) va vaqt QO'LDA qo'shiladi:

```dart
var dt = (elapsed - last).inMicroseconds / 1000.0;
if (dt > _maxFrameMs) dt = _maxFrameMs;   // 32 ms
_navT += dt / _navMs;
```

Qotish bo'lsa suzish shunchaki cho'ziladi, lekin **hech qachon
sakramaydi**: tugma har doim oradagi hamma belgini birin-ketin
kattalashtirib o'tadi. **Bu tartibni buzmang** — `Ticker` ni
qaytadan `AnimationController` ga almashtirsangiz muammo o'sha
zahoti qaytadi.

### Tezlik

Bitta tugma oralig'iga **280 ms**, ustiga ekran kengligi
bo'yicha ko'paytma (`_speedFactor`): ~360 dp da 1.20, 600 dp da
1.00, 900 dp va undan katta ekranda 0.90 — kichik ekranda tugma
bosib o'tadigan masofa qisqa, shu sabab bir xil vaqt u yerda
"shosha-pisha" ko'rinadi. Umumiy davomiylik 320–1400 ms
oralig'ida qisiladi. Bosh sahifadan profilga (4 oraliq) ~1,1
soniya.

Egri chiziq — `Curves.easeInOutSine`. `easeInOutCubic` sinab
ko'rilgan edi: u o'rtasida o'rtacha tezlikdan IKKI BAROBAR tez
ketardi va aynan shu "uchib o'tdi" hissini bergan.

## HAMMA FAYL SHIFRLANADI

Talab: ilovaga tegishli **barcha** fayllar shifrlangan bo'lsin.
Rasm keshi (`cached_network_image`) bundan mustasno — foydalanuvchi
uni shart emas dedi.

| Fayl | Usul |
|---|---|
| Video bo'laklari | AES-128-CBC (bo'lak darajasida) |
| Ro'yxat keshi, kirish tokeni | AES-256-GCM |
| `meta.json` | AES-256-GCM (`read_meta` / `write_meta`) |
| `download_queue.json` | AES-256-GCM (`read_sealed` / `write_sealed`) |
| `w<N>.warm` belgilari | AES-256-GCM |
| Tarix kadrlari (JPEG) | AES-256-GCM (`secureSave`, base64) |

Yangi kichik fayl qo'shsangiz — `read_sealed` / `write_sealed` dan
foydalaning, `fs::write` ni to'g'ridan-to'g'ri ishlatmang.

**Yorliq (label) qat'iy belgilanadi**, fayl yo'lidan olinmaydi:
papka yo'li ilova yangilanganda o'zgarishi mumkin va o'shanda kalit
ham o'zgarib, eski fayllar o'qilmay qolardi.

**Migratsiya**: shifrlashdan oldin yozilgan ochiq fayllar ham
o'qilaveradi (avval shifr ochishga urinamiz, bo'lmasa oddiy
ma'lumot deb qaraymiz). Keyingi yozishda ular o'zi shifrlangan
holatga o'tadi.

## TOMOSHA TARIXI

### Qayerda saqlanadi

**Asosiy manba — Turso.** Mahalliy nusxa FAQAT oflayn uchun
(foydalanuvchi talabi: "to'g'ridan-to'g'ri Turso bilan ishlasin,
iloji boricha kamroq so'rov bilan").

Jadval `watch_history_db`: `user_id + anime_id + season_id +
epizod_number` birlamchi kalit, ya'ni bitta qism uchun HAR DOIM
bitta qator. `(user_id, updated_at DESC)` indeksi — ro'yxat aynan
shu tartibda so'raladi.

### So'rovlar soni — buzmang

| Qachon | Nechta so'rov |
|---|---|
| Pleyerdan chiqilganda / qism almashganda / ilova fonga ketganda | **1 ta** `POST /api/history` |
| Kutubxona tugmasi bosilganda | **1 ta** `GET /api/history` |

To'xtagan joy har soniya eslab qolinadi, lekin u FAQAT telefon
xotirasiga yoziladi (`WatchProgress`) — serverga emas.

`GET` javobi ro'yxat uchun kerak bo'lgan hamma narsani bir yo'la
beradi (anime nomi, posteri, bo'lim raqami), ya'ni qo'shimcha
so'rov yo'q. Ro'yxat **60 soniya** xotirada "yangi" hisoblanadi.

**Yuklash `HistoryTab` ning `initState` ida EMAS**: Kutubxona
sahifasi ilova ochilganda birga quriladi (`IndexedStack`), shu
sabab u yerda yuklasak foydalanuvchi kutubxonani ochmasa ham
so'rov ketardi. Yuklash `RootScreen._onTabTap` da — tugma
bosilganda.

**Oflayn**: yuborib bo'lmagan yozuv shifrlangan navbatga
(`watch_history_outbox_<user>`) tushadi va keyingi yuklashda
yuboriladi. O'qib bo'lmasa — oxirgi olingan ro'yxat ko'rsatiladi.
Kalitlar HAR BIR HISOB UCHUN ALOHIDA: bitta telefondan ikki kishi
kirsa, biri ikkinchisining tarixini ko'rmaydi.

### To'xtagan joydagi kadr

`rust/src/mp4.rs` — MP4 konteyneridan BITTA kadr ajratib oladi;
`video_cache.rs` dagi `/thumb?u=<url>&ms=<vaqt>` yo'li uni xizmat
qiladi:

1. yuqori darajadagi atomlar kezilib `moov` topiladi — faqat
   16 baytlik sarlavhalar o'qiladi, ya'ni `mdat` (butun video)
   ustidan sakrab o'tiladi;
2. `stts`/`stss`/`stsc`/`stsz`/`stco` jadvallaridan kerakli
   soniyaning KALIT KADRI topiladi;
3. faqat o'sha kadr olinadi (diskdan — bepul, yoki tarmoqdan —
   50-300 KB);
4. `build_single_frame_mp4` bitta kadrlik to'la haqiqiy MP4
   yasaydi (`stsd` asl fayldan AYNAN ko'chiriladi — busiz dekoder
   kadrni ocholmaydi);
5. natija xotirada 60 soniya turadi va o'zi o'chadi — diskka
   YOZILMAYDI.

Dart tomoni (`WatchHistory.thumbnail`) bu manzilni
`video_thumbnail` paketiga beradi, u telefonning APPARAT dekoderi
bilan JPEG chiqaradi. JPEG shifrlangan holda saqlanadi va qism
oldinga surilsa eskisi o'chiriladi.

**Kadrni Rust dekodlamaydi va dekodlamasin**: H.264/H.265
dekoderi sof Rust'da yo'q, C kutubxonasi esa APK'ni bir necha MB
kattalashtiradi va loyihaning "faqat sof Rust" qoidasini buzadi.

**`/thumb` va `/v` ni bir joyga qo'shmang**: `/v` (ijro) tarmoqqa
UMUMAN chiqmaydi — bu loyihaning asosiy qoidasi. `/thumb` esa
chiqishi mumkin, lekin faqat bir necha yuz kilobayt oladi va
bo'laklarni diskka yozmaydi.

Har bir qadamda xato bo'lsa 404 qaytadi va ilova posterni
ko'rsatadi — hech qachon yiqilmaydi.

### Kutubxona sahifasi

Uchta oyna: **Tarix** (ishlaydi), **Sevimlilar** va
**Yuklanmalar** (hozircha bo'sh — keyingi vazifa).

Tarix ichida "Anime bo'yicha" va "Qism bo'yicha". Qism qatori —
16:9 kadr, pastida progress chizig'i, o'ng tomonda kichik
yozuvlar. **Kadr ustiga qorayish (scrim) TUSHMAYDI** — foydalanuvchi
rasm tiniq ko'rinishini so'ragan; o'qilishi yozuvning O'Z qora
soyasi bilan ta'minlanadi.

## Tekshiruv (har bir o'zgarishdan keyin)

```
flutter analyze          # 0 muammo bo'lishi kerak
flutter test             # test/ — ism va username qoidalari
cd rust && cargo test --lib     # 15/15 o'tishi kerak
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

## KIRISH TOKENI DISKDA (AES-256-GCM)

**TOPILGAN MUAMMO.** Kirish tokeni faqat XOTIRADA turardi.
Foydalanuvchi Telegramga o'tganda xotirasi kam telefonlarda Android
ilovani BUTUNLAY yopib qo'yishi mumkin — token yo'qolardi va qaytib
kelgan odam kira olmasdi. U qaytadan urinardi, ilova esa HAR SAFAR
serverdan YANGI token so'rardi, har bir START esa serverda YANGI
SESSIYA ochardi. Natija: foydalanuvchi bir marta ham kira olmagani
holda "Qurilmalar" ro'yxatida **4 ta sessiya**.

**YECHIM — ikki tomondan.**

*Ilova tomonda.* Token diskka AES-256-GCM bilan MUHRLANGAN faylga
yoziladi (`pending_login.bin`). Kalit asosiy kalitdan (Android
Keystore) HKDF orqali olinadi, ya'ni fayl boshqa qurilmada ham,
ilovadan tashqarida ham ochilmaydi.

- `rust_secure_save` / `_load` / `_clear` — `rust/src/crypto.rs`;
- `AuthService.start()` muddati tugamagan tokenni **qayta
  ishlatadi** — ortiqcha sessiya umuman ochilmaydi;
- `AuthService.restore()` va ilovaga qaytishda
  (`RootScreen.didChangeAppLifecycleState`) `resumePendingLogin()`
  chaqiriladi: START bosilgan bo'lsa hisob **o'zi** ochiladi;
- kirilgach yoki 5 daqiqa o'tgach fayl o'chiriladi.

**QOIDA:** shifrlash o'chiq bo'lsa (asosiy kalit hali o'rnatilmagan)
fayl **umuman yozilmaydi**. Sessiya tokenini ochiq matnda diskka
yozgandan ko'ra, kutilayotgan kirishni yo'qotgan yaxshi.

Test: `cargo test --lib maxfiy_fayl` — diskdagi faylda token ochiq
matnda YO'Qligi ham tekshiriladi.

*Worker tomonda.* `create_session` endi ayni shu qurilma (nomi +
tizimi bir xil) uchun eski yozuvni oldindan o'chiradi — bitta
telefon ro'yxatda HAR DOIM bitta qator egallaydi. Busiz takroriy
urinishlar 4 ta chegarani to'ldirib, foydalanuvchining BOSHQA
haqiqiy qurilmalarini chiqarib yuborardi.

## ISM VA USERNAME — AVTOMATIK BERILADI, HECH NARSA SO'RALMAYDI

Telegramdan faqat `telegram_id` (hisobni tanish uchun), til va
premium belgisi olinadi. **Ism va username Telegramdan
OLINMAYDI.**

- Yangi hisobga nomni **server o'zi qo'yadi**: bazada band
  bo'lmagan **eng kichik** raqamdan `User 7` (ism) va `user_7`
  (username), `profile_done = 1`. Ya'ni foydalanuvchi START
  bosgan zahoti ilovaga kiradi — hech qanday oyna chiqmaydi;
- bo'sh raqamni `next_user_slot` bitta SQL so'rovida topadi
  (`worker/src/lib.rs`). Hisob ID'sining o'zi ishlatilmaydi:
  hisob o'chirilsa ID bo'shaydi va o'chirilgan odamning nomi
  yangi odamga tushib qolardi;
- nomsiz qolgan **eski** hisoblarga `init_db` bir marta
  `UPDATE OR IGNORE ... username='user_'||id` bilan nom beradi;
- foydalanuvchi ikkovini ham profil kartasining **o'ng yuqori
  burchagidagi tahrirlash tugmasi** orqali o'zgartiradi
  (`lib/screens/profile_edit_screen.dart`);
- keyingi kirishlarda `upsert_user` ism/username ustiga
  **yozmaydi** — aks holda tanlangan nom har safar qaytib
  qolardi.

### Ism qoidasi

- eng ko'pi **20 ta belgi**; emoji va istalgan belgi mumkin;
- 20 tani **ilova** sanaydi (`AuthService.nameProblem`, `characters`
  paketi — bitta emoji bitta belgi). Serverdagi chegara faqat
  suiiste'molga qarshi (160 ta Unicode kodi): Rustning `chars()`
  emojini bir necha kod deb sanaydi, ya'ni u yerda 20 deb
  qo'ysak, 4 ta emojili ism ham rad etilardi.

### Username qoidalari (IKKI JOYDA bir xil)

`worker/src/lib.rs` → `username_problem` va
`lib/services/auth_service.dart` → `AuthService.usernameProblem`.
**Birini o'zgartirsangiz ikkinchisini ham o'zgartiring.**

- 3–15 belgi (yuqori chegara — foydalanuvchi talabi);
- faqat `A-Z a-z 0-9 _`. Klaviaturada ham boshqa belgi
  yozilmaydi (`FilteringTextInputFormatter`), ya'ni emoji va
  bo'shliq umuman kirmaydi;
- takrorlanmaydi. Qiyoslash registrga bog'liq emas
  (`LOWER(username)`), bo'sh nomlar indeksga kirmaydi:
  `CREATE UNIQUE INDEX ... WHERE username <> ''`.

Real vaqtda tekshirish: `GET /api/auth/username-check?u=...`.
Ilova har bir belgida emas, yozish to'xtaganidan **350 ms** keyin
so'raydi va kechikib kelgan javobni (nom o'zgargan bo'lsa)
e'tiborsiz qoldiradi — aks holda 15 harf 15 ta so'rov bo'lardi va
javoblar tartibsiz kelib natijani chalkashtirardi.

`profile_done` endi hamma hisobda 1 — maydon eski ilova
versiyalari bilan moslik uchun qoldirilgan, unga qarab hech
qanday oyna ochilmaydi.

## HISOBNI O'CHIRISH

`POST /api/auth/delete-account`. Ilovada **ikki marta** so'raladi:
ikkinchi oyna oqibatlarni ro'yxat qilib ko'rsatadi.

**TARTIB QAT'IY:** 1) B2'dagi profil rasmi → 2) sessiyalar →
3) bir martalik tokenlar → 4) hisobning o'zi.

Nega aynan shunday: bazadagi yozuv B2'dagi faylga **yagona
havola**. Avval hisob o'chsa va keyin fayl o'chmay qolsa, uni endi
hech kim topa olmaydi — fayl omborda abadiy yotib, pul yeb turadi.

Shu sabab rasm o'chishi **tekshiriladi** (`b2_delete_checked`):
o'chmasa hisobga umuman tegilmaydi va 502 qaytadi — foydalanuvchi
qaytadan urinishi mumkin. Fayl allaqachon yo'q bo'lsa, bu xato
hisoblanmaydi.

## QAYSI TELEGRAM BILAN KIRISH

Telefonda bir nechta Telegram bo'lishi mumkin (Telegram, Telegram X,
Plus Messenger...). Ilgari havola `url_launcher` orqali tizimning
STANDART ilovasiga ketardi — foydalanuvchi tanlay olmasdi.

Endi `lib/services/telegram_apps.dart`:

- `kKnownTelegramApps` — ma'lum paketlar ro'yxati;
- `installed()` — qaysilari o'rnatilganini bilib oladi;
- `openWith()` — havolani ANIQ paketga yuboradi.

Bitta bo'lsa to'g'ridan-to'g'ri ochiladi, bir nechta bo'lsa ro'yxat
chiqadi. Tanlov shu seans uchun eslab qolinadi.

**MUHIM:** Android 11+ da ilova boshqa ilovaning borligini faqat
manifestdagi `<queries>` ro'yxatidagilar uchun bila oladi. Paketlar
CI'da (`build-flutter-apk.yml`) `<package>` sifatida qo'shiladi —
ro'yxatga yangi ilova qo'shsangiz, **o'sha yerga ham qo'shing**.

## PROFIL RASMI (foydalanuvchi o'zi tanlaydi)

Profildagi rasm ustiga bosilsa galereya ochiladi. Yo'l anime
rasmlari bilan **bir xil**: ilova faylni B2'ga to'g'ridan-to'g'ri
yuklaydi (`/api/upload-token`), keyin workerga faqat **fayl nomini**
aytadi (`POST /api/auth/avatar`). Rasm baytlari worker orqali
o'tmaydi.

- Fayl nomi qolipi **`avatar_<foydalanuvchi id>_<vaqt>.jpg`** —
  worker uni `valid_avatar_file` bilan tekshiradi. Busiz kimdir
  o'z profiliga masalan `anime_17.jpg` ni bog'lab, keyingi
  almashtirishda worker o'sha anime rasmini B2'dan **o'chirib**
  yuborardi.
- Eski rasm B2'dan **butunlay** o'chiriladi — lekin faqat yangisi
  bazaga saqlangandan **keyin** (saqlash yiqilsa foydalanuvchi
  rasmsiz qolmasin).
- Nom har safar yangi (ichida vaqt belgisi bor), shu sabab eski
  rasm keshda qolib ketmaydi.
- `users_db.avatar_file` bo'sh bo'lsa — Telegram avatari
  (`/api/avatar/:id`) ko'rsatiladi.

`users_db` ga ikkita ustun qo'shildi: **`balance`** (profildagi
"Balans:" qatori) va **`avatar_file`**. Ular `init_db` da
`ALTER TABLE` bilan, **har biri alohida** yuboriladi: Turso
to'plamdagi birinchi xatodan keyin qolganini bajarmaydi, ya'ni
ikkovi bitta to'plamda bo'lsa ikkinchisi hech qachon yaratilmasdi.

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
  tayanadi), bitta so'rovdagi eng katta oraliq esa **64 MiB**
  (`DL_REQUEST_CHUNKS`, worker'dagi `RANGE_MAX` bilan bir xil);
- **oqimlar soni 16** (`DOWNLOAD_THREADS`). O'lchov: bitta ulanish
  mobil tarmoqda atigi ~0.4-0.5 MB/s beradi (yo'l kechikishi sabab),
  shu sabab umumiy tezlik deyarli TO'G'RIDAN-TO'G'RI oqimlar soniga
  proporsional. Qurilmadagi o'lchov: 6 ta oqim = 3 MB/s (oxiriga
  borib 0.5), 12 ta = 5 -> 3.5-4 MB/s, 16 ta = ~6.5 MB/s kutiladi.
  Bundan ko'proq qilish ma'nosiz — kanal (8 MB/s) to'lgach oqim
  qo'shish faqat xotira va batareya sarflaydi.

### Ish qanday taqsimlanadi (`Work` + `claim_next`)

Oynadagi yetishmayotgan bo'laklar **bitta umumiy kursorda** turadi;
oqimlar ishni **kerak bo'lganda, kichik ulushlar bilan** oladi:

| Qoida | Nima qiladi |
|---|---|
| **Adil ulush** | Hech bir oqim qolgan ishning `1/oqimlar` ulushidan ko'pini olmaydi — oxirida bitta oqimda katta ish qolib ketmaydi. |
| **Vaqtga moslashish** | Ulush oqimning O'Z tezligiga qarab ~`CLAIM_TARGET_SECS` (5 s) lik ish qilib olinadi. Sekin ulanish kichik ulush oladi. |
| **Pastki chegara** | Ulush `CLAIM_MIN` (4 MiB) dan kichik bo'lmaydi — mayda so'rovlar uchun yo'l vaqti bekorga sarflanmasin. Kichik faylda chegara o'zi kichrayadi. |
| **Qaytarish** | Javob yarmida uzilsa, ulushning olinmagani navbatga qaytariladi (`return_work`) va uni birinchi bo'sh oqim oladi. |

**NEGA O'ZGARDI (foydalanuvchi: "3 -> 2 -> 1 -> 0.5 MB/s").** Ilgari
ish `DOWNLOAD_THREADS` ta teng **yo'lakka** (`Lane`) bo'linardi va
yo'lagi tugagan oqim boshqasining ishini o'g'irlashi mumkin edi —
lekin faqat HAVODA BO'LMAGAN qismini. 166 MB fayl = 166 bo'lak,
6 ta yo'lak = ~28 bo'lak, bitta so'rov esa 64 bo'lakkacha: ya'ni
**har bir oqim o'z yo'lagini bitta so'rovda olib qo'yardi** va
o'g'irlash uchun hech narsa qolmasdi. Ishi tugagan oqim butunlay
chiqib ketardi, faol oqimlar soni 6 -> 5 -> ... -> 1 ga tushardi va
tezlik ham aynan shunga proporsional pasayardi. Yo'lak tuzatishi
faqat ~400 MB'dan katta fayllarda ishlardi.

Testlar: `yuklab_olish_bitta_sekin_ulanishdan_sudralmaydi` (bitta
sekin ulanish butun yuklashni sudramaydi + ekrandagi tezlik
o'lchovi), `yuklab_olish_yolaklar_bilan_takrorsiz_ketadi` (qoplama:
takror ham, bo'shliq ham yo'q), `yuklab_olish_oxirigacha_parallel_ketadi`.

### Kesh chetiga chiqib ketgan oyna

Worker javobida `X-Cache: MISS` yoki `HIT-RANGE` bo'lsa — javob
isitilgan oynadan EMAS, ya'ni Cloudflare oyna yozuvini o'chirgan va
qolgan yuklash sekin yo'ldan ketadi. Endi ilova buni sezib oynani
**qayta isitadi** (`note_cold_window`), lekin B2 puli uchun QATTIQ
cheklangan: bitta oyna uchun `REWARM_COOLDOWN` (5 daqiqa) ichida
eng ko'pi bir marta. Test: `oyna_keshdan_tushsa_qayta_isitiladi`.

### Oyna chegarasi (480 MiB) endi to'xtatmaydi

Oynadagi **oxirgi ulush olingan zahoti** keyingi oyna fon'da
isitila boshlaydi (`warm_window_bg`). Ilgari chegarada hamma oqim
to'xtab, 480 MiB B2'dan keshga ko'chguncha kutib turardi. Tanbal
keshlash qoidasi buzilmaydi: isitish baribir faqat o'sha oynaga
o'tish oldidan boshlanadi.

### Ekranda tezlik

`rust_video_cache_stats` javobiga `speed` (bayt/soniya) va
`streams` (faol oqimlar soni) qo'shildi; qism qatorida
"1080p / 47% / 78 / 166MB · 5.8 MB/s" ko'rinadi. Sabab: ilgari
ekranda faqat foiz bor edi va "sekinlashdi" degan gapni tekshirib
bo'lmasdi.

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

## TELEGRAM ORQALI KIRISH

Foydalanuvchi hisobi **faqat Telegram bot orqali** ochiladi —
parol, SMS, email yo'q.

### Oqim

```
Ilova                          Worker                      Telegram
  │ POST /api/auth/telegram/start
  ├────────────────────────────>│ 16 xonali token yaratadi
  │<─── token + deep_link ──────│ login_tokens (pending, 5 daq)
  │ t.me/aniraxuzloginbot?start=<token>
  ├─────────────────────────────────────────────────────────>│
  │                             │<── POST /api/telegram/webhook
  │                             │  users_db: topadi yoki yaratadi
  │                             │  sessions_db + login_tokens:
  │                             │    BITTA to'plam so'rovida
  │ GET /api/auth/telegram/status?token=...  (har 0,8 sek + resumed)
  ├────────────────────────────>│
  │<── session + user ──────────│
```

### BOT TEZLIGI — BAZAGA NECHA MARTA BORILADI

Botning "sekinligi" Telegramda emas, **bazaga ketma-ket
borishlarda** edi. Cloudflare chekkasidan Turso'ga har borish
~100 ms, START bosilgandan keyin esa ular ketma-ket ketardi:

| Ilgari | Hozir |
|---|---|
| `SELECT` login_tokens | o'sha-o'sha (1) |
| `SELECT` users_db + `UPDATE` users_db | bitta `UPDATE ... RETURNING *` (1) |
| `SELECT MAX(id)` sessions_db | yo'q — ID `INSERT` ichida hisoblanadi |
| `DELETE` eski qurilma | hammasi bitta `turso_batch` (1) |
| `INSERT` sessiya | ⤷ o'sha to'plamda |
| `DELETE` chegaradan ortig'i | ⤷ o'sha to'plamda |
| `UPDATE` login_tokens approved | ⤷ o'sha to'plamda |
| **~8 borish** | **3 borish** |

Ikkita qoida:

1. `turso_batch` endi **har bir buyruq natijasini tekshiradi** va
   xatoda `Err` qaytaradi. Ilgari javob umuman o'qilmasdi —
   sessiya yozilmagan bo'lsa ham kirish tokeni "tasdiqlangan"
   bo'lib qolishi mumkin edi. Turso to'plamdagi **birinchi
   xatodan keyin qolganini bajarmaydi**, ya'ni tartib muhim:
   sessiya `INSERT` i tasdiqlashdan OLDIN turadi.
2. Ilova natijani **0,8 soniyada** bir so'raydi (ilgari 2 sek).

### BOTDAGI YOZUVLAR

Foydalanuvchi botdan **texnik atama ko'rmasligi kerak**. Har bir
xabar ikki narsani aytadi: NIMA bo'ldi va ENDI NIMA QILISH kerak.
Matnlar bitta joyda — `MSG_HELP`, `MSG_BAD_LINK`, `MSG_EXPIRED`,
`MSG_ALREADY`, `MSG_TRY_LATER` (`worker/src/lib.rs`). Ilgari
xatolik matni to'g'ridan-to'g'ri chiqarilardi
(`❌ Xatolik: Telegram xatosi (sendMessage): ...`) — bu
foydalanuvchiga hech narsa tushuntirmaydi, faqat qo'rqitadi.

Kirish muvaffaqiyatli bo'lganda xabar **ID va username** ni ham
ko'rsatadi va ularni qayerdan o'zgartirishni aytadi.

### Jadvallar (`init_db` ichida, alohida `turso_batch`)

| Jadval | Vazifasi |
|---|---|
| `users_db` | `id` = **oxirgi id + 1** (anime/epizod bilan bir xil tartib), `telegram_id` UNIQUE |
| `login_tokens` | bir martalik 16 xonali token, 5 daqiqa yashaydi |
| `sessions_db` | sessiya jurnali: hisob + **qaysi API** (`api_base`) + **qaysi qurilma** (`device`, `platform`, `app_version`) |
| `app_config` | webhook siri va manzili |

`init_db` ning yuqori qismida `ALTER TABLE ... ADD COLUMN` bor va u
ustun mavjud bo'lganda xato beradi — shu sabab kirish jadvallari
**alohida** `turso_batch` chaqiruvida yuboriladi.

### 4 TA QURILMA CHEGARASI

Bitta hisobga eng ko'pi **4 ta** qurilma kira oladi. 5-chisi
kirganda `create_session` eng **oxirgi onlayn bo'lgan 4 tasini**
qoldiradi, qolgani (ya'ni eng oldin onlayn bo'lgani) o'chiriladi.
Tartib `last_seen_at` bo'yicha, u esa har bir `/api/auth/me`
so'rovida yangilanadi.

Chiqarilgan qurilma keyingi `/api/auth/me` da **401** oladi va
ilova o'zini avtomatik hisobdan chiqaradi (`AuthService.refresh`).
**FAQAT 401** hisobni o'chiradi — tarmoq xatosi yoki 500 emas,
aks holda internet uzilganda foydalanuvchi hisobidan chiqib
ketardi.

### Xavfsizlik qoidalari — BUZILMASIN

- **Bot tokeni ilovaga hech qachon tushmasligi kerak.** U faqat
  Cloudflare secret (`TELEGRAM_BOT_TOKEN`). APK ichidagi satrlarni
  har kim o'qiy oladi.
- **Telegram fayl manzili** (`api.telegram.org/file/bot<TOKEN>/...`)
  ichida bot tokeni bor. Shu sabab avatar `/api/avatar/:id` orqali
  **worker ichidan** uzatiladi va tashqariga faqat rasm baytlari
  chiqadi. Bu manzilni hech qachon javobga qo'shmang.
- Webhook `X-Telegram-Bot-Api-Secret-Token` sarlavhasi bo'yicha
  tekshiriladi. Sirni worker **o'zi** yaratadi (`app_config`) —
  qo'lda qo'shiladigan qo'shimcha secret yo'q.
- Sessiya tokeni javoblarda **qaytarilmaydi**:
  `/api/auth/sessions` uni `current: true/false` belgisiga
  aylantirib, ustunning o'zini o'chirib tashlaydi.

### Sozlash tekshiruvi

Kirish ishlamay qolsa BIRINCHI shu manzil ochiladi:

```
https://aniraxuzapp.ogabekraximov650.workers.dev/api/auth/telegram/health
```

`"ok": true` — hammasi joyida. `bot_token_configured: false` bo'lsa
Cloudflare secret yo'q; `bot_reachable: false` bo'lsa token noto'g'ri
(BotFather'da tiklangan bo'lishi mumkin). Javobda hech qanday sir
ma'lumot yo'q.

### Webhook o'zini o'zi ro'yxatdan o'tkazadi

`ensure_webhook` birinchi `/api/auth/telegram/start` so'rovida
ishlaydi: worker o'z domenini so'rovdan biladi, shu sabab domen
o'zgarsa ham o'zi qayta ro'yxatdan o'tadi. Qo'lda `setWebhook`
qilish shart emas.

### Kesh bilan aloqasi

`main()` ichida kirish yo'llari (`/api/auth/`, `/api/telegram/`)
**yozish keshini tozalash**dan ATAYLAB ajratilgan. Aks holda har
bir kirish `/api/anime` va `/api/seasons` keshini kuydirib
yuborardi. Kirish javoblari `Cache-Control: no-store` bilan
keladi.

### Ilova tomoni

| Fayl | Vazifasi |
|---|---|
| `lib/services/auth_service.dart` | sessiya, hisob, qurilma ma'lumoti (`ChangeNotifier`) |
| `lib/widgets/telegram_logo.dart` | logotip — `CustomPainter`, hech qanday `assets/` yo'q |
| `lib/screens/telegram_login_screen.dart` | kutish ekrani (2 sek so'rov + `resumed`da darhol) |
| `lib/screens/sessions_screen.dart` | kirgan qurilmalar ro'yxati |
| `lib/screens/profile_screen.dart` | kirilmagan: **faqat** logotip + tugma; kirilgan: to'liq profil |

Sessiya tokeni `flutter_secure_storage` da (Android Keystore).
Hisob ma'lumoti ham keshlanadi — shu sabab **internetsiz** ham
profil ochiq turadi.

### Keyingi qadam (hozir QILINMAGAN — foydalanuvchi so'ragan)

Ko'rish tarixini (`lib/services/watch_progress.dart`) hisobga
bog'lash. Hozir progress faqat telefonda saqlanadi; serverga
bog'langanda telefon almashtirilganda ham tarix qolardi. Buning
uchun `users_db.id` bo'yicha yangi jadval (masalan
`watch_progress_db`) va `/api/progress` endpointlari kerak
bo'ladi. **Admin panel himoyasi ataylab qo'shilmagan** — ilova
hali sinovda, tayyor bo'lganda panel butunlay olib tashlanadi.

## ILOVA BELGISI (ARU logotipi)

Qora plita, undan **ARU** harflari o'yib olingan. Barcha fayllar va
ularni qayta chiqarish tartibi: **`branding/README.md`**.

Muhim: `android/` papkasi har build'da `flutter create` bilan qaytadan
yaratiladi va u bilan birga Flutter'ning standart ko'k belgisi keladi.
Shu sabab `build-flutter-apk.yml` dagi «Ilova belgisini o'rnatish»
qadami har safar `branding/android-res/` ni ustiga ko'chiradi. Bu
qadamni olib tashlamang — belgi darhol standartiga qaytadi.

Belgi CI'da QAYTA CHIZILMAYDI: PNG'lar repoda tayyor yotadi, CI faqat
ko'chiradi. Logotip o'zgarsa `node branding/build-icons.js` ni
mahalliy ishga tushirib, natijani commit qilish kerak.

## Tegilmaydigan joylar

- `rust/src/video_cache.rs` ning bo'lak-keshlash va shifrlash qismi
  (sinovdan o'tgan, 15 ta test);
- `rust/Cargo.toml` dagi `panic = "abort"` — Rust tomonida panic
  bo'lsa butun ilova o'ladi, shu sabab Rust kodi juda ehtiyotkorlik
  bilan yozilgan.
