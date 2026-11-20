package com.naveen.byteapp

import android.Manifest
import android.app.NotificationManager
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * BYTE's single activity — the storage app.
 *
 * 1. "Share to BYTE" from any app (files, photos, links, text).
 * 2. Voice notes from the neckband: answers the assist / voice-command
 *    intents (headset long-press once BYTE is the default assistant) and
 *    forwards them to Dart as "trigger" → the quick recorder.
 *    prepareMic ends the headset's voice-recognition session so the phone
 *    mic is the stable input; while a capture runs an active MediaSession
 *    turns any headset press into "stop & save".
 * 3. File helpers Dart cannot do itself: video frames, PDF pages as
 *    pictures (for reading scanned pages), saving a backup to Downloads.
 * 4. Network state for the Drive pill, WAV → AAC for recordings, and
 *    speech-to-text for "Speak to write" (VoiceBridge).
 */
class MainActivity : FlutterFragmentActivity() {
    companion object {
        /** True while quick capture is recording (set from byte/capture captureStarted/Stopped). */
        @Volatile var capturing = false
    }

    private val tag = "BYTE"
    private var channel: MethodChannel? = null
    private var dartReady = false
    private var pendingTrigger = false

    private var session: MediaSession? = null
    private var headset: BluetoothHeadset? = null

    /** Speech to text for notes. */
    private val voice by lazy { VoiceBridge(this) }

    /** The phone's own gallery: list it, watch it, delete originals with Android's dialog. */
    private val gallery by lazy { GalleryBridge(this) }

    /** Live words while a voice note records (the speech engine reads a copy of the sound). */
    private val live by lazy { LiveWords(this) }

    /** Locks and opens the files of the private space (channel "byte/crypt"). */
    private val crypt by lazy { CryptBridge(this) }

