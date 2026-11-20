package com.naveen.byteapp

import android.animation.ValueAnimator
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
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import kotlin.math.abs

/**
 * The floating BYTE bubble: a small round button that sits on top of every
 * app. Tap it and a short menu opens — Voice note, New note, Search, and the
 * open items of the checklist you pinned. While BYTE records, its ring glows
 * green; tapping it then stops and saves.
 *
 * It is a foreground service only so that Android keeps the bubble alive
 * while BYTE itself is in the background. It records nothing and reads
 * nothing: every action opens BYTE, and BYTE does the work.
 */
class BubbleService : Service() {
    companion object {
        private const val TAG = "BYTE/bubble"
        private const val CHANNEL = "byte_bubble"
        private const val NOTIF_ID = 9911
        const val PREFS = "byte_bubble"
        const val ACTION_HIDE = "com.naveen.byteapp.BUBBLE_HIDE"
        const val ACTION_REFRESH = "com.naveen.byteapp.BUBBLE_REFRESH"

        @Volatile var running = false

        /** Set by MainActivity while a voice note is being recorded: the ring glows. */
        @Volatile var recording = false

        fun wanted(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("on", false)

        fun allowed(ctx: Context) = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(ctx)

        /** Call while BYTE is on screen. Never throws. */
        fun start(ctx: Context) {
            if (!allowed(ctx)) return
            try {
                ctx.startService(Intent(ctx, BubbleService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "start: $e")
            }
        }

        fun stop(ctx: Context) {
            try { ctx.stopService(Intent(ctx, BubbleService::class.java)) } catch (_: Exception) {}
        }

        /** Something the bubble shows has changed (recording state, pinned checklist). */
        fun refresh(ctx: Context) {
            if (!running) return
            try {
                ctx.startService(Intent(ctx, BubbleService::class.java).setAction(ACTION_REFRESH))
            } catch (_: Exception) {}
        }
    }

    private var wm: WindowManager? = null
    private var bubble: FrameLayout? = null
    private var ring: View? = null
    private var panel: LinearLayout? = null
    private var bubbleParams: WindowManager.LayoutParams? = null

    /** When (uptime) a touch outside last closed the menu. */
    private var panelClosedAt = 0L
    private var glow: ValueAnimator? = null

    private val ink = Color.parseColor("#14181B")
    private val paper = Color.parseColor("#F6F4EE")
    private val green = Color.parseColor("#2FBF71")
    private val faint = Color.parseColor("#8A9096")

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HIDE) {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("on", false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        if (!allowed(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (bubble == null) {
            goForeground()
            try {
                showBubble()
                running = true
            } catch (e: Exception) {
                Log.w(TAG, "show: $e")
                stopSelf()
                return START_NOT_STICKY
            }
        }
        applyState()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        glow?.cancel()
        glow = null
        closePanel()
        bubble?.let { try { wm?.removeView(it) } catch (_: Exception) {} }
        bubble = null
        super.onDestroy()
    }

    // ---- Foreground notification (keeps the bubble alive) ------------------

    private fun goForeground() {
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "Floating bubble", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Shows while the floating BYTE bubble is on"
                    setShowBadge(false)
                })
            }
            val hide = PendingIntent.getService(
                this, 1, Intent(this, BubbleService::class.java).setAction(ACTION_HIDE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val n: Notification = NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("The BYTE bubble is on")
                .setContentText("Tap to hide it")
                .setContentIntent(hide)
                .setOngoing(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .build()
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Exception) {
            // Without the foreground state the bubble still shows; Android may just close it sooner.
            Log.w(TAG, "foreground: $e")
        }
    }

    // ---- The bubble ---------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE

    private fun showBubble() {
        val w = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        wm = w
        val size = dp(54f)
        val box = FrameLayout(this)
        // The ring: only its colour changes (quiet grey, glowing green while recording).
        val r = View(this)
        box.addView(r, FrameLayout.LayoutParams(size, size))
        val face = TextView(this).apply {
            text = "B"
            setTextColor(paper)
            typeface = Typeface.DEFAULT_BOLD
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            gravity = Gravity.CENTER
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(ink) }
            contentDescription = "BYTE"
        }
        val inner = size - dp(8f)
        box.addView(face, FrameLayout.LayoutParams(inner, inner, Gravity.CENTER))
        ring = r

        val sp = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val lp = WindowManager.LayoutParams(
            size, size, overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        lp.gravity = Gravity.TOP or Gravity.START
        val screenW = resources.displayMetrics.widthPixels
        val screenH = resources.displayMetrics.heightPixels
        lp.x = sp.getInt("x", screenW - size - dp(6f)).coerceIn(0, (screenW - size).coerceAtLeast(0))
        lp.y = sp.getInt("y", screenH / 3).coerceIn(dp(24f), (screenH - size - dp(24f)).coerceAtLeast(dp(24f)))
        bubbleParams = lp

        val slop = ViewConfiguration.get(this).scaledTouchSlop
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        box.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY; startX = lp.x; startY = lp.y; moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - downX).toInt()
                    val dy = (e.rawY - downY).toInt()
                    if (!moved && (abs(dx) > slop || abs(dy) > slop)) { moved = true; closePanel() }
                    if (moved) {
                        lp.x = startX + dx
                        lp.y = startY + dy
                        try { w.updateViewLayout(box, lp) } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (moved) {
                        // Rest against the nearer side, inside the screen.
                        val sw = resources.displayMetrics.widthPixels
                        val sh = resources.displayMetrics.heightPixels
                        lp.x = if (lp.x + size / 2 < sw / 2) dp(6f) else sw - size - dp(6f)
                        lp.y = lp.y.coerceIn(dp(24f), (sh - size - dp(24f)).coerceAtLeast(dp(24f)))
                        try { w.updateViewLayout(box, lp) } catch (_: Exception) {}
                        sp.edit().putInt("x", lp.x).putInt("y", lp.y).apply()
                    } else {
                        v.performClick()
                        // The menu is a window above the bubble: this same touch already
                        // closed it (it counted as "outside" for it). Do not open it again.
                        if (recording || panelClosedAt < e.downTime) onTap()
                    }
                    true
                }
                else -> false
            }
        }
        w.addView(box, lp)
        bubble = box
    }

