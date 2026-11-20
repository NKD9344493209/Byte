package com.naveen.byteapp

import android.app.Activity
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Live words while a voice note is being recorded (channel "byte/live").
 *
 * BYTE's own recorder keeps the microphone and writes the audio file, as
 * always. A copy of the same sound is handed to Android's ON-DEVICE speech
 * engine through a pipe — so the engine never opens the microphone itself and
 * can never disturb the recording. If the engine is missing, has no language
 * pack, or stops reading, only the words stop: the recording carries on.
 *
 * Needs Android 13 (the "audio from a pipe" option). Dart: supported, start,
 * feed, stop, cancel, download. Dart receives: partial, segment, end, error.
 */
class LiveWords(private val activity: Activity) {
    private val tag = "BYTE/live"
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    private var recognizer: SpeechRecognizer? = null
    private var readEnd: ParcelFileDescriptor? = null
    private var writeEnd: ParcelFileDescriptor? = null
    private var session = 0
    private var dropped = 0

    fun register(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "byte/live")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "supported" -> result.success(supported())
                    "start" -> result.success(start(call.argument<String>("locale") ?: "en-IN", call.argument<List<String>>("hints") ?: emptyList()))
                    "feed" -> { feed(call.arguments as? ByteArray); result.success(null) }
                    "stop" -> { stop(); result.success(null) }
                    "cancel" -> { cleanup(session); result.success(null) }
                    "download" -> result.success(download(call.argument<String>("locale") ?: "en-IN"))
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(tag, "${call.method}: $e")
                try { result.success(null) } catch (_: Exception) {}
            }
        }
    }

    fun dispose() {
        cleanup(session)
        main.removeCallbacksAndMessages(null)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun supported(): Boolean =
        Build.VERSION.SDK_INT >= 33 && try { SpeechRecognizer.isOnDeviceRecognitionAvailable(activity) } catch (_: Exception) { false }

    private fun send(event: String, value: Any?) {
        try { channel?.invokeMethod(event, value) } catch (_: Exception) {}
    }

    private fun intentFor(locale: String, hints: List<String>, source: ParcelFileDescriptor?): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            if (Build.VERSION.SDK_INT >= 33) {
                if (source != null) {
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, source)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
                    // One long session cut into sentences; it ends when the pipe is closed.
                    putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
                }
                // The words you taught BYTE: a hint to the engine.
                if (hints.isNotEmpty()) putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(hints.take(100)))
            }
        }

    private fun words(b: Bundle?): String = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""

    private fun start(locale: String, hints: List<String>): Boolean {
        if (!supported() || Build.VERSION.SDK_INT < 33) return false
        cleanup(session)
        val my = ++session
        dropped = 0
        try {
            val pipe = ParcelFileDescriptor.createPipe()
            readEnd = pipe[0]
            writeEnd = pipe[1]
            // Never wait on the pipe: if the engine does not read, sound is dropped, not queued.
            val fd = pipe[1].fileDescriptor
            Os.fcntlInt(fd, OsConstants.F_SETFL, Os.fcntlInt(fd, OsConstants.F_GETFL, 0) or OsConstants.O_NONBLOCK)

            val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            recognizer = r
            r.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onPartialResults(partialResults: Bundle?) {
                    if (my != session) return
                    val t = words(partialResults)
                    if (t.isNotBlank()) send("partial", t)
                }
                override fun onSegmentResults(segmentResults: Bundle) {
                    if (my != session) return
                    val t = words(segmentResults)
                    if (t.isNotBlank()) send("segment", t)
                }
                override fun onEndOfSegmentedSession() {
                    if (my != session) return
                    send("end", null)
                    cleanup(my)
                }
                override fun onResults(results: Bundle?) {
                    if (my != session) return
                    val t = words(results)
                    if (t.isNotBlank()) send("segment", t)
                    send("end", null)
                    cleanup(my)
                }
                override fun onError(error: Int) {
                    if (my != session) return
                    Log.i(tag, "recognizer error $error")
                    send("error", error)
                    cleanup(my)
                }
            })
            r.startListening(intentFor(locale, hints, pipe[0]))
            return true
        } catch (e: Throwable) {
            Log.w(tag, "start: $e")
            cleanup(my)
            return false
        }
    }

    /** A piece of the recording (16 kHz, mono, 16-bit) for the engine. Never blocks. */
    private fun feed(bytes: ByteArray?) {
        val w = writeEnd ?: return
        if (bytes == null || bytes.isEmpty()) return
        var off = 0
        try {
            while (off < bytes.size) {
                // Pieces of at most 4096 bytes go in whole or not at all, so samples never split.
                val len = minOf(4096, bytes.size - off)
                Os.write(w.fileDescriptor, bytes, off, len)
                off += len
            }
            dropped = 0
        } catch (e: ErrnoException) {
            if (e.errno == OsConstants.EAGAIN) {
                // The engine is not keeping up (or not reading at all).
                if (++dropped > 60) {
                    Log.i(tag, "engine is not reading — words off for this recording")
                    send("error", -1)
                    cleanup(session)
                }
            } else {
                // The engine closed its side.
                closeWrite()
            }
        } catch (e: Exception) {
            closeWrite()
        }
    }

    private fun closeWrite() {
        try { writeEnd?.close() } catch (_: Exception) {}
        writeEnd = null
    }

    /** The recording is over: close the pipe; the last words arrive, then "end". */
    private fun stop() {
        val my = session
        if (recognizer == null) { send("end", null); return }
        closeWrite()
        // If the engine never says "end", say it ourselves.
        main.postDelayed({
            if (my == session && recognizer != null) {
                send("end", null)
                cleanup(my)
            }
        }, 4000)
    }

    private fun cleanup(which: Int) {
        if (which != session) return
        session++ // late callbacks of this session are ignored from here on
        closeWrite()
        try { readEnd?.close() } catch (_: Exception) {}
        readEnd = null
        val r = recognizer
        recognizer = null
        if (r != null) {
            try { r.cancel() } catch (_: Exception) {}
            try { r.destroy() } catch (_: Exception) {}
        }
    }

    /** Opens Android's own "download this language for offline speech" step. */
    private fun download(locale: String): Boolean {
        if (Build.VERSION.SDK_INT < 33 || !supported()) return false
        return try {
            val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            r.triggerModelDownload(intentFor(locale, emptyList(), null))
            main.postDelayed({ try { r.destroy() } catch (_: Exception) {} }, 10_000)
            true
        } catch (e: Exception) {
            Log.w(tag, "download: $e")
            false
        }
    }
}
