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

## BAZA TOZALANDI VA SXEMA IXCHAMLASHTIRILDI (2026-09)

B2 ombori va Turso bazasi **ikkinchi marta butunlay bo'shatildi**
(bir martalik GitHub Action bilan; fayl ishlatilgach repodan
o'chirildi). Shu sabab `init_db` jadvallarni yakuniy ko'rinishida
yaratadi va `ALTER TABLE` yamoqlari YO'Q.

**`migrate_db` va `reset_stats_once` OLIB TASHLANDI.** Ular eski
sxemani yamoqlash uchun edi; baza toza bo'lgach ikkalasi ham
faqat ortiqcha kod va har yangi izolyatda ortiqcha so'rov edi.

**QOIDA (o'zgarmadi):** yana tozalash kerak bo'lsa — avval YANGI
workerni deploy qiling, KEYIN tozalang. Aks holda tozalash
paytida kelgan bitta so'rov eski sxemani qaytarib yozib qo'yadi.

### ORTIQCHA USTUNLAR OLIB TASHLANDI

Sabab: baza bekorga shishmasin. Qaysi ustun nega ketdi:

| Jadval | Olib tashlandi | Nega |
|---|---|---|
| `users_db` | `language_code`, `is_premium` | yozilardi, hech qayerda o'qilmasdi |
| `sessions_db` | `telegram_id`, `username`, `first_name`, `api_base` | `users_db` dagining nusxasi; ism o'zgarsa eskirib qolardi |
| `login_tokens` | `api_base` | ishlatilmasdi |
| `anime_db` | `created_at` | anime qachon qo'shilgani hech qayerda ko'rsatilmaydi |
| `watch_history_db` | `created_at` | yozilardi, o'qilmasdi |

**`watch_history_db.video_url` endi YALANG FAYL NOMI.** Bu jadval
eng tez o'sadi (qatorlar = foydalanuvchilar × ko'rilgan qismlar),
shu sabab har qatorda to'liq manzil (~90 belgi) o'rniga faqat
fayl nomi (~35 belgi) saqlanadi. Manzil ilovaga berishdan oldin
`resolve_list` bilan yig'iladi — `epizod_db.url_*` bilan bir xil
qoida. Yon foyda: domen o'zgarsa eski yozuvlar ishlayveradi.

## VAQT MINTAQASI — UTC+5 (TOSHKENT)

Hamma vaqt Unix millisekundda (UTC) saqlanadi. Statistika
"chelaklari" esa Toshkent vaqti bo'yicha belgilanadi:
`day_key(ms)` -> `2026-09-11`, `hour_key(ms)` -> `2026-09-11T14`.
**Bu funksiyalarni o'zgartirmang** — eski qatorlar boshqa
mintaqada yozilgan bo'lsa, hisob siljib ketadi.

## INDEKSLAR: KAM, LEKIN ANIQ

Har bir indeks YOZISHNI sekinlashtiradi. Qoida: **birlamchi
kalitning BOSHIDAGI ustunlar bo'yicha qidiruvga qo'shimcha indeks
kerak emas.**

| Indeks | Qaysi so'rov uchun |
|---|---|
| `season_janr(janr)` | janr bo'yicha filtr |
| `users_db(LOWER(username))` unique | username takrorlanmasin |
| `users_db(created_at)` | "shu davrda nechta hisob ochilgan" |
| `login_tokens(expires_at)` | eskirgan tokenlarni tozalash |
| `sessions_db(user_id, last_seen_at)` | qurilmalar ro'yxati, 4 ta chegara |
| `sessions_db(last_seen_at)` | **kunlik faol foydalanuvchi** |
| `watch_history_db(user_id, deleted_at, updated_at DESC)` | tarix ro'yxati |

`anime_db`, `epizod_db`, `ratings_db`, `favorites_db`,
`stats_*` — faqat birlamchi kalit. Qo'shimcha indeks qo'shishdan
oldin uni AYNAN qaysi so'rov ishlatishini yozib qo'ying.

`session_user` ham tejaldi: ikkita so'rov o'rniga bitta "quvur",
va `last_seen_at` faqat **60 soniyada bir marta** yoziladi.

## SHAFFOF STATISTIKA

`GET /api/stats` — hammasi bitta so'rovda, chekkada **5 daqiqa**
keshlanadi (`cache_seconds`), ilovada yana 10 daqiqa
(`StatsService`). Raqamlar diskka ham yoziladi — oflaynda oxirgi
ma'lum holat ko'rinadi.

| Ko'rsatkich | Kunlik | Hafta / oy | Umumiy |
|---|---|---|---|
| Foydalanuvchilar | oxirgi 24 soatda onlayn (`sessions_db.last_seen_at`) | `users_db.created_at` | hamma hisob |
| Ko'rishlar | oxirgi 24 soat | kunlik chelaklar | jami |
| Trafik | oxirgi 24 soat | kunlik chelaklar | jami |
| Tomosha vaqti | oxirgi 24 soat | kunlik chelaklar | jami |

**YILLIK ko'rsatkich ATAYLAB YO'Q** (foydalanuvchi talabi):
kunlik, haftalik, oylik va umumiy yetarli.

**Hodisalar ro'yxati saqlanmaydi** (u millionlab qator bo'lardi) —
faqat yig'indilar: `stats_hourly` (oxirgi 24 soat uchun, 3 kundan
eskisi o'chiriladi) va `stats_daily` (hafta/oy/jami).

