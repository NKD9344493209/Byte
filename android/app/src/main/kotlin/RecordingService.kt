package com.naveen.byteapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Keeps a recording going when the screen turns off.
 *
 * Android silences the microphone of an app that is not on screen, unless
 * the app runs a "microphone" foreground service with a notification. This
 * service is only that: a quiet "BYTE is recording" line in the shade for as
 * long as the recorder has the mic open. It records nothing itself.
 *
 * MainActivity starts it when the recorder opens the mic (BYTE is on screen
 * at that moment, which Android 14 requires) and stops it when the mic closes.
 */
class RecordingService : Service() {
    companion object {
        private const val TAG = "BYTE/rec"
        private const val CHANNEL = "byte_recording"
        private const val NOTIF_ID = 9901

        /** True once Android has accepted the foreground service. */
        @Volatile
        var running = false

        /** Call while BYTE is on screen. Never throws; if Android refuses, [running] stays false. */
        fun start(ctx: Context) {
            try {
                // startService, not startForegroundService: BYTE is in front here, and a
                // refusal then costs nothing (no "did not call startForeground" crash).
                ctx.startService(Intent(ctx, RecordingService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "start: $e")
            }
        }

        fun stop(ctx: Context) {
            try { ctx.stopService(Intent(ctx, RecordingService::class.java)) } catch (_: Exception) {}
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            ensureChannel()
            // FOREGROUND_SERVICE_TYPE_MICROPHONE exists from API 30; below that the
            // 2-argument call uses the type declared in the manifest.
            if (Build.VERSION.SDK_INT >= 30) {
                startForeground(NOTIF_ID, notif(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIF_ID, notif())
            }
            running = true
        } catch (e: Exception) {
            Log.w(TAG, "startForeground: $e")
            running = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    /** BYTE was swiped away from Recents: the recorder is gone, so this line goes too. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Recording", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shows while BYTE records a voice note"
            setShowBadge(false)
        })
    }

    private fun notif(): Notification {
        val open = PendingIntent.getActivity(
            this, NOTIF_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("BYTE is recording")
            .setContentText("Tap to open BYTE")
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}
