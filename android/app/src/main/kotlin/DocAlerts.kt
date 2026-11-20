package com.naveen.byteapp

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * BYTE's reminders: "this paper runs out soon" for the document wallet
 * (group "docs"), and "do this now" for a checklist item (group "tasks").
 *
 * Dart hands over the whole list of a group each time something changes
 * ([setAll]); this object keeps the lists (so they can be set again after the
 * phone restarts) and asks Android to wake BYTE's [DocAlertReceiver] at each
 * time. The alarms are the ordinary, inexact kind: no special permission, and
 * Android may deliver one a few minutes late to save battery.
 */
object DocAlerts {
    private const val TAG = "ByteDocAlerts"
    private const val PREFS = "byte_doc_alerts"
    private const val KEY = "alarms"
    private const val CHANNEL = "byte_docs"
    private const val TASK_CHANNEL = "byte_task_reminders"
    const val ACTION = "com.naveen.byteapp.DOC_ALERT"

    /** [noteId] set: a checklist item's reminder; [index] is the item's number in that note. */
    data class Alarm(val id: Int, val at: Long, val title: String, val text: String, val noteId: String = "", val index: Int = -1)

    /** Where a group's list is kept. "docs" keeps the name it always had. */
    private fun keyOf(group: String) = if (group == "docs") KEY else "${KEY}_$group"

    private fun parse(raw: String?): List<Alarm> {
        val out = ArrayList<Alarm>()
        try {
            val arr = JSONArray(raw ?: "[]")
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val at = o.optLong("at", 0L)
                if (at <= 0L) continue
                out.add(Alarm(o.optInt("id", 0), at, o.optString("title", ""), o.optString("text", ""), o.optString("noteId", ""), o.optInt("index", -1)))
            }
        } catch (e: Exception) {
            Log.w(TAG, "parse: $e")
        }
        return out
    }

    private fun toJson(list: List<Alarm>): String {
        val arr = JSONArray()
        for (a in list) arr.put(JSONObject().put("id", a.id).put("at", a.at).put("title", a.title).put("text", a.text).put("noteId", a.noteId).put("index", a.index))
        return arr.toString()
    }

    private fun intentFor(ctx: Context, a: Alarm): Intent =
        Intent(ctx, DocAlertReceiver::class.java).setAction(ACTION).putExtra("id", a.id).putExtra("title", a.title).putExtra("text", a.text)
            .putExtra("noteId", a.noteId).putExtra("index", a.index)

    /**
     * Replaces every reminder of [group] with the ones in [json] (a JSON array
     * of {id, at, title, text, noteId?, index?}). The ids of two groups must
     * not overlap: Android tells the alarms apart by them.
     */
    fun setAll(ctx: Context, json: String?, group: String = "docs") {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val key = keyOf(group)
        for (old in parse(sp.getString(key, "[]"))) {
            try {
                val pi = PendingIntent.getBroadcast(ctx, old.id, intentFor(ctx, old), PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
                if (pi != null) {
                    am.cancel(pi)
                    pi.cancel()
                }
            } catch (e: Exception) {
                Log.w(TAG, "cancel: $e")
            }
        }
        val now = System.currentTimeMillis()
        val fresh = parse(json).filter { it.at > now }
        sp.edit().putString(key, toJson(fresh)).apply()
        schedule(ctx, fresh)
    }

    /** After the phone restarted: Android forgot the alarms; set the kept ones again. */
    fun rearm(ctx: Context) {
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        for (group in listOf("docs", "tasks")) schedule(ctx, parse(sp.getString(keyOf(group), "[]")).filter { it.at > now })
    }

    private fun schedule(ctx: Context, list: List<Alarm>) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for (a in list) {
            try {
                val pi = PendingIntent.getBroadcast(ctx, a.id, intentFor(ctx, a), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                // A checklist item's reminder is for a time of day: on the minute where
                // the phone allows it. A paper that runs out in a week may come a little late.
                val onTheMinute = a.noteId.isNotEmpty() && (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms())
                if (onTheMinute) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, a.at, pi)
                } else {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, a.at, pi)
                }
            } catch (e: Exception) {
                Log.w(TAG, "schedule ${a.id}: $e")
            }
        }
    }

    /**
     * Shows the reminder of a checklist item: its words, the list's name, and
     * a "Done" button that ticks it without opening BYTE. A tap opens the list.
     */
    fun showTask(ctx: Context, id: Int, title: String, text: String, noteId: String, index: Int) {
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) {
                nm.createNotificationChannel(NotificationChannel(TASK_CHANNEL, "List reminders", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "When a thing on one of your checklists is due"
                })
            }
            // One notification per item (not per alarm number, which is dealt
            // out afresh each time): a later reminder never replaces one that
            // is still waiting on the screen.
            val notifId = 0x40000000 or ("$noteId#$index".hashCode() and 0x3FFFFFFF)
            val open = PendingIntent.getActivity(
                ctx, notifId,
                Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra("byte_open", "note:$noteId"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val done = PendingIntent.getBroadcast(
                ctx, notifId,
                Intent(ctx, ChecklistReceiver::class.java).setAction(ChecklistReceiver.TASK_DONE)
                    .putExtra("noteId", noteId).putExtra("index", index).putExtra("text", title).putExtra("notif", notifId),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val n = NotificationCompat.Builder(ctx, TASK_CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(open)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .addAction(0, "✓ Done", done)
                .build()
            nm.notify(notifId, n)
        } catch (e: Exception) {
            Log.w(TAG, "show task: $e")
        }
    }

    /** Shows one reminder. A tap opens the document wallet. */
    fun show(ctx: Context, id: Int, title: String, text: String) {
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "Document reminders", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "When a paper in your document wallet is about to run out"
                })
            }
            val open = PendingIntent.getActivity(
                ctx, 3,
                Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra("byte_open", "wallet"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val n = NotificationCompat.Builder(ctx, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            nm.notify(40000 + (id and 0xFFFF), n)
        } catch (e: Exception) {
            // (Android 13+: nothing shows when notifications are not allowed for BYTE.)
            Log.w(TAG, "show: $e")
        }
    }
}

/** Woken by Android at a reminder's time, and once after the phone restarts. */
class DocAlertReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            DocAlerts.rearm(ctx)
            // A restart clears every notification: a checklist with things left to do goes back up.
            ChecklistPins.afterRestart(ctx)
            return
        }
        if (intent.action != DocAlerts.ACTION) return
        val id = intent.getIntExtra("id", 0)
        val title = intent.getStringExtra("title") ?: "BYTE"
        val text = intent.getStringExtra("text") ?: ""
        val noteId = intent.getStringExtra("noteId") ?: ""
        if (noteId.isNotEmpty()) {
            DocAlerts.showTask(ctx, id, title, text, noteId, intent.getIntExtra("index", -1))
        } else {
            DocAlerts.show(ctx, id, title, text)
        }
    }
}
