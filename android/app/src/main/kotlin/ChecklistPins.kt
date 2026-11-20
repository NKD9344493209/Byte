package com.naveen.byteapp

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import org.json.JSONArray
import org.json.JSONObject

/**
 * The checklist you pinned in BYTE, kept where the notification shade and
 * the floating bubble can show it and tick it — also while BYTE is closed.
 *
 * BYTE (Dart) hands over the list with [set]. A tick made here is applied to
 * this copy at once, and remembered in a small "to do in the real note" list
 * that BYTE collects with [takeTicks] the next time it is open — the note
 * itself lives in the encrypted vault, which only BYTE can write.
 */
object ChecklistPins {
    private const val TAG = "BYTE/pin"
    // A new name: Android never lets an app raise an existing channel, and the
    // first one ("byte_checklist") was a quiet one that some phones tuck away.
    private const val CHANNEL = "byte_pinned_list"
    private const val OLD_CHANNEL = "byte_checklist"
    private const val NOTIF_ID = 9921
    private const val KEY = "pin"
    private const val KEY_TICKS = "ticks"
    private const val KEY_ADDS = "adds"

    /** The name of the "type here" box of the notification's Add button. */
    const val REPLY_KEY = "byte_add"

    /** Set by MainActivity while BYTE is running: a tick was made, come and collect it now. */
    @Volatile var onTick: (() -> Unit)? = null

    class Item(val index: Int, val text: String, val level: Int)
    class Pin(val noteId: String, val title: String, val open: List<Item>, val total: Int)

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(BubbleService.PREFS, Context.MODE_PRIVATE)

    /** [json]: {"noteId","title","items":[{"i":0,"text":"…","level":0,"done":false}]} — or null/"" to unpin. */
    fun set(ctx: Context, json: String?) {
        val sp = prefs(ctx)
        if (json.isNullOrEmpty()) {
            sp.edit().remove(KEY).apply()
            cancel(ctx)
        } else {
            sp.edit().putString(KEY, json).apply()
            show(ctx)
        }
        armStartAgain(ctx)
        BubbleService.refresh(ctx)
        ChecklistWidgetProvider.refresh(ctx)
    }

    /**
     * A list that repeats (every day, every week) starts again at "resetAt":
     * from then on this copy shows everything un-ticked. ("every" is the
     * length of one round, in milliseconds.) BYTE does the same to the note.
     */
    private fun startAgainIfDue(ctx: Context, o: JSONObject): Boolean {
        val resetAt = o.optLong("resetAt", 0L)
        val every = o.optLong("every", 0L)
        val now = System.currentTimeMillis()
        if (resetAt <= 0L || every <= 0L || now < resetAt) return false
        val items = o.optJSONArray("items") ?: JSONArray()
        for (k in 0 until items.length()) items.getJSONObject(k).put("done", false)
        o.put("resetAt", resetAt + ((now - resetAt) / every + 1) * every)
        prefs(ctx).edit().putString(KEY, o.toString()).apply()
        return true
    }

    /** Asks Android to wake BYTE when the repeating list starts again, so the notification shows the new round. */
    private fun armStartAgain(ctx: Context) {
        try {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            val pi = PendingIntent.getBroadcast(
                ctx, 98,
                Intent(ctx, ChecklistReceiver::class.java).setAction(ChecklistReceiver.START_AGAIN),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            am.cancel(pi)
            val raw = prefs(ctx).getString(KEY, null) ?: return
            val resetAt = JSONObject(raw).optLong("resetAt", 0L)
            if (resetAt > System.currentTimeMillis()) am.setAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, resetAt, pi)
        } catch (e: Exception) {
            Log.w(TAG, "arm: $e")
        }
    }

    /** The phone restarted: the notification and the "start again" alarm are gone; put both back. */
    fun afterRestart(ctx: Context) {
        val pin = read(ctx) ?: return
        armStartAgain(ctx)
        if (pin.open.isNotEmpty()) show(ctx)
        ChecklistWidgetProvider.refresh(ctx)
    }

    /** The time a repeating list starts again has come: show the new round. */
    fun startAgain(ctx: Context) {
        read(ctx) ?: return // (reading it un-ticks everything when the time has come)
        armStartAgain(ctx)
        show(ctx)
        BubbleService.refresh(ctx)
        ChecklistWidgetProvider.refresh(ctx)
    }

