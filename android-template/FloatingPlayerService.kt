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

        val posMs = intent.getLongExtra(EXTRA_POSITION_MS, 0L)
        if (rootView == null) buildOverlay()
        startPlayback(url, posMs)

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

        val w = dp(220)
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

        // O'rtada — ijro/pauza.
        btnPlay = iconButton(android.R.drawable.ic_media_pause, dp(40)).also {
            val lp = FrameLayout.LayoutParams(dp(40), dp(40))
            lp.gravity = Gravity.CENTER
            layer.addView(it, lp)
            it.setOnClickListener { _ -> togglePlay() }
        }

        // Yuqori o'ng — yopish.
        iconButton(android.R.drawable.ic_menu_close_clear_cancel, dp(28)).also {
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
        iconButton(android.R.drawable.ic_menu_view, dp(28)).also {
            val lp = FrameLayout.LayoutParams(dp(28), dp(28))
            lp.gravity = Gravity.TOP or Gravity.START
            lp.topMargin = dp(4); lp.leftMargin = dp(4)
            layer.addView(it, lp)
            it.setOnClickListener { _ -> returnToApp() }
        }

        // Pastki o'ng — o'lchamni o'zgartirish tutqichi.
        iconButton(android.R.drawable.ic_menu_crop, dp(26)).also {
            val lp = FrameLayout.LayoutParams(dp(26), dp(26))
            lp.gravity = Gravity.BOTTOM or Gravity.END
            lp.bottomMargin = dp(4); lp.rightMargin = dp(4)
            layer.addView(it, lp)
            attachResize(it)
        }
    }

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
        if (v) scheduleHideControls()
    }

    private fun scheduleHideControls() {
        val v = rootView ?: return
        v.removeCallbacks(hideRunnable)
        v.postDelayed(hideRunnable, 3000)
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