**TRAFIKNI ILOVA SANAYDI (worker EMAS).**

Ikki marta tuzatildi, ikkinchisi yakuniy:

1. *Birinchi urinish (endi yo'q).* Javobning E'LON QILINGAN
   uzunligi (`Content-Length`) sanalardi — 166 MB lik video
   "1,14 GB" bo'lib ko'rinardi, chunki pleyer `Range: bytes=0-`
   deb butun faylni so'rab, bir necha megabaytdan keyin
   ulanishni uzadi.
2. *Ikkinchi urinish (endi yo'q).* Javob tanasi sanovchi
   `TransformStream` quvuridan o'tkazilardi. Hisob to'g'rilandi,
   lekin IJRO BUZILDI — pleyerda "yuklanmadi" xatosi chiqa
   boshladi.

**Hozirgi qoida: worker javobga UMUMAN tegmaydi.** `b2_play` va
`b2_proxy` javoblari qanday bo'lsa shundayligicha uzatiladi.
Hech qanday `X-U` sarlavhasi ham yo'q (yadrodan ham, pleyerdan
ham olib tashlangan) — manzil ham, kesh kalitlari ham toza.

Sanoq ilovada:

* `android-template/MainActivity.kt` -> `aru/net` kanali ->
  `TrafficStats.getUidRxBytes(Process.myUid())`. Bu — tizim
  yadrosining hisoblagichi, ya'ni ilova HAQIQATAN qabul qilgan
  bayt: pleyer oqimi, yuklab olish, rasmlar, API — hammasi.
  Mahalliy `127.0.0.1` uzatmasi bunga KIRMAYDI.
* `lib/services/traffic_service.dart` — har 60 soniyada (va
  ilova fon'ga o'tganda) o'lchov oladi, FARQNI yig'indiga
  qo'shadi va diskka yozadi (`list_traffic.rustbin`, shifrlangan).
  Yozuvda hisob raqami ham bor: hisob almashsa eski yig'indi
  tashlab yuboriladi.
* **SUTKADA BIR MARTA** `POST /api/traffic {"bytes": N}` —
  bitta so'rov. Worker `note_traffic` bilan umumiy chelaklarga
  va `users_db.traffic_bytes` ga qo'shadi. Javob 200 bo'lsa
  ilova yuborilgan miqdorni ayiradi va qaytadan sanay boshlaydi.
* Telefon o'chib yonganda tizim hisoblagichi nolga tushadi —
  bu aniqlanadi (yangi qiymat eskisidan kichik) va o'sha
  qiymatning o'zi farq sifatida olinadi.

**Har qanday bayt sanaladi.** `getUidRxBytes` — ilovaning UID'i
ostidagi HAMMA soket: video oqimi, yuklab olish, posterlar,
avatarlar, baza/API so'rovlari, TCP va UDP, sarlavhalari bilan.
Yadro hisoblagichi bo'lmagan qurilmada zaxira yo'l ishlaydi
(Rust yadrosining video hisobi).

**Profil sahifasidagi "Trafik" = Turso'dagi raqam + ilovada
hozircha yuborilmagan yig'indi.** Talab: hisobot sutkada bir
marta ketadi, lekin ko'rsatkich kutib turmasligi kerak. Shu
sabab ekranda ikkovining yig'indisi ko'rinadi:

* raqam TIRIK — video ko'rilgan sayin o'sadi;
* hisobot o'tgan zahoti yig'indi bazaga ko'chadi va son
  SAKRAMAYDI (bazadagisi o'sadi, mahalliysi shuncha kamayadi);
* internet bo'lmasa ham diskdagi oxirgi raqam + mahalliy
  yig'indi ko'rinadi.

**Ko'rish — ODAM BOSHIGA BITTA.** Foydalanuvchi talabi: "bitta
odam bitta videoni 50 marta ko'rsa ham ko'rishlar soni 1 tadan
oshmasin". Shu sabab umumiy hisob faqat shu odam shu qismni
BIRINCHI marta ko'rganda oshadi (`view_count = 0` bo'lganda);
shaxsiy `view_count` esa o'sib boraveradi.

## ILOVA HAJMI: VAQTINCHALIK NUSXALAR

TOPILGAN XATO (foydalanuvchi: "ilova hajmi juda tez ko'tarilib
ketyapti, xuddi keraksiz fayllarni yuklab olayotgandek").

Sabab yuklab olingan videolar emas, **fayl TANLASH** edi:
`image_picker` galereyadan tanlangan faylni ilovaning
vaqtinchalik papkasiga (`getTemporaryDirectory`, Android'da
`cacheDir`) NUSXALAYDI. Admin panelidan 300 MB lik qism
yuklansa, telefonda yana 300 MB paydo bo'lardi — va hech qachon
o'chmasdi. Uch sifat bilan bitta qism ~1 GB joy egallardi.

Yechim `lib/services/storage_janitor.dart` da, ikki qatlam:

1. `dropPicked(path)` — yuklash tugashi bilan nusxa o'chiriladi.
   Video uchun qanday tugashidan qat'i nazar (`finally`), rasm
   uchun esa FAQAT muvaffaqiyatda — xato bo'lsa foydalanuvchi
   qayta urinib ko'ra olsin.
2. `sweep()` — ilova ochilganda 30 daqiqadan eski qoldiqlar
   tozalanadi (tizim ilovani yuklash o'rtasida yopib qo'ygan
   bo'lsa). `libCachedImageData` (posterlar keshi) tegilmaydi.

Faqat ilovaning O'Z papkasidagi nusxa o'chiriladi —
galereyadagi asl faylga hech qachon tegilmaydi.

## HAR BIR HISOBGA — O'Z PAPKASI

TALAB (foydalanuvchi): "chiqish yoki hisobni o'chirishda endi hech
narsa tozalanmasin; boshqa accountga o'tganda ilova ichida
`accountid_1` deb oxiriga user id qo'yib papka ochilsin, yangi
accountga o'tsa `accountid_5` — ya'ni account ma'lumotlari
chalkashib ketmasligi uchun. Lekin rasm va video fayllar bitta
joydan olinishi kerak ikkala accountda ham."

Hisobga TEGISHLI hamma narsa `<hujjatlar>/accountid_<id>` ichida:

* tomosha tarixi va tarix kadrlari (`list_*`, `thumb_*`);
* qayerda to'xtagani (`WatchProgress`);
* sevimlilar, shaxsiy statistika, trafik hisobi.

Kirilmagan bo'lsa — `accountid_0` (mehmon).

**UMUMIY bo'lib qoladigan narsalar** (ikkala hisob ham bitta
joydan oladi, bir xil fayl ikki marta yuklab olinmaydi):

* yuklab olingan videolar — `video_byte_cache` (Rust yadrosi);
* posterlar — vaqtinchalik papkadagi `libCachedImageData`;
* anime ro'yxati — `anime_cache.rustbin`.

**HECH NARSA O'CHIRILMAYDI.** `AccountData.switchTo(id)` faqat
uch ish qiladi: eski papkaga yozilmagan narsalarni yozadi,
papkani almashtiradi, xotiradagi ro'yxatlarni yangi papkadan
qaytadan o'qiydi. Eski hisobga qaytilsa hammasi o'z holicha
ochiladi.

**ESKI VERSIYADAN KO'CHISH:** ilgari fayllar hujjatlar papkasining
o'zida yotardi. Hisob birinchi marta o'z papkasini olganda ular
avtomatik ko'chiriladi (`_adoptLegacyFiles`) — tarix yo'qolmaydi.

## PLEYER OYNALARINI SURISH — SILLIQLIK

Uchta oyna (`Ma'lumot | Qismlar | Bo'limlar`) `PageView` bilan
qo'lda suriladi. Kuchsiz telefonda qotishning sabablari va
yechimlari:

* har bir oyna `_KeepAlivePage` ichida — bir marta qurilgach
  tirik qoladi (`AutomaticKeepAliveClientMixin`);
* oyna ichi `RepaintBoundary` da — surish paytida mazmun
  qaytadan CHIZILMAYDI, tayyor qatlam ko'chiriladi;
* pleyerning o'zi ham, uning ostidagi "hozir nima ko'rilyapti"
  qatori ham alohida `RepaintBoundary` da — pleyerning o'z
  yangilanishi pastdagi ro'yxatni sudrab ketmaydi;
* barmoq ekranda turganda davriy ishlar to'xtaydi
  (`_gestureBusy`): yuklab olish holati so'ralmaydi, oyna
  tekshiruvi va sog'liq kuzatuvchisi o'tkazib yuboriladi.
  Qulf 5 soniyadan keyin o'zi ochiladi — "surish tugadi" xabari
  kelmay qolsa ham tizim to'xtab qolmaydi;
* `allowImplicitScrolling: true` — qo'shni oyna oldindan
  quriladi.

## TOMOSHA VAQTI

TALAB: "1x tezlikda ko'rganda hisoblansin" va "epizod vaqtidan
oshmasin".

- ilova videoning O'Z nuqtasi bo'yicha o'lchaydi (pauza, buferlash
  va sek qo'shilmaydi), faqat ijro ketayotganda va tezlik 1x
  bo'lganda (`video_player_screen` -> `_watchTickPos`);
- yig'indi qism uzunligidan oshmaydi (`WatchHistory.addWatched`
  va serverda yana bir marta cheklanadi);
- serverga JAMI vaqt yuboriladi, server esa faqat **farqni**
  qo'shadi — takroriy yuborish raqamni shishirmaydi;
- ko'rinishi: `1:59` (faqat soat:daqiqa), kattasi `1.284:05`.

## BAHO (IMDb USULI) VA SEVIMLILAR

Ikkovi ham **BO'LIM** darajasida (`ratings_db`, `favorites_db`).

Reyting — **oddiy o'rtacha** (`sum / count`, ikki kasr xona).
Foydalanuvchi talabi: "birinchi odam 10 baho bersa reyting ham
10 bo'lsin, iloji boricha ANIQ bo'lsin". IMDb uslubidagi vaznli
(bayes) o'rtacha sinab ko'rilgan edi — u bitta baho bo'lganda
10 ni 8.5 ga tushirardi va shu sabab OLIB TASHLANDI.

Baho qo'yish oynasida yulduz bosilganda faqat TANLANADI;
saqlash uchun "Baholash" tugmasi bosiladi ("Bekor qilish" ham
bor).

Tezlik uchun `season_db` da hisoblangan ustunlar turadi:
`views_total`, `watch_ms_total`, `fav_count`, `rating_sum`,
`rating_count`, `epizod_count`. Ya'ni Ma'lumot oynasi uchun
BITTA qator o'qiladi (`GET /api/season/:a/:s`), `COUNT(*)`
hech qachon ishlatilmaydi.

## BO'LIM QO'SHISH VA JANRLAR

**TOPILGAN XATO (500):** `season_id` birlamchi kalitning bir
qismi edi va QO'LDA kiritilardi — band raqam kiritilsa SQLite
"UNIQUE constraint failed" berardi va so'rov 500 bo'lib
yiqilardi.

Endi `season_id` ni **server beradi** (`MAX+1`), formada faqat
"N-bo'lim" raqami so'raladi, band raqam esa tushunarli xabar
bilan qaytariladi ("2-bo'lim allaqachon mavjud").

Janrlar `lib/data/janrlar.dart` da (37 ta, alifbo tartibida) va
bo'lim qo'shish oynasida **tugma** ko'rinishida. Bazada
`season_janr` bog'lovchi jadvalida saqlanadi; `season_db.janri`
esa faqat ko'rsatish uchun matn nusxasi.

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

### KIRMAGAN FOYDALANUVCHI ANIMENI OCHOLMAYDI

Bosh sahifadagi kartalar HAMMAGA ko'rinadi, lekin ustiga bosilganda
`AuthService.isLoggedIn` tekshiriladi (`HomeScreen._openSeason`).
Kirilmagan bo'lsa pleyer OCHILMAYDI — o'rniga oyna chiqadi:
"Iltimos anime ko'rish uchun avval profil sahifasiga o'tib
accountingizga kiring yoki yangi accaunt oching".

### SEVIMLILAR VA SHAXSIY STATISTIKA

Pleyerdagi yurakcha bosilgan bo'limlar Kutubxonadagi
**Sevimlilar** oynasida ko'rinadi (`GET /api/favorites` — javobda
bo'lim qatorlarining O'ZI keladi, ya'ni kartochka darhol
chiziladi va pleyer qo'shimcha so'rovsiz ochiladi). Ro'yxat
Kutubxona tugmasi bosilganda yangilanadi va diskka yoziladi.