    fun read(ctx: Context): Pin? {
        val raw = prefs(ctx).getString(KEY, null) ?: return null
        return try {
            val o = JSONObject(raw)
            startAgainIfDue(ctx, o)
            val items = o.optJSONArray("items") ?: JSONArray()
            val open = ArrayList<Item>()
            for (k in 0 until items.length()) {
                val row = items.getJSONObject(k)
                if (!row.optBoolean("done", false)) open.add(Item(row.optInt("i", k), row.optString("text", ""), row.optInt("level", 0)))
            }
            Pin(o.optString("noteId", ""), o.optString("title", "Checklist"), open, items.length())
        } catch (e: Exception) {
            Log.w(TAG, "read: $e")
            null
        }
    }

    /** Ticks task number [index] of the pinned checklist (the same numbering BYTE uses). */
    fun tick(ctx: Context, index: Int) {
        read(ctx) // a repeating list that is due starts again first
        val sp = prefs(ctx)
        val raw = sp.getString(KEY, null) ?: return
        try {
            val o = JSONObject(raw)
            val items = o.optJSONArray("items") ?: return
            var found = false
            for (k in 0 until items.length()) {
                val row = items.getJSONObject(k)
                if (row.optInt("i", k) == index && !row.optBoolean("done", false)) {
                    row.put("done", true)
                    found = true
                }
            }
            if (!found) return
            val ticks = JSONArray(sp.getString(KEY_TICKS, "[]"))
            ticks.put(JSONObject().put("noteId", o.optString("noteId", "")).put("index", index).put("at", System.currentTimeMillis()))
            sp.edit().putString(KEY, o.toString()).putString(KEY_TICKS, ticks.toString()).apply()
            show(ctx)
            BubbleService.refresh(ctx)
            ChecklistWidgetProvider.refresh(ctx)
            // BYTE is open (maybe showing this very list): it writes the tick into the note at once.
            try { onTick?.invoke() } catch (_: Exception) {}
        } catch (e: Exception) {
            Log.w(TAG, "tick: $e")
        }
    }

    /**
     * Ticks task [index] of note [noteId] — from the "Done" button of a
     * reminder. The list in the notifications is ticked the usual way; any
     * other list only gets the tick remembered for BYTE to write in.
     */
    fun tickNote(ctx: Context, noteId: String, index: Int, text: String = "") {
        if (noteId.isEmpty() || index < 0) return
        val sp = prefs(ctx)
        try {
            val raw = sp.getString(KEY, null)
            if (raw != null && JSONObject(raw).optString("noteId", "") == noteId) {
                tick(ctx, index)
                return
            }
            val ticks = JSONArray(sp.getString(KEY_TICKS, "[]"))
            // [text]: the item's words when the reminder was set — BYTE ticks the
            // item that still says so, even if the list was changed since.
            ticks.put(JSONObject().put("noteId", noteId).put("index", index).put("text", text).put("at", System.currentTimeMillis()))
            sp.edit().putString(KEY_TICKS, ticks.toString()).apply()
            try { onTick?.invoke() } catch (_: Exception) {}
        } catch (e: Exception) {
            Log.w(TAG, "tick note: $e")
        }
    }

    /** What was typed, as separate things to do: "milk, eggs; bread" is three. */
    fun splitTyped(text: String): List<String> =
        text.split(Regex("[\\r\\n\\u2028\\u2029,;]+")).map { it.trim() }.filter { it.isNotEmpty() }

    /**
     * What was said, as separate things to do — the same way BYTE itself does it:
     * split at commas, full stops, "and then", "then", "also"; a capital letter each.
     */
    fun splitSpoken(text: String): List<String> {
        val parts = text.split(Regex("\\n+|[.;,]\\s+|[.;,]$|\\s+(?:and then|then|and also|also)\\s+", RegexOption.IGNORE_CASE))
        val out = ArrayList<String>()
        for (p in parts) {
            var t = p.trim()
            if (t.lowercase().startsWith("and ")) t = t.substring(4).trim()
            if (t.isEmpty()) continue
            out.add(t.substring(0, 1).uppercase() + t.substring(1))
        }
        return out
    }

