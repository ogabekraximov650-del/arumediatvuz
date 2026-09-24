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
- **ISH DAVOMIDA XABAR YOZMANG.** Foydalanuvchi talabi (aynan
  shunday): "vazifani to'liq tugatmagunincha menga umuman xabar
  yozma, shunchaki vazifani bajar va oxirida vazifani to'liq
  tugatgach xabar ber — sababi sen har safar xabar yuborganingda
  limit kamayadi".

  Ya'ni: "hozir buni qilyapman", "endi buni boshladim", oraliq
  hisobot — **YO'Q**. Hamma vazifa bajarilib, tekshirilib,
  push qilingandan keyin BITTA to'liq xabar.
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

### KALIT `epizod_id`, RAQAM EMAS (2026-09, TOPILGAN XATO)

TALAB (foydalanuvchi): "watch history jurnaliga epizod raqami
emas idsi yozilsin — sababi qism raqamini o'zgartirganda tomosha
tarixidagi kadrlar qotib qoldi, ya'ni ishlamadi".

Sabab aniq edi: `watch_history_db` ning birlamchi kaliti
`(user_id, anime_id, season_id, epizod_number)` edi. Admin
"5-qism"ni "6-qism" qilib qo'ysa, tarixdagi yozuv HECH QAYSI
qismga tegmay qolardi — kadr ham, "davom ettirish" ham ishlamasdi.

Endi kalit `epizod_id` (qism qo'shilganda bir marta beriladi va
hech qachon o'zgarmaydi).

**`epizod_number` USTUNI YO'Q** (foydalanuvchi talabi:
"jurnaldan epizod number'ni olib tashla, epizod id yetadi").
Raqam baribir `epizod_db` dan `LEFT JOIN` bilan olinardi — bu
ustun faqat o'qilmagan nusxa edi. Jadval eng tez o'sadigani,
har qatordan bitta ustun tejash arziydi.

Diskdagi NUSXADA raqam saqlanaveradi: oflaynda "N-qism" deb
yozish uchun boshqa manba yo'q.

ESLATMA: `CREATE TABLE IF NOT EXISTS` mavjud jadvalni
o'zgartirmaydi, ya'ni bazada ustunning O'ZI keyingi tozalashgacha
qolib turadi (unga endi hech narsa yozilmaydi va o'qilmaydi).
`ALTER TABLE` yamog'i ATAYLAB qo'shilmadi — bu yerdagi qoida.

Qo'shilgan ustun: **`last_quality`** — foydalanuvchi shu qismni
oxirgi marta qaysi sifatda ko'rgani ("720p"). Pleyer qismni
ochishda shu sifatni tiklaydi (`_restoreQuality`), ya'ni keyingi
safar internet yoqilganda video AYNAN o'sha sifatdan davom etadi.
Foydalanuvchi sifatni qo'lda tanlasa — uning tanlovi ustun
(`_qualityChosenByUser`).

Ilovadagi eski (diskda qolgan) yozuvlarda `epizod_id` yo'q. Ular
o'qishda TASHLAB YUBORILADI (`WatchHistory._fromRows`) — aks
holda hammasi bitta kalitga (0) tushib, bir-birining ustiga
yozilardi.

### JANRLAR: BITTA BO'LIM — BITTA QATOR (2026-09)

TALAB (foydalanuvchi): "hozir tursoda bitta bo'lim uchun 4 yoki
5 ta qator yozilyabdi, bu esa harajatni oshiradi".

To'g'ri edi: `season_janr` BOG'LOVCHI jadval edi va har bir janr
uchun alohida qator + alohida `INSERT` ketardi.

Endi u `PRIMARY KEY (anime_id, season_id)` va **`janr_1 ...
janr_10`** ustunlaridan iborat: bitta bo'lim = bitta qator,
bitta `INSERT ... ON CONFLICT` so'rovi. Bo'sh ustun = janr yo'q.
Janr tanlanganda birinchi bo'sh ustunga tushadi (`save_janrs`
qatorni qaytadan yozadi, ya'ni bu o'z-o'zidan hal bo'ladi).

Nega 10 ta: ro'yxatda jami 37 janr bor, bitta bo'limga odatda
3-6 tasi qo'yiladi; bo'sh TEXT ustun SQLite'da bir baytdan
oshmaydi.

**`idx_janr` indeksi OLIB TASHLANDI** — janr 10 ta ustunning
istalganida bo'lishi mumkin va bitta indeks ularni qamrab
ololmaydi. Janr bo'yicha filtr bo'limlar ro'yxatini to'liq ko'rib
chiqadi, lekin bo'limlar soni KICHIK (kontent, foydalanuvchi
emas) — ya'ni bu arzon, yutuq esa har bo'limga bitta yozuv.

### `epizod_db`: `intro_1 ... intro_10`

Openingni o'tkazib yuborish oraliqlari — 5 ta JUFTLIK
(`intro_1`/`intro_2` — 1-oraliq boshi va oxiri, ... `intro_9`/
`intro_10` — 5-oraliq). Qiymat SONIYADA (matn emas): pleyer har
kadrda solishtiradi. 0 — oraliq belgilanmagan.

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

Trafik chelaklarini **ILOVA** to'ldiradi (sinxronlash paketi
ichida). Cloudflare Analytics manbasi sinab ko'rilgan va OLIB
TASHLANGAN — sabab "YAGONA YOZUV YO'LI" bo'limida.

**YILLIK ko'rsatkich ATAYLAB YO'Q** (foydalanuvchi talabi):
kunlik, haftalik, oylik va umumiy yetarli.

**Hodisalar ro'yxati saqlanmaydi** (u millionlab qator bo'lardi) —
faqat yig'indilar: `stats_hourly` (oxirgi 24 soat uchun, 3 kundan
eskisi o'chiriladi) va `stats_daily` (hafta/oy/jami).

Chelaklarga yozish **paketga bir marta** bo'ladi (ilgari har bir
qism uchun 4 ta qator) — "YAGONA YOZUV YO'LI" bo'limiga qarang.

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

### UCHINCHI URINISH — YADRO HISOBLAGICHI HAM OLIB TASHLANDI

Bir muddat hisob Android yadrosidan olindi
(`TrafficStats.getUidRxBytes`). U ham NOTO'G'RI chiqdi.

