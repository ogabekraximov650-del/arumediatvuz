// android-template/FloatingPlayerService.kt
//
// ═══════════════════════════════════════════════════════════════
//  ILOVALAR USTIDA SUZUVCHI PLEYER (to'liq boshqariladigan)
// ═══════════════════════════════════════════════════════════════
//
// Bu — tizim PiP'i EMAS. PiP oynasini Android boshqaradi: uning
// ichiga o'z tugmalaringizni qo'ya olmaysiz, hohlagan joyga surib
// bo'lmaydi va o'lchamini erkin o'zgartirib bo'lmaydi.
//
// Bu yerdagi oyna esa BIZNIKI: `WindowManager` ga to'g'ridan-
// to'g'ri qo'yiladi, ya'ni ilova ichidagi kichik pleyer qanday
// ishlasa — surish, tugmalar, o'lcham — bu ham xuddi shunday
// ishlaydi, lekin BOSHQA ILOVALAR USTIDA.
//
// ── NEGA VIDEO FLUTTER'DA EMAS ─────────────────────────────────
//
// Flutter dvigateli `FlutterActivity` oynasiga chizadi. Overlay
// esa Activity EMAS — u alohida `WindowManager` oynasi. Ilova
// videoni `VideoViewType.platformView` (SurfaceView) bilan
// chizadi, platform view'lar esa Activity ierarxiyasini talab
// qiladi va overlay ichida ishlamaydi.
//
// Shu sabab bu yerda video NATIVE ExoPlayer bilan chiziladi —
// aynan `video_player` paketining o'zi Android'da ishlatadigan
// dvigatel (androidx.media3). Ya'ni yangi begona texnologiya
// qo'shilmayapti, shunchaki u to'g'ridan-to'g'ri chaqirilyapti.
//
// ── NEGA FOREGROUND SERVICE ────────────────────────────────────
//
// Ilova fonga ketgach oddiy service'ni Android istalgan payt
// o'ldiradi — video o'rtasida uzilib qolardi. Foreground service
// esa bildirishnoma ko'rsatadi va tizim uni saqlab qoladi. Android
// 14 dan boshlab bunday service `mediaPlayback` turi va
// FOREGROUND_SERVICE_MEDIA_PLAYBACK ruxsatini talab qiladi
// (ikkalasini ham CI manifestga qo'shadi).
//
// ── BU FAYL QAYERGA BORADI ─────────────────────────────────────
//
// `android/` papkasi `.gitignore` da va CI uni har safar
// `flutter create` bilan qaytadan yaratadi. Shu sabab bu fayl
// shablon sifatida repoda turadi, CI esa `__PKG__` o'rniga
// haqiqiy paket nomini qo'yib ko'chiradi
// (.github/workflows/build-flutter-apk.yml).

package __PKG__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import kotlin.math.abs
import kotlin.math.roundToInt

class FloatingPlayerService : Service() {

    companion object {
        const val ACTION_START = "aru.float.START"
        const val ACTION_STOP = "aru.float.STOP"

        const val EXTRA_URL = "url"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PLAYLIST = "playlist"
        const val EXTRA_INDEX = "index"
        const val EXTRA_QUALITY = "quality"

        private const val CHANNEL_ID = "aru_floating_player"
        private const val NOTIF_ID = 4711

        /// Oyna hozir ochiqmi. Flutter tomoni shuni so'raydi.
        @Volatile
        var running: Boolean = false
            private set

        /// Oyna yopilgandagi OXIRGI ijro nuqtasi (ms).
        ///
        /// Ilova qaytganda pleyer AYNAN shu joydan davom etadi.
        /// `-1` — hali hech narsa yozilmagan.
        @Volatile
        var lastPositionMs: Long = -1L

        /// Qurilmada "ilovalar ustida ko'rsatish" ruxsati bormi.
        ///
        /// Android 6 dan past versiyalarda bunday ruxsat tushunchasi
        /// yo'q — o'shanda doim `true`.
        fun canDraw(ctx: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
            return Settings.canDrawOverlays(ctx)
        }
    }

    private var windowManager: WindowManager? = null
    private var rootView: FrameLayout? = null
    private var player: ExoPlayer? = null
    private var surfaceView: SurfaceView? = null
    private var btnPlay: ImageView? = null
    private var controlsLayer: FrameLayout? = null

