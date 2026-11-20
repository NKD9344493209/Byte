package com.naveen.byteapp

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Speech to text for "Speak to write" in notes: Android's own recognizer,
 * with live partial words sent to Dart while you talk. With earbuds on, the
 * headset's voice link is opened first (BtMic) so it hears the buds' mic.
 *
 * Channel "byte/voice": isRecognitionAvailable, headsetMic, listen, cancelListen;
 * Dart receives "partial" with the words so far.
 */
class VoiceBridge(private val activity: Activity) {
    private val tag = "BYTE/voice"

    private var recognizer: SpeechRecognizer? = null
    private var listenResult: MethodChannel.Result? = null
    private var voiceChannel: MethodChannel? = null

    fun register(engine: FlutterEngine) {
        val vc = MethodChannel(engine.dartExecutor.binaryMessenger, "byte/voice")
        voiceChannel = vc
        vc.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isRecognitionAvailable" -> result.success(SpeechRecognizer.isRecognitionAvailable(activity))
                    "headsetMic" -> result.success(BtMic.describe(activity)) // "no Bluetooth mic" | "Bluetooth mic <name>…"
                    "listen" -> listen(call.argument<Boolean>("offline") ?: true, call.argument<String>("locale") ?: "en-IN", (call.argument<Int>("pauseMs") ?: 3000).toLong(), (call.argument<Int>("minMs") ?: 10_000).toLong(), result)
                    "cancelListen" -> { cancelListen(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(tag, "voice ${call.method}: $e")
                // A listen that failed while starting must not leave BYTE "busy" for the next one.
                if (listenResult === result) {
                    listenResult = null
                    dropFocus()
                }
                try { result.success(hashMapOf("error" to "error")) } catch (_: Exception) {}
            }
        }
    }

    fun dispose() {
        cancelListen() // replies 'cancelled' and drops the pending attach — nothing starts on a dead bridge
        BtMic.release(activity)
        dropFocus()
        try { recognizer?.destroy() } catch (_: Exception) {}
        recognizer = null
    }

    // ---- speech in -------------------------------------------------------

    // Audio focus while BYTE listens: Spotify/YouTube pause, then resume.
    private var focusRequest: android.media.AudioFocusRequest? = null
    private fun takeFocus() {
        try {
            val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= 26) {
                if (focusRequest != null) return // already ours
                val req = android.media.AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                    .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_ASSISTANT).setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setOnAudioFocusChangeListener { }
                    .build()
                focusRequest = req
                am.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            }
        } catch (e: Exception) { Log.w(tag, "focus: $e") }
    }
    private fun dropFocus() {
        try {
            val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= 26) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
                focusRequest = null
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
            }
        } catch (e: Exception) { Log.w(tag, "focus drop: $e") }
    }

    private fun listen(offline: Boolean, locale: String, pauseMs: Long, minMs: Long, result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.success(hashMapOf("error" to "unavailable")); return
        }
        if (listenResult != null) {
            result.success(hashMapOf("error" to "busy")); return
        }
        listenResult = result
        takeFocus()
        // Earbuds / neckband on? Open their voice link first so BYTE hears the
        // buds' mic (otherwise Android records the pocket). No headset → at once.
        BtMic.attach(activity) {
            if (listenResult !== result) return@attach // cancelled while the link opened
            // From here every exit goes through finishListen(), which replies once.
            try {
                startRecognizer(offline, locale, pauseMs, minMs)
            } catch (e: Exception) {
                Log.w(tag, "listen start: $e")
                finishListen(hashMapOf("error" to "error_start"))
            }
        }
    }

    private fun startRecognizer(offline: Boolean, locale: String, pauseMs: Long, minMs: Long) {
        try { recognizer?.destroy() } catch (_: Exception) {}
        val r = SpeechRecognizer.createSpeechRecognizer(activity)
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onPartialResults(partialResults: Bundle?) {
                val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = list?.firstOrNull() ?: return
                if (text.isNotBlank()) try { voiceChannel?.invokeMethod("partial", text) } catch (_: Exception) {}
            }
            override fun onError(error: Int) {
                val why = when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "nothing"
                    SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network"
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
                    SpeechRecognizer.ERROR_AUDIO -> "audio"
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
                    else -> "error_$error"
                }
                finishListen(hashMapOf("error" to why))
            }
            override fun onResults(results: Bundle?) {
                val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: arrayListOf()
                val scores = results?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
                finishListen(hashMapOf(
                    "text" to (list.firstOrNull() ?: ""),
                    "alternatives" to ArrayList(list),
                    "confidence" to (scores?.firstOrNull()?.toDouble() ?: -1.0),
                ))
            }
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, offline)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            // Patient listening: wait this long after you stop talking (slow or
            // halting speech is fine). Google's recognizer honours these loosely.
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, pauseMs)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, pauseMs)
            // Long for sentences (10 s), short for a yes/no (the caller says).
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, minMs)
        }
        r.startListening(intent)
    }

    private fun finishListen(payload: HashMap<String, Any?>) {
        val r = listenResult ?: return
        listenResult = null
        BtMic.releaseSoon(activity) // keeps the headset link for a few seconds in case the next turn comes
        dropFocus()
        try { r.success(payload) } catch (e: Exception) { Log.w(tag, "listen reply: $e") }
    }

    private fun cancelListen() {
        try { recognizer?.cancel() } catch (_: Exception) {}
        finishListen(hashMapOf("error" to "cancelled"))
    }
}
