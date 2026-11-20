package com.naveen.byteapp

import android.app.Activity
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Channel "byte/crypt": the private space asks Android to lock and open
 * files ([VaultCrypt] does the work). Everything runs off the main thread;
 * every call is answered exactly once, on the main thread.
 */
class CryptBridge(private val activity: Activity) {
    private val tag = "BYTE/crypt"
    private var channel: MethodChannel? = null

    // Two workers: a big video being locked does not hold up a small preview.
    private val pool: ExecutorService = Executors.newFixedThreadPool(2)

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "byte/crypt").also { ch ->
            ch.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
        pool.shutdown()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        // Read the arguments here (main thread), work on the pool.
        val key = call.argument<ByteArray>("key")
        val data = call.argument<ByteArray>("data")
        val src = call.argument<String>("src")
        val dst = call.argument<String>("dst")
        val work: (() -> Any?)? = when (call.method) {
            "random" -> { -> VaultCrypt.randomBytes((call.argument<Int>("n") ?: 32).coerceIn(1, 1024)) }
            "kdf" -> {
                val pin = call.argument<String>("pin") ?: ""
                val salt = call.argument<ByteArray>("salt") ?: ByteArray(0)
                val rounds = call.argument<Int>("rounds") ?: 1
                { -> VaultCrypt.kdf(pin, salt, rounds) }
            }
            "seal" -> { -> VaultCrypt.seal(need(key, "key"), need(data, "data")) }
            // null = wrong key (a wrong PIN), not an error.
            "open" -> { -> VaultCrypt.open(need(key, "key"), need(data, "data")) }
            "sealFile" -> { -> VaultCrypt.sealFile(need(key, "key"), File(need(src, "src")), File(need(dst, "dst"))) }
            "openFile" -> { -> VaultCrypt.openFile(need(key, "key"), File(need(src, "src")), File(need(dst, "dst"))) }
            "openBytes" -> { -> VaultCrypt.openBytes(need(key, "key"), File(need(src, "src"))) }
            "isSealed" -> { -> VaultCrypt.isSealed(File(need(src, "src"))) }
            else -> null
        }
        if (work == null) {
            result.notImplemented()
            return
        }
        val method = call.method
        try {
            pool.execute {
                var value: Any? = null
                var error: Throwable? = null
                try {
                    value = work()
                } catch (t: Throwable) {
                    error = t
                }
                activity.runOnUiThread {
                    try {
                        val e = error
                        if (e == null) {
                            result.success(value)
                        } else {
                            Log.w(tag, "$method: $e")
                            // "locked": the key does not fit or the file was changed; "io": anything else.
                            result.error(if (e is java.security.GeneralSecurityException) "locked" else "io", e.message ?: e.toString(), null)
                        }
                    } catch (t: Throwable) {
                        Log.w(tag, "$method reply: $t")
                    }
                }
            }
        } catch (t: Throwable) {
            // The pool was shut down (the activity is going away).
            result.error("io", t.message ?: t.toString(), null)
        }
    }

    private fun <T> need(v: T?, name: String): T = v ?: throw IllegalArgumentException("missing $name")
}