    /** A voice note started from the floating bubble: go back to the app underneath when it is saved. */
    private var returnAfterCapture = false
    private var notifyResult: MethodChannel.Result? = null
    private val reqNotify = 7002

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/capture")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePendingTrigger" -> {
                    dartReady = true
                    val p = pendingTrigger
                    pendingTrigger = false
                    result.success(if (p) pendingSource else null)
                }
                "prepareMic" -> { prepareMic(); result.success(null) }
                "isMusicActive" -> {
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    result.success(am.isMusicActive)
                }
                "captureStarted" -> { capturing = true; startSession(); result.success(null) }
                // The recorder is about to open the microphone / has closed it (quick
                // capture and the long recorder both): keep the mic alive with the
                // screen off for exactly that long.
                "micBusy" -> { holdMic(); result.success(null) }
                "micFree" -> { releaseMic(); result.success(null) }
                "captureStopped" -> { capturing = false; overLockUntil = 0L; stopSession(); hideOverLock(); result.success(null) }
                // Started from the floating bubble and now saved: hand the screen back to the app underneath.
                "backToApp" -> {
                    val back = returnAfterCapture
                    returnAfterCapture = false
                    if (back) moveTaskToBack(true)
                    result.success(back)
                }
                // The quick recorder has closed (or never opened): back behind the lock
                // screen, whatever state a failed save may have left behind.
                "overLockDone" -> {
                    capturing = false; overLockUntil = 0L; stopSession(); hideOverLock()
                    // Left the recorder without recording (Back): the bubble's "return" no longer applies.
                    returnAfterCapture = false
                    result.success(null)
                }
                "consumeNativeBeep" -> {
                    val recent = System.currentTimeMillis() - nativeBeepAt < 15_000
                    nativeBeepAt = 0L
                    result.success(recent)
                }
                // The neckband path needs "Nearby devices" (to end the headset's own
                // voice session). Asked from Settings, never at launch; answers when
                // the user has chosen.
                "requestHeadsetPermission" -> when {
                    hasBtPermission() -> { if (headset == null) connectHeadsetProxy(); result.success(true) }
                    btPermissionResult != null -> result.success(false)
                    else -> {
                        btPermissionResult = result
                        requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), reqBluetooth)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // "byte_open" from the launcher shortcut: which place to open.
                    "consumeOpen" -> { val v = pendingOpen; pendingOpen = null; result.success(v) }
                    // The private space is on screen: no screenshots, and a blank card in the recent-apps list.
                    "secure" -> {
                        if (call.argument<Boolean>("on") == true) {
                            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        setupFilesChannel(flutterEngine)
        setupShareChannel(flutterEngine)
        voice.register(flutterEngine)
        gallery.register(flutterEngine)
        live.register(flutterEngine)
        crypt.register(flutterEngine)
        setupBubbleChannel(flutterEngine)
        setupAlertsChannel(flutterEngine)
        // Recording compression (WAV ↔ AAC) off the main thread.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/audio").setMethodCallHandler { call, result ->
            val input = call.argument<String>("input") ?: ""
            val output = call.argument<String>("output") ?: ""
            when (call.method) {
                "compress", "decompress" -> {
                    val bitrate = call.argument<Int>("bitrate") ?: 32_000
                    val isCompress = call.method == "compress"
                    Thread {
                        val size = try {
                            if (isCompress) AudioCompress.wavToAac(input, output, bitrate) else AudioCompress.aacToWav(input, output)
                        } catch (e: Exception) { -1L }
                        runOnUiThread { result.success(size) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
        cloudChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/cloud").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isUnmetered" -> result.success(isUnmetered())
                    "isOnline" -> result.success(isOnline())
                    "watchNetwork" -> { watchNetwork(); result.success(true) }
                    // Android 10+: a panel slides up over BYTE (Wi-Fi + mobile data); older → full settings.
                    "openInternetPanel" -> result.success(openPanel(if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_INTERNET_CONNECTIVITY else Settings.ACTION_WIRELESS_SETTINGS))
                    "openWifiPanel" -> result.success(openPanel(if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS))
                    else -> result.notImplemented()
                }
            }
        }
    }

    private var cloudChannel: MethodChannel? = null
    private var netCallback: android.net.ConnectivityManager.NetworkCallback? = null
    private var lastOnline: Boolean? = null

    /** Working internet right now (validated, so a captive Wi-Fi doesn't count). */
    private fun isOnline(): Boolean = try {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        caps != null && caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    } catch (e: Exception) { true }

    /** Tell Dart the moment the internet comes or goes (the Drive pill turns green/red). */
    private fun watchNetwork() {
        if (netCallback != null) return
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
            val cb = object : android.net.ConnectivityManager.NetworkCallback() {
                private fun report() {
                    val now = isOnline()
                    if (now == lastOnline) return
                    lastOnline = now
                    runOnUiThread { try { cloudChannel?.invokeMethod("net", now) } catch (_: Exception) {} }
                }
                override fun onAvailable(network: android.net.Network) = report()
                override fun onLost(network: android.net.Network) {
                    android.os.Handler(mainLooper).postDelayed({ report() }, 400)
                }
                override fun onCapabilitiesChanged(network: android.net.Network, caps: android.net.NetworkCapabilities) = report()
            }
            cm.registerDefaultNetworkCallback(cb)
            netCallback = cb
            lastOnline = isOnline()
        } catch (e: Exception) { Log.w(tag, "watchNetwork: $e") }
    }

    private fun openPanel(action: String): Boolean = try {
        startActivity(Intent(action)); true
    } catch (e: Exception) {
        try { startActivity(Intent(Settings.ACTION_SETTINGS)); true } catch (_: Exception) { false }
    }

    /** Wi-Fi (or any network the system doesn't bill): big uploads are fine. */
    private fun isUnmetered(): Boolean = try {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        caps != null && caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    } catch (e: Exception) { false }

    // ---- "Share to BYTE" from any app --------------------------------------

    private var shareChannel: MethodChannel? = null
    private var shareDartReady = false
    private val pendingShares = ArrayList<HashMap<String, String>>()

    private fun setupShareChannel(flutterEngine: FlutterEngine) {
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/share")
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePendingShares" -> {
                    shareDartReady = true
                    val out = ArrayList(pendingShares)
                    pendingShares.clear()
                    result.success(out)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun collectShare(intent: Intent) {
        try {
            val items = ArrayList<HashMap<String, String>>()
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: ""
            val uris = ArrayList<Uri>()
            if (intent.action == Intent.ACTION_SEND) {
                @Suppress("DEPRECATION")
                (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
            }
            for (u in uris) {
                val name = displayName(u)
                val dst = File(File(cacheDir, "shared").apply { mkdirs() }, "${System.currentTimeMillis()}-$name")
                contentResolver.openInputStream(u).use { input ->
                    dst.outputStream().use { input!!.copyTo(it) }
                }
                items.add(hashMapOf("type" to "file", "path" to dst.absolutePath, "name" to name))
            }
            if (uris.isEmpty() && !text.isNullOrBlank()) {
                items.add(hashMapOf("type" to "text", "text" to text, "subject" to subject))
            }
            if (items.isEmpty()) return
            Log.i(tag, "share: ${items.size} item(s), dartReady=$shareDartReady")
            if (shareDartReady) {
                shareChannel?.invokeMethod("shared", items)
            } else {
                pendingShares.addAll(items)
            }
        } catch (e: Exception) {
            Log.w(tag, "collectShare: $e")
        }
    }

    private fun displayName(uri: Uri): String {
        var name = "shared"
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) name = c.getString(0) ?: name
            }
        } catch (_: Exception) {}
        if (!name.contains('.')) {
            val ext = android.webkit.MimeTypeMap.getSingleton()
                .getExtensionFromMimeType(contentResolver.getType(uri) ?: "")
            if (!ext.isNullOrEmpty()) name = "$name.$ext"
        }
        return name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
    }

