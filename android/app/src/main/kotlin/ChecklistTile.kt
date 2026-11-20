package com.naveen.byteapp

import android.app.Activity
import android.app.PendingIntent
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.Toast
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * The "BYTE checklist" button in the phone's control centre (quick settings).
 *
 * One tap opens a small panel over whatever is on screen: the things still
 * to do, each ticked with a tap. It lights up while something is left to do.
 */
class ChecklistTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        try {
            val tile = qsTile ?: return
            val left = ChecklistPins.read(this)?.open?.size ?: 0
            tile.state = if (left > 0) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            tile.label = "BYTE checklist"
            if (Build.VERSION.SDK_INT >= 29) tile.subtitle = if (left > 0) "$left to do" else "Nothing to do"
            tile.updateTile()
        } catch (e: Exception) {
            Log.w(TAG, "tile: $e")
        }
    }

    override fun onClick() {
        super.onClick()
        try {
            if (isLocked) unlockAndRun { openPanel() } else openPanel()
        } catch (e: Exception) {
            Log.w(TAG, "click: $e")
        }
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openPanel() {
        val i = Intent(this, ChecklistPanelActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                // Android 14 and later only take the "pending" form.
                startActivityAndCollapse(PendingIntent.getActivity(this, 3, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(i)
            }
        } catch (e: Exception) {
            Log.w(TAG, "open: $e")
        }
    }

    private companion object {
        const val TAG = "BYTE/tile"
    }
}

/**
 * The small panel the control-centre button opens, over whatever is on screen:
 * the checklist that is in your notifications.
 *
 *  - Tap a line: it is ticked.
 *  - Type "milk, eggs, bread" and tap Add: three new lines. Or tap the mic and say them.
 *  - With no list yet, the first thing you add starts one.
 *
 * Everything is kept at once (the same way as a tick made in the notification)
 * and written into the note by BYTE.
 */
class ChecklistPanelActivity : Activity() {
    private var dark = false
    private val paper get() = if (dark) Color.parseColor("#1B1F22") else Color.parseColor("#F6F4EE")
    private val ink get() = if (dark) Color.parseColor("#ECEFF1") else Color.parseColor("#14181B")
    private val faint get() = if (dark) Color.parseColor("#9AA1A7") else Color.parseColor("#6F767C")
    private val line get() = if (dark) Color.parseColor("#22FFFFFF") else Color.parseColor("#22000000")
    private val green = Color.parseColor("#2FBF71")
    private val onGreen = Color.parseColor("#0B1F14")

    // The parts that change. Built once, so what is being typed is never lost.
    private lateinit var card: LinearLayout
    private lateinit var title: TextView
    private lateinit var sub: TextView
    private lateinit var rows: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var box: EditText
    private lateinit var openButton: TextView

    /** The speech window of the phone is open: the panel waits for it. */
    private var listening = false

    private fun dp(v: Float): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Light or dark the way BYTE itself is set (Settings, Appearance).
        val phoneDark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        dark = try {
            when (getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getString("flutter.theme_mode", "system")) {
                "dark" -> true
                "light" -> false
                else -> phoneDark
            }
        } catch (_: Exception) {
            phoneDark
        }
        // The dimming runs under the bars at the top and the bottom too.
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                @Suppress("DEPRECATION")
                window.setDecorFitsSystemWindows(false)
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            }
        } catch (e: Exception) {
            Log.w(TAG, "edge to edge: $e")
        }
        build()
    }

    override fun onResume() {
        super.onResume()
        refresh() // ticked or added meanwhile in the notification or in BYTE
    }

    override fun onStop() {
        super.onStop()
        // Left with Home or another app: the panel does not wait in the background.
        if (!isChangingConfigurations && !listening) finish()
    }

    /** A soft press mark over [shape] (or over a plain row when [shape] is null). */
    private fun pressable(shape: GradientDrawable?): RippleDrawable =
        RippleDrawable(ColorStateList.valueOf(if (dark) Color.parseColor("#33FFFFFF") else Color.parseColor("#22000000")), shape, if (shape == null) ColorDrawable(Color.WHITE) else null)

    private fun text(s: String, size: Float, color: Int, bold: Boolean = false): TextView = TextView(this).apply {
        text = s
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun button(label: String, filled: Boolean, onClick: () -> Unit): TextView = text(label, 15f, if (filled) onGreen else ink, bold = true).apply {
        gravity = Gravity.CENTER
        setPadding(dp(16f), dp(13f), dp(16f), dp(13f))
        background = pressable(GradientDrawable().apply {
            cornerRadius = dp(14f).toFloat()
            if (filled) setColor(green) else { setColor(paper); setStroke(dp(1f), line) }
        })
        setOnClickListener { onClick() }
    }

    private fun gap(height: Float): View = View(this).apply { layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(height)) }

    /** Builds the panel once; [refresh] fills it. */
    private fun build() {
        card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val r = dp(24f).toFloat()
            background = GradientDrawable().apply {
                setColor(paper)
                cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
            }
            setPadding(dp(20f), dp(18f), dp(20f), dp(20f))
            isClickable = true // a tap on the card is not a tap outside
        }
        title = text("", 19f, ink, bold = true).apply { maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END }
        sub = text("", 14f, faint).apply { setPadding(0, dp(4f), 0, dp(10f)) }
        rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        // Long lists scroll; the box and the buttons under them stay on screen.
        scroll = ScrollView(this).apply { addView(rows) }
        card.addView(title)
        card.addView(sub)
        card.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        card.addView(gap(12f))

        // Add: type many at once, or say them.
        box = EditText(this).apply {
            hint = "Add: milk, eggs, bread"
            setHintTextColor(faint)
            setTextColor(ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_DONE
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            setPadding(dp(14f), dp(12f), dp(14f), dp(12f))
            background = GradientDrawable().apply { cornerRadius = dp(14f).toFloat(); setColor(paper); setStroke(dp(1f), line) }
            setOnEditorActionListener { _, action, _ ->
                if (action == EditorInfo.IME_ACTION_DONE) { addTyped(); true } else false
            }
        }
        val mic = button("🎤", filled = false) { speak() }.apply { contentDescription = "Say the things to do" }
        val add = button("Add", filled = true) { addTyped() }
        val addRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(box, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(mic, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(8f) })
            addView(add, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(8f) })
        }
        card.addView(addRow)
        card.addView(gap(10f))
        openButton = button("Open the list in BYTE", filled = false) { openByte("pinned") }
        card.addView(openButton)

        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor("#73000000"))
            setOnClickListener { finish() } // a tap outside closes the panel
            setOnApplyWindowInsetsListener { _, insets ->
                // Clear of the status bar at the top; above the keyboard (or the bar) at the bottom.
                val (top, bottom) = bars(insets)
                (card.layoutParams as? FrameLayout.LayoutParams)?.let {
                    if (it.topMargin != top + dp(48f)) {
                        it.topMargin = top + dp(48f)
                        card.layoutParams = it
                    }
                }
                if (card.paddingBottom != dp(20f) + bottom) card.setPadding(dp(20f), dp(18f), dp(20f), dp(20f) + bottom)
                insets
            }
        }
        root.addView(card, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply { topMargin = dp(72f) })
        setContentView(root)
    }

    /** Shows the list as it is now. */
    private fun refresh() {
        val pin = ChecklistPins.read(this)
        if (pin == null) {
            title.text = "No checklist yet"
            sub.text = "Type the things to do below, or tap the mic and say them. BYTE starts a list."
        } else {
            title.text = pin.title
            val done = pin.total - pin.open.size
            sub.text = if (pin.open.isEmpty()) "All ${pin.total} done" else "$done of ${pin.total} done. Tap a line to tick it."
        }
        openButton.visibility = if (pin == null) View.GONE else View.VISIBLE
        rows.removeAllViews()
        for (item in pin?.open ?: emptyList()) {
            rows.addView(text("○   " + item.text, 17f, ink).apply {
                setPadding(if (item.level > 0) dp(28f) else 0, dp(13f), 0, dp(13f))
                maxLines = 3
                ellipsize = android.text.TextUtils.TruncateAt.END
                background = pressable(null)
                setOnClickListener {
                    ChecklistPins.tick(this@ChecklistPanelActivity, item.index)
                    refresh()
                }
            })
            rows.addView(View(this).apply { setBackgroundColor(line) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1f)))
        }
    }

    /** What is in the box becomes lines: "milk, eggs, bread" is three. */
    private fun addTyped() {
        val n = ChecklistPins.add(this, ChecklistPins.splitTyped(box.text.toString()))
        if (n == 0) return
        box.setText("")
        added()
    }

    private fun added() {
        refresh()
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) } // the new lines are at the end
    }

    /** The phone's own speech window: what is said becomes lines. */
    private fun speak() {
        try {
            val i = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL, android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(android.speech.RecognizerIntent.EXTRA_PROMPT, "Say the things to do")
            // The language chosen in BYTE (Settings, Words while you talk).
            val lang = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getString("flutter.voice_locale", null)
            i.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE, if (lang.isNullOrEmpty()) "en-IN" else lang)
            listening = true
            @Suppress("DEPRECATION")
            startActivityForResult(i, REQ_SPEAK)
        } catch (e: Exception) {
            listening = false
            Log.w(TAG, "speak: $e")
            Toast.makeText(this, "This phone has no speech input. Type the things instead.", Toast.LENGTH_LONG).show()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_SPEAK) return
        listening = false
        if (resultCode != RESULT_OK) return
        val said = data?.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS)?.firstOrNull() ?: return
        if (ChecklistPins.add(this, ChecklistPins.splitSpoken(said)) > 0) added()
    }

    /** (top, bottom): the height of the status bar, and of the keyboard or the bar at the bottom. */
    private fun bars(insets: WindowInsets): Pair<Int, Int> =
        if (Build.VERSION.SDK_INT >= 30) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            val keys = insets.getInsets(WindowInsets.Type.ime())
            Pair(bars.top, maxOf(bars.bottom, keys.bottom))
        } else {
            @Suppress("DEPRECATION")
            Pair(insets.systemWindowInsetTop, insets.systemWindowInsetBottom)
        }

    /** Opens BYTE at [what] ("pinned": the list itself). */
    private fun openByte(what: String) {
        try {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra("byte_open", what),
            )
        } catch (e: Exception) {
            Log.w(TAG, "open $what: $e")
        }
        finish()
    }

    private companion object {
        const val TAG = "BYTE/tile"
        const val REQ_SPEAK = 41
    }
}