Profil sahifasida rasm/balans tagida **2x2 shaxsiy statistika**:
nechta ANIME (bo'lim emas — `anime_id` bo'yicha noyob), nechta
qism, necha soat va qancha trafik. Bitta so'rov:
`GET /api/me/stats`.

## ADMIN PANELIDAN "OTILIB CHIQISH"

Rasm/video tanlashda Android galereyani oldinga chiqaradi va
xotirasi kam telefonda ILOVANI BUTUNLAY YOPADI — foydalanuvchi
qaytganda ilova noldan ochilardi.

Buni `Navigator` bilan hal qilib bo'lmaydi (jarayonning o'zi
o'ladi). Shu sabab `lib/services/ui_state.dart`: fayl tanlashdan
OLDIN diskka belgi qo'yiladi, tanlash tugashi bilan olib
tashlanadi. Ilova ochilganda `RootScreen` o'sha belgini ko'rsa —
admin panelini qaytadan ochadi. Foydalanuvchi orqaga qaytsa yoki
ilovani o'zi yopsa, belgi allaqachon tozalangan bo'ladi.

## BOSH SAHIFADAGI KARTA

Karta = bitta BO'LIM (`season_db` qatori). Nomning ustida
`N-bo'lim` yozuvi turadi (`bolim_id`), nomga ajratiladigan joy
esa kartaning O'Z kengligidan hisoblanadi (`LayoutBuilder`):
harf kattaligi va qatorlar soni ekranga qarab o'zgaradi, ya'ni
uzun nom kichik telefonda rasmni bosib ketmaydi, kattasida esa
to'liq ko'rinadi.

