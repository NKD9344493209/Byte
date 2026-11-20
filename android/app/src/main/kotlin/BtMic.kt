package com.naveen.byteapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import android.util.Log

/**
 * Routes the microphone to a Bluetooth headset while BYTE listens.
 *
 * Why: with a neckband / earbuds connected, Android still records from the
 * PHONE's microphone unless the app opens the headset's voice link (SCO).
 * Music (A2DP) comes out of the buds, but "yes" said into the buds never
 * reaches the recogniser — it hears the pocket. That is the "Bluetooth keeps
 * failing" bug.
 *
 * attach(): if a Bluetooth headset with a mic is on, open the voice link and
 * call [ready] once the link is up (or after a short timeout — then BYTE still
 * listens, on the phone mic). No headset → [ready] at once. Always on the main
 * thread, always exactly once.
 *
 * releaseSoon(): close the link a little later, so a speak → listen → speak
 * conversation does not re-open it every turn (each open costs ~1 s).
 */
object BtMic {
    private const val tag = "BYTE/btmic"
    private const val LINGER_MS = 6000L
    private const val OPEN_TIMEOUT_MS = 2500L

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var attached = false
    private var opening = false
    private var pendingRelease: Runnable? = null
    private var openTimeout: Runnable? = null
    /** uptime of the last failed open — don't burn 2.5 s again on every round for 15 s. */
    private var failedAt = 0L
    private const val RETRY_AFTER_MS = 15_000L
    private var waiters = ArrayList<() -> Unit>()
    private var scoReceiver: BroadcastReceiver? = null
    private var commListener: Any? = null // AudioManager.OnCommunicationDeviceChangedListener (API 31+)

