# ARU — brend belgisi

Qora plita, undan **ARU** harflari o'yib olingan. Harf ichidagi yopiq
bo'shliqlar (A ning uchburchagi, R ning qorni) plita materiali bo'lib
qoladi — aynan shu "orollar" harfni o'qitadi.

| Rang | Kod | Nima |
|---|---|---|
| Plita | `#000000` | to'liq qora |
| O'yiq | `#FFFFFF` | harflar ko'rinadigan rang |

Burchak radiusi: `114 / 512` = **22.3%** — ilova belgilari uchun
odatiy nisbat. Burchaklardan tashqarida oq qoladi (shaffof emas).

Burchaksiz, to'la kvadrat zamin kerak bo'lsa —
`aru-logo-square-1080.png`.

## Qaysi faylni qayerga qo'yish kerak

| Fayl | Qayerda ishlatiladi |
|---|---|
| `aru-logo.svg` | **Asosiy manba.** Vektor — istalgan o'lchamda aniq. Sayt, bosma, prezentatsiya. |
| `aru-logo-2048.png` | Do'kon, bosma, zaxira |
| `aru-logo-1080.png` | Ijtimoiy tarmoqlar, post, banner |
| `aru-logo-512.png` | Ilova do'konlari talab qiladigan o'lcham |
| `aru-telegram-1080.png` | **Telegram kanali avatari** — pastdagi izohga qarang |
| `aru-logo-square-1080.png` | Burchaksiz, to'la kvadrat nusxa |
| `aru-logo-round.svg` | **Doira** nusxa — Android `ic_launcher_round` shundan chiqarilgan. Geometriyasi `aru-telegram.svg` niki (harflar doira chetiga tegmaydi). |
| `aru-mark.png` | **Oq harflar, shaffof fon** — ilova ICHIDA ishlatiladi (`assets/aru-mark.png` shunga aynan teng). To'q fon uchun. |
| `android-res/**` | Android ilova belgisi va ochilish ekrani (CI avtomatik ko'chiradi) |

### Telegram uchun nega alohida fayl?

Telegram avatarni **doira** qilib qirqadi. Asosiy logotipda harflar
chetlarga tiralgan, shu sabab doira ularning uchini kesib yuboradi.
`aru-telegram-*.png` da logotipning o'zi o'zgarmagan — faqat atrofidagi
bo'sh joy kattaroq, shuning uchun doira qirqimida hech nima yo'qolmaydi.

## Qayta chiqarish

```bash
node branding/build-icons.js
```

Nima bo'ladi:

1. `aru-geometry.js` harflarning aniq konturlarini hisoblaydi
   (chizilgan emas — hisoblangan: tik tayanch qalin, ko'ndalang va
   egri chiziq tepasi ingichka, U ning tagi taglikdan sal pastga
   chiqadi — shrift qonunlari bo'yicha);
2. SVG yig'iladi;
3. Chromium uni yirik o'lchamda rasmga oladi;
4. `pngscale.py` har bir zichlik uchun aniq siqadi.

### Ikkita texnik tuzoq (yana o'ralashib qolmaslik uchun)

* **Headless Chromium oynasining tepasida ~84px band bor.** Shu sabab
  so'ralgan balandlikdan kamrog'i chiziladi va rasm pastdan qirqiladi.
  Yechim: oyna `PAD` ga baland so'raladi, keyin chap-yuqori burchakdan
  aniq kvadrat kesib olinadi.
* **Chromium eng kichik oyna o'lchamidan pastini chiza olmaydi** —
  48px belgi to'g'ridan-to'g'ri so'ralsa, katta rasmning bir bo'lagi
  chiqadi. Shu sabab kichik o'lchamlar `MASTER` dan siqib olinadi.

`pngscale.py` — tashqi kutubxonasiz (faqat `zlib`) PNG o'qish/yozish va
siqish. Shaffoflik to'g'ri ishlanadi: piksellar oldin alfaga
ko'paytiriladi, keyin o'rtachalanadi — aks holda chetlarda qora hoshiya
paydo bo'lardi.