### So'rovlar soni — buzmang

| Qachon | Nechta so'rov |
|---|---|
| Pleyerdan chiqilganda / qism almashganda / ilova fonga ketganda | **1 ta** `POST /api/history` |
| Kutubxona tugmasi bosilganda | **1 ta** `GET /api/history` |

To'xtagan joy har soniya eslab qolinadi, lekin u FAQAT telefon
xotirasiga yoziladi (`WatchProgress`) — serverga emas.

### QANCHA KO'RILSA TARIXGA TUSHADI (chegara QAT'IY EMAS)

**TOPILGAN XATO.** Chegara qat'iy 15 soniya edi: `flush()` da ham,
`WatchProgress.save()` da ham. 17 soniyalik qismda esa boshidagi 15
va oxiridagi 30 soniya butun qismni qoplab olardi — ya'ni qisqa
qism necha marta ko'rilsa ham **tarixga umuman tushmasdi** va har
safar **boshidan** ochilardi. Foydalanuvchi aynan shuni ko'rgan.

Endi chegara qism uzunligiga bog'langan va ikkala joyda BITTA
qoida (`WatchProgress.minPositionFor` / `endMarginFor`):
uzunlikning **10%** i, lekin ko'pi bilan 15 (boshida) va 30
(oxirida) soniya. Uzun qismlarda hech narsa o'zgarmadi.