TOPILGAN XATO (foydalanuvchi: "ilova trafikni xato hisoblayapti —
ilova ICHIDA aylanayotgan trafikni ham hisoblayapti").

`getUidRxBytes` ilovaning UID'i ostidagi HAMMA soketni sanaydi,
shu jumladan MAHALLIY (`127.0.0.1`) uzatmani ham. Pleyer esa
videoni tarmoqdan emas, ilovaning O'Z kesh-serveridan oladi.
Natija:

* bitta video IKKI MARTA sanalardi — bir marta Rust yadrosi uni
  workerdan tortib olganda, ikkinchi marta o'sha baytlar pleyerga
  mahalliy uzatilganda;
* ALLAQACHON yuklab olingan videoni oflayn qayta ko'rganda ham
  trafik o'sardi — hech qanday bayt tarmoqdan kelmagan bo'lsa ham.

`aru/net` kanali OLIB TASHLANDI (`MainActivity.kt` da endi uning
o'rnida `aru/storage` — telefon xotirasi uchun).

### HOZIRGI QOIDA: FAQAT TARMOQQA CHIQADIGAN IKKI JOY

TALAB (foydalanuvchi): "ilova faqatgina internet yoniq vaqtda
worker orqali kelgan baytlarni hisoblashi kerak, ilova
ichidagilarni emas".

| Manba | Nima sanaladi |
|---|---|
| `rust_video_cache_net_bytes` | Rust yadrosi workerdan HAQIQATAN tortib olgan video baytlari |
| `NetMeter` (`lib/services/net_meter.dart`) | http klienti qabul qilgan bayt: API javoblari, posterlar, avatarlar |

Diskdan o'qish, `127.0.0.1`, keshdan olingan rasm — UMUMAN
sanalmaydi, chunki ular bu ikki joydan o'tmaydi.

**HAMMA SO'ROV QANDAY QILIB SANOVCHI KLIENTDAN O'TADI.** Ilovada
14 ta faylda `http.get(...)` bor. Ularni birma-bir o'zgartirish
qarz bo'lardi (yangi so'rov yozilganda hisobga qo'shishni unutish
oson), shu sabab `main()` butun ilovani `http.runWithClient`
zonasida ishga tushiradi — o'shanda `http.get`, `http.post` va
umuman `Client()` chaqiruvlarining HAMMASI `CountingClient` ni
oladi. `cached_network_image` ham oddiy `http.Client()` yaratadi,
ya'ni posterlar ham shu hisobga tushadi.

**MUHIM:** `CountingClient` ning ICHKI klienti `Zone.root.run`
bilan yaratiladi. Aks holda u o'zini o'zi chaqirib, cheksiz
rekursiyaga tushadi.

Qolgani o'zgarmadi:

* `lib/services/traffic_service.dart` — har 30 soniyada (va
  ilova fon'ga o'tganda) o'lchov oladi, FARQNI yig'indiga
  qo'shadi va diskka yozadi (`list_traffic.rustbin`, shifrlangan).
  Yozuvda hisob raqami ham bor: hisob almashsa eski yig'indi
  tashlab yuboriladi.
* Yig'indi **sinxronlash paketining ichida** ketadi
  (`traffic_bytes`) — alohida so'rov YO'Q. Worker uni HAM umumiy
  chelaklarga, HAM `users_db.traffic_bytes` ga qo'shadi
  (`note_traffic`). Javob 200 bo'lsa
  ilova yuborilgan miqdorni ayiradi va qaytadan sanay boshlaydi.
* Ilova qayta ishga tushganda ikkala hisoblagich ham nolga
  tushadi — bu aniqlanadi (yangi qiymat eskisidan kichik) va
  o'sha qiymatning o'zi farq sifatida olinadi.

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

**Baho va sevimli serverga DARHOL bormaydi.** Yangi holat
telefonda hisoblanadi (server bilan BIR XIL qoida bo'yicha),
diskka yoziladi va `SyncQueue` navbatiga tushadi — oflaynda ham
ishlaydi va "saqlanmadi" degan xato chiqmaydi. Batafsil —
"YAGONA YOZUV YO'LI" bo'limi.

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
`season_janr` jadvalining `janr_1 ... janr_10` ustunlarida
saqlanadi (bitta bo'lim — bitta qator, yuqoridagi "JANRLAR"
bo'limiga qarang); `season_db.janri` esa faqat ko'rsatish uchun
matn nusxasi.

## OPENINGNI O'TKAZIB YUBORISH (2026-09)

TALAB (foydalanuvchi): qism qo'shishda `5:14  6:44` deb yozilsa,
video 5:14 ga kelganda "O'tkazib yuborish" tugmasi chiqsin;
bosilsa video 6:44 ga sakrasin.

| Qayerda | Nima |
|---|---|
| Baza | `epizod_db.intro_1 ... intro_10` — 5 juftlik, MATN (`"5:14"`) |
| Qoida | `lib/services/intro_times.dart` — matn <-> millisekund |
| Admin | `add_epizod_screen.dart` — video yuklash oynalari tagida 2 ustun × 5 qator |
| Pleyer | `video_player_screen.dart` -> `_updateIntro` / `_skipIntro` |

### VAQT MATN BO'LIB SAQLANADI (soniya EMAS)

TALAB (foydalanuvchi): "intro vaqtini 5:14 va 6:44 qilib
yoziladigan qil, soniya bilan emas".

Ilgari bazada SONIYA turardi va admin oynasi uni ikki marta
o'girardi (yozishda matn -> soniya, ochishda soniya -> matn).
Bitta ortiqcha qatlam, bitta ortiqcha xato manbai.

Endi bazada ham, ekranda ham AYNAN bir xil matn. Pleyer uni qism
ochilganda BIR MARTA millisekundga o'giradi (`introRangesOf`) va
keyin tayyor songa qaraydi — ya'ni tezlikka ta'sir qilmaydi.

O'girish qoidasi IKKI joyda kerak (admin oynasi va pleyer), shu
sabab u alohida faylda: `lib/services/intro_times.dart`
(`test/intro_times_test.dart` bilan qo'riqlanadi). Nusxa
ko'chirmang — ikkovi bir kun ajralib qoladi.

Tushuniladigan yozuvlar: `5:14`, `05:14`, `1:02:03`, `314`
(yalang soniya — eski yozuvlar). Xato yozuv oraliqni shunchaki
"belgilanmagan" qiladi, PLEYERNI YIQITMAYDI.

### TOPILGAN XATO: INTRO CHIQMASDI

Foydalanuvchi: "pleyerda intro chiqmayapti".

Sabab intro kodida emas edi. Pleyer qismlar ro'yxatini AVVAL
diskdagi keshdan o'qiydi va darhol qism ochadi; keyin serverdan
yangi ro'yxat keladi va `_episodes` almashtiriladi — LEKIN
`_currentEp` ESKI (kesh) obyekt bo'lib qolardi.

Ya'ni admin qismga endi qo'shgan intro vaqtlari ochiq qismda
ko'rinmasdi. Xuddi shu narsa yangi qo'shilgan sifat yoki
o'zgargan nom uchun ham amal qilardi.

Yechim: `_adoptFreshEpisode()` — yangi ro'yxat kelganda ochiq
qism AYNAN o'sha qismning yangi qatori bilan almashtiriladi
(`epizod_id` bo'yicha) va intro oraliqlari qaytadan o'qiladi.

### VAQTNI YOZIB BO'LMASDI (TOPILGAN XATO)

Foydalanuvchi: "intro vaqtini yozib bo'lmayapti, boshqacha
keyboard chiqishi kerak edi".

Sabab: maydonda `TextInputType.phone` turardi. Telefon
klaviaturasida `-`, `+`, `*#`, `.` bor, LEKIN **ikki nuqta
(`:`) YO'Q** — ya'ni `5:14` deb yozishning imkoni yo'q edi.

Endi `TextInputType.datetime` (aynan vaqt uchun: raqamlar bilan
birga `:` chiqadi). Ustiga ikki qavat himoya:

* `FilteringTextInputFormatter` faqat raqam va `:` ni o'tkazadi;
* saqlashda `normalizeIntroInput` ishga tushadi — `514` ham
  `5:14` bo'lib saqlanadi (oxirgi ikki raqam soniya), `44` ->
  `0:44`, `7` -> `0:07`.

### TUGMANING KO'RINISHI, NOMI VA JOYI

* **nomi** — "O'tkazish" (foydalanuvchi aniq shunday so'ragan);
* **joyi** — videoning CHAP YUQORI burchagi. Fullscreen'da
  kontrollar ochiq bo'lsa yuqori qatorda "orqaga" tugmasi
  turadi, shu sabab intro tugmasi o'sha qatorning TAGIGA
  tushadi (`top: 54`) — aks holda ular ustma-ust kelardi;
* **ko'rinishi** pastki paneldagi `HQ` tugmasidan AYNAN
  ko'chirilgan: fon oq 15%, chekkasi `white30`, burchagi 7.
  **Ikkovini birga o'zgartiring** — aks holda ular ajralib
  qoladi.

Ko'rinish qoidasi:

* tugma intro oralig'i **TUGAGUNCHA** turadi (foydalanuvchi
  talabi). Ilgari 5 soniyalik taymer bor edi va tugma o'zi
  yashirinardi — o'sha payt ekranga qaralmasa o'tkazib yuborish
  imkoni yo'qolardi. Endi u faqat oraliq tugaganda yoki bosilgach
  yo'qoladi.

Tugma Stack'ning ENG USTIDA, sek gesture qatlamidan KEYIN
turadi — aks holda unga bosilgan tap sek qatlamiga tushib,
video oldinga sakrab ketardi.

### AVTOMATIK O'TKAZISH (uch nuqta menyusi)

TALAB (foydalanuvchi): "o'ng yuqori qismiga 3ta nuqta qo'y,
ustiga bossa `introni avtomatik o'tkazish` degan yoqib
o'chiradigan tugma bo'lsin: yoqib qo'ysa intro avtomatik
o'tkazib yuboriladi, agar o'chiq bo'lsa qo'lda o'tkazishi kerak".

* uch nuqta — videoning O'NG YUQORI burchagida, faqat kontrollar
  ochiq bo'lganda (yoki menyu ochiq turganda) ko'rinadi.
  Fullscreen sarlavhasi uning tagiga kirmasin deb yuqori qatorda
  44 px joy qoldirilgan;
* bosilganda uch nuqta ostida KICHIK OYNA ochiladi: "Avto
  o'tkazish" yozuvi va yoqib-o'chiradigan tugma (`toggle_on` /
  `toggle_off`). Ko'rinishi `HQ` tugmasidan olingan — oq 15% fon,
  `white30` chekka, burchak 7 (foydalanuvchi talabi);
* **`PopupMenuButton` ISHLATILMAYDI.** Foydalanuvchi talabi:
  "avto o'tkazishni bosganda oyna yopilib ketmasin, faqat oyna
  tashqarisiga yoki 3ta nuqtaga bossa yo'qolsin" — `PopupMenuButton`
  esa tanlangan zahoti o'zini yopadi va buni o'zgartirib bo'lmaydi.
  O'rniga Stack'da uchta qatlam: PARDA (butun ekran, bosilsa
  yopadi), OYNA, va ularning USTIDA uch nuqta (unga bosilsa
  parda tutib qolmasdan menyu yopiladi);
* menyu ochiq turganda kontrollar YASHIRINMAYDI (`_hideTimer`
  bekor qilinadi) — aks holda uch nuqta daraxtdan olib tashlanib,
  oyna "muallaq" qolardi;
* yoqilgan bo'lsa `_updateIntro` tugma ko'rsatish o'rniga
  darhol `_skipIntro()` chaqiradi. Tugma yoqilgan damda video
  intro ichida bo'lsa — o'sha zahoti o'tkaziladi.

Holat `lib/services/app_settings.dart` da: diskda, SHIFRLANGAN
va HISOB PAPKASIDA (`list_settings.rustbin`). Ya'ni bitta
telefonda ikki kishi kirsa har birining o'z sozlamasi bo'ladi.
`shared_preferences` ATAYLAB qo'shilmadi — bittagina bayroq
uchun yangi bog'liqlik va shifrlanmagan fayl ortiqcha.

## PLEYER: PARDA, OXIR VA HALQA

### BILDIRISHNOMA PARDASI PAUZA QILMAYDI

TOPILGAN XATO (foydalanuvchi: "telefonning yuqoridagi internet va
boshqa narsalarni yoqib o'chiradigan oynasini tushirsa video
pauza bo'lyapti; agar ko'tarsa yana play bo'lib ketsin").

Sabab: `didChangeAppLifecycleState` da `inactive` ham `paused`
bilan bir qatorda turardi. Android pardani tushirganda `inactive`
yuboradi — ilova esa FONGA KETMAYDI, video ko'rinib turaveradi.
Xuddi shu holat qo'ng'iroq oynasi va tizim dialoglarida ham.

Endi:

| Holat | Nima bo'ladi |
|---|---|
| `inactive` | tegilmaydi (parda, dialog) |
| `paused` / `hidden` / `detached` | pauza + ESLAB QOLINADI |
| `resumed` | biz pauza qilgan bo'lsak qaytadi |

`_pausedByLifecycle` bayrog'i SHART: usiz foydalanuvchi ataylab
pauza qilib qo'ygan video ham fon'dan qaytganda o'z-o'zidan ijro
bo'lib ketardi.

### VIDEO TUGAGACH QAYTA BOSHLANMAYDI

TALAB (foydalanuvchi): "video tugagach qayta boshlanmasin,
shunchaki pauza bo'lsin".

`_onCompleted` da ilgari `seekTo(0)` + `play()` turardi. Endi
pleyer oxirida pauza bo'lib turadi. "Play" bosilsa
`_togglePlayPause` uni BOSHIDAN boshlaydi (aks holda `play()`
oxirda turgan videoda hech narsa qilmasdi).

### HALQA: FAQAT AYLANMA YOY

TALAB (foydalanuvchi, aniqlashtirilgan): "play/pause atrofida
aylanadigan chiziq qolsin va avvalgidek aylansin, faqat orqasida
kichkina qizil chiziq bor — shuni olib tashla".

Ya'ni play/pause tugmasi atrofida:

* KUTISH paytida (buferlash, sek, tayyorlash) — avvalgidek
  aylanma yoy. Unga TEGILMAGAN;
* qolgan HAMMA vaqtda — hech nima. Videoning qayeridaligini
  ko'rsatadigan qizil yoy ham, uning orqasidagi xira halqa ham
  OLIB TASHLANDI (vaqt pastdagi chiziqda ko'rinib turibdi).

Kod soddalashdi: `_PlayerRing` va `_PlayerRingPainter` dan
`busy`, `progress`, `trackColor` maydonlari butunlay olindi —
halqa endi FAQAT kutish holatida yaratiladi (`_centerButton`
ichida `if (busy)`), shu sabab u har doim aylanib turadi.

### PASTKI (QO'LDA SURILADIGAN) PROGRESS — FAQAT QIZIL NUQTA

TALAB (foydalanuvchi): "progress chizig'ida faqat qizil nuqta
qolsin deganda PASTDAGI videoni boshqa vaqtga o'tkazadigan,
ya'ni qo'lda suriladigan progressni aytgandim".

`_VideoProgressBar` endi hech qanday chiziq chizmaydi:

* orqa (yuklanmagan) qism — yo'q;
* diskka yuklab olingan oq qism — yo'q (shu sabab
  `downloadedRatio` va `_readyRatio()` ham olib tashlandi);
* o'tilgan qizil qism — yo'q.

Qoladigan yagona ko'rinadigan narsa — hozirgi joydagi QIZIL
NUQTA. Stack ichidagi shaffof `SizedBox(width: w)` faqat kenglik
beradi; bosish zonasi (`thumb + 20` balandlik) avvalgidek keng
qoldi, ya'ni surish qulayligi kamaymadi.

## PLEYERDAGI VAQT — FAQAT DAQIQA VA SONIYA

TALAB (foydalanuvchi): "pleyerdagi vaqt faqat daqiqa va
soniyalarda ko'rsatilsin; agar video 2 soat bo'lsa pleyer
`120:00` qilib ko'rsatishi kerak".

Soat AJRATILMAYDI — daqiqa 60 dan oshib ketaveradi. Ikki joyda
bir xil qoida: `video_player_screen.dart` -> `_fmt` va
`history_screen.dart` -> `_clock` (tarix oynasidagi vaqt ham
shunday — foydalanuvchi so'ragan).

## AYLANMA HALQA — BITTA, BITTA JOYDA

TOPILGAN XATO (foydalanuvchi: "pleyerda sek qilganda aylanadigan
progress chizig'idan IKKITA chiqib qolyapti").

Sabab: halqa IKKI joyda chizilardi — kontrollar ichidagi tugma
atrofida (`_centerButton`) va kontrollar yashiringandagi alohida
qatlamda (`_busyRingOverlay`). Ular `_showControls` bo'yicha
almashardi, LEKIN kontrollar `AnimatedOpacity` bilan 200 ms
so'nadi: bayroq o'zgargan zahoti ikkinchi halqa chiqar,
birinchisi esa hali so'nib ulgurmagan bo'lardi. Ustiga ikkovi
har xil joyda turardi (biri kontrollar ustunining o'rtasida,
ikkinchisi ekran markazida) — shu sabab ustma-ust ham tushmasdi.

Endi play/pause tugmasi ham, halqa ham Stack'dagi BITTA
qatlamda (ekran markazida), `_busyRingOverlay` va `_spinnerOnly`
OLIB TASHLANGAN. Kontrollar ichida tugma yo'q — u yerda faqat
tugma egallaydigan bo'sh joy (`SizedBox`) qoldi.

| kutish | ikonka | ekranda |
|---|---|---|
| ha | ha | aylanma halqa + ikonka |
| ha | yo'q | faqat aylanma halqa |
| yo'q | ha | faqat ikonka (halqa yo'q) |
| yo'q | yo'q | hech nima |

**Bu tuzilishni buzmang:** halqani yana ikkinchi joyda chizsangiz
muammo o'sha zahoti qaytadi.

## OFLAYNDA — FAQAT YUKLAB OLINGANLARI

TALAB (foydalanuvchi):

* bosh sahifada faqat yuklab olingan qismi bor anime kartochkasi;
* tomosha tarixi va sevimlilardan ham faqat yuklab olingan
  epizodi borlari ko'rinsin, **qolganlari yashirilsin LEKIN
  XOTIRADA TURSIN**.

Ya'ni hech narsa O'CHIRILMAYDI — ro'yxat faqat filtrlanadi va
internet yoqilishi bilan hammasi qaytadi.

`lib/services/offline_library.dart` — bitta indeks, uchta ekran:

1. diskdagi bo'limlar ro'yxatidan har bir bo'limning qismlari
   o'qiladi (`eps_<anime>_<season>`);
2. hamma sifat manzillari BITTA ro'yxatga yig'iladi;
3. `videoStats` bitta chaqiruvda hammasining holatini beradi —
   u faqat XOTIRADAGI hisobni o'qiydi, diskka chiqmaydi.

**NEGA HAR QATORDA `videoIsComplete` CHAQIRILMAYDI:** u DISKKA
chiqadi (bir marta skanerlaydi) va ro'yxat chizilayotganda buni
qilish kadrlarni tashlab yuborardi.

**NEGA `videoStats` IKKI MARTA SO'RALADI:** Rust tomoni diskni
fon oqimida skanerlaydi, ya'ni ilova endi ochilganda birinchi
javob bo'sh bo'lishi mumkin. Bo'sh javobni "hech narsa
yuklanmagan" deb qabul qilsak, oflayn bosh sahifa bir zumga
bo'm-bo'sh ko'rinardi.

Internet bor-yo'qligi ham SHU YERDA (`isOffline`) — uchta ekran
bir xil haqiqatga qaraydi, uchta alohida obuna ochilmaydi.

**Indeks hali yig'ilmagan bo'lsa (`ready == false`) hech narsa
yashirilmaydi** — aks holda oflaynda ochilgan ilova bir lahzaga
bo'm-bo'sh ko'rinardi.

## OFLAYNDA PLEYER

Ikki xato tuzatildi:

1. **"Ma'lumot" oynasi bo'sh turardi.** `SeasonService.load` da
   disk keshi yo'q edi. Endi javob diskka yoziladi
   (`season_<a>_<s>`) va oflaynda o'sha ko'rsatiladi; pleyer uni
   tarmoq kutmasdan, DARHOL o'qiydi (`SeasonService.fromDisk`).
   Ustiga ekrandagi maydonlar avval `_info` dan olinadi
   (`_seasonStr` / `_seasonNum`): tarixdan ochilganda
   `widget.season` da atigi bir necha maydon bo'ladi.
2. **Tarixdagi kadr bosilganda qism ochilmasdi.**
   `_autoOpenEpisode` ichida to'g'ridan-to'g'ri
   `if (_offline) return;` turardi. Endi oflaynda ham ochiladi;
   ochib bo'lmaydigan qism (hech bir sifati to'liq emas)
   `_getUrl` bo'sh qaytargani uchun o'zi chetlab o'tiladi.

Tarixdan ochish endi qism RAQAMI bilan emas, `startEpizodId`
bilan bo'ladi.

## TARIX KADRLARI: DARHOL VA QOTISHSIZ

Ikki xato ketma-ket tuzatildi va yechim AYNAN hozirgisi.

**1-xato.** "Anime bo'yicha oynasidan Qism bo'yicha oynasiga surib
o'tkazganda birozga qotib turib keyin o'tyabdi."

Sabab: qo'shni oyna surish BOSHLANGAN zahoti quriladi
(`allowImplicitScrolling`) va o'sha kadrda ro'yxatdagi har bir
qator kadr so'rardi. Kadr esa diskdan SINXRON o'qilib shifri
ochilardi (`secureLoad` — FFI), ya'ni bu ish UI oqimida, aynan
surish boshlangan kadrda bajarilardi.

**2-xato (birinchi yechim keltirib chiqargan).** Birinchi yechim
surish davom etayotganda kadr so'rovlarini KUTDIRARDI
(`holdThumbs` / `releaseThumbs`). Qotish yo'qoldi, lekin rasmlar
kechikib chiqadigan bo'ldi — foydalanuvchi: "juda sekin
yangilanyapti, tez va real-time'da yangilanishi kerak". Chunki
kutish barmoq ko'tarilgunicha (fling bilan bir-ikki soniya)
davom etardi.

**HOZIRGI YECHIM: KUTISH YO'Q, OLDINDAN TAYYOR.**

Ro'yxat o'qilishi bilan diskdagi kadrlar FON'DA xotiraga
ko'chiriladi (`WatchHistory._warmThumbs`) — har bir fayldan oldin
kadrga yo'l beriladi, ya'ni UI qotmaydi, va har bir kadr tayyor
bo'lishi bilan ro'yxat yangilanadi. Ro'yxat qurilganda esa
qatorlar kadrni XOTIRADAN oladi (`peekThumb`): na disk, na
kutish.

Shu sabab surish paytidagi qulf endi KERAK EMAS va OLIB
TASHLANDI — qulfsiz ham surish silliq, chunki surish paytida
bajariladigan ish umuman qolmadi.

### YOZISHMADAGI VIDEO KADRI — KO'RUVCHI O'ZI YASAYDI

**TALAB (foydalanuvchi):** «serverga thumbnail yuklanmasin»,
«tomosha tarixidagidek, faqat support chatga mos qilib,
xatolarsiz va tez ishlaydigan qilib video boshidan kadr olinsin»,
«kadr 2-chi soniyadan emas — 100 ms dagi kadr».

**Hozirgi usul (`lib/services/chat_video_thumb.dart`):**

1. Rust yadrosining `"/thumb?u=<manzil>&ms=100"` yo'li faylning
   faqat kerakli baytlarini (`moov` + birinchi kalit kadr) olib,
   BITTA KADRLIK haqiqiy MP4 yasaydi. Yozishmadagi video 2-5 MB
   bo'lgani uchun bu odatda ~100-300 KB.
2. `MainActivity.grabFrame` shundan JPEG chiqaradi.
3. JPEG **shifrlanib diskka** yoziladi
   (`chatthumb_<fayl>.rustbin`) — shu video uchun tarmoqqa boshqa
   hech qachon chiqilmaydi.

Serverga HECH NARSA yuklanmaydi: `media_thumb` maydoni ham,
B2'dagi `thumb_*.jpg` fayllari ham endi ishlatilmaydi.

**Kadr qaysi lahzadan:** `ms=100`. 2 soniya ko'p edi (videoning
boshi ko'rinmasdi), 0 ms esa ko'pincha qora chiqadi. 100 ms
baribir birinchi kalit kadrning ichida bo'ladi, ya'ni 0 ms bilan
bir xil baytlar olinadi — qo'shimcha narxi YO'Q.

### BU XUSUSIYAT BIR MARTA QAYTARIB OLINGAN — SHARTLARNI BUZMANG

Avvalgi urinish (`chat_thumbs.dart`, commit `6671626` da olib
tashlangan) **ishlamadi va video ijrosini sekinlashtirdi**.
`ChatThumbs` ning to'xtatuvchisi yo'q edi: ekran yopilsa ham ish
davom etardi — 4 urinish x 35 s + tanaffuslar ≈ **2,5 daqiqa**,
ikkitasi parallel. Foydalanuvchi chatdan chiqib video ochganda
bu so'rovlar hamon tarmoqni yeb turardi va sekin ulanishda ijro
qotardi.

O'shanda yozilgan TO'RTTA SHART hozir bajarilgan — **ularni
buzmang:**

| shart | qayerda bajarilgan |
|---|---|
| 1. Ekran yopilganda ish to'xtasin | `ChatVideoThumb` **singleton EMAS**: uni ekran yaratadi va `dispose()` qiladi. `_disposed` har `await` dan keyin tekshiriladi. |
| 2. Video ijro etilayotganda umuman ishlamasin | `VideoGate.busy` — har urinishdan oldin. Pleyer va media oynasi `initState`/`dispose` da `enter()`/`leave()` chaqiradi (`lib/services/video_gate.dart`). |
| 3. Urinishlar soni VA vaqti chegaralangan | Lahzalar `_atMsList` = 100 ms, 1 s, 5 s, 15 s (bosh qismi buzilgan video uchun); har lahza bir urinish (15 s), faqat vaqt tugasa bir marta qayta (30 s). Ekran uchun jami **40 ta tarmoq urinishi** (`_sessionBudget`). Navbatda kutish urinish hisoblanmaydi (ilgari 8 s dan keyin sinalmay yiqilardi). |
| 4. Sekin tarmoqda sinalsin | Shu sabab takror urinish yo'q darajada kam — sekin tarmoqda takror faqat zarar. |

**Shuni ham buzmang:** kadr ro'yxat qurilayotgan kadrda
so'ralmaydi — `_VideoThumb` uni `addPostFrameCallback` ichida
so'raydi va puffak faqat XOTIRADAN o'qiydi (`peek`). Diskdan
sinxron o'qish (`secureLoad`, FFI + shifr) ham birinchi `await`
dan KEYIN bajariladi.

**Yadrodagi kadr xotirasi (`THUMB_MEMO`) BIR NECHTA yozuv saqlaydi.**
Ilgari u bitta edi va izohda "bitta yetarli, qatorlar birin-ketin
so'raydi" deb yozilgandi. Kadr ajratuvchi manzilni HAR DOIM ikki
marta ochadi (avval metadata, keyin kadr) — parallel so'rovlarda
ikkinchisi birinchisining bo'lagini o'chirib yuborardi va kadr
qaytadan yasalardi. Regressiya testi:
`kadr_xotirasi_bir_nechta_yozuvni_saqlaydi`.

### KADR NEGA JUDA SEKIN EDI — ZAXIRA BO'LAK (2026-09)

**TOPILGAN XATO (foydalanuvchi):** «thumbnail qo'yish juda juda
sekin ishlayapti... tomosha tarixidagi thumbnail qo'yish ham
nimagadir sekin».

**Sabab:** `ThumbReader::read` ning har bir chaqiruvi ALOHIDA
HTTP so'rovi edi, `find_moov` esa MP4 sarlavhalarini **atigi 16
baytdan** o'qiydi. Odatdagi fayl tartibi `ftyp` → `mdat` → `moov`,
ya'ni bitta kadr uchun:

| # | o'qish | nima |
|---|---|---|
| 1 | `read(0, 16)` | `ftyp` sarlavhasi |
| 2 | `read(32, 16)` | `mdat` sarlavhasi |
| 3 | `read(<oxiri>, 16)` | `moov` sarlavhasi |
| 4 | `read(moov, ~0,5 MB)` | `moov` tanasi |
| 5 | kalit kadr | kadr baytlari |

**Beshta ketma-ket so'rov**, har biri to'liq borib-kelish vaqti
(mobil tarmoqda 0,3-0,8 s) → bitta kadr 2-5 soniya. Bu tomosha
tarixiga ham, yozishmaga ham BIR XIL tegadi — shu sabab
foydalanuvchi ikkalasining sekinligini aytgan.

**Yechim:** `ThumbReader` da **zaxira bo'lak**. Tarmoqqa
chiqilganda kerakligidan ko'proq (`READAHEAD` = 256 KB) olinadi
va xotirada saqlanadi; kichik sarlavha o'qishlari o'sha
bo'lakdan chiqadi. So'rovlar 5 tadan **2 taga** tushadi
(ko'pincha `moov` va kalit kadr bitta bo'lakka tushib, bittaga
ham).

Katta o'qish (kalit kadr oralig'i 8 MB gacha) saqlanmaydi —
`BUF_MAX` = 1 MB, aks holda arzon telefonda xotira video
ijrosidan tortib olinardi.

**Regressiya testi:** `kadr_sarlavhalari_bitta_sorovda_keladi` —
uchta kichik o'qish bitta so'rovga tushishini o'lchaydi. Zaxira
olib tashlansa test yiqiladi.

Shundan keyin yozishmadagi `_maxParallel` 1 dan **2** ga
ko'tarildi (tomosha tarixidagidek) va `_sessionBudget` 8 dan
**16** ga: har bir kadr arzonlashgach, bitta sekin video
orqasidagilarni ushlab turmaydi.

### PLEYER SEKIN OCHILISHI VA TARIX KADRLARI (2026-09-24)

**Foydalanuvchi:** «pleyer va support chatdagi video judayam sekin
ochilyapti, ba'zida ochilmay qolyapti», «tomosha tarixidagi kadrlar
sekin yangilanyapti va ba'zida (rasmdagidek) xato bo'lib qolyapti».

| Sabab | Tuzatish |
|---|---|
| Har kadr uchun `moov` (0,3-2 MB) qaytadan tarmoqdan olinardi | `MOOV_MEMO` (Rust, 4 ta video / 16 MB / 30 daqiqa). Test: `moov_xotirada_saqlanadi` |
| Ko'rish davomida har 45 s da ANIQ kadr yasalardi — kalit kadrdan to'xtagan joygacha 8 MB gacha, ijro bilan bitta kanalda | Ko'rish davomida faqat KALIT KADR (`/thumb?...&exact=0`). Aniq kadr pleyer yopilgach yasaladi (`_roughKeys`) |
| Tarix kadrlari `VideoGate` ga bo'ysunmasdi — qism almashganda / tarixdan ochilganda pleyer bilan kanalni bo'lishardi | Aniq kadr `VideoGate.busy` paytida KUTADI |
| Vaqtinchalik (eski nuqtadagi) rasm turgan qator haqiqiy kadrni boshqa so'ramasdi | `_Frame` `hasThumb`/`ensureThumb` bilan qayta so'raydi (yiqilsa 20 s tanaffus) |
| Rasmdagi qotgan doira — `RefreshIndicator` + `BouncingScrollPhysics` | Tarix ro'yxatlari `Clamping` harakatida; yangilash 25 s dan oshmaydi |
| `initialize()` 25 s da uzilar, keyin oyna MAJBURAN qayta isitilardi (150 s gacha) | 40 s; vaqt tugasa isitmasdan bir marta qayta ochiladi |
| Worker har so'rovda `app_min_version` ni Turso'dan o'qirdi | Izolyat xotirasida 60 s (`min_version_cached`) |

### YOZISHMADA `moov` OXIRIDA BO'LGAN VIDEOLAR KADRSIZ EDI (2026-09-24)

**Foydalanuvchi:** «support chatdagi videolarning hammasida thumbnail
ko'rsatilmayapti, faqat men encode qilgan va moov atomi oldinga
o'tkazilgan videolarda ko'rsatilyapti».

Rust'dagi kadr yasash `moov` oxirida bo'lgan faylda ham TO'G'RI
ishlaydi — ffmpeg bilan yasalgan ikkala fayldan (faststart va
oddiy) baytma-bayt BIR XIL bo'lak chiqdi (`haqiqiy_fayldan_kadr`,
qo'lda ishlatiladigan test). Muammo tarmoqda edi:

| Sabab | Tuzatish |
|---|---|
| Worker `/api/media` keshda yo'q faylga javob berishdan OLDIN butun faylni keshga ko'chiradi — katta (telefon/Telegram) videoda o'nlab soniya; yadro 15 s da ulanishni uzardi va isitish ham to'xtab, kadr HECH QACHON chiqmasdi | **Foydalanuvchi talabi: FAQAT keshdan, B2'ga to'g'ridan-to'g'ri murojaat YO'Q** (keshga tushmasa 503). Yadro kadr so'rovlarini 180 s kutadi (`THUMB_NET_TIMEOUT`), tayyor bo'lak `THUMB_MEMO` da 10 daqiqa turadi (8 ta / 6 MB) |
| Hajm uchun HEAD (worker'da doim 404) + `bytes=0-0` — ikkita ortiqcha so'rov | Hajm birinchi o'qishning `Content-Range` idan (`probe_head`) |
| `ThumbReader` da bitta zaxira bo'lak: `moov` (oxiri) o'qilgach faylning boshi o'chib, kalit kadr uchun yana so'rov ketardi | Ikkita zaxira bo'lak, faylning boshi saqlanadi. `moov` oxirida: 2 so'rov (ilgari 5), boshida: 1. Test: `moov_oxirida_bolsa_ham_kadr_yasaladi` |

### KADR AJRATUVCHI TASLIM BO'LMAYDI (`MainActivity.grabFrame`)

Telegramdan kelgan ba'zi MP4 fayllarda `getFrameAtTime` har doim
`null` qaytaradi — bu ilovaning xatosi EMAS: telefonning O'Z fayl
menejeri ham o'sha fayllarda kadr ko'rsata olmaydi. Shu sabab
ketma-ket bir necha yo'l sinaladi va birinchi natija beradigani
olinadi:

1. bo'lakning oxirgi kadri (`OPTION_CLOSEST`);
2. bo'lakning boshi (`OPTION_CLOSEST_SYNC`, keyin `OPTION_CLOSEST`);
3. `getFrameAtTime()` — tizim o'zi tanlagan "vakil kadr";
4. `getFrameAtIndex(0)` (Android 9+) — izlashsiz, eng ishonchlisi.

Hammasi MAHALLIY ish: tarmoq kerak emas, har biri bir necha o'n
millisekund.

**Kesh muddati (foydalanuvchi talabi):** Cloudflare kesh yozuvlari
`CHUNK_CACHE_SECONDS` = **1000 kun** (ilgari 400).

## YUKLAB OLISH: NAVBAT, 3 TA JOY VA OXIRIGACHA TEZLIK (2026-09-24)

**Foydalanuvchi:** «qaysi sifat boshida bosilsa avval o'sha yuklansin,
yangilari navbatda tursin», «bir vaqtda eng ko'pi 3 ta sifat,
bittasi tugashi bilan keyingisi avtomatik», «fayl 70% ga borganda
tezlik pasayib ketyapti» (fayllar 71 MB gacha).

| Nima | Qanday |
|---|---|
| Navbat tartibi | `DownloadState::seq` (bosilish tartibi). Ilgari `HashMap` dan birinchi uchragani olinardi — tartib tasodifiy edi. Diskdagi navbat ham shu tartibda yoziladi |
| 3 ta joy | `DOWNLOAD_WORKERS = 3`, `choose_task`: boshlangan vazifa (`started`) tugaguncha joyini ushlaydi — xato bilan kutayotgan bo'lsa ham. Test: `navbat_tartibi_va_uchta_joy` |
| Navbatdagini isitmaslik | `start_prepare` endi `start_download` da emas, `run_download` boshida |
| UI | `queued` maydoni → "navbatda" yozuvi (pleyer va Kutubxona) |
| 70% dagi sekinlashish | Sabab: ulush (4 MiB) oxirigacha egasida qolardi; ish tugagan oqimlar chiqib ketar, oxirini sekin ulanishlar YOLG'IZ tortardi. 71 bo'lak / 16 oqim — qolgan ish oqimlardan kamaygan payt ≈ 77%. Yechim: **ish o'g'irlash** (`steal_locked`: eng kech tugaydigan ulushdan tezlikka mutanosib qism) + **yakuniy takrorlash** (`duplicate_locked`: odatdagidan 2 barobar uzoq ketayotgan oxirgi bo'lak parallel olinadi, yutqazgan oqim `stop` bayrog'i bilan darhol to'xtaydi; bitta bo'lak eng ko'pi 2 marta) |
| O'lchov | `yuklab_olish_umumiy_kanalda_oxirigacha_tez` (umumiy kanal + ulanish chegarasi): eski — 70% dan keyin tezlik ~45% ga tushardi; yangi — tushmaydi, jami 4,6 s → 3,6 s. Ortiqcha trafik < 1% (`tekshir_trafik`) |
| 480 MiB dan katta fayl | Keyingi oyna endi oyna BOSHIDA isitiladi (ilgari oxirida — chegarada hamma oqim kutib qolardi) |

### 98% DA TO'XTAB QOLISH (2026-09-24, skrinshot: 70,1/71,1 MB, telefon tarmog'i 0 KB/s)

Yuklash SEKIN emas, TO'XTAB turardi. Sabab: bitta javob keshdan
emas kelsa (`X-Cache: MISS`, `note_cold_window`), oyna qayta
isitilar va HAR BIR oqim HAR BIR so'rovdan oldin `wait_for_warm` da
90 s gacha kutardi. Qo'shimcha: bosqichda birorta bo'lak olinmasa
keyingi urinishgacha 60 s gacha kutilardi.

Tuzatish: qayta isitish uchun BITTA umumiy muddat — `REWARM_WAIT_MAX`
= 3 s (isitish fon'da tugaydi); xatodan keyingi kutish eng ko'pi
10 s. Test `keshdan_bitta_miss_yuklashni_toxtatib_qoymaydi`:
31 s → 4 s.

**Telegram / Cherrygram bilan solishtirish** (`FileLoadOperation`):
Telegram 128 KB (tajribaviy/Cherrygram "o'rta": 512 KB, 8 so'rov;
Cherrygram "ekstremal": 1 MB, 12 so'rov) qat'iy bo'laklar bilan,
doimiy ulanishlarda, bir vaqtda N ta so'rovni havoda ushlab turadi —
biri tugashi bilan keyingisi. Bizda: 1 MiB bo'lak, 16 oqim,
moslashuvchan ulush + ish o'g'irlash + yakuniy takrorlash — xuddi
shu tamoyil (havodagi so'rovlar soni oxirigacha kamaymaydi).

### YUKLASH 5,5 MB/s DAN OSHMASDI — DASTURIY AES (2026-09-24)

Foydalanuvchi interneti 8-10 MB/s, yuklash esa 5,5 MB/s. Sabab:
`aes` 0.8 ARM64 da apparat AES'ni FAQAT `--cfg aes_armv8` bilan
ishlatadi; CI'da bu bayroq yo'q edi, ya'ni har bir bo'lak DASTURIY
AES-128-CBC bilan shifrlanardi. O'lchov (`crypto::tests::shifr_tezligi`,
server protsessori): apparat ~1050 MB/s, dasturiy ~47 MB/s — telefonning
kichik yadrolarida bundan bir necha barobar sekin.

Tuzatish (keyinroq soddalashtirildi): `aes`/`cbc`/`aes-gcm` kutubxonalari
BUTUNLAY olib tashlandi — hamma shifrlash `ring` orqali (u 64-bit da
apparat AES'ni o'zi aniqlaydi, bayroq kerak emas). Pastdagi
"AES-CBC → AES-128-GCM" bo'limiga qarang.

### VIDEO BO'LAKLARI: AES-CBC → AES-128-GCM (2026-09-24)

Foydalanuvchi: «CTR CBC dan yaxshi bo'lsa CBC ni butunlay olib tashla».
CBC (FFmpeg uchun edi, FFmpeg endi ishlatilmaydi) va `cbc`/`aes`
kutubxonalari OLIB TASHLANDI. Bo'laklar endi `ring` ning AES-128-GCM
i bilan (CTR + 16 bayt teg): `[12 bayt tasodifiy nonce][shifr][teg]`.

* NEGA GCM, toza CTR emas: `video_cache` shifrlangan va (kalit
  kechikkanda yozilgan) OCHIQ bo'lakni HAJMIDAN ajratadi — toza CTR da
  hajm o'zgarmaydi. Teg esa buzilgan bo'lakni aniqlaydi.
* `ring` HTTPS uchun allaqachon bor: 64-bit da apparat AES, 32-bit da
  NEON. O'lchov (server): CBC 1050 MB/s → GCM 5700 MB/s.
* Fayl nomi `.bin` → `.c2`; eski `.bin` bo'laklar `scan_and_clean` da
  o'chiriladi (eski yuklanmalar QAYTA yuklanadi).
* Tezroq shifrlash vaqtlarni o'zgartirdi: ish o'g'irlash va yakuniy
  takrorlash endi faqat haqiqatan sekin holatda (`STEAL_MIN_MS` 1,5 s,
  takror — bo'lak kamida 1 s yuklanayotgan va 1 s yutuq bo'lsa).
* Testlar `[profile.test] opt-level = 2` bilan (debug da sinov
  serverlari sekin edi).

**Worker keshi:** B2 dagi hamma fayl 1000 kun (`CHUNK_CACHE_SECONDS`);
telefon sarlavhasi (`CLIENT_CACHE`) ham 1000 kun; 12 MiB dan katta
faylni oraliqsiz so'raganda ham endi kesh oynasi orqali. Telegram
avatarlari (B2 emas, `/api/avatar/`) 1 kun — rasm almashsa yangilansin.

### DISKDA HAMMA NARSA SHIFRLANGAN (2026-09-24)

Foydalanuvchi: «diskda saqlanadigan hamma narsa shifrlansin, faqat
video emas».

| Nima | Qanday |
|---|---|
| Video bo'laklari | AES-128-GCM (`crypto::encrypt_chunk`) |
| Ro'yxat keshlari, tarix/chat kadrlari, navbat, meta | AES-256-GCM (`seal_blob`, `secureSave`) |
| **Rasm keshi** (posterlar, avatarlar, izoh rasmlari) | Ilgari OCHIQ edi. Endi `image_cache.dart`: `_SealingLocalFs` — undan olingan HAR QANDAY fayl muhrlangan (`_SealedFile`: `openWrite`/`writeAsBytes` muhrlaydi, `readAsBytes` ochadi). Papka `files/aru_images/v2/` |
| URL'lar ro'yxati | Ilgari ochiq sqlite. Endi `JsonCacheInfoRepository.withFile` + muhrlangan fayl `aru_images/v2.index` (kesh `.tmp` qo'shni fayl orqali yozadi — u ham muhrlangan, yorliq `.tmp` siz) |
| Hisob egasi fayli | `secureSave` (kalit yo'q bo'lsagina ochiq — himoya o'chmasin) |
| Sozlamalar/tokenlar | `EncryptedSharedPreferences` (avvaldan) |
| Vaqtinchalik: yozilayotgan ovozli xabar, tanlangan rasm | Tizim plagini yozadi (shifrlab bo'lmaydi); yuborilgach O'CHIRILADI |

Rust: `rust_seal_bytes`/`rust_open_bytes`/`rust_free_bytes` (ikkilik,
base64 siz); `RustCore.sealBytes/openBytes`, `cryptoReady`. Kalit
tayyor bo'lmasa rasm DISKKA yozilmaydi va mavjud fayllar o'chirilmaydi.
Eski ochiq kesh (`aru_images/*`, `databases/aru_images.db*`)
`AppImageCache.dropLegacy` da o'chadi.

**Test (haqiqiy yadro bilan):**
`cd rust && cargo build --release`, keyin
`LD_PRELOAD=$PWD/rust/target/release/librust_core.so flutter test test/image_cache_encryption_test.dart`.
Oddiy `flutter test` da bu testlar o'tkazib yuboriladi.

### BIR NECHTA SIFAT BIRGA: JAMI 16 TA ULANISH (2026-09-24)

Foydalanuvchi: «yangi tizimda battar sekin, 2 MB/s dan o'tmayapti».
3 ta sifat x 16 oqim = 48 ta parallel ulanish ochilardi. Endi havodagi
so'rovlar BUTUN ilova uchun `DL_TOTAL_CONNS` = 16 (`DlPermit`, ruxsat
`fetch_span` ichida — isitishni kutish tugagach — olinadi). Sifatlar
ularni bo'lishadi; biri tugasa qolganlari darhol oladi. Ruxsat
kutilgan vaqt oqimning "sekinligi"ga kirmaydi (`inflight_restart`).
Test: `uch_sifat_birga_ulanishlar_chegarasidan_oshmaydi`.

**Chat kadrlari:** buzilgan bosh qismli videolar uchun bir nechta lahza
(`_atMsList`); navbatdagi 8 soniyalik chegara olib tashlandi (u
sekin videolar orqasidagilarni sinamasdan "yiqildi" deb qo'yardi).

## PROFIL: XOTIRA VA TRAFIK

TALAB (foydalanuvchi): "profildagi Xotira va Trafik
statistikalarining o'rnini almashtir: xotirada faqat xotira
ko'rsatilsin, trafikda esa nimaga qancha trafik ketgani aniq
qilib ko'rsatilsin".

| Qayerda | Nima |
|---|---|
| To'rtlikning 4-katagi | **Xotira** — bitta umumiy raqam |
| Pastdagi keng oyna | **Trafik** — toifalar ro'yxati |

### TRAFIK TOIFALARI

Jami raqam = serverdagi son (`users_db.traffic_bytes`) + ilovada
hozircha yuborilmagan yig'indi (eski qoida: hisobot sutkada bir
marta ketadi, ko'rsatkich esa kutmasligi kerak).

Toifalar esa FAQAT telefonda ma'lum — serverda bitta umumiy son
turadi, u nimaga ketganini bilmaydi:

| Toifa | Manba |
|---|---|
| Videolar | `rust_video_cache_net_bytes` |
| Rasmlar | `/api/image/...`, `/api/avatar/...` (http klient) |
| Ma'lumotlar | qolgan hamma API so'rovi |

`TrafficService._totals` — bu UMR BO'YI hisob: sutkalik hisobot
yuborilgach ham NOLLANMAYDI (nollanadigani `_pending`).
Diskka `list_traffic.rustbin` ga yoziladi.

Toifalar yig'indisi jamidan kam bo'lsa (ilova qayta o'rnatilgan,
boshqa qurilmada ko'rilgan) — farq **"Oldingi hisob"** qatoriga
tushadi, ya'ni foizlar har doim 100% ni beradi.

### XOTIRA TOIFALARI

Xotira o'lchovi (`storage_usage.dart`) o'z holicha qoldi — u endi
faqat JAMI raqam sifatida ko'rsatiladi. Toifalarga bo'lish kodi
saqlanib turibdi: kerak bo'lsa oyna qaytariladi.

## YAGONA YOZUV YO'LI: `SyncQueue` + `POST /api/sync`

**Bu loyihaning eng muhim arxitektura qarori.** Buzmang.

### NEGA (pul)

Turso har bir **yozilgan qator** uchun to'lov oladi. Eski
tartibda bitta qism ko'rilganda **7 ta** qator yozilardi:

| Nima | Qator |
|---|---|
| `watch_history_db` upsert | 1 |
| `epizod_db` — views_total, watch_ms_total | 1 |
| `season_db` — views_total, watch_ms_total | 1 |
| `stats_hourly` + `stats_daily` (views) | 2 |
| `stats_hourly` + `stats_daily` (watch_ms) | 2 |

Ustiga `sessions_db.last_seen_at` **har 60 soniyada**. Bitta faol
odam kuniga ~149 qator, shundan ~85% i `last_seen_at`.

| Foydalanuvchi | Eski tartib | Yangi tartib |
|---|---|---|
| 10k | 45M/oy | 4.5M/oy |
| 100k | ~420M/oy (~$281) | ~45M/oy (**$24.92**) |
| 300k | ~1.3 mlrd/oy | ~135M/oy (~$53) |

Foydalanuvchi qo'ygan shart: **kunlik yozish so'rovlari 50 tadan
oshmasin**. Hozirgi tartibda o'rtacha **2-4 ta**.

### UCHTA QOIDA (`lib/services/sync_queue.dart`)

**1. Hamma yozuv avval telefonda.** Ekranda o'zgarish DARHOL
ko'rinadi, serverga keyin xabar beriladi.

**2. Navbat siqiladi.** Har yozuvning `key` si bor
(`h:anime:season:epizod`, `r:anime:season`, `f:anime:season`);
o'sha kalit navbatda bo'lsa eskisi ALMASHTIRILADI. Bir qismni 50
marta ko'rgan odam ham navbatda **bitta** qator qoldiradi.

Ikki xil maydon HAR XIL siqiladi:

| Tur | Qoida |
|---|---|
| holat (pozitsiya, sifat, baho, sevimli) | oxirgisi o'rnini bosadi |
| "birinchi ko'rish" belgisi | **yo'qolmaydi** (`||`) |

`watched_ms` JAMI qiymat sifatida yuboriladi (`WatchHistory` uni
eski yozuvdan davom ettiradi), farqni server hisoblaydi.

**3. Yuborish shartlari + qat'iy kunlik chegara.**

| Shart | Qiymat |
|---|---|
| Navbat to'ldi | 20 qator |
| Fonga ketdi va oxirgi yuborishdan | 30 daqiqa |
| Ochildi va oxirgi yuborishdan | 6 soat |
| Har holda | 24 soatda 1 marta |
| Chiqish / hisobni o'chirish | majburiy |
| **Oddiy yuborish, kuniga** | **12** |
| **Qat'iy chegara, kuniga** | **50** |

Kunlik hisoblagich telefonda (`list_sync_state.rustbin`), mahalliy
yarim tunda nolga tushadi.

### SERVER: `POST /api/sync` (`sync_route`)

ATIGI IKKI marta bazaga boradi:

1. **bitta o'qish quvuri** — eski holat (tarix, baho, sevimlilar,
   mavjud bo'limlar) va oxirgi paket raqami;
2. **bitta yozuv quvuri** — hamma o'zgarish birdan.

Jamlanadi:

* statistika chelaklari — **paketga bir marta** (ilgari har bir
  qism uchun 4 ta);
* `season_db` — **bo'limga bitta** UPDATE: ko'rish, tomosha vaqti,
  reyting va sevimlilar o'zgarishi birga ketadi;
* qiymatlar **NISBIY** (`+?`) yoziladi — boshqa qurilmadan kelgan
  o'zgarish ustidan yozib yuborilmaydi.

### IKKI MARTA SANALMASLIK

Har paketda bir martalik `batch_id`. Oxirgisi `sync_batches`
jadvalida saqlanadi; takrori kelsa worker **hech narsa
yozmaydi** va `duplicate: true` qaytaradi.

Bu MUHIM: ko'rishlar soni va tomosha vaqti **qo'shiladigan**
raqamlar — takror yozilsa hisob shishib ketardi.

### SOXTA RAQAMLARDAN HIMOYA

Endi ko'rishlar sonini va tomosha vaqtini TELEFON aytadi, ya'ni
o'zgartirilgan ilova statistikani shishira olardi. Har paketda:

| Chegara | Qiymat |
|---|---|
| tarix yozuvlari | 100 |
| baho / sevimli | 50 |
| tomosha vaqti jami | 24 soat |
| yangi ko'rishlar | 50 |
| trafik | 256 GiB |

Telefon soati ham tekshiriladi: `updated_at` kelajakda bo'lsa
server vaqtiga tenglashtiriladi.

### `last_seen_at`: 60 SONIYA → 12 SOAT

`SEEN_EVERY_MS`. Bu bazadagi eng ko'p takrorlanadigan yozuv edi.
Kunlik faol foydalanuvchi 24 soatlik oyna bilan sanaladi, shu
sabab 12 soat aniqlikni buzmaydi. Sinxronlash paketi ham shu
vaqtni yangilaydi — u yerda bepul, o'sha quvurning ichida.

### RO'YXATLAR: SERVER JAVOBI USTIGA NAVBAT QO'YILADI

**Yo'l qo'yilishi mumkin bo'lgan xato:** tarix va sevimlilar
ro'yxati serverdan keladi va xotiradagini butunlay almashtiradi.
Navbatdagi yozuv serverda hali yo'q — ya'ni foydalanuvchi
hozirgina qo'shgan narsasi ekrandan YO'QOLIB qolardi.

Shu sabab `WatchHistory._mergeLocal` va
`FavoritesService._mergeLocal` server javobining ustiga
`SyncQueue.pendingHistory()` / `pendingFavorites()` ni qo'yadi.
**Bu ikkisini olib tashlamang.**

### NIMA HALI HAM DARHOL KETADI

| Nima | Nega |
|---|---|
| Kirish / ro'yxatdan o'tish | sessiyani server yaratadi |
| Admin paneli (anime/bo'lim/qism) | kontentning o'zi, faqat admin |
| Hisobni o'chirish | orqaga qaytmaydigan amal |

### UMUMIY TRAFIK — ILOVADAN (Cloudflare Analytics OLIB TASHLANDI)

Bir muddat bosh sahifadagi trafik Cloudflare'ning
`workersInvocationsAdaptive.sum.responseBodySize` maydonidan
olindi. Texnik jihatdan **ishladi**, lekin raqam telefon qabul
qilganidan **~10 barobar katta** chiqdi: pleyer
`Range: bytes=0-` bilan so'rab, bir necha megabaytdan keyin
ulanishni uzadi — Cloudflare esa yo'lga chiqqan baytni sanaydi.

Foydalanuvchi bunga "bu soxta" dedi, shu sabab **butun Cloudflare
manbasi olib tashlandi** (`cf_traffic_sync`, `traffic_src`,
`CF_*` sirlar). Endi yagona manba — ilova.

**Eski qatorlar BIR MARTA o'chirildi.** `init_db` ichida
`traffic_reset_v2` belgisi bilan: belgi yo'q bo'lsa
`stats_hourly` va `stats_daily` dagi `metric='traffic'` qatorlari
o'chiriladi va belgi qo'yiladi. Aks holda yangi (to'g'ri) raqam
eskisining ustiga qo'shilib, hech qachon haqiqatga kelmasdi.
Kelajakda yana tozalash kerak bo'lsa — belgi nomini
`traffic_reset_v3` ga o'zgartiring.

**Agar server xarajatini bilish kerak bo'lsa** — uni Cloudflare
dashboardidan qarash kerak, ilovaga qo'shish emas
(foydalanuvchi talabi: admin paneliga ham qo'shilmasin).

## TOPILGAN XATOLAR: KIRISH, CHIQISH VA HISOBNI O'CHIRISH

Uchtasi ham 2026-09 da foydalanuvchi topgan va tuzatilgan.

### 1. CHIQQANDAN KEYIN ILOVA O'ZINI O'ZI QAYTA KIRGIZARDI

**Belgi:** hisobdan chiqib, qaytadan kirmoqchi bo'lsa
"Telegramni ochish" tugmasi umuman chiqmasdan hisobga qaytib
kirib ketardi.

**Sabab:** kutilayotgan kirish tokeni HISOB PAPKASIDA saqlanadi
(`_pendingPath` -> `dataDirPath`). `check()` kirish
muvaffaqiyatli bo'lganda avval `_save()` ni chaqirardi, u esa
papkani `accountid_0` (mehmon) dan `accountid_<id>` ga
almashtirardi. Keyingi `clearPending()` YANGI papkadagi mavjud
bo'lmagan faylni o'chirardi — asl token mehmon papkasida
qolaverardi. Chiqilgandan keyin ilova yana mehmon papkasiga
tushar, o'sha tokenni topar va o'zini o'zi kirgizib yuborardi.

**Tuzatish:** `clearPending()` endi `_save()` dan OLDIN
chaqiriladi; ustiga `_clear()` (chiqish) papka almashishidan
oldin ham, keyin ham tozalaydi. **Tartibni buzmang.**

### 2. HISOBNI UMUMAN O'CHIRIB BO'LMASDI

**Sabab (ikkitasi):**

1. Profil rasmi B2'dan o'chmasa BUTUN amal to'xtardi va 502
   qaytardi. B2 bir zumga javob bermasa foydalanuvchi hisobidan
   abadiy qutula olmasdi;
2. hamma o'chirish BITTA Turso quvurida edi — bitta buyruq
   yiqilsa hisobning o'zi ham o'chmay qolardi.

**Tuzatish:**

* rasm o'chmasa ham hisob o'chadi, fayl nomi `orphan_files`
  jadvaliga yoziladi (fayl "yo'qolib" ketmaydi, keyin topib
  o'chirsa bo'ladi);
* ikki bosqich: 1) hisoblagichlarni tuzatish va shaxsiy
  yozuvlar — xatosi yutiladi; 2) `sessions_db`, `login_tokens`,
  `users_db` — MAJBURIY, yiqilsa aniq xabar qaytadi;
* ilova endi serverning xabarini KO'RSATADI ("O'chirib bo'lmadi"
  degan quruq matn o'rniga).

### 3. HISOB PAPKASI BOSHQA ODAMGA O'TIB KETISHI MUMKIN EDI

**Xavf:** `users_db.id` QAYTA ISHLATILADI — server yangi hisobga
"band bo'lmagan eng kichik raqam" ni beradi (`next_user_slot`,
`user_1` / `User 1` nomlari uchun). Papka nomi esa aynan shu
raqamdan yasaladi (`accountid_1`). Ya'ni 1-raqamli hisob
o'chirilib, keyingi odam ham 1 ni olsa, eski egasining
telefonidagi papka yangi odamga ochilib qolardi.

**Tuzatish:** papkaga `owner.json` yoziladi — ichida egasining
TELEGRAM raqami (u hech qachon qayta ishlatilmaydi). Kirganda
raqam mos kelmasa papka tozalanadi
(`AccountData.guardOwner`, `switchTo` va `restore` da
chaqiriladi).

### 4. `ensure_db` YIQILSA HAM "TAYYOR" DEB BELGILARDI

`init_db` xatosi yutilardi, lekin `DB_READY` baribir
qo'yilardi — izolyat umrining oxirigacha jadvallar yaratilmagan
holda ishlayverardi va har bir so'rov "no such table" bilan
yiqilardi. Endi belgi FAQAT uchala quvur ham muvaffaqiyatli
bo'lganda qo'yiladi.

## BALANS, OBUNA VA TO'LOVLAR (tezchek.uz)

TALAB (foydalanuvchi): profil sahifasida "Obuna olish va Balans
to'ldirish" tugmasi; ichida uchta surib o'tkaziladigan oyna —
**Obuna**, **To'ldirish**, **Tarix**. Balansda pul bo'lsa Obuna
oynasi, bo'lmasa To'ldirish oynasi ochiladi.

### PUL BILAN BOG'LIQ HAR BIR QAROR SERVERDA

Ilovada birorta narx YO'Q. Tariflar `worker/src/lib.rs` dagi
`PLANS` da:

| Kun | Narx |
|---|---|
| 1 | 1 000 so'm |
| 5 | 4 000 so'm |
| 10 | 7 000 so'm |
| 20 | 12 000 so'm |
| 30 | 15 000 so'm |

Ilova faqat **kunni** yuboradi (`{"days": 5}`), narxni server
o'zi topadi. Aks holda o'zgartirilgan ilova 30 kunlik obunani
1 so'mga olardi. **Narxni ilovaga ko'chirmang.**

### JADVALLAR

| Jadval | Nima |
|---|---|
| `payments_db` | har bir to'lov havolasi (`order_id` PK, `status`, `expires_at`) |
| `subs_db` | odamga bitta qator: obuna qachon tugaydi |
| `billing_log` | Tarix oynasi: har bir to'ldirish va obuna |

### YO'LLAR

| Yo'l | Nima qiladi |
|---|---|
| `GET /api/billing` | balans, obuna muddati, tariflar, faol havolalar, tarix |
| `POST /api/billing/create` | tezchek'da to'lov yaratadi, havola qaytaradi |
| `POST /api/billing/check` | to'lov bo'ldimi; bo'lsa balansni oshiradi |
| `POST /api/billing/subscribe` | balansdan yechib obunani uzaytiradi |

### TEZCHEK API

Hujjat: `https://tezchek.uz/public-api-system`
(OpenAPI: `?action=get_openapi`). Atigi ikkita yo'l kerak:

```
POST https://tezchek.uz/api/create_invoice
     {api_key, amount}            -> {ok, order_id, pay_url}

POST https://tezchek.uz/api/status_invoice
     {api_key, order_id}          -> {ok, payment:{status:"paid"|...}}
```

Kalit — worker siri **`TEZCHEK_API_KEY`** (GitHub secret'dan
`deploy-worker.yml` qo'yadi). U ilovaga **hech qachon
chiqmaydi**.

### PUL IKKI MARTA QO'SHILMASLIGI

"Tekshirish" tugmasini necha marta bossa ham balans BIR MARTA
oshadi:

```sql
UPDATE payments_db SET status='paid', paid_at=?
 WHERE order_id=? AND status='pending' RETURNING order_id
```

Qator qaytmasa — demak boshqa so'rov ulgurgan va balans
allaqachon oshirilgan. **Bu shartni olib tashlamang.**

### HAVOLA 1 SOAT YASHAYDI

`PAY_LINK_TTL_MS`. Muddati o'tgan havolalar ro'yxatda
ko'rsatilmaydi, bir kundan keyin esa jadvaldan o'chiriladi
(`/api/billing` ichidagi tozalash).

## YUKLANMALAR OYNASI

TALAB (foydalanuvchi): foiz **real vaqtda** yangilansin, qanaqa
sifatda / qancha MB / qancha foiz yozilsin, tozalash tugmasi
kattaroq va aniq ishlaydigan bo'lsin, kadr yonida yuklab olish
ikoni bo'lsin.

* `DownloadsIndex.refreshStats()` — ARZON yangilanish: faqat
  `downloaded`/`total` raqamlari (bitta `videoStats` chaqiruvi,
  diskka chiqmaydi). Ro'yxatda har soniyada chaqiriladi, to'liq
  `refresh()` esa 10 soniyada bir marta;
* ro'yxat `WatchHistory` ni ham eshitadi — kadr tarix
  oynasidagidek darhol yangilanadi (ilgari faqat `DownloadsIndex`
  eshitilardi va kadr eskirib turardi);
* `qualityOf(url)` — fayl nomidan sifatni ajratadi
  (`ep_1_1_720p_...mp4` -> `720p`);
* tugmalar `_RowIconButton` — 40x40 bosish maydoni (ilgari ikonka
  17 nuqta edi va barmoq tegmasdan qolardi);
* yuklab olish ikoni `_QualitySheet` ni ochadi: har bir sifat,
  hajmi va "Yuklab olish" tugmasi. Hajm yuklab olingan sifat
  uchun diskdan, qolganlari uchun bir baytlik `Range` so'rovidan
  (`DownloadsIndex.sizeOf`).

## TUZATILGAN XATOLAR (2026-09, ikkinchi to'plam)

### AVTO O'TKAZISH ISHLAMASDI — CHEKSIZ SEK HALQASI

**Belgi:** avto o'tkazish yoqilganda intro vaqti kelganda
o'rtadagi halqa aylanaverardi, video esa o'tmasdi.

**Sabab:** sek AYNAN oraliqning oxirgi millisekundiga qilinardi.
Pleyer eng yaqin KALIT KADRGA tushadi va u ko'pincha oraliqning
ICHIDA qolardi — keyingi pozitsiya yangilanishida `_introAt`
yana o'sha oraliqni topib, `_skipIntro` qaytadan chaqirilardi.

**Tuzatish:** sek oraliq oxiridan `_introSkipPad` (400 ms) keyinga
qilinadi va o'tkazilgan oraliq `_introDone` ga yoziladi — ikkinchi
marta AVTOMATIK o'tkazilmaydi (qo'lda tugma bosish mumkin).

### TRAFIK FOIZI 100% DAN OSHARDI

Tepadagi jami raqam SERVERDAN olinardi, pastdagi taqsimot esa
TELEFONDAGI umrbod hisobdan — ikki xil manba. Telefondagisi
kattaroq bo'lib qolsa "70,9 MB — 100.00%" bo'lib, jami esa
70,3 MB bo'lib turardi. Endi jami — **ikkovining kattasi**.

### PASTKI PANEL TIZIM TUGMALARI USTIGA CHIQARDI

Faqat `viewPadding` ga tayanilardi va u ba'zi holatda nol
kelardi. Endi `viewPadding` va `padding` ning KATTASI olinadi,
eng kam chekinish 24 nuqta.

### PLEYER OYNALARI KO'RINMASDI

Yarim shaffof oq to'rtburchak ochiq kadr ustida yo'qolib ketardi.
Endi `_PlayerPanel`: `BackdropFilter` (orqa xiralashadi) + quyuq
QORA fon + aniq chegara va soya.

## YUKLASH TEZLIGI O'LCHAGICHI

**Nima aniqlangan:** server (isitilgan keshdan) **35-87 MB/s**
beradi va bo'lak o'lchami deyarli ahamiyatsiz — 1x32 MiB ham,
16x2 MiB ham bir xil. Ya'ni 5-6 MB/s chegara **telefondagi
kodda**.

Qaysi qismida ekani TAXMIN bilan emas, o'lchov bilan aniqlanadi.
`DlTiming` har bir oqimning vaqtini beshga bo'lib yig'adi va
yuklash tugagach jurnalga yozadi:

```
O'LCHOV <kalit>: 166.0 MB / 31.2s = 5.32 MB/s |
  kutish 2.1s (7%) · ttfb 2.9s (9%) · o'qish 18.1s (58%) ·
  yozish 9.4s (30%) · qulf 0.8s (3%)
```

Bitta yuklashdan keyin shu qator sababni ANIQ ko'rsatadi.

## TELEGRAM O'ZI OCHILMAYDI

TALAB (foydalanuvchi): "Telegram orqali kirish tugmasini
bosganda Telegram avtomatik ochilmasin — shunchaki 'Telegramni
ochish' degan tugma chiqib tursin".

Ilgari kirish ekrani ochilishi bilan ilova o'zi Telegramga
sakrab ketardi. Endi ekran ochilganda faqat BITTA holat so'rovi
yuboriladi (token diskda saqlangani uchun foydalanuvchi START'ni
allaqachon bosgan bo'lishi mumkin), Telegram esa FAQAT
"Telegramni ochish" tugmasi bosilganda ochiladi.

## KUTUBXONA: YUKLANMALAR

TALAB (foydalanuvchi): "Kutubxona sahifasidagi yuklanmalar
oynasini olib tashlab, tarix oynasiga qism bo'yicha oynasining
o'ng tarafiga qo'sh".

Kutubxonada endi ikkita oyna (Tarix, Sevimlilar); "Yuklanmalar"
esa tomosha tarixining UCHINCHI sahifasi — barmoq bilan surib
o'tiladi.

### RO'YXAT QANDAY YIG'ILADI

Rust yadrosida "qaysi videolar keshda bor" degan ro'yxat YO'Q —
u faqat berilgan manzillar bo'yicha holat qaytaradi. Shu sabab
`downloads_index.dart` nomzodlarni `OfflineLibrary` dagi kabi
yig'adi (anime keshi + tarix + sevimlilar -> `eps_*` -> hamma
sifat manzillari) va BITTA `videoStats` chaqiruvi bilan
holatni oladi. `downloaded > 0` bo'lganlari qoladi.

**Tartib — oxirgi bo'lak qachon yozilgani.** Rust har video
uchun alohida papka ochadi
(`<support>/video_byte_cache/<kalit>`), papkaning
o'zgartirilgan vaqti aynan shuni bildiradi. Kalit qoidasi
`cacheKeyOf` da va u `rust/src/video_cache.rs` -> `cache_key`
bilan BIR XIL bo'lishi SHART — biri o'zgarsa ikkinchisi ham
o'zgarishi kerak.

**Bitta qism = bitta qator** (eng ko'p yuklangan sifat), lekin
o'chirishda qismning HAMMA sifati o'chiriladi.

**To'liq yuklanmagan qism** bosilganda ochilmaydi — avval
"to'liq yuklab olinsinmi?" deb so'raladi (foydalanuvchi talabi).

## BREND: ARU / ARUmedia

Ilova nomi — **ARUmedia**, logotipi — **ARU**. (`fulutter` faqat
repo/papka nomi va Android paket nomi: `uz.fulutter.fulutter`.)

| Qayerda | Nima |
|---|---|
| Telefondagi belgi | `branding/android-res/mipmap-*/ic_launcher.png` |
| Yumaloq belgi | `ic_launcher_round.png` — MIUI/One UI aynan shuni oladi |
| Moslashuvchan belgi | `mipmap-anydpi-v26/ic_launcher.xml` (qora fon + oq harflar) |
| Belgi ostidagi yozuv | CI manifestga `android:label="ARUmedia"` yozadi |
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

**Asosiy manba — Turso, lekin YOZUV NAVBAT ORQALI.** Mahalliy
nusxa ham oflayn uchun, ham yuborilmagan o'zgarishlarni ushlab
turish uchun kerak: server ro'yxati kelganda uning ustiga
`SyncQueue.pendingHistory()` qo'yiladi (`_mergeLocal`), aks holda
hozirgina ko'rilgan qism ekrandan yo'qolib qolardi.

Jadval `watch_history_db`: `user_id + anime_id + season_id +
epizod_id` birlamchi kalit (RAQAM emas — yuqoridagi "KALIT
`epizod_id`" bo'limiga qarang), ya'ni bitta qism uchun HAR DOIM
bitta qator. `(user_id, deleted_at, updated_at DESC)` indeksi —
ro'yxat aynan shu tartibda so'raladi.

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

Sevimlilar ro'yxati ham server javobining ustiga navbatni
qo'yadi (`FavoritesService._mergeLocal`) — yurakcha bosilgan
zahoti Kutubxonada ko'rinadi, sinxronlash kutilmaydi.

Profil sahifasida rasm/balans tagida **2x2 shaxsiy statistika**:
nechta ANIME (bo'lim emas — `anime_id` bo'yicha noyob), nechta
qism, necha soat va qancha trafik. Bitta so'rov:
`GET /api/me/stats`. Paket muvaffaqiyatli ketgach u majburiy
yangilanadi — aks holda raqamlar bir necha soat orqada qolardi.

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
   (`startEpizodId` / `startAt`);
2. shu bo'limning tarixda yozuvi bo'lsa — o'sha qism, to'xtagan
   joyidan;
3. aks holda — eng birinchi qism.

Sifat ham tiklanadi: tarixdagi `last_quality` shu qismda mavjud
bo'lsa, video aynan o'sha sifatdan ochiladi (`_restoreQuality`).

**OFLAYNDA HAM OCHILADI (2026-09 da o'zgardi).** Ilgari bu yerda
`if (_offline) return;` turardi va tarixdagi kadr bosilganda
oflaynda hech nima ochilmasdi. Endi qism to'liq yuklab olingan
bo'lsa ochiladi; aks holda `_getUrl` bo'sh qaytaradi va pleyer
o'rnida "Ko'rmoqchi bo'lgan qismni tanlang" yozuvi qoladi.
Avtomatik ochish internet holati ANIQLANGUNCHA baribir kutadi
(`_connectivityKnown`) — qaysi sifat ochilishi shunga bog'liq.

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

## HISOBNI O'CHIRISH VA HISOBDAN CHIQISH

Ikkalasi ham **progress chizig'i bilan** ko'rsatiladi
(`_TaskDialog`, `profile_screen.dart`) — foydalanuvchi talabi.

### CHIQISH (`logout`)

1. `syncBeforeLogout()` — navbat MAJBURIY yuboriladi;
2. chiziq 100% ga yetgach: **"Hammasi saqlandi — ma'lumotlaringiz
   sinxronlandi. Sizni ilovamizda kutib qolamiz!"**;
3. keyin `logout()`.

**Internet yo'q bo'lsa chiqish BLOKLANMAYDI.** Oyna "ma'lumotlar
telefonda saqlanadi va keyingi kirishingizda yuboriladi" deydi va
**Baribir chiqish / Qayta urinish / Bekor qilish** tugmalarini
beradi. Navbat hisobning `accountid_<id>` papkasida qoladi.

**Chiqishda telefonda HECH NARSA o'chmaydi** (eski qoida o'z
kuchida): o'sha hisobga qaytilsa hammasi joyida turadi.

### HISOBNI O'CHIRISH (`POST /api/auth/delete-account`)

Ilovada **ikki marta** so'raladi; ikkinchi oyna oqibatlarni
ro'yxat qilib ko'rsatadi.

**TARTIB QAT'IY:** 1) B2'dagi profil rasmi → 2) hisoblagichlarni
tuzatish → 3) qolgan hamma yozuv → 4) telefondagi nusxalar.

Nega rasm birinchi: bazadagi yozuv B2'dagi faylga **yagona
havola**. Avval hisob o'chsa va keyin fayl o'chmay qolsa, uni endi
hech kim topa olmaydi — fayl omborda abadiy yotib, pul yeb turadi.
Shu sabab rasm o'chishi **tekshiriladi** (`b2_delete_checked`):
o'chmasa hisobga umuman tegilmaydi va 502 qaytadi.

#### Nima o'chadi, nima qoladi

| O'CHADI (odamning o'zi) | QOLADI (tarixiy jamlanma) |
|---|---|
| `users_db`, `sessions_db`, `login_tokens` | `stats_hourly` / `stats_daily` |
| `watch_history_db` | `epizod_db.views_total`, `watch_ms_total` |
| `favorites_db` | `season_db.views_total`, `watch_ms_total` |
| `ratings_db` | |
| `sync_batches` | |
| B2'dagi avatar | |

**TUZATILADI** — hozirgi holatni sanaydigan raqamlar:
`season_db.fav_count`, `rating_sum`, `rating_count`
(`MAX(... - ?, 0)` bilan, bo'limga bitta UPDATE).

**Nega baho ham o'chadi** (foydalanuvchi topgan xato): bir odam
hisobini 3-4 marta o'chirib, har safar yangi hisobdan baho bersa
reyting soxtalashadi. Odamlarning 90% i hisobni o'chirmaydi —
ilovani o'chiradi yoki shunchaki chiqib ketadi, ya'ni bu yo'l
ataylab suiiste'mol uchun ochiq qolardi.

**Navbat yuborilmaydi, tashlab yuboriladi** (`SyncQueue.wipe`):
bir soniyadan keyin baribir o'chadigan yozuvni yozishning ma'nosi
yo'q.

#### Telefonda nima tozalanadi (`AccountData.wipeDevice`)

Hisob papkasi (tomosha tarixi, sevimlilar, kadrlar, trafik
hisobi, sozlamalar, navbat) → yuklab olingan videolar
(`videoCacheWipe`) → posterlar keshi (`libCachedImageData`).

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

- **YOZUV** — hammasi `POST /api/sync` orqali, paket bo'lib
  ("YAGONA YOZUV YO'LI" bo'limiga qarang). 100 ming faol
  foydalanuvchida Turso xarajati ~$25/oy;
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
  │ t.me/arumedialoginbot   (bot manzili)?start=<token>
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
| `sessions_db` | sessiya jurnali: hisob + **qaysi qurilma** (`device`, `platform`, `app_version`). `session_token` ustunida tokenning **SHA-256 xeshi** turadi, tokenning o'zi EMAS |
| `app_config` | webhook siri va manzili |

`init_db` ning yuqori qismida `ALTER TABLE ... ADD COLUMN` bor va u
ustun mavjud bo'lganda xato beradi — shu sabab kirish jadvallari
**alohida** `turso_batch` chaqiruvida yuboriladi.

### SESSIYA TOKENI BAZADA OCHIQ SAQLANMAYDI

**TOPILGAN XAVF:** `sessions_db.session_token` da tokenning O'ZI
turardi. Baza oqib ketsa (yoki `TURSO_TOKEN` qo'lga tushsa)
hujumchi barcha faol sessiyalarni o'sha zahoti egallardi.

Endi bazada faqat **SHA-256 xeshi** saqlanadi (`token_hash`).
Ilova xom tokenni yuboradi, worker xeshlab solishtiradi.

* Tuz (salt) YO'Q va kerak emas: token 64 bayt tasodifiy
  ma'lumot, lug'at hujumi unga ta'sir qilmaydi.
* **Eski sessiyalar uzilmaydi:** `session_user` avval xesh bilan
  qaraydi, topilmasa ochiq token bilan qaraydi va qatorni o'sha
  zahoti xeshga o'tkazadi. Migratsiya o'z-o'zidan bo'ladi.
* `login_tokens.session_token` — **ataylab xom** qoladi: u ilovaga
  tokenni bir marta yetkazish kanali. Qator 5 daqiqa yashaydi
  (`LOGIN_CLAIM_TTL_MS`), ya'ni ochiq ko'rinish oynasi shu bilan
  cheklangan.

**Bu yerni buzmang:** yangi joyda `session_token` bo'yicha qidirsangiz
qiymatni `token_hash()` dan o'tkazing, aks holda so'rov jim ishlamay
qoladi.

### YOZISHMANI KUZATISH: VERSIYA BO'YICHA (200 QATOR EMAS, 1 QATOR)

`chat_threads.chat_ver` — suhbatda **biror narsa** o'zgarganda
bittaga oshadigan son. Uzoq kutish (`/api/chat/wait?ver=N`) aynan
shu bitta sonni asosiy kalit bo'yicha o'qiydi.

**Nega:** ilgari har tekshiruvda oxirgi **200 xabar** o'qilib
(`CHAT_LIMIT`), ulardan 4 ta son hisoblanardi. Bitta kutish
so'rovi = 16 tekshiruv = ~3 200 qator. Chat ochiq bitta odam
sekundiga **~168 qator** o'qirdi — hech narsa bo'lmasa ham. Bu
Turso kvotasining asosiy yeyuvchisi edi va bekor turgan
foydalanuvchilar soniga proportsional o'sardi.

Versiya **oshiriladigan** joylar (hammasi shu ro'yxatda bo'lishi shart):

| Joy | Nima bo'ladi |
|---|---|
| xabar yuborish (2 ta upsert) | `INSERT` da `chat_ver=1`, `DO UPDATE` da `+1` |
| "o'qildi" belgisi | `+1`, lekin **faqat** `unread_* <> 0` bo'lsa |
| `refresh_thread` (o'chirishdan keyin) | `+1` |

**ENG MUHIM TUZOQ:** "o'qildi" dagi `<> 0` shartini olib tashlamang.
Usiz har ochilish versiyani oshiradi → ilova o'zgarish deb biladi →
qayta yuklaydi → yana "o'qildi" → **cheksiz aylanish**.

**Eski APK'lar uzilmaydi:** `ver` yubormagan mijozga eski (200
qatorli) yo'l o'z holicha ishlaydi.

Ustun mavjud bazaga **alohida** `ALTER TABLE` bilan qo'shiladi va
natijasi ataylab e'tiborsiz qoldiriladi — u umumiy `turso_batch`
ichida bo'lsa, "ustun bor" xatosi `DB_READY` ni o'rnatmay qo'yardi
va butun DDL har so'rovda qaytadan ketardi.

### EMOJI VA YARIM SHAFFOF MATN

Foydalanuvchi yozgan matn ko'p joyda `Colors.white.withValues(alpha: X)`
bilan chiziladi. `TextStyle.color` dan bo'yoq (Paint) yasaladi va
**rangli** emoji glifi ham o'sha alpha bilan chiziladi — natijada
emoji qora fon ichidan ko'rinib, **qoramtir** bo'lib qoladi
(alpha 0.55 da ayniqsa yaqqol).

Yechim — `lib/widgets/emoji_text.dart`: matn harf/emoji bo'laklariga
ajratiladi, emojidan alpha olib tashlanadi, harflar esa o'z xiraligini
saqlaydi. Bo'linish `characters` paketi bilan (grapheme cluster
bo'yicha) — aks holda `👨‍👩‍👧` yoki `👍🏽` o'rtasidan kesilardi.

**Qoida:** foydalanuvchi yozgan matnni alpha bilan chizsangiz
`Text` emas, `EmojiText` ishlating.

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
https://arumediatv.uzcom.workers.dev/api/auth/telegram/health
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

## APK VERSIYASI VA "ILOVA O'RNATILMADI" (2026-09)

### Ikkita raqam — ikkita boshqa vazifa

| raqam | qayerdan | kim ishlatadi |
|---|---|---|
| `versionName` (`0.0.1`) | `pubspec.yaml` | faqat **odam** ko'radi |
| `versionCode` (butun son) | `pubspec.yaml` dagi `+` dan keyin | **Android** — mavjud ilova ustiga yangilash qarorini shu bo'yicha qabul qiladi |

Hozir ikkalasi ham `pubspec.yaml` dan olinadi (foydalanuvchi
talabi: `version: 0.0.1+1`, ya'ni versionName `0.0.1`,
versionCode `1`). **Yangi APK chiqarganda `+` dan keyingi raqamni
oshirishni unutmang** — aks holda telefondagi ilova ustiga
yangisi tushmaydi.

Tarix: 265-build'gacha `versionCode = github.run_number` edi
(telefonlarga 265 gacha raqamlar o'rnatilgan), keyin u pubspec'ga
o'tkazilib 1 ga tushib ketdi. Ya'ni **telefonda eski ilova
tursa**, 1 kabi kichik raqam downgrade bo'ladi va rad etiladi.
Toza o'rnatishda raqamning kattaligi ahamiyatsiz.

### O'RNATILMASLIK SABABI: TELEFON XOTIRASI TO'LGAN EDI

**HAL QILINDI.** Foydalanuvchi: «telefon xotirasi to'lib ketibdi,
shunga shunaqa bo'lyapti ekan».

Ya'ni sabab APK'da ham, `versionCode` da ham, imzo kalitida ham
EMAS edi. Android o'rnatish uchun joy topa olmaganda
"Ilova o'rnatilmadi" deb, boshqa hech narsa tushuntirmasdan rad
etadi — aynan shu bo'lgan.

Quyidagi tekshiruv baribir foydali bo'ldi va saqlanadi.

**APK'ning o'zida nuqson yo'q** — build-297, 298 va 300 yuklab
olinib tekshirilgan:

* imzo sertifikati uchchalasida bir xil (`CN=AniRaxUz`),
  v1 + v2 + v3 imzo sxemalari joyida, APK Signing Block butun;
* `AndroidManifest.xml` 297 va 298 da **bayt-bayt bir xil**
  (SHA-256 mos), 300 da faqat versiya raqami farq qiladi;
* `minSdkVersion=24`, `targetSdkVersion=36`, paket
  `uz.arumediatv.soft`;
* `lib/` da faqat `armeabi-v7a`, `.so` fayllar **siqilmagan**
  (`method=0`) va **4096 ga tekislangan** — ya'ni
  `extractNativeLibs=false` talabi bajarilgan;
* ZIP butun: 92 ta yozuv, `MANIFEST.MF` da 89 ta `Name:`.

### IMZO KALITI

265-build'gacha har build **tasodifiy** debug kaliti bilan
imzolanardi (`$HOME/.android/debug.keystore` toza runner'da hech
qachon topilmasdi). Endi kalit repoda: `ci/release.keystore`
(`CN=AniRaxUz`, SHA-256 `8F:47:32:E1:B6:01:D6:34:...`), Secrets
qo'yilgan bo'lsa undan olinadi.

Boshqa kalitli APK eskisining ustiga tushmaydi
(`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) — lekin **toza
o'rnatishda bu ham sabab bo'la olmaydi**.

### SERVER TOMONDAGI TUZOQ

`X-App-Version` ga `pubspec.yaml` dagi to'liq yozuv (`0.0.1+1`)
boradi va worker uni admin paneldagi **"ENG PAST VERSIYA"**
(`app_min_version`) bilan solishtiradi
(`worker/src/lib.rs` → `version_rank`). Versiyani
**pasaytirganda** panelda turgan chegarani ham pasaytirish kerak,
aks holda ilova o'rnatiladi-yu, har so'rov `426` bilan rad
etiladi. Diqqat: `version_rank` da build raqami `clamp(0, 999)` —
999 dan katta build raqami taqqoslashda farq qilmaydi.

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