    /**
     * Adds [texts] at the end of the checklist — made outside BYTE (the
     * control-centre panel, the notification's Add button). With no list yet,
     * a new one is started. Like a tick, it shows here at once and BYTE writes
     * it into the real note (see [pendingAdds]). Answers how many were added.
     */
    fun add(ctx: Context, texts: List<String>): Int {
        // One thing is one line, whatever kind of line end came with it.
        val clean = texts.map { it.replace(Regex("[\\r\\n\\u2028\\u2029]+"), " ").trim().take(300) }.filter { it.isNotEmpty() }.take(50)
        if (clean.isEmpty()) return 0
        read(ctx) // a repeating list that is due starts again first
        val sp = prefs(ctx)
        return try {
            val raw = sp.getString(KEY, null)
            val fresh = raw == null
            val o = if (raw == null) {
                JSONObject().put("noteId", java.util.UUID.randomUUID().toString()).put("title", "Checklist").put("items", JSONArray())
            } else {
                JSONObject(raw)
            }
            val items = o.optJSONArray("items") ?: JSONArray().also { o.put("items", it) }
            var next = 0
            for (k in 0 until items.length()) next = maxOf(next, items.getJSONObject(k).optInt("i", k) + 1)
            val adds = JSONArray(sp.getString(KEY_ADDS, "[]"))
            val noteId = o.optString("noteId", "")
            for (t in clean) {
                items.put(JSONObject().put("i", next++).put("text", t).put("level", 0).put("done", false))
                adds.put(JSONObject().put("noteId", noteId).put("text", t).put("fresh", fresh))
            }
            sp.edit().putString(KEY, o.toString()).putString(KEY_ADDS, adds.toString()).apply()
            show(ctx)
            BubbleService.refresh(ctx)
            ChecklistWidgetProvider.refresh(ctx)
            // BYTE is open: it writes them into the note at once.
            try { onTick?.invoke() } catch (_: Exception) {}
            clean.size
        } catch (e: Exception) {
            Log.w(TAG, "add: $e")
            0
        }
    }

    /**
     * The things added outside BYTE that are not in their note yet, as a JSON
     * array text. They stay here until BYTE says they are written ([addsWritten]),
     * so nothing is lost when BYTE could not write just then.
     */
    fun pendingAdds(ctx: Context): String = prefs(ctx).getString(KEY_ADDS, "[]") ?: "[]"

    /** BYTE wrote the first [count] of [pendingAdds] into their notes: forget those. */
    fun addsWritten(ctx: Context, count: Int) {
        if (count <= 0) return
        val sp = prefs(ctx)
        try {
            val all = JSONArray(sp.getString(KEY_ADDS, "[]"))
            val rest = JSONArray()
            for (k in count until all.length()) rest.put(all.get(k))
            if (rest.length() == 0) sp.edit().remove(KEY_ADDS).apply() else sp.edit().putString(KEY_ADDS, rest.toString()).apply()
        } catch (e: Exception) {
            Log.w(TAG, "adds written: $e")
            sp.edit().remove(KEY_ADDS).apply()
        }
    }

    /** The ticks made outside BYTE since the last call, as a JSON array text; the list is then emptied. */
    fun takeTicks(ctx: Context): String {
        val sp = prefs(ctx)
        val raw = sp.getString(KEY_TICKS, "[]") ?: "[]"
        sp.edit().remove(KEY_TICKS).apply()
        return raw
    }