### RO'YXAT DARHOL YANGILANADI (server javobi kutilmaydi)

`flush()` yozuvni serverga yuborishdan OLDIN uchta ish qiladi:

1. `_applyLocal` — yozuvni xotiradagi ro'yxatga qo'yadi (bor bo'lsa
   ustiga yozadi), sanani yangilaydi, ro'yxatni qayta saralaydi va
   shifrlangan nusxaga yozadi. Shu sabab hozirgina ko'rilgan qism
   Kutubxonada **eng tepada** turadi — internet bo'lmasa ham;
2. `_prepareThumb` — to'xtagan joydagi kadrni SHU ZAHOTI yasab
   diskka yozadi (pastga qarang);
3. va faqat keyin — bitta `POST`.

Nom, bo'lim nomi va rasmlar `startEpisode()` orqali pleyerdan
keladi (`widget.season`), ya'ni mahalliy yozuv ham to'liq bo'ladi.

### KADRLAR REAL VAQTDA YANGILANADI

Kadr tayyor bo'lishi bilan `WatchHistory` xabar beradi
(`notifyListeners`), har bir qator esa `peekThumb` orqali uni
darhol oladi. Ya'ni "Anime bo'yicha" va "Qism bo'yicha"
oynalarining IKKALASI ham bir vaqtda yangilanadi — boshqa oynaga
kirib chiqishni kutish shart emas.

