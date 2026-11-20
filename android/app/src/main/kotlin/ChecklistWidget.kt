package com.naveen.byteapp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.widget.RemoteViews
import android.widget.RemoteViewsService

/**
 * The BYTE checklist on the home screen.
 *
 * It shows the list that is in your notifications: its name, how much is
 * done, and every thing still to do in a list that scrolls. A tap on a line
 * ticks it (the same way as a tick in the notification); "＋ Add" opens the
 * small panel where things are typed or said; a tap on the name opens the
 * list in BYTE.
 */
class ChecklistWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        render(context, appWidgetManager, appWidgetIds)
    }

    companion object {
        private const val TAG = "BYTE/widget"

        /** The list changed (a tick, something added, pinned, unpinned): every widget on the home screen follows. */
        fun refresh(ctx: Context) {
            try {
                val mgr = AppWidgetManager.getInstance(ctx) ?: return
                val ids = mgr.getAppWidgetIds(ComponentName(ctx, ChecklistWidgetProvider::class.java))
                if (ids != null && ids.isNotEmpty()) render(ctx, mgr, ids)
            } catch (e: Exception) {
                Log.w(TAG, "refresh: $e")
            }
        }

        private fun render(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
            try {
                val pin = ChecklistPins.read(ctx)
                val views = RemoteViews(ctx.packageName, R.layout.checklist_widget)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

                if (pin == null) {
                    views.setTextViewText(R.id.cw_title, "No checklist yet")
                    views.setTextViewText(R.id.cw_sub, "Tap ＋ Add to start one")
                    views.setTextViewText(R.id.cw_empty, "Type or say the things to do. BYTE starts a list.")
                } else {
                    views.setTextViewText(R.id.cw_title, pin.title)
                    val done = pin.total - pin.open.size
                    views.setTextViewText(R.id.cw_sub, if (pin.open.isEmpty()) "All ${pin.total} done" else "$done of ${pin.total} done")
                    // (Empty words while there are items: this line also shows for a
                    // moment before the list has loaded.)
                    views.setTextViewText(R.id.cw_empty, if (pin.open.isEmpty()) "Nothing left to do" else "")
                }

                // The open items: a list that scrolls, filled by ChecklistWidgetService.
                @Suppress("DEPRECATION")
                views.setRemoteAdapter(R.id.cw_list, Intent(ctx, ChecklistWidgetService::class.java))
                views.setEmptyView(R.id.cw_list, R.id.cw_empty)
                // One "tick this one" for the whole list; each line adds its own number to it.
                // (That is why this one must be changeable — "mutable" — on Android 12+.)
                views.setPendingIntentTemplate(
                    R.id.cw_list,
                    PendingIntent.getBroadcast(
                        ctx, 96,
                        Intent(ctx, ChecklistReceiver::class.java).setAction(ChecklistReceiver.WIDGET_TICK),
                        PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0),
                    ),
                )

                // The name: the whole list in BYTE (or a new list while there is none).
                views.setOnClickPendingIntent(
                    R.id.cw_head,
                    PendingIntent.getActivity(
                        ctx, 4,
                        Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            .putExtra("byte_open", if (pin == null) "checklist" else "pinned"),
                        flags,
                    ),
                )
                // "＋ Add": the small panel, to type or say things.
                views.setOnClickPendingIntent(
                    R.id.cw_add,
                    PendingIntent.getActivity(ctx, 5, Intent(ctx, ChecklistPanelActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP), flags),
                )
                mgr.updateAppWidget(ids, views)
                // The lines themselves are asked for again.
                @Suppress("DEPRECATION")
                mgr.notifyAppWidgetViewDataChanged(ids, R.id.cw_list)
            } catch (e: Exception) {
                Log.w(TAG, "render: $e")
            }
        }
    }
}

/** Hands the home screen the lines of the widget's list, one by one. */
class ChecklistWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Lines(applicationContext)

    private class Lines(private val ctx: Context) : RemoteViewsFactory {
        private var items: List<ChecklistPins.Item> = emptyList()

        override fun onCreate() {}

        override fun onDataSetChanged() {
            items = try {
                ChecklistPins.read(ctx)?.open ?: emptyList()
            } catch (e: Exception) {
                Log.w("BYTE/widget", "lines: $e")
                emptyList()
            }
        }

        override fun onDestroy() {
            items = emptyList()
        }

        override fun getCount(): Int = items.size

        override fun getViewAt(position: Int): RemoteViews {
            val row = RemoteViews(ctx.packageName, R.layout.checklist_widget_row)
            // (The list can shrink between two calls: an empty line then, never a crash.)
            val item = items.getOrNull(position) ?: return row
            row.setTextViewText(R.id.cw_item, (if (item.level > 0) "      ○  " else "○  ") + item.text)
            // This line's own number, added to the list's "tick this one".
            row.setOnClickFillInIntent(R.id.cw_item, Intent().putExtra("index", item.index))
            return row
        }

        // An empty line of BYTE's own while a line loads, not the phone's "Loading…".
        override fun getLoadingView(): RemoteViews? = RemoteViews(ctx.packageName, R.layout.checklist_widget_row)

        override fun getViewTypeCount(): Int = 1

        override fun getItemId(position: Int): Long = items.getOrNull(position)?.index?.toLong() ?: position.toLong()

        override fun hasStableIds(): Boolean = true
    }
}