    private fun cancel(ctx: Context) {
        try {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIF_ID)
        } catch (_: Exception) {}
    }

    /** The channel of the pinned list: shown like any other notification, but it never rings or buzzes. */
    private fun channel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < 26) return
        try { nm.deleteNotificationChannel(OLD_CHANNEL) } catch (_: Exception) {}
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Checklist in notifications", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Your checklist, with tick buttons and an Add button"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        })
    }

    /**
     * Can the phone show the list right now? False when notifications are not
     * allowed for BYTE, or when "Checklist in notifications" was turned off in
     * the phone's settings.
     */
    fun canShow(ctx: Context): Boolean {
        return try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 24 && !nm.areNotificationsEnabled()) return false
            channel(nm)
            Build.VERSION.SDK_INT < 26 || nm.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
        } catch (e: Exception) {
            Log.w(TAG, "canShow: $e")
            false
        }
    }

    /** Draws (or redraws) the notification: the open items, tick buttons for the next two, and Add. */
    fun show(ctx: Context) {
        val pin = read(ctx) ?: return
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            channel(nm)
            val open = PendingIntent.getActivity(
                ctx, 2,
                Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra("byte_open", "pinned"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val b = NotificationCompat.Builder(ctx, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentIntent(open)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            if (pin.open.isEmpty()) {
                b.setContentTitle(pin.title).setContentText("All ${pin.total} done").setOngoing(false).setAutoCancel(true)
            } else {
                val first = pin.open.first()
                val style = NotificationCompat.InboxStyle()
                for (item in pin.open.take(6)) style.addLine((if (item.level > 0) "    ○ " else "○ ") + item.text)
                if (pin.open.size > 6) style.setSummaryText("+ ${pin.open.size - 6} more")
                b.setContentTitle("${pin.title} · ${pin.total - pin.open.size} of ${pin.total} done")
                    .setContentText("Next: ${first.text}")
                    .setStyle(style)
                    .setOngoing(true)
                    // Android 14 lets a swipe clear even a lasting notification. While
                    // things are left to do, the list comes straight back; it leaves
                    // when everything is ticked, or when it is taken out in BYTE.
                    .setDeleteIntent(
                        PendingIntent.getBroadcast(
                            ctx, 97,
                            Intent(ctx, ChecklistReceiver::class.java).setAction(ChecklistReceiver.SWIPED),
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                        ),
                    )
                // A tick button for each of the next two things to do: a tap ticks
                // that one and saves it. (Android shows three buttons at most; the
                // third is "Add".)
                for (item in pin.open.take(2)) {
                    val done = PendingIntent.getBroadcast(
                        ctx, 100 + item.index,
                        Intent(ctx, ChecklistReceiver::class.java).putExtra("index", item.index),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    b.addAction(0, "✓ " + item.text.take(if (pin.open.size == 1) 20 else 12), done)
                }
            }
            // "Add": type right in the notification — "milk, eggs, bread" is three things.
            val add = PendingIntent.getBroadcast(
                ctx, 99,
                Intent(ctx, ChecklistReceiver::class.java).setAction(ChecklistReceiver.ADD),
                PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0),
            )
            b.addAction(
                NotificationCompat.Action.Builder(0, "＋ Add", add)
                    .addRemoteInput(RemoteInput.Builder(REPLY_KEY).setLabel("milk, eggs, bread").build())
                    .build(),
            )
            nm.notify(NOTIF_ID, b.build())
        } catch (e: Exception) {
            // No notification permission, or notifications blocked: the bubble still shows the list.
            Log.w(TAG, "show: $e")
        }
    }
}

/** The buttons of the checklist notification: the ticks, and "Add". */
class ChecklistReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ADD) {
            val typed = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(ChecklistPins.REPLY_KEY)?.toString() ?: ""
            // Nothing typed: still draw the notification again, or its box keeps spinning.
            if (ChecklistPins.add(context, ChecklistPins.splitTyped(typed)) == 0) ChecklistPins.show(context)
            return
        }
        if (intent.action == START_AGAIN) {
            ChecklistPins.startAgain(context)
            return
        }
        if (intent.action == SWIPED) {
            // Swiped away with things still to do: it goes back up.
            if (ChecklistPins.read(context)?.open?.isNotEmpty() == true) ChecklistPins.show(context)
            return
        }
        if (intent.action == TASK_DONE) {
            // "Done" on a reminder: tick the item, and take the reminder away.
            ChecklistPins.tickNote(context, intent.getStringExtra("noteId") ?: "", intent.getIntExtra("index", -1), intent.getStringExtra("text") ?: "")
            try {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(intent.getIntExtra("notif", 0))
            } catch (_: Exception) {}
            return
        }
        val index = intent.getIntExtra("index", -1)
        if (index >= 0) ChecklistPins.tick(context, index)
    }

    companion object {
        const val ADD = "com.naveen.byteapp.CHECKLIST_ADD"
        const val START_AGAIN = "com.naveen.byteapp.CHECKLIST_START_AGAIN"
        const val SWIPED = "com.naveen.byteapp.CHECKLIST_SWIPED"

        /** A line tapped in the home-screen widget (its number comes along as "index"). */
        const val WIDGET_TICK = "com.naveen.byteapp.CHECKLIST_WIDGET_TICK"
        const val TASK_DONE = "com.naveen.byteapp.TASK_DONE"
    }
}