    /** Turned the phone: the bubble goes back inside the screen, against the nearer side. */
    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        val box = bubble ?: return
        val lp = bubbleParams ?: return
        closePanel()
        val sw = resources.displayMetrics.widthPixels
        val sh = resources.displayMetrics.heightPixels
        lp.x = if (lp.x + lp.width / 2 < sw / 2) dp(6f) else sw - lp.width - dp(6f)
        lp.y = lp.y.coerceIn(dp(24f), (sh - lp.height - dp(24f)).coerceAtLeast(dp(24f)))
        try { wm?.updateViewLayout(box, lp) } catch (_: Exception) {}
    }

    private fun applyState() {
        val r = ring ?: return
        val on = recording
        r.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.TRANSPARENT)
            setStroke(dp(3f), if (on) green else faint)
        }
        glow?.cancel()
        glow = null
        r.alpha = 1f
        if (on) {
            // A slow breath: the same green glow the old BYTE button had.
            glow = ValueAnimator.ofFloat(1f, 0.35f).apply {
                duration = 900
                repeatMode = ValueAnimator.REVERSE
                repeatCount = ValueAnimator.INFINITE
                addUpdateListener { r.alpha = it.animatedValue as Float }
                start()
            }
            closePanel()
        } else if (panel != null) {
            // The pinned checklist may have changed: draw the menu again.
            closePanel()
            openPanel()
        }
    }

    private fun onTap() {
        if (recording) {
            // Recording: one tap = stop and save.
            openByte("record")
            return
        }
        if (panel != null) closePanel() else openPanel()
    }

    // ---- The menu -----------------------------------------------------------

    private fun row(text: String, bold: Boolean = false, dim: Boolean = false, onClick: (() -> Unit)?): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(if (dim) faint else ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(16f), dp(11f), dp(16f), dp(11f))
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
            if (onClick != null) setOnClickListener { onClick() }
        }

    private fun openPanel() {
        val w = wm ?: return
        val bp = bubbleParams ?: return
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply { setColor(paper); cornerRadius = dp(18f).toFloat(); setStroke(dp(1f), Color.parseColor("#22000000")) }
            setPadding(0, dp(6f), 0, dp(6f))
        }
        col.addView(row("🎤  Voice note", bold = true) { closePanel(); openByte("record") })
        col.addView(row("📝  New note") { closePanel(); openByte("note") })
        col.addView(row("☑️  New checklist") { closePanel(); openByte("checklist") })
        col.addView(row("🔍  Search") { closePanel(); openByte("search") })

        // The checklist pinned in BYTE: its open items, tick them right here.
        val pin = ChecklistPins.read(this)
        if (pin != null && pin.open.isNotEmpty()) {
            col.addView(View(this).apply { setBackgroundColor(Color.parseColor("#22000000")) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1f)))
            col.addView(row(pin.title, dim = true) { closePanel(); openByte("pinned") })
            for (item in pin.open.take(5)) {
                val label = (if (item.level > 0) "      ○  " else "○  ") + item.text
                col.addView(row(label) {
                    ChecklistPins.tick(this, item.index)
                    closePanel()
                    openPanel()
                })
            }
            if (pin.open.size > 5) col.addView(row("+ ${pin.open.size - 5} more", dim = true) { closePanel(); openByte("pinned") })
        }
        col.addView(View(this).apply { setBackgroundColor(Color.parseColor("#22000000")) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1f)))
        col.addView(row("Hide the bubble", dim = true) {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("on", false).apply()
            stopSelf()
        })

        val width = dp(250f)
        val lp = WindowManager.LayoutParams(
            width, WindowManager.LayoutParams.WRAP_CONTENT, overlayType(),
            // Not focusable (the app below keeps the keyboard), but a touch outside closes the menu.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        lp.gravity = Gravity.TOP or Gravity.START
        val sw = resources.displayMetrics.widthPixels
        val sh = resources.displayMetrics.heightPixels
        val left = bp.x + bp.width / 2 < sw / 2
        lp.x = if (left) bp.x + bp.width + dp(8f) else (bp.x - width - dp(8f)).coerceAtLeast(dp(6f))
        lp.y = bp.y.coerceIn(dp(24f), (sh - dp(380f)).coerceAtLeast(dp(24f)))
        col.setOnTouchListener { v, e ->
            if (e.actionMasked == MotionEvent.ACTION_OUTSIDE) {
                panelClosedAt = android.os.SystemClock.uptimeMillis()
                v.performClick()
                closePanel()
                true
            } else {
                false
            }
        }
        try {
            w.addView(col, lp)
            panel = col
        } catch (e: Exception) {
            Log.w(TAG, "panel: $e")
        }
    }

    private fun closePanel() {
        panel?.let { try { wm?.removeView(it) } catch (_: Exception) {} }
        panel = null
    }

    /** Every action opens BYTE; [what] says which part (MainActivity hands it to Dart). */
    private fun openByte(what: String) {
        try {
            val i = Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("byte_from_bubble", true)
            if (what == "record") {
                i.action = Intent.ACTION_VOICE_COMMAND
            } else {
                i.putExtra("byte_open", what)
            }
            startActivity(i)
        } catch (e: Exception) {
            Log.w(TAG, "open $what: $e")
        }
    }
}