### YOZUVNI O'CHIRISH

Qism kadri ustida **uzoq bosilsa** "Rostdan ham bu tarixni
o'chirib tashlaysizmi?" so'raladi. "Ha" bo'lsa: ro'yxatdan darhol
yo'qoladi, kadr fayli o'chiriladi, serverga `DELETE /api/history`
ketadi.

**Yozuv bazadan O'CHMAYDI** (foydalanuvchi talabi): faqat
`deleted_at` belgilanadi. Qism keyin qayta ko'rilsa yozuv yana
paydo bo'ladi, statistika esa umuman buzilmaydi. Yuborib bo'lmasa — navbatga tushadi (`_op: delete`) va
keyin yuboriladi, ya'ni yozuv qaytib kelmaydi.

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

### To'xtagan joydagi kadr — MILLISEKUNDGACHA ANIQ

**TOPILGAN XATO.** Ilgari ikkita joyda aniqlik yo'qolardi:
kalit (`thumbKey`) vaqtni **10 soniyaga** yaxlitlardi va Rust
faqat **kalit kadr**ni berardi (Android esa uni
`OPTION_CLOSEST_SYNC` bilan o'qirdi). Natijada rasm to'xtagan
joydan bir necha soniya narida bo'lardi.

Endi:

* `thumbKey` — aniq millisekund (`<video>_<ms>`);
* Rust `/thumb` kalit kadrdan **so'ralgan kadrgacha** bo'lgan
  namunalarni BITTA oraliq bilan o'qib, ulardan kichik MP4 yasaydi
  (`mp4::build_clip_mp4`). Dekodlash tartibida har bir kadrning
  tayanchlari undan oldin turadi, shu sabab bo'lakni istalgan
  joyda kesish xavfsiz. `ctts` ATAYLAB ko'chirilmaydi — usiz
  "eng oxirgi kadr" AYNAN so'ralgan kadr bo'lib qoladi;
* `MainActivity.kt` bo'lakning davomiyligini o'qib, **oxiridan
  1 ms beri**ga `OPTION_CLOSEST` bilan boradi.

Chegaralar: bitta kadr uchun eng ko'pi **16 MB** va **900**
namuna o'qiladi; oshsa eski yo'lga (bitta kalit kadr) qaytadi —
rasm eskiroq bo'ladi, lekin trafik cheklangan qoladi.

### Kadr QACHON yasaladi

Ko'rish tugagan zahoti (`flush()` ichida), ro'yxat ochilishini
kutmasdan. Ikkita sabab:

* tarix oynasi ochilganda og'ir ish qolmaydi — "Anime bo'yicha"
  dan "Qism bo'yicha" ga o'tishdagi qotish aynan shundan edi;
* **oflaynda ham rasm ko'rinadi**: yuklab olinmagan qism uchun
  kadr tarmoqdan olinadi, tarmoq esa aynan ko'rish paytida bor
  edi.

`rust/src/mp4.rs` — MP4 konteyneridan kadr ajratib oladi;
`video_cache.rs` dagi `/thumb?u=<url>&ms=<vaqt>` yo'li uni xizmat
qiladi:

1. yuqori darajadagi atomlar kezilib `moov` topiladi — faqat
   16 baytlik sarlavhalar o'qiladi, ya'ni `mdat` (butun video)
   ustidan sakrab o'tiladi;
2. `stts`/`stss`/`stsc`/`stsz`/`stco` jadvallaridan kerakli
   soniyaning KALIT KADRI topiladi;
3. faqat o'sha kadr olinadi (diskdan — bepul, yoki tarmoqdan —
   50-300 KB);