    // ── QISMLAR RO'YXATI ────────────────────────────────────────
    //
    // Ro'yxat ilovadan TAYYOR holda keladi: oyna ochilgach ilova
    // fonga ketadi va undan qo'shimcha so'rab bo'lmaydi.
    //
    // Tartib ilovadagi bilan bir xil — yangi qism YUQORIDA. Shu
    // sabab "keyingi qism" indeksni KAMAYTIRADI.
    private var episodes: List<Episode> = emptyList()
    private var epIndex = 0
    private var quality = ""

    private var btnPrev: ImageView? = null
    private var btnNext: ImageView? = null
    private var btnQuality: ImageView? = null
    private var btnOpen: ImageView? = null
    private var btnClose: ImageView? = null
    private var handleResize: ImageView? = null

    /// Sifat tanlash ro'yxati ochiqmi (oyna ichidagi kichik menyu).
    private var qualityMenu: LinearLayout? = null

    data class Quality(val label: String, val url: String)
    data class Episode(
        val id: Int,
        val title: String,
        val qualities: List<Quality>
    )

    private lateinit var params: WindowManager.LayoutParams

    /// Videoning haqiqiy nisbati — o'lcham o'zgartirilganda oyna
    /// shu nisbatni saqlaydi, aks holda rasm cho'zilib ketardi.
    private var videoRatio = 16f / 9f

    /// Boshqaruv tugmalari ko'rinib turibdimi. Ular doim turib
    /// qolsa rasmni to'sardi — shu sabab bosilganda chiqadi va
    /// bir necha soniyadan keyin o'zi yashirinadi.
    private var controlsVisible = true
    private val hideRunnable = Runnable { setControlsVisible(false) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
        }

        val url = intent?.getStringExtra(EXTRA_URL).orEmpty()
        if (url.isEmpty()) {
            stopEverything()
            return START_NOT_STICKY
        }

        // Ruxsat bo'lmasa oyna qo'yib bo'lmaydi — tizim istisno
        // otadi. Ruxsatni Flutter tomoni OLDINDAN so'raydi, bu
        // yerda faqat oxirgi tekshiruv.
        if (!canDraw(this)) {
            stopEverything()
            return START_NOT_STICKY
        }

        startForegroundSafely(intent.getStringExtra(EXTRA_TITLE).orEmpty())

        episodes = parsePlaylist(intent.getStringExtra(EXTRA_PLAYLIST).orEmpty())
        epIndex = intent.getIntExtra(EXTRA_INDEX, 0)
            .coerceIn(0, (episodes.size - 1).coerceAtLeast(0))
        quality = intent.getStringExtra(EXTRA_QUALITY).orEmpty()

        val posMs = intent.getLongExtra(EXTRA_POSITION_MS, 0L)
        if (rootView == null) buildOverlay()
        startPlayback(url, posMs)
        applyAdaptiveControls()

