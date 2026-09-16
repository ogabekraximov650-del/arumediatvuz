# ci/release.keystore — ILOVANING IMZO KALITI

## Nega bu fayl bu yerda

TOPILGAN JIDDIY XATO (foydalanuvchi: "yangi versiyani o'rnatmoqchi
bo'lganimda ilova yangilanmayapti ... versiya katta bo'lsa ham
yangilanmasdi").

Ilgari CI har build'da **yangi, tasodifiy** imzo kaliti yasardi:

    KS="$HOME/.android/debug.keystore"
    if [ ! -f "$KS" ]; then keytool -genkeypair ... fi

GitHub runner har safar TOZA mashina — ya'ni bu fayl hech qachon
topilmasdi va **har APK boshqa kalit bilan imzolanardi**.

Android qoidasi qat'iy: yangi APK eskisi bilan **AYNAN BIR XIL**
kalit bilan imzolangan bo'lishi kerak. Aks holda tizim o'rnatishni
rad etadi (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) — versiya raqami
katta bo'lsa ham. Aynan shu sabab 8 dan 9 ga o'tganda ham ilova
yangilanmagan.

Endi kalit SHU YERDA va o'zgarmaydi — yangi APK eskisining ustiga
bemalol o'rnatiladi.

## Xavfsizlik haqida rostini aytish

Bu kalit repoda OCHIQ turibdi. Ya'ni repoga kirish huquqi bor odam
xuddi shu imzo bilan APK yasay oladi va uni foydalanuvchining
ilovasi ustiga "yangilanish" qilib o'rnatishi mumkin — lekin buning
uchun u APK'ni odamlarga yetkazishi kerak, foydalanuvchilar esa
APK'ni GitHub Release'dan oladi.

**Yaxshiroq yo'l** (tavsiya qilinadi): keystore'ni GitHub Secrets'ga
ko'chirish.

    base64 -w0 ci/release.keystore

Chiqqan matnni `ANDROID_KEYSTORE_B64` nomi bilan Secrets'ga qo'ying,
parolni esa `ANDROID_KEYSTORE_PASS` deb. CI secret bo'lsa **o'shani
ishlatadi**, bo'lmasa shu fayldan foydalanadi — ya'ni ikkala holda
ham ishlaydi.

Keyin bu faylni repodan o'chirsangiz bo'ladi. Lekin ESKI KALITNI
YO'QOTMANG: u yo'qolsa, allaqachon o'rnatilgan ilovalarni boshqa
hech qachon yangilab bo'lmaydi — foydalanuvchilar ilovani o'chirib,
qaytadan o'rnatishga majbur bo'ladi.

## Kalit ma'lumotlari

    alias:    arumedia
    parol:    arumedia  (store va key uchun bir xil)
    muddati:  30 yil
    SHA-256:  8F:47:32:E1:B6:01:D6:34:2C:42:56:B3:F0:78:D7:62:
              A2:9C:59:D0:E2:59:5E:81:37:BB:59:EA:88:D4:F7:1E

SHA-256 worker uchun ham kerak: ilova o'z imzosining shu hash'ini
serverga yuboradi va server uni shu qiymat bilan solishtiradi
(`app_gate` izohiga qarang).