    // ---- Files: Downloads/BYTE (survives uninstall) + pick a backup -----

    private var pickResult: MethodChannel.Result? = null
    private val pickRequest = 7101

    private fun setupFilesChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        try {
                            val path = call.argument<String>("path")!!
                            val name = call.argument<String>("name")!!
                            val mime = call.argument<String>("mime") ?: "application/octet-stream"
                            result.success(saveToDownloads(File(path), name, mime))
                        } catch (e: Exception) {
                            result.error("save", e.message, null)
                        }
                    }
                    // Both read video frames, which can take a second: never on the main thread.
                    "videoThumb" -> {
                        val path = call.argument<String>("path") ?: ""
                        val out = call.argument<String>("out") ?: ""
                        val maxW = call.argument<Int>("maxWidth") ?: 480
                        Thread {
                            try {
                                val ok = videoThumb(path, out, maxW)
                                runOnUiThread { result.success(ok) }
                            } catch (e: Throwable) {
                                runOnUiThread { result.error("thumb", e.message, null) }
                            }
                        }.start()
                    }
                    "videoFrames" -> {
                        val path = call.argument<String>("path") ?: ""
                        val outDir = call.argument<String>("outDir") ?: ""
                        val prefix = call.argument<String>("prefix") ?: "frame"
                        val count = call.argument<Int>("count") ?: 4
                        val maxW = call.argument<Int>("maxWidth") ?: 640
                        Thread {
                            try {
                                val frames = videoFrames(path, outDir, prefix, count, maxW)
                                runOnUiThread { result.success(frames) }
                            } catch (e: Throwable) {
                                runOnUiThread { result.error("frames", e.message, null) }
                            }
                        }.start()
                    }
                    "pdfRender" -> {
                        // Pages of a PDF as JPEG pictures (for the first-page preview and for
                        // reading scanned pages with OCR). Off the main thread: a page takes ~100 ms.
                        val path = call.argument<String>("path") ?: ""
                        val outDir = call.argument<String>("outDir") ?: ""
                        val prefix = call.argument<String>("prefix") ?: "page"
                        val maxW = call.argument<Int>("maxWidth") ?: 1200
                        val pages = (call.argument<List<Any?>>("pages") ?: emptyList()).mapNotNull { (it as? Number)?.toInt() }
                        Thread {
                            val out = try {
                                pdfRender(path, outDir, prefix, pages, maxW)
                            } catch (e: Throwable) {
                                Log.w(tag, "pdfRender: $e")
                                ArrayList<HashMap<String, Any>>()
                            }
                            runOnUiThread { result.success(out) }
                        }.start()
                    }
                    "pickFile" -> {
                        if (pickResult != null) {
                            result.error("busy", "picker already open", null); return@setMethodCallHandler
                        }
                        pickResult = result
                        val mime = call.argument<String>("mime") ?: "*/*"
                        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(mime, "application/octet-stream"))
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(i, pickRequest)
                        } catch (e: Exception) {
                            pickResult = null
                            result.error("pick", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** One frame (~1 s in) scaled to [maxW] and saved as JPEG. */
    private fun videoThumb(path: String, out: String, maxW: Int): Boolean {
        val r = android.media.MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            val frame = r.getFrameAtTime(1_000_000, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: r.getFrameAtTime() ?: return false
            val scale = if (frame.width > maxW) maxW.toFloat() / frame.width else 1f
            val bmp = if (scale < 1f)
                android.graphics.Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt(), (frame.height * scale).toInt(), true)
            else frame
            File(out).outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 82, it) }
            return true
        } finally {
            try { r.release() } catch (_: Exception) {}
        }
    }

    /** [count] frames spread evenly through the video, as JPEG files. */
    private fun videoFrames(path: String, outDir: String, prefix: String, count: Int, maxW: Int): List<String> {
        val r = android.media.MediaMetadataRetriever()
        val out = ArrayList<String>()
        try {
            r.setDataSource(path)
            val durUs = (r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L) * 1000L
            for (i in 0 until count) {
                val t = if (durUs <= 0) 0L else durUs * (2 * i + 1) / (2 * count)
                val frame = r.getFrameAtTime(t, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: continue
                val scale = if (frame.width > maxW) maxW.toFloat() / frame.width else 1f
                val bmp = if (scale < 1f)
                    android.graphics.Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt(), (frame.height * scale).toInt(), true)
                else frame
                val f = File(outDir, "$prefix-$i.jpg")
                f.outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, it) }
                out.add(f.absolutePath)
            }
        } finally {
            try { r.release() } catch (_: Exception) {}
        }
        return out
    }

    /**
     * Draws the given pages (0-based) of the PDF at [path], [maxW] pixels wide,
     * as JPEG files "<prefix>-<page>.jpg" in [outDir]. Returns [{page, path}].
     * A locked or broken PDF throws; the caller answers with an empty list.
     */
    private fun pdfRender(path: String, outDir: String, prefix: String, pages: List<Int>, maxW: Int): ArrayList<HashMap<String, Any>> {
        val out = ArrayList<HashMap<String, Any>>()
        if (path.isEmpty() || outDir.isEmpty() || pages.isEmpty()) return out
        File(outDir).mkdirs()
        val pfd = android.os.ParcelFileDescriptor.open(File(path), android.os.ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = try {
            android.graphics.pdf.PdfRenderer(pfd)
        } catch (e: Throwable) {
            try { pfd.close() } catch (_: Exception) {}
            throw e
        }
        try {
            for (i in pages) {
                if (i < 0 || i >= renderer.pageCount) continue
                // One bad page (or one too big for memory) must not lose the pages already drawn.
                try {
                    val page = renderer.openPage(i)
                    try {
                        val pw = page.width.coerceAtLeast(1)
                        val ph = page.height.coerceAtLeast(1)
                        var w = maxW.coerceIn(64, 2400)
                        var h = (ph.toLong() * w / pw).toInt().coerceAtLeast(1)
                        // A very tall page: shrink both sides together so it is not squashed.
                        if (h > 6000) { w = (pw.toLong() * 6000 / ph).toInt().coerceAtLeast(1); h = 6000 }
                        val bmp = android.graphics.Bitmap.createBitmap(w, h, android.graphics.Bitmap.Config.ARGB_8888)
                        try {
                            bmp.eraseColor(android.graphics.Color.WHITE) // PDFs have no background of their own
                            page.render(bmp, null, null, android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            val f = File(outDir, "$prefix-$i.jpg")
                            val ok = f.outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 88, it) }
                            if (ok) out.add(hashMapOf("page" to i, "path" to f.absolutePath)) else f.delete()
                        } finally {
                            bmp.recycle()
                        }
                    } finally {
                        page.close()
                    }
                } catch (e: Throwable) {
                    Log.w(tag, "pdfRender page $i: $e")
                }
            }
        } finally {
            try { renderer.close() } catch (_: Exception) {} // closes the file descriptor too
        }
        return out
    }

    /** Copies [src] into the public Downloads/BYTE folder. Returns a label. */
    private fun saveToDownloads(src: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/BYTE")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            resolver.openOutputStream(uri).use { out ->
                FileInputStream(src).use { it.copyTo(out!!) }
            }
            values.clear(); values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Downloads/BYTE/$name"
        } else {
            @Suppress("DEPRECATION")
            val dir = File(android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOWNLOADS), "BYTE")
            dir.mkdirs()
            val dst = File(dir, name)
            src.copyTo(dst, overwrite = true)
            return dst.absolutePath
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (gallery.onActivityResult(requestCode, resultCode)) return
        if (requestCode != pickRequest) return
        val r = pickResult ?: return
        pickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) { r.success(null); return }
        try {
            val name = "picked-${System.currentTimeMillis()}.zip"
            val dst = File(cacheDir, name)
            contentResolver.openInputStream(uri).use { input ->
                dst.outputStream().use { input!!.copyTo(it) }
            }
            r.success(dst.absolutePath)
        } catch (e: Exception) {
            r.error("pick", e.message, null)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        clearOldNotificationsOnce()
        connectHeadsetProxy() // only when "Nearby devices" was already allowed; never asks here
        // Private by default. Also undoes what an earlier process may have left on this activity.
        hideOverLock()
        // After Android killed BYTE in the background, or a reopen from Recents, the
        // launch intent arrives a second time: an old headset press or an old share
        // must not happen again.
        val replay = savedInstanceState != null ||
            ((intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (!replay) handleIntent(intent)
    }

    /**
     * The assistant-era BYTE kept lines in the notification shade (stickies,
     * "left off", the calls service). Those features are gone; clear what they
     * left behind, once, on the first start of the storage app.
     */
    private fun clearOldNotificationsOnce() {
        try {
            val sp = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (sp.getBoolean("flutter.storage_rebuild_cleared", false)) return
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancelAll()
            // Their channels too, so the phone's settings no longer list "Reminders", "Hey BYTE"…
            if (Build.VERSION.SDK_INT >= 26) {
                for (ch in nm.notificationChannels) {
                    try { nm.deleteNotificationChannel(ch.id) } catch (_: Exception) {}
                }
            }
            sp.edit().putBoolean("flutter.storage_rebuild_cleared", true).apply()
        } catch (e: Exception) {
            Log.w(tag, "clear old notifications: $e")
        }
    }

    override fun onResume() {
        super.onResume()
        inBackground = false
        // The bubble is wanted but Android closed it (or the phone restarted): bring it back.
        if (BubbleService.wanted(this) && !BubbleService.running) BubbleService.start(this)
    }

    override fun onStop() {
        super.onStop()
        inBackground = true
        // Out of sight and not recording: BYTE goes back behind the lock screen.
        // (Not during the first moments of a headset press: waking a locked phone
        // passes through a stop, and the recorder has not started yet.)
        if (!capturing && android.os.SystemClock.uptimeMillis() >= overLockUntil) hideOverLock()
    }

    // ---- Document wallet reminders (channel "byte/alerts") --------------------

    private fun setupAlertsChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/alerts")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        // The whole list of reminders (JSON array text); replaces what was set before.
                        // "group": "docs" (the document wallet) or "tasks" (checklist items).
                        "setAll" -> { DocAlerts.setAll(this, call.argument<String>("json"), call.argument<String>("group") ?: "docs"); result.success(true) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.w(tag, "alerts ${call.method}: $e")
                    try { result.success(false) } catch (_: Exception) {}
                }
            }
    }

    // ---- Floating bubble + pinned checklist (channel "byte/bubble") -----------

    private fun setupBubbleChannel(flutterEngine: FlutterEngine) {
        val bubbleChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/bubble")
        // A tick made in the bubble or the notification while BYTE is running goes into the note now.
        ChecklistPins.onTick = { runOnUiThread { try { bubbleChannel.invokeMethod("ticked", null) } catch (_: Exception) {} } }
        bubbleChannel
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "state" -> result.success(hashMapOf(
                            "allowed" to BubbleService.allowed(this),
                            "on" to BubbleService.wanted(this),
                            "running" to BubbleService.running,
                        ))
                        // Turn the bubble on or off. On without the "display over other apps"
                        // permission: opens that settings page and answers false.
                        "set" -> {
                            val on = call.argument<Boolean>("on") ?: false
                            val sp = getSharedPreferences(BubbleService.PREFS, Context.MODE_PRIVATE)
                            if (!on) {
                                sp.edit().putBoolean("on", false).apply()
                                BubbleService.stop(this)
                                result.success(false)
                            } else if (!BubbleService.allowed(this)) {
                                try {
                                    startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                                } catch (e: Exception) {
                                    Log.w(tag, "overlay settings: $e")
                                }
                                result.success(false)
                            } else {
                                sp.edit().putBoolean("on", true).apply()
                                BubbleService.start(this)
                                result.success(true)
                            }
                        }
                        // The checklist to pin (JSON text), or null to unpin.
                        "pin" -> { ChecklistPins.set(this, call.argument<String>("json")); result.success(null) }
                        // Ticks made in the notification or the bubble since the last call (JSON array text).
                        "takeTicks" -> result.success(ChecklistPins.takeTicks(this))
                        // Things added to the list outside BYTE, not yet in their note (JSON array text)…
                        "pendingAdds" -> result.success(ChecklistPins.pendingAdds(this))
                        // …and "the first so-many are written now".
                        "addsWritten" -> { ChecklistPins.addsWritten(this, call.argument<Int>("count") ?: 0); result.success(null) }
                        // Android 13+: may BYTE show notifications? Asks once; answers when the user has chosen.
                        "askNotifications" -> when {
                            Build.VERSION.SDK_INT < 33 -> result.success(true)
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED -> result.success(true)
                            notifyResult != null -> result.success(false)
                            else -> {
                                notifyResult = result
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), reqNotify)
                            }
                        }
                        // Asks Android to put the "BYTE checklist" button in the control centre.
                        // Answers 2 = added, 1 = it was there already, 0 = the user said no,
                        // -1 = this phone cannot be asked (it is added by hand).
                        "addTile" -> {
                            if (Build.VERSION.SDK_INT < 33) {
                                result.success(-1)
                            } else {
                                var answered = false
                                val sbm = getSystemService(android.app.StatusBarManager::class.java)
                                sbm.requestAddTileService(
                                    android.content.ComponentName(this, ChecklistTileService::class.java),
                                    "BYTE checklist",
                                    android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_tile_checklist),
                                    mainExecutor,
                                ) { code ->
                                    if (!answered) {
                                        answered = true
                                        try { result.success(if (code in 0..2) code else -1) } catch (_: Exception) {}
                                    }
                                }
                                // The phone's question takes the screen from BYTE. Still in front a
                                // moment later: this phone did not ask, so the button is added by hand.
                                window.decorView.postDelayed({
                                    if (!answered && hasWindowFocus()) {
                                        answered = true
                                        try { result.success(-1) } catch (_: Exception) {}
                                    }
                                }, 1500)
                            }
                        }
                        // Asks the home screen to take the checklist widget (the phone shows
                        // its own "Add to home screen" box). False: this home screen cannot
                        // be asked, and the widget is added by hand.
                        "addWidget" -> {
                            var asked = false
                            if (Build.VERSION.SDK_INT >= 26) {
                                val mgr = android.appwidget.AppWidgetManager.getInstance(this)
                                if (mgr != null && mgr.isRequestPinAppWidgetSupported) {
                                    asked = mgr.requestPinAppWidget(android.content.ComponentName(this, ChecklistWidgetProvider::class.java), null, null)
                                }
                            }
                            result.success(asked)
                        }
                        // Can the phone show the checklist notification right now?
                        "canNotify" -> result.success(ChecklistPins.canShow(this))
                        // The phone's own page where notifications are allowed for BYTE.
                        "openNotifySettings" -> {
                            val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                            try {
                                if (Build.VERSION.SDK_INT >= 26) {
                                    startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                                } else {
                                    startActivity(details)
                                }
                            } catch (e: Exception) {
                                Log.w(tag, "notification settings: $e")
                                startActivity(details)
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.w(tag, "bubble ${call.method}: $e")
                    try { result.success(null) } catch (_: Exception) {}
                }
            }
    }

    private val reqBluetooth = 7001
    private var btPermissionResult: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode == reqBluetooth) {
            val r = btPermissionResult
            btPermissionResult = null
            val ok = hasBtPermission()
            if (ok && headset == null) connectHeadsetProxy()
            try { r?.success(ok) } catch (_: Exception) {}
            return
        }
        if (gallery.onPermissionResult(requestCode)) return
        if (requestCode == reqNotify) {
            val r = notifyResult
            notifyResult = null
            val ok = Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            try { r?.success(ok) } catch (_: Exception) {}
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        capturing = false // the engine (and any recording) dies with us; don't keep routing presses here
        try {
            netCallback?.let { (getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager).unregisterNetworkCallback(it) }
        } catch (_: Exception) {}
        netCallback = null
        overLockCheck.removeCallbacksAndMessages(null)
        micCheck.removeCallbacksAndMessages(null)
        micHeld = false
        BubbleService.recording = false
        BubbleService.refresh(this)
        RecordingService.stop(this)
        stopSession()
        gallery.dispose()
        live.dispose()
        crypt.dispose()
        ChecklistPins.onTick = null
        voice.dispose()
        try {
            val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            headset?.let { bm.adapter?.closeProfileProxy(BluetoothProfile.HEADSET, it) }
        } catch (_: Exception) {}
        headset = null
        super.onDestroy()
    }

    // ---- Trigger plumbing ------------------------------------------------

    /** "byte_open" extra from a launcher shortcut or our own notification: Dart asks for it on resume. */
    private var pendingOpen: String? = null

    private fun handleIntent(intent: Intent?) {
        intent?.getStringExtra("byte_open")?.let { pendingOpen = it; intent.removeExtra("byte_open") }
        val action = intent?.action ?: return
        if (action == Intent.ACTION_SEND || action == Intent.ACTION_SEND_MULTIPLE) {
            collectShare(intent)
            intent.action = Intent.ACTION_MAIN
            return
        }
        val isTrigger = action == Intent.ACTION_ASSIST ||
            action == Intent.ACTION_VOICE_COMMAND ||
            action == "android.speech.action.VOICE_SEARCH_HANDS_FREE" ||
            action == "android.intent.action.VOICE_ASSIST" ||
            action == "android.speech.action.WEB_SEARCH"
        if (!isTrigger) return
        intent.action = Intent.ACTION_MAIN // consume, so a recreate doesn't refire
        // The assistant gesture (power button / home long-press) is "the button";
        // every headset intent records.
        val fromBubble = intent.getBooleanExtra("byte_from_bubble", false)
        intent.removeExtra("byte_from_bubble")
        val source = if (fromBubble) "bubble" else if (action == Intent.ACTION_ASSIST) "button" else "headset"
        // A recording is running: any press means "stop and save". No beep, no mic prep.
        if (capturing) {
            // Stopping from the bubble over another app: go back to that app once it is saved.
            if (fromBubble && inBackground) returnAfterCapture = true
            fireTrigger(source)
            return
        }
        if (source == "button") {
            // The power-button long-press (fingerprint sensor needs a firm press and
            // opens the assistant by mistake): don't start recording unless asked to.
            when (getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getString("flutter.button_wake", "open")) {
                "record" -> {}
                "ignore" -> {
                    Log.i(tag, "assist from button ignored")
                    if (inBackground) moveTaskToBack(true) // don't hide BYTE from someone who is looking at it
                    return
                }
                else -> { Log.i(tag, "assist from button → just open"); return }
            }
        }
        if (fromBubble) {
            if (BubbleService.recording) {
                // A recorder already has the mic (the long recorder, or one that is
                // still opening): only bring BYTE to the front. No beep, no mic
                // preparation — both would disturb the recording.
                fireTrigger(source)
                return
            }
            // Tapped on the bubble over another app (the phone is unlocked):
            // record, then give the screen back to that app. Tapped while BYTE
            // itself was in front: stay in BYTE.
            if (inBackground) returnAfterCapture = true // cleared only by backToApp / overLockDone
            fastPath()
            fireTrigger(source)
            return
        }
        // Recording a voice note works from the lock screen; BYTE goes back
        // behind the lock as soon as the capture ends (hideOverLock).
        showOverLock()
        // Safety net: if no recording is running half a minute from now (mic
        // refused, nothing opened), stop sitting over the lock screen.
        overLockUntil = android.os.SystemClock.uptimeMillis() + 30_000
        overLockCheck.removeCallbacksAndMessages(null)
        overLockCheck.postDelayed({ overLockUntil = 0L; if (!capturing) hideOverLock() }, 30_000)
        // Instant feedback + mic prep BEFORE Flutter is even awake: the user
        // hears the beep within ~100 ms and stops pressing the button.
        fastPath()
        fireTrigger(source)
    }

    private val overLockCheck by lazy { android.os.Handler(mainLooper) }

    /** Uptime until which a fresh headset press may hold BYTE over the lock screen while the recorder opens. */
    private var overLockUntil = 0L

    /** True from onStop (and before the first onResume) until BYTE is in front again. */
    private var inBackground = true

    /** A voice note from the neckband with the phone locked: light the screen and sit over the lock. */
    private fun showOverLock() {
        try {
            if (Build.VERSION.SDK_INT >= 27) {
                // Screen first: a sleeping display only shows an activity that may wake it.
                setTurnScreenOn(true)
                setShowWhenLocked(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                )
            }
        } catch (e: Exception) {
            Log.w(tag, "showOverLock: $e")
        }
    }

    /** Capture over: BYTE needs the phone unlocked again, like any other app. */
    private fun hideOverLock() {
        try {
            if (Build.VERSION.SDK_INT >= 27) {
                setShowWhenLocked(false)
                setTurnScreenOn(false)
            } else {
                @Suppress("DEPRECATION")
                window.clearFlags(
                    android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                )
            }
        } catch (e: Exception) {
            Log.w(tag, "hideOverLock: $e")
        }
    }

    private var nativeBeepAt = 0L
    private var beeper: android.media.MediaPlayer? = null

    private fun fastPath() {
        try {
            prepareMic()
        } catch (e: Exception) {
            Log.w(tag, "fastPath prepareMic: $e")
        }
        try {
            beeper?.release()
            val mp = android.media.MediaPlayer.create(this, R.raw.byte_start)
            mp.setOnCompletionListener { it.release(); if (beeper === it) beeper = null }
            beeper = mp
            mp.start()
            nativeBeepAt = System.currentTimeMillis()
        } catch (e: Exception) {
            Log.w(tag, "fastPath beep: $e")
        }
    }

    private var pendingSource = "headset"

    private fun fireTrigger(source: String = "headset") {
        Log.i(tag, "fireTrigger dartReady=$dartReady source=$source")
        pendingSource = source
        if (dartReady) {
            channel?.invokeMethod("trigger", source)
        } else {
            pendingTrigger = true
        }
    }

    // ---- Bluetooth headset: end its voice session -------------------------

    private fun hasBtPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun connectHeadsetProxy() {
        if (!hasBtPermission()) return
        try {
            val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            bm.adapter?.getProfileProxy(this, object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    if (profile == BluetoothProfile.HEADSET) headset = proxy as BluetoothHeadset
                }
                override fun onServiceDisconnected(profile: Int) {
                    if (profile == BluetoothProfile.HEADSET) headset = null
                }
            }, BluetoothProfile.HEADSET)
        } catch (e: Exception) {
            Log.w(tag, "headset proxy: $e")
        }
    }

    /**
     * The headset long-press started a voice-recognition session; the phone
     * keeps a Bluetooth voice link open for it and routes the mic there. End
     * the session and the link, then reset the audio mode, so recording uses
     * the phone mic with no further route changes.
     */
    private fun prepareMic() {
        if (headset == null && hasBtPermission()) connectHeadsetProxy()
        try {
            val hs = headset
            if (hs != null && hasBtPermission()) {
                for (d in hs.connectedDevices) {
                    try {
                        val stopped = hs.stopVoiceRecognition(d)
                        Log.i(tag, "stopVoiceRecognition(${d.address.takeLast(5)}) = $stopped")
                    } catch (e: Exception) {
                        Log.w(tag, "stopVoiceRecognition: $e")
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(tag, "prepareMic headset: $e")
        }

        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            @Suppress("DEPRECATION")
            am.stopBluetoothSco()
            @Suppress("DEPRECATION")
            am.isBluetoothScoOn = false
        } catch (_: Exception) {}
        try {
            am.mode = AudioManager.MODE_NORMAL
        } catch (_: Exception) {}
        Log.i(tag, "prepareMic done; musicActive=${am.isMusicActive}")
    }

    // ---- Keeping the microphone while the screen is off --------------------

    private val micCheck by lazy { android.os.Handler(mainLooper) }
    private var micHeld = false

    /**
     * A recording is starting. Android silences the microphone of an app that
     * is not on screen unless it runs a "microphone" foreground service, so
     * start one (RecordingService). If Android refuses it, keep the screen on
     * instead — the recording then lasts as long as the screen does.
     */
    private fun holdMic() {
        micHeld = true
        BubbleService.recording = true
        BubbleService.refresh(this)
        RecordingService.start(this)
        micCheck.removeCallbacksAndMessages(null)
        micCheck.postDelayed({
            if (micHeld && !RecordingService.running) {
                Log.i(tag, "no recording service: keeping the screen on instead")
                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }, 1500)
    }

    private fun releaseMic() {
        micHeld = false
        BubbleService.recording = false
        BubbleService.refresh(this)
        micCheck.removeCallbacksAndMessages(null)
        RecordingService.stop(this)
        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    // ---- Media session while capturing ---------------------------------

    private fun startSession() {
        if (session != null) return
        val s = MediaSession(this, "BYTE capture")
        s.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                val ke: KeyEvent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                }
                Log.i(tag, "media button $ke")
                if (ke != null && ke.action == KeyEvent.ACTION_DOWN && ke.repeatCount == 0) {
                    fireTrigger()
                }
                return true
            }
        })
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
                        PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS
                )
                .setState(PlaybackState.STATE_PLAYING, 0L, 1f)
                .build()
        )
        s.isActive = true
        session = s
    }

    private fun stopSession() {
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
    }
}
