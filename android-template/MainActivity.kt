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

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
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
