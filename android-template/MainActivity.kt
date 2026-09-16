// android-template/MainActivity.kt
//
// ═══════════════════════════════════════════════════════════════
//  TOMOSHA TARIXI UCHUN KADR AJRATUVCHI
// ═══════════════════════════════════════════════════════════════
//
// Videodan kadr olishni Flutter uddalay olmaydi — rasm GPU
// qatlamida chiziladi va uni "surat qilib olish" mumkin emas.
// Android'da esa buning uchun tayyor vosita bor:
// `MediaMetadataRetriever`.
//
// ── NEGA TASHQI PAKET EMAS ─────────────────────────────────────
//
// `video_thumbnail` paketi sinab ko'rildi va build'ni YIQITDI:
// u 2023-yildan beri yangilanmagan, Gradle faylida allaqachon
// yopilgan `jcenter()` ombori va eski DSL turibdi. Uni har
// Flutter/Gradle yangilanishida "tuzatib" yurish — qarz.
//
// Kerakli ish esa atigi bir necha qator, shu sabab u ilovaning
// O'ZIDA yozilgan. Tashqi bog'liqlik yo'q, Gradle xavfi yo'q.
//
// ── BU FAYL QAYERGA BORADI ─────────────────────────────────────
//
// `android/` papkasi `.gitignore` da — uni CI `flutter create`
// bilan har safar qaytadan yaratadi. Shu sabab bu fayl shablon
// sifatida repoda turadi va CI uni `MainActivity.kt` ustiga
// ko'chiradi, `__PKG__` o'rniga haqiqiy paket nomini qo'yib
// (build-flutter-apk.yml ga qarang).
//
// Kadr manzili — Rust yadrosidagi "/thumb" yo'li: u butun videoni
// emas, faqat kerakli kadrni beradi (rust/src/mp4.rs).