4. `build_clip_mp4` kalit kadrdan so'ralgan kadrgacha bo'lgan
   to'la haqiqiy MP4 yasaydi (`stsd` asl fayldan AYNAN
   ko'chiriladi — busiz dekoder kadrni ocholmaydi);
5. natija xotirada 60 soniya turadi va o'zi o'chadi — diskka
   YOZILMAYDI.

Dart tomoni (`WatchHistory.thumbnail`) bu manzilni ilovaning O'Z
kadr ajratuvchisiga (`MainActivity.kt`) beradi, u telefonning
APPARAT dekoderi bilan JPEG chiqaradi. JPEG shifrlangan holda saqlanadi va qism
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

Tarix ichida "Anime bo'yicha" va "Qism bo'yicha". Ikkovi BITTA
joyda yashaydi (`PageView`): tugma bosilsa ham, barmoq bilan
surilsa ham sahifa suzib almashadi.

**Anime bo'yicha** — har bir anime bitta karta: oxirgi ko'rilgan
qismning KADRI, tagida **bo'lim nomi** (anime nomi EMAS), tagida
"Oxirgi marta N-bo'lim M-qismni ko'rdingiz" va
"Sana: 12:46/01/01/2026" (soat/kun/oy/yil).

**Qism bo'yicha** — 16:9 kadr, pastida progress chizig'i,
chiziqning USTIDA yozuvlar: chapda bo'lim nomi / `N-bo'lim
M-qism` / `sana: ...`, o'ngda esa `43,21% | 12:34/56:12`.

Kadrga bosilsa — o'sha qism AYNAN o'sha joydan ochiladi; uzoq
bosilsa — o'chirish so'raladi.

**Kadr ustiga qorayish (scrim) TUSHMAYDI** — foydalanuvchi
rasm tiniq ko'rinishini so'ragan; o'qilishi yozuvning O'Z qora
soyasi bilan ta'minlanadi.

### Pleyer oynalari

Tartib: **Ma'lumot | Qismlar | Bo'limlar**, ochilganda Ma'lumot
turadi. Oynalar `PageView` bilan **qo'lda suriladi**; har biri
`_KeepAlivePage` ichida — bir marta qurilgandan keyin tirik
qoladi va surish paytida QAYTA QURILMAYDI (kuchsiz telefondagi
qotish aynan shundan edi). Tarix oynalarida ham xuddi shunday
(`AutomaticKeepAliveClientMixin` + qatorlarda `RepaintBoundary`).

Ma'lumot oynasida: yuqorida **Baholash** (10 ta yulduz) va
**Sevimlilarga qo'shish**; tagida bo'limning raqamlari
(ko'rishlar, tomosha vaqti, sevimlilar, reyting, `N-bo'lim ·
M qism`, qo'shilgan sana); undan keyin to'liq ma'lumot.

Pleyer bilan qism o'tkazish tugmalari **orasida** — hozir qaysi
bo'lim va qism ko'rilayotgani, u necha marta ko'rilgani, qancha
vaqt tomosha qilingani va qachon qo'shilgani.

### Pleyer QAYSI qismni ochadi

`_autoOpenEpisode` / `_resumeTarget` (`video_player_screen.dart`):

1. tarixdan kelingan bo'lsa — AYNAN o'sha qism, o'sha vaqtdan
   (`startEpizodNumber` / `startAt`);
2. shu bo'limning tarixda yozuvi bo'lsa — o'sha qism, to'xtagan
   joyidan;
3. aks holda — eng birinchi qism.

**Oflaynda pleyer UMUMAN ochilmaydi** (foydalanuvchi talabi):
o'rnida "Ko'rmoqchi bo'lgan qismni tanlang" yozuvi turadi.
Shu sabab avtomatik ochish internet holati ANIQLANGUNCHA
kutadi (`_connectivityKnown`).

Qism qo'lda tanlanganda ham nuqta `_savedPositionOf` orqali
topiladi: avval `WatchProgress` (aniqroq), bo'lmasa tarixdagi
nuqta — ya'ni ilova qayta o'rnatilgan bo'lsa ham qism kelgan
joyidan ochiladi.

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
ro'yxatda (`watch_positions`). Boshidagi va oxiridagi chegaralar
qism uzunligining 10% i (ko'pi bilan 15 / 30 soniya — yuqoridagi
"QANCHA KO'RILSA" bo'limiga qarang); yozish **har soniyada,
darhol diskka**
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