        running = true
        return START_NOT_STICKY
    }

    // ── BILDIRISHNOMA ───────────────────────────────────────────

    private fun startForegroundSafely(title: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm?.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID,
                    "Suzuvchi pleyer",
                    // PAST muhimlik: ovoz chiqarmaydi va ekranda
                    // qalqib chiqmaydi — video ko'rayotganda
                    // bezovta qilmasligi uchun.
                    NotificationManager.IMPORTANCE_LOW
                ).apply { setShowBadge(false) }
                nm?.createNotificationChannel(ch)
            }
        }

        val open = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pi = if (open != null) {
            PendingIntent.getActivity(
                this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                        PendingIntent.FLAG_IMMUTABLE else 0)
            )
        } else null

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notif = builder
            .setContentTitle(if (title.isEmpty()) "Suzuvchi pleyer" else title)
            .setContentText("Ilovalar ustida ijro etilmoqda")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .also { if (pi != null) it.setContentIntent(pi) }
            .build()

        // Android 10 dan boshlab service turi ko'rsatilishi kerak,
        // 14 dan boshlab esa u MAJBURIY va mos ruxsat talab qiladi.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID, notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    // ── OYNA ────────────────────────────────────────────────────

    private fun dp(v: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics
    ).roundToInt()

    private fun buildOverlay() {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowManager = wm

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        // Boshlang'ich kenglik ATAYLAB 260dp: `applyAdaptiveControls`
        // dagi 240dp chegarasidan yuqori, ya'ni qism o'tkazish
        // tugmalari DARHOL ko'rinadi. Foydalanuvchi hohlasa
        // kichraytiradi — o'shanda ular o'zi yashirinadi.
        val w = dp(260)
        params = WindowManager.LayoutParams(
            w,
            (w / videoRatio).roundToInt(),
            type,
            // NOT_FOCUSABLE: oyna klaviatura fokusini olmaydi, ya'ni
            // ostidagi ilova odatdagidek ishlayveradi. Tegishlar
            // baribir bizga keladi (NOT_TOUCHABLE QO'YILMAGAN).
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(12)
            y = dp(120)
        }

        val root = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                setColor(Color.BLACK)
                cornerRadius = dp(12).toFloat()
                setStroke(dp(1), Color.argb(60, 255, 255, 255))
            }
            clipToOutline = true
        }
        rootView = root

        surfaceView = SurfaceView(this).also {
            root.addView(
                it,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                )
            )
        }

        buildControls(root)
        attachDrag(root)

        wm.addView(root, params)
        scheduleHideControls()
    }

    private fun buildControls(root: FrameLayout) {
        val layer = FrameLayout(this).apply {
            setBackgroundColor(Color.argb(60, 0, 0, 0))
        }
        controlsLayer = layer
        root.addView(
            layer,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        // ── O'RTADAGI QATOR: oldingi / ijro / keyingi ─────────
        //
        // Uchovi bitta qatorda: oyna kichrayganda chetdagilari
        // yashiriladi va o'rtadagi ijro tugmasi joyida qoladi
        // (`applyAdaptiveControls`).
        btnPrev = iconButton(android.R.drawable.ic_media_previous, dp(30)).also {
            val lp = FrameLayout.LayoutParams(dp(30), dp(30))
            lp.gravity = Gravity.CENTER
            lp.rightMargin = dp(58)
            layer.addView(it, lp)
            it.setOnClickListener { _ -> stepEpisode(-1) }
        }

        btnPlay = iconButton(android.R.drawable.ic_media_pause, dp(40)).also {
            val lp = FrameLayout.LayoutParams(dp(40), dp(40))
            lp.gravity = Gravity.CENTER
            layer.addView(it, lp)
            it.setOnClickListener { _ -> togglePlay() }
        }

        btnNext = iconButton(android.R.drawable.ic_media_next, dp(30)).also {
            val lp = FrameLayout.LayoutParams(dp(30), dp(30))
            lp.gravity = Gravity.CENTER
            lp.leftMargin = dp(58)
            layer.addView(it, lp)
            it.setOnClickListener { _ -> stepEpisode(1) }
        }

        // Yuqori o'ng — yopish.
        btnClose = iconButton(
            android.R.drawable.ic_menu_close_clear_cancel, dp(28)
        ).also {
            val lp = FrameLayout.LayoutParams(dp(28), dp(28))
            lp.gravity = Gravity.TOP or Gravity.END
            lp.topMargin = dp(4); lp.rightMargin = dp(4)
            layer.addView(it, lp)
            it.setOnClickListener { _ ->
                lastPositionMs = player?.currentPosition ?: -1L
                stopEverything()
            }
        }

        // Yuqori chap — ilovaga qaytish.
        btnOpen = iconButton(android.R.drawable.ic_menu_view, dp(28)).also {
            val lp = FrameLayout.LayoutParams(dp(28), dp(28))
            lp.gravity = Gravity.TOP or Gravity.START
            lp.topMargin = dp(4); lp.leftMargin = dp(4)
            layer.addView(it, lp)
            it.setOnClickListener { _ -> returnToApp() }
        }

        // Pastki chap — sifat tanlash.
        btnQuality = iconButton(android.R.drawable.ic_menu_manage, dp(26)).also {
            val lp = FrameLayout.LayoutParams(dp(26), dp(26))
            lp.gravity = Gravity.BOTTOM or Gravity.START
            lp.bottomMargin = dp(4); lp.leftMargin = dp(4)
            layer.addView(it, lp)
            it.setOnClickListener { _ -> toggleQualityMenu() }
        }

        // Pastki o'ng — o'lchamni o'zgartirish tutqichi.
        handleResize = iconButton(android.R.drawable.ic_menu_crop, dp(26)).also {
            val lp = FrameLayout.LayoutParams(dp(26), dp(26))
            lp.gravity = Gravity.BOTTOM or Gravity.END
            lp.bottomMargin = dp(4); lp.rightMargin = dp(4)
            layer.addView(it, lp)
            attachResize(it)
        }
    }

    // ── TUGMALAR OYNA O'LCHAMIGA QARAB ──────────────────────────
    //
    // Kichik oynada hamma tugma sig'maydi — ular bir-birining
    // ustiga chiqib, rasmni butunlay to'sardi. Shu sabab oyna
    // kengligiga qarab bosqichma-bosqich ko'payadi:
    //
    //   < 180dp  — faqat ijro/pauza va yopish (eng zarurlari);
    //   < 240dp  — + ilovaga qaytish va o'lcham tutqichi;
    //   < 300dp  — + oldingi/keyingi qism;
    //   >= 300dp — + sifat tanlash (hammasi).
    //
    // Qism tugmalari ro'yxat bo'sh bo'lsa umuman chiqmaydi, sifat
    // tugmasi esa tanlov bitta bo'lsa keraksiz.
    private fun applyAdaptiveControls() {
        val wDp = params.width / resources.displayMetrics.density

        val showBasics = wDp >= 180f
        val showEpisodes = wDp >= 240f && episodes.size > 1
        val showQuality = wDp >= 300f && (currentEpisode()?.qualities?.size ?: 0) > 1

        btnOpen?.visibility = vis(showBasics)
        handleResize?.visibility = vis(showBasics)

        // Ro'yxat chetida bo'lsa mos tugma o'chiriladi (ko'rinadi,
        // lekin bosilmaydi) — birdan yo'qolib qolgani chalkash
        // bo'lardi.
        btnPrev?.visibility = vis(showEpisodes)
        btnNext?.visibility = vis(showEpisodes)
        btnPrev?.isEnabled = epIndex < episodes.size - 1
        btnNext?.isEnabled = epIndex > 0
        btnPrev?.alpha = if (btnPrev?.isEnabled == true) 1f else 0.35f
        btnNext?.alpha = if (btnNext?.isEnabled == true) 1f else 0.35f

        btnQuality?.visibility = vis(showQuality)
        if (!showQuality) closeQualityMenu()
    }

    private fun vis(show: Boolean): Int = if (show) View.VISIBLE else View.GONE

    private fun iconButton(res: Int, size: Int): ImageView {
        return ImageView(this).apply {
            setImageResource(res)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(4), dp(4), dp(4), dp(4))
            background = GradientDrawable().apply {
                setColor(Color.argb(140, 0, 0, 0))
                cornerRadius = (size / 4).toFloat()
            }
            isClickable = true
        }
    }

    // ── SURISH VA O'LCHAM ───────────────────────────────────────

    private fun attachDrag(root: View) {
        var startX = 0; var startY = 0
        var touchX = 0f; var touchY = 0f
        var moved = false

        root.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x; startY = params.y
                    touchX = e.rawX; touchY = e.rawY
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - touchX
                    val dy = e.rawY - touchY
                    // Kichik qaltirash "surish" deb hisoblanmasin —
                    // aks holda oddiy bosish ham surishga aylanardi.
                    if (abs(dx) > dp(4) || abs(dy) > dp(4)) moved = true
                    if (moved) {
                        params.x = startX + dx.roundToInt()
                        params.y = startY + dy.roundToInt()
                        clampToScreen()
                        safeUpdate()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    // Surilmagan bo'lsa — bu oddiy bosish: tugmalarni
                    // ko'rsatib/yashirib qo'yamiz.
                    if (!moved) setControlsVisible(!controlsVisible)
                    true
                }
                else -> false
            }
        }
    }

    private fun attachResize(handle: View) {
        var startW = 0
        var touchX = 0f

        handle.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    startW = params.width
                    touchX = e.rawX
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - touchX).roundToInt()
                    // Kenglik bo'yicha boshqariladi, balandlik esa
                    // nisbatdan hisoblanadi — rasm cho'zilmaydi.
                    val minW = dp(140)
                    val maxW = resources.displayMetrics.widthPixels - dp(16)
                    val w = (startW + dx).coerceIn(minW, maxW)
                    params.width = w
                    params.height = (w / videoRatio).roundToInt()
                    clampToScreen()
                    safeUpdate()
                    // Oyna kattalashdi/kichraydi — tugmalar soni
                    // ham shunga qarab o'zgaradi.
                    applyAdaptiveControls()
                    true
                }
                else -> false
            }
        }
    }

    /// Oyna ekrandan tashqariga chiqib ketmasin.
    private fun clampToScreen() {
        val dm = resources.displayMetrics
        val maxX = (dm.widthPixels - params.width).coerceAtLeast(0)
        val maxY = (dm.heightPixels - params.height).coerceAtLeast(0)
        params.x = params.x.coerceIn(0, maxX)
        params.y = params.y.coerceIn(0, maxY)
    }

    /// Oyna allaqachon olib tashlangan bo'lsa `updateViewLayout`
    /// istisno otadi — shu sabab har chaqiruv himoyalangan.
    private fun safeUpdate() {
        val wm = windowManager ?: return
        val v = rootView ?: return
        try {
            wm.updateViewLayout(v, params)
        } catch (e: Throwable) {
        }
    }

    private fun setControlsVisible(v: Boolean) {
        controlsVisible = v
        controlsLayer?.visibility = if (v) View.VISIBLE else View.GONE
        if (v) scheduleHideControls() else closeQualityMenu()
    }

    private fun scheduleHideControls() {
        val v = rootView ?: return
        v.removeCallbacks(hideRunnable)
        v.postDelayed(hideRunnable, 3000)
    }

    // ── QISMLAR VA SIFAT ────────────────────────────────────────

    /// Ilovadan kelgan JSON ro'yxatni o'qiydi.
    ///
    /// Buzuq JSON kelsa BO'SH ro'yxat qaytadi — oyna baribir
    /// ochiladi, shunchaki qism/sifat tugmalari bo'lmaydi.
    private fun parsePlaylist(raw: String): List<Episode> {
        if (raw.isEmpty()) return emptyList()
        return try {
            val arr = JSONArray(raw)
            val out = ArrayList<Episode>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val qs = o.optJSONArray("qualities") ?: JSONArray()
                val quals = ArrayList<Quality>(qs.length())
                for (j in 0 until qs.length()) {
                    val q: JSONObject = qs.optJSONObject(j) ?: continue
                    val label = q.optString("label")
                    val url = q.optString("url")
                    if (label.isNotEmpty() && url.isNotEmpty()) {
                        quals.add(Quality(label, url))
                    }
                }
                if (quals.isEmpty()) continue
                out.add(
                    Episode(
                        id = o.optInt("id"),
                        title = o.optString("title"),
                        qualities = quals
                    )
                )
            }
            out
        } catch (e: Throwable) {
            emptyList()
        }
    }

    private fun currentEpisode(): Episode? = episodes.getOrNull(epIndex)

    /// Tanlangan sifatdagi manzil. O'sha sifat bu qismda bo'lmasa
    /// — mavjud birinchisi (ro'yxat yuqoridan pastga saralangan,
    /// ya'ni eng yaxshisi).
    private fun urlFor(ep: Episode): String {
        return ep.qualities.firstOrNull { it.label == quality }?.url
            ?: ep.qualities.first().url
    }

    /// Qismni almashtiradi.
    ///
    /// `delta = +1` — KEYINGI qism. Ro'yxat yangi qism yuqorida
    /// bo'lgani uchun bu indeksni KAMAYTIRADI (ilovadagi
    /// `_stepEpisode` bilan bir xil mantiq).
    private fun stepEpisode(delta: Int) {
        if (episodes.isEmpty()) return
        val target = epIndex - delta
        if (target < 0 || target >= episodes.size) return

        epIndex = target
        val ep = episodes[target]
        // Yangi qism BOSHIDAN boshlanadi.
        startPlayback(urlFor(ep), 0L)
        applyAdaptiveControls()
        scheduleHideControls()
    }

    private fun toggleQualityMenu() {
        if (qualityMenu != null) closeQualityMenu() else openQualityMenu()
    }

    private fun closeQualityMenu() {
        val m = qualityMenu ?: return
        (m.parent as? FrameLayout)?.removeView(m)
        qualityMenu = null
    }

    private fun openQualityMenu() {
        val layer = controlsLayer ?: return
        val ep = currentEpisode() ?: return
        closeQualityMenu()

        val menu = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(Color.argb(230, 20, 20, 30))
                cornerRadius = dp(8).toFloat()
                setStroke(dp(1), Color.argb(60, 255, 255, 255))
            }
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }

        for (q in ep.qualities) {
            val row = TextView(this).apply {
                text = q.label
                setTextColor(
                    if (q.label == quality) Color.rgb(255, 55, 95)
                    else Color.WHITE
                )
                textSize = 12f
                setPadding(dp(10), dp(6), dp(10), dp(6))
                isClickable = true
                setOnClickListener { _ -> selectQuality(q) }
            }
            menu.addView(row)
        }

        val lp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT
        )
        lp.gravity = Gravity.BOTTOM or Gravity.START
        lp.bottomMargin = dp(34); lp.leftMargin = dp(4)
        layer.addView(menu, lp)
        qualityMenu = menu

        // Menyu ochiq turganda tugmalar o'z-o'zidan yashirinmasin.
        rootView?.removeCallbacks(hideRunnable)
    }

    /// Sifatni almashtiradi va AYNAN o'sha soniyadan davom etadi.
    private fun selectQuality(q: Quality) {
        quality = q.label
        val at = player?.currentPosition ?: 0L
        startPlayback(q.url, at)
        closeQualityMenu()
        scheduleHideControls()
    }

    // ── IJRO ────────────────────────────────────────────────────

    private fun startPlayback(url: String, positionMs: Long) {
        val p = player ?: ExoPlayer.Builder(this).build().also {
            player = it
            surfaceView?.let { sv -> it.setVideoSurfaceView(sv) }
            it.addListener(object : Player.Listener {
                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    if (videoSize.width > 0 && videoSize.height > 0) {
                        videoRatio = videoSize.width.toFloat() /
                            videoSize.height.toFloat()
                        params.height =
                            (params.width / videoRatio).roundToInt()
                        clampToScreen()
                        safeUpdate()
                    }
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    btnPlay?.setImageResource(
                        if (isPlaying) android.R.drawable.ic_media_pause
                        else android.R.drawable.ic_media_play
                    )
                }
            })
        }

        p.setMediaItem(MediaItem.fromUri(Uri.parse(url)))
        p.prepare()
        if (positionMs > 0) p.seekTo(positionMs)
        p.playWhenReady = true
    }

    private fun togglePlay() {
        val p = player ?: return
        if (p.isPlaying) p.pause() else p.play()
        scheduleHideControls()
    }

    /// Ilovaga qaytadi va ijro nuqtasini u bilan birga olib boradi.
    private fun returnToApp() {
        lastPositionMs = player?.currentPosition ?: -1L
        val i = packageManager.getLaunchIntentForPackage(packageName)
        if (i != null) {
            i.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            try {
                startActivity(i)
            } catch (e: Throwable) {
            }
        }
        stopEverything()
    }

    private fun stopEverything() {
        if (lastPositionMs < 0) {
            lastPositionMs = player?.currentPosition ?: -1L
        }
        running = false

        rootView?.removeCallbacks(hideRunnable)

        try {
            player?.release()
        } catch (e: Throwable) {
        }
        player = null

        val wm = windowManager
        val v = rootView
        if (wm != null && v != null) {
            try {
                wm.removeView(v)
            } catch (e: Throwable) {
            }
        }
        rootView = null
        surfaceView = null
        controlsLayer = null
        btnPlay = null
        btnPrev = null
        btnNext = null
        btnQuality = null
        btnOpen = null
        btnClose = null
        handleResize = null
        qualityMenu = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        // `stopEverything` allaqachon chaqirilgan bo'lsa bu yerda
        // hammasi `null` — takror chaqirish zararsiz.
        stopEverything()
        super.onDestroy()
    }
}