    /** A Bluetooth headset that can record is connected right now. */
    fun headsetMic(ctx: Context): AudioDeviceInfo? = try {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull {
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                (Build.VERSION.SDK_INT >= 31 && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
        }
    } catch (e: Exception) { Log.w(tag, "devices: $e"); null }

    fun isAttached() = attached

    /** One line for the Calls log / diagnostics. */
    fun describe(ctx: Context): String {
        val d = headsetMic(ctx) ?: return "no Bluetooth mic"
        val name = try { d.productName?.toString() ?: "" } catch (_: Exception) { "" }
        return "Bluetooth mic ${name.ifBlank { "headset" }}${if (attached) " (voice link on)" else ""}"
    }

    fun attach(ctx: Context, ready: () -> Unit) {
        val app = ctx.applicationContext
        pendingRelease?.let { main.removeCallbacks(it) }
        pendingRelease = null
        if (attached) { main.post(ready); return }
        val dev = headsetMic(app)
        if (dev == null) { main.post(ready); return }
        if (!opening && failedAt != 0L && SystemClock.uptimeMillis() - failedAt < RETRY_AFTER_MS) {
            main.post(ready); return // it just failed; phone mic for now
        }
        waiters.add(ready)
        if (opening) return
        opening = true
        val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val timeout = Runnable {
            Log.i(tag, "voice link: timeout — listening on the phone mic")
            opened(app, false)
        }
        openTimeout = timeout
        main.postDelayed(timeout, OPEN_TIMEOUT_MS)
        try {
            if (Build.VERSION.SDK_INT >= 31) openModern(app, am, dev) { ok -> opened(app, ok) }
            else openLegacy(app, am) { ok -> opened(app, ok) }
        } catch (e: Exception) {
            Log.w(tag, "voice link: $e")
            opened(app, false)
        }
    }

    private fun cancelOpenTimeout() {
        openTimeout?.let { main.removeCallbacks(it) }
        openTimeout = null
    }

    /** Close the voice link after a short linger (a new attach() cancels it). */
    fun releaseSoon(ctx: Context) {
        if (!attached && !opening) return
        pendingRelease?.let { main.removeCallbacks(it) }
        val r = Runnable { pendingRelease = null; release(ctx) }
        pendingRelease = r
        main.postDelayed(r, LINGER_MS)
    }

    fun release(ctx: Context) {
        val app = ctx.applicationContext
        pendingRelease?.let { main.removeCallbacks(it) }
        pendingRelease = null
        if (!attached && !opening) return
        cancelOpenTimeout()
        attached = false
        opening = false
        val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                am.clearCommunicationDevice()
                removeCommListener(am)
            } else {
                @Suppress("DEPRECATION")
                am.isBluetoothScoOn = false
                @Suppress("DEPRECATION")
                am.stopBluetoothSco()
            }
        } catch (e: Exception) { Log.w(tag, "release: $e") }
        unregisterSco(app)
        // Anyone still waiting gets their callback — they listen on the phone mic.
        val w = waiters; waiters = ArrayList()
        for (cb in w) main.post(cb)
        Log.i(tag, "voice link closed")
    }

    // ───────────── internals ─────────────

    private fun opened(app: Context, ok: Boolean) {
        if (!opening) return
        cancelOpenTimeout()
        opening = false
        attached = ok
        failedAt = if (ok) 0L else SystemClock.uptimeMillis()
        if (ok) unregisterSco(app) // the link is up; the state receiver has done its job
        if (!ok) {
            // Leave nothing half-open: a failed SCO start can otherwise mute the phone mic.
            try {
                val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                if (Build.VERSION.SDK_INT >= 31) { am.clearCommunicationDevice(); removeCommListener(am) }
                else { @Suppress("DEPRECATION") am.stopBluetoothSco() }
            } catch (_: Exception) {}
            unregisterSco(app)
        }
        Log.i(tag, "voice link ${if (ok) "on" else "unavailable"}")
        val w = waiters; waiters = ArrayList()
        for (cb in w) main.post(cb)
    }

    @androidx.annotation.RequiresApi(31)
    private fun openModern(app: Context, am: AudioManager, dev: AudioDeviceInfo, done: (Boolean) -> Unit) {
        // Pick the matching *communication* device (same type as the input we found).
        val target = am.availableCommunicationDevices.firstOrNull { it.type == dev.type }
            ?: am.availableCommunicationDevices.firstOrNull {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
            }
        if (target == null) { done(false); return }
        var finished = false
        fun finish(ok: Boolean) { if (!finished) { finished = true; done(ok) } }
        if (target.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
            // setCommunicationDevice only *selects* the headset; the SCO link
            // itself comes up ~0.5–1 s later. Start recording before that and
            // the first second is still the phone mic — so wait for CONNECTED
            // (the broadcast still fires on 31+), with attach()'s timeout as the net.
            watchSco(app, am) { ok -> finish(ok) }
        } else {
            // LE Audio headset: no SCO; the selection callback is the signal.
            val listener = AudioManager.OnCommunicationDeviceChangedListener { d ->
                if (d != null && d.id == target.id) finish(true)
            }
            commListener = listener
            try { am.addOnCommunicationDeviceChangedListener(app.mainExecutor, listener) } catch (e: Exception) { Log.w(tag, "listener: $e") }
        }
        val ok = am.setCommunicationDevice(target)
        if (!ok) { removeCommListener(am); unregisterSco(app); finish(false); return }
        if (target.type != AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
            // Already routed (some phones switch synchronously) → no callback comes.
            val now = am.communicationDevice
            if (now != null && now.id == target.id) finish(true)
        }
    }

    /** Calls [done] once: true on SCO_AUDIO_STATE_CONNECTED (or already on), false on ERROR. */
    private fun watchSco(app: Context, am: AudioManager, done: (Boolean) -> Unit) {
        unregisterSco(app)
        var finished = false
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (finished) return
                when (intent?.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, AudioManager.SCO_AUDIO_STATE_ERROR)) {
                    AudioManager.SCO_AUDIO_STATE_CONNECTED -> { finished = true; done(true) }
                    AudioManager.SCO_AUDIO_STATE_ERROR -> { finished = true; done(false) }
                }
            }
        }
        scoReceiver = r
        ContextCompat.registerReceiver(app, r, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED), ContextCompat.RECEIVER_NOT_EXPORTED)
        @Suppress("DEPRECATION")
        if (am.isBluetoothScoOn) { finished = true; done(true) }
    }

    private fun removeCommListener(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= 31) {
            (commListener as? AudioManager.OnCommunicationDeviceChangedListener)?.let {
                try { am.removeOnCommunicationDeviceChangedListener(it) } catch (_: Exception) {}
            }
        }
        commListener = null
    }

    @Suppress("DEPRECATION")
    private fun openLegacy(app: Context, am: AudioManager, done: (Boolean) -> Unit) {
        if (!am.isBluetoothScoAvailableOffCall) { done(false); return }
        watchSco(app, am) { ok ->
            if (ok) try { am.isBluetoothScoOn = true } catch (_: Exception) {}
            done(ok)
        }
        if (!am.isBluetoothScoOn) am.startBluetoothSco()
    }

    private fun unregisterSco(app: Context) {
        scoReceiver?.let { try { app.unregisterReceiver(it) } catch (_: Exception) {} }
        scoReceiver = null
    }
}