package __PKG__

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.provider.Settings
import android.util.Base64
import android.util.Rational
import android.view.WindowManager
import java.security.MessageDigest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    /// PiP holatini Flutter tomonga xabar qilish uchun saqlanadi.
    /// `configureFlutterEngine` da to'ldiriladi, tizim PiP'ga
    /// kirganda/chiqqanda ishlatiladi.
    private var pipChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aru/thumb")
            .setMethodCallHandler { call, result ->
                if (call.method != "grab") {
                    result.notImplemented()
                } else {
                    val url = call.argument<String>("url") ?: ""
                    val maxWidth = call.argument<Int>("maxWidth") ?: 640
                    val quality = call.argument<Int>("quality") ?: 72
                    // Dekodlash bir necha yuz millisekund olishi
                    // mumkin — UI oqimida bajarilmaydi, aks holda
                    // ro'yxat sirg'alayotganda ilova qotib qolardi.
                    Thread {
                        val bytes = grabFrame(url, maxWidth, quality)
                        runOnUiThread { result.success(bytes) }
                    }.start()
                }
            }

        // ── ILOVANING HAQIQIYLIGINI TASDIQLASH ────────────────
        //
        // TALAB (foydalanuvchi): "APP_KEY nimaga kerak? ... busiz
        // ishlaydigan qilish kerak, ya'ni worker ilovaning
        // haqiqiyligini tekshirishi kerak".
        //
        // ── NEGA IMZO ─────────────────────────────────────────
        //
        // APK'ga qo'yilgan sir (kalit) — shunchaki APK ichidagi
        // matn: uni ochib o'qish mumkin va u hech narsani
        // isbotlamaydi.
        //
        // Imzo sertifikati esa boshqacha: uni ILOVA O'ZI
        // tanlamaydi, TIZIM beradi. Kimdir ilovani o'zgartirib
        // qayta yig'sa, uni O'Z kaliti bilan imzolashga majbur —
        // bizning kalitimiz unda yo'q. Natijada hash boshqacha
        // chiqadi va server bunday ilovani rad etadi.
        //
        // ── ROSTINI AYTISH KERAK ──────────────────────────────
        //
        // Hash'ning O'ZINI APK'dan o'qib, so'rovni qo'lda yasash
        // mumkin. Ya'ni bu:
        //   * O'ZGARTIRILGAN ILOVANI to'xtatadi (asosiy maqsad);
        //   * brauzer, bot va oddiy skriptlarni to'xtatadi;
        //   * maqsadli hujumchini to'xtatmaydi.
        // Mutlaq yechim (Play Integrity) Play Store'ni talab
        // qiladi, bu ilova esa APK bo'lib tarqatiladi.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aru/signature")
            .setMethodCallHandler { call, result ->
                if (call.method != "sha256") {
                    result.notImplemented()
                } else {
                    result.success(signatureSha256())
                }
            }

        // ── SKRINSHOT VA EKRAN YOZIB OLISHNI TAQIQLASH ─────────
        //
        // TALAB (foydalanuvchi): "ilovada video pleyerda va shaxsiy
        // chatda screenshot olish va ekranni yozib olish
        // taqiqlansin".
        //
        // Android'da buning yagona ishonchli yo'li — oynaga
        // `FLAG_SECURE` qo'yish. U bir vaqtning o'zida:
        //   * skrinshotni bloklaydi (tizim "ruxsat yo'q" deydi);
        //   * ekran yozuvida va ekranni uzatishda oynani QORA
        //     qilib ko'rsatadi;
        //   * oxirgi ilovalar ro'yxatida ham tarkibni yashiradi.
        //
        // Bayroq BUTUN oynaga tegishli, ya'ni u faqat kerakli
        // ekran ochilganda yoqiladi va yopilganda o'chiriladi —
        // aks holda butun ilovada skrinshot ishlamay qolardi.
        //
        // NEGA TASHQI PAKET EMAS: bu atigi ikki qator kod.
        // `flutter_windowmanager` esa uzoq vaqtdan beri
        // yangilanmagan va Gradle yangilanishlarida yiqiladi
        // (yuqoridagi `video_thumbnail` bilan bir xil dard).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aru/secure")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "on" -> {
                        runOnUiThread {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(true)
                    }
                    "off" -> {
                        runOnUiThread {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── ILOVALAR USTIDA SUZUVCHI PLEYER (PiP) ─────────────
        //
        // TALAB (foydalanuvchi): pleyer boshqa ilovalar ustida
        // ham ko'rinib tursin.
        //
        // ── NEGA TIZIM PiP'i, OVERLAY EMAS ────────────────────
        //
        // Boshqa ilovalar ustiga chizishning ikki yo'li bor:
        //
        //   1. SYSTEM_ALERT_WINDOW — ilova o'z oynasini hamma
        //      narsa ustiga chizadi. Tugmalar, o'lcham va surish
        //      to'liq bizning ixtiyorimizda BO'LARDI, lekin:
        //      foydalanuvchidan alohida ruxsat so'raladi
        //      (Sozlamalar ichida qo'lda yoqiladi), doimiy
        //      bildirishnoma bilan foreground service kerak,
        //      va Play Store bunga shubha bilan qaraydi.
        //
        //   2. Tizim PiP'i — Android'ning O'ZI beradigan kichik
        //      oyna. Hech qanday ruxsat so'ralmaydi, tizim o'zi
        //      boshqaradi: foydalanuvchi uni surib qo'yadi,
        //      ikki barobar bosib kattalashtiradi.
        //
        // Ikkinchisi tanlandi: ruxsatsiz ishlaydi va tizimning
        // odatiy xulqiga mos. Evaziga oyna kichik va tugmalar
        // cheklangan — bu PiP'ning tabiati, kamchilik emas.
        //
        // ── MANIFEST TALABI ───────────────────────────────────
        //
        // Activity'da `supportsPictureInPicture="true"` va
        // `configChanges` da `screenLayout|smallestScreenSize`
        // bo'lishi SHART, aks holda PiP'ga o'tganda Activity
        // qayta yaratiladi va ijro uziladi. Buni CI qo'shadi
        // (.github/workflows/build-flutter-apk.yml).
        pipChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "aru/pip"
        )
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Qurilma PiP'ni umuman qo'llab-quvvatlaydimi.
                // Arzon va Android 8 dan eski qurilmalarda yo'q —
                // ilova tugmani o'shanda ko'rsatmasligi uchun.
                "supported" -> result.success(isPipSupported())

                "enter" -> {
                    if (!isPipSupported()) {
                        result.success(false)
                    } else {
                        // Video nisbati beriladi — aks holda oyna
                        // kvadratga yaqin chiqib, rasm yon-tomondan
                        // qirqiladi. Nisbat kelmasa 16:9.
                        val w = call.argument<Int>("width") ?: 16
                        val h = call.argument<Int>("height") ?: 9
                        result.success(enterPip(w, h))
                    }
                }

                else -> result.notImplemented()
            }
        }

        // ── ILOVALAR USTIDA SUZUVCHI PLEYER (to'liq oyna) ──────
        //
        // Yuqoridagi PiP — tizimning oynasi: tugmalarsiz va
        // surib bo'lmaydigan. Bu esa BIZNING oynamiz:
        // `FloatingPlayerService` uni `WindowManager` ga qo'yadi,
        // ya'ni ilova ichidagi kichik pleyer kabi to'liq
        // boshqariladi. Batafsil — o'sha fayl boshidagi izohda.
        //
        // Evaziga "ilovalar ustida ko'rsatish" ruxsati kerak. Uni
        // oddiy dialog bilan so'rab bo'lmaydi — foydalanuvchi
        // Sozlamalarda qo'lda yoqadi, shu sabab bu yerda o'sha
        // sahifani ochadigan alohida metod bor.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aru/float")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canDraw" -> result.success(
                        FloatingPlayerService.canDraw(this)
                    )

                    // Sozlamalardagi "Ilovalar ustida ko'rsatish"
                    // sahifasini ochadi. Javob — sahifa ochildimi;
                    // foydalanuvchi ruxsat berdimi degani EMAS, uni
                    // qaytib kelgach `canDraw` bilan tekshiriladi.
                    "requestPermission" -> result.success(openOverlaySettings())

                    "start" -> {
                        if (!FloatingPlayerService.canDraw(this)) {
                            result.success(false)
                        } else {
                            val i = Intent(this, FloatingPlayerService::class.java)
                                .setAction(FloatingPlayerService.ACTION_START)
                                .putExtra(
                                    FloatingPlayerService.EXTRA_URL,
                                    call.argument<String>("url") ?: ""
                                )
                                .putExtra(
                                    FloatingPlayerService.EXTRA_POSITION_MS,
                                    (call.argument<Number>("positionMs")
                                        ?: 0).toLong()
                                )
                                .putExtra(
                                    FloatingPlayerService.EXTRA_TITLE,
                                    call.argument<String>("title") ?: ""
                                )
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(i)
                            } else {
                                startService(i)
                            }
                            // Oyna ochilgach ilovani orqaga olamiz —
                            // aks holda u o'z ustida turib qolardi.
                            moveTaskToBack(true)
                            result.success(true)
                        }
                    }

                    "stop" -> {
                        startService(
                            Intent(this, FloatingPlayerService::class.java)
                                .setAction(FloatingPlayerService.ACTION_STOP)
                        )
                        result.success(true)
                    }

                    "isRunning" -> result.success(FloatingPlayerService.running)

                    // Oyna yopilgandagi ijro nuqtasi (ms). `-1` —
                    // yo'q. O'qilgach tozalanadi: bir xil qiymat
                    // ikkinchi marta ishlatilib qolmasin.
                    "takeLastPosition" -> {
                        val p = FloatingPlayerService.lastPositionMs
                        FloatingPlayerService.lastPositionMs = -1L
                        result.success(p)
                    }

                    else -> result.notImplemented()
                }
            }

        // ── TRAFIK KANALI OLIB TASHLANGAN ──────────────────────
        //
        // Bu yerda ilgari `TrafficStats.getUidRxBytes` bor edi.
        // U ilovaning UID'i ostidagi HAMMA soketni sanardi —
        // shu jumladan MAHALLIY (`127.0.0.1`) uzatmani ham:
        // pleyer videoni ilovaning o'z kesh-serveridan oladi,
        // ya'ni bitta video IKKI MARTA sanalardi, yuklab olingan
        // videoni oflayn qayta ko'rganda esa trafik yo'q joydan
        // o'sardi.
        //
        // Hisob endi AYNAN tarmoqqa chiqadigan ikki joyda olinadi
        // (Rust yadrosi va ilovaning http klienti) —
        // `lib/services/traffic_service.dart` ga qarang.
        //
        // Keyinroq shu yerda telefon xotirasini o'qiydigan
        // `aru/storage` kanali ham bor edi; profil sahifasidan
        // "telefon xotirasi N% band" qatori olib tashlangach
        // (foydalanuvchi talabi) u ham keraksiz bo'lib qoldi.
    }

    /// "Ilovalar ustida ko'rsatish" sozlamasini ochadi.
    ///
    /// Bu ruxsat ODDIY ruxsat emas: `requestPermissions` bilan
    /// so'rab bo'lmaydi, foydalanuvchi uni Sozlamalarda qo'lda
    /// yoqishi kerak. Shu sabab bu yerda faqat o'sha sahifa
    /// ochiladi.
    private fun openOverlaySettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Throwable) {
            // Ba'zi qobiqlarda bu sahifa yo'q — o'shanda ilovaning
            // umumiy sozlamalari ochiladi.
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                true
            } catch (e2: Throwable) {
                false
            }
        }
    }

    /// Qurilma PiP'ni qo'llab-quvvatlaydimi.
    ///
    /// Android 8.0 (API 26) dan past — umuman yo'q. Undan
    /// yuqorida ham tizim xususiyati bo'lishi SHART emas:
    /// ba'zi arzon va Go-nashr qurilmalarda u o'chirilgan.
    private fun isPipSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return packageManager.hasSystemFeature(
            PackageManager.FEATURE_PICTURE_IN_PICTURE
        )
    }

    /// PiP rejimiga o'tadi. Muvaffaqiyatli bo'lsa `true`.
    ///
    /// Nisbat Android tomonidan CHEKLANGAN: taxminan 1:2.39 dan
    /// 2.39:1 gacha. Chetdan chiqqan qiymat bilan tizim istisno
    /// otadi — shu sabab qiymat shu oraliqqa siqiladi.
    private fun enterPip(width: Int, height: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val w = if (width > 0) width else 16
            val h = if (height > 0) height else 9

            // Nisbatni ruxsat etilgan oraliqqa siqish. 100 ga
            // ko'paytirib butun son bilan ishlanadi — Rational
            // kasr qabul qilmaydi.
            val ratio = w.toDouble() / h.toDouble()
            val safe = ratio.coerceIn(0.42, 2.39)
            val num = (safe * 1000).toInt()

            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(num, 1000))
                .build()
            enterPictureInPictureMode(params)
        } catch (e: Throwable) {
            false
        }
    }

    /// Tizim PiP'ga kirganda/chiqqanda Flutter tomonga xabar.
    ///
    /// Ilova buni bilishi KERAK: PiP oynasida boshqaruv tugmalari
    /// va sarlavha ortiqcha — ular kichik oynani to'ldirib
    /// yuboradi. Flutter tomoni shu xabarni olib ularni yashiradi.
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod(
            "changed",
            mapOf("inPip" to isInPictureInPictureMode)
        )
    }

    /// APK imzo sertifikatining SHA-256 hash'i (base64).
    ///
    /// Bir nechta imzo bo'lsa BIRINCHISI olinadi — Flutter
    /// ilovalarida imzo doim bitta.
    ///
    /// Xato bo'lsa bo'sh satr: server bunday holatda so'rovni
    /// rad etadi, lekin ilova yiqilmaydi.
    private fun signatureSha256(): String {
        return try {
            val pm = packageManager
            val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(
                    packageName, PackageManager.GET_SIGNING_CERTIFICATES
                )
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(
                    packageName, PackageManager.GET_SIGNATURES
                )
                @Suppress("DEPRECATION")
                info.signatures
            }
            val first = sigs?.firstOrNull() ?: return ""
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(first.toByteArray())
            Base64.encodeToString(digest, Base64.NO_WRAP)
        } catch (e: Throwable) {
            ""
        }
    }

    /// Manzildagi videodan OXIRGI kadrni JPEG qilib qaytaradi.
    ///
    /// ── NEGA AYNAN OXIRGI KADR ─────────────────────────────────
    ///
    /// Manzilda (`rust/src/video_cache.rs` -> `/thumb`) kalit
    /// kadrdan foydalanuvchi TO'XTAGAN kadrgacha bo'lgan kichik MP4
    /// turadi. Uning eng oxirgi kadri — aynan kerakli kadr.
    ///
    /// Ilgari bu yerda `OPTION_CLOSEST_SYNC` bilan 0-vaqt
    /// so'ralardi, ya'ni har doim KALIT KADR olinardi va rasm
    /// to'xtagan joydan bir necha soniya oldingi bo'lib chiqardi.
    /// Endi davomiylik o'qilib, uning oxiriga `OPTION_CLOSEST`
    /// bilan boriladi — bu dekoderni kalit kadrdan boshlab
    /// kerakli kadrgacha ochishga majbur qiladi.
    ///
    /// Kadr olinmasa `null` — bu XATO EMAS, oddiy zaxira yo'l:
    /// ilova o'shanda posterni ko'rsatadi.
    private fun grabFrame(url: String, maxWidth: Int, quality: Int): ByteArray? {
        if (url.isEmpty()) return null
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(url, HashMap<String, String>())

            // Bo'lakning davomiyligi (ms). O'qilmasa 0 — pastdagi
            // zaxira yo'l ishlaydi.
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L

            // Oxiridan 1 ms berida: bu AYNAN oxirgi kadrning ichiga
            // tushadi (kadr kamida bir necha o'nlab millisekund
            // ko'rsatiladi), davomiylikdan tashqariga chiqmaydi.
            var bmp: Bitmap? = null
            if (durationMs > 1) {
                bmp = retriever.getFrameAtTime(
                    (durationMs - 1) * 1000,
                    MediaMetadataRetriever.OPTION_CLOSEST
                )
            }
            // Zaxira: dekoder oxirgi kadrni ocholmasa — kalit kadr.
            // Rasm bir oz eskiroq bo'ladi, lekin bo'sh joydan yaxshi.
            if (bmp == null) {
                bmp = retriever.getFrameAtTime(
                    0,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                )
            }
            if (bmp == null) return null

            var frame: Bitmap = bmp

            // Ro'yxatdagi qator uchun to'liq o'lcham shart emas —
            // kichraytirish JPEG'ni bir necha barobar kichraytiradi.
            if (frame.width > maxWidth && frame.width > 0) {
                val h = (frame.height.toLong() * maxWidth / frame.width)
                    .toInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(frame, maxWidth, h, true)
                if (scaled !== frame) {
                    frame.recycle()
                    frame = scaled
                }
            }

            val out = ByteArrayOutputStream()
            frame.compress(Bitmap.CompressFormat.JPEG, quality, out)
            frame.recycle()
            return out.toByteArray()
        } catch (e: Throwable) {
            return null
        } finally {
            try {
                retriever.release()
            } catch (e: Throwable) {
            }
        }
    }
}
