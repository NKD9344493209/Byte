package com.naveen.byteapp

import android.content.ContentUris
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The phone's own gallery, for BYTE (channel "byte/gallery").
 *
 * BYTE does not copy the gallery. It only LISTS it: each photo and video
 * stays where the camera put it, and BYTE keeps its path. This class
 *  - asks for the "Photos and videos" permission,
 *  - reads the list in pages (by MediaStore id, so "what is new since last
 *    time" is one cheap question),
 *  - tells Dart when the gallery changes,
 *  - and deletes originals — only through Android's own confirmation dialog
 *    (one dialog for a whole batch).
 */
class GalleryBridge(private val activity: MainActivity) {
    companion object {
        const val REQ_PERMISSION = 7201
        const val REQ_DELETE = 7203
    }

    private val tag = "BYTE/gallery"
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var permissionResult: MethodChannel.Result? = null
    private var permissionForAudio = false
    private var deleteResult: MethodChannel.Result? = null
    private var observer: ContentObserver? = null

    fun register(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "byte/gallery")
        channel?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // "all" | "partial" (only the photos the user picked, Android 14) | "none"
                    "permission" -> result.success(permission())
                    "audioPermission" -> result.success(hasAudio())
                    "request" -> request(result, audio = false)
                    "requestAudio" -> request(result, audio = true)
                    "scan" -> {
                        val kind = call.argument<String>("kind") ?: "image"
                        val afterId = (call.argument<Number>("afterId") ?: 0).toLong()
                        val limit = (call.argument<Number>("limit") ?: 500).toInt().coerceIn(1, 2000)
                        val calls = call.argument<Boolean>("calls") ?: false
                        // Off the main thread: a first look at a big gallery reads thousands of rows.
                        Thread {
                            val out = try {
                                scan(kind, afterId, limit, calls)
                            } catch (e: Throwable) {
                                Log.w(tag, "scan $kind: $e")
                                null
                            }
                            main.post { result.success(out) }
                        }.start()
                    }
                    "delete" -> delete(
                        call.argument<List<String>>("keys") ?: emptyList(),
                        call.argument<List<String>>("paths") ?: emptyList(),
                        result,
                    )
                    // key -> the path that id has NOW, for the ids that still exist; null = could not ask.
                    "paths" -> {
                        val keys = call.argument<List<String>>("keys") ?: emptyList()
                        Thread {
                            val out = try { currentPaths(keys) } catch (e: Throwable) { Log.w(tag, "paths: $e"); null }
                            main.post { result.success(out) }
                        }.start()
                    }
                    // path -> the key the gallery lists that file under NOW; null = could not ask.
                    "lookup" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        Thread {
                            val out = try { keysForPaths(paths) } catch (e: Throwable) { Log.w(tag, "lookup: $e"); null }
                            main.post { result.success(out) }
                        }.start()
                    }
                    // Android's own small picture of a photo or video, as a JPEG file.
                    "thumb" -> {
                        val key = call.argument<String>("key") ?: ""
                        val out = call.argument<String>("out") ?: ""
                        val size = (call.argument<Number>("size") ?: 480).toInt().coerceIn(96, 1024)
                        Thread {
                            val ok = try { thumb(key, out, size) } catch (e: Throwable) { Log.w(tag, "thumb: $e"); false }
                            main.post { result.success(ok) }
                        }.start()
                    }
                    "watch" -> { watch(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(tag, "${call.method}: $e")
                try { result.success(null) } catch (_: Exception) {}
            }
        }
    }

    fun dispose() {
        observer?.let { try { activity.contentResolver.unregisterContentObserver(it) } catch (_: Exception) {} }
        observer = null
        main.removeCallbacksAndMessages(null)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ---- Permission ------------------------------------------------------

    private fun granted(name: String) = activity.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED

    private fun permission(): String = when {
        Build.VERSION.SDK_INT >= 33 -> when {
            granted("android.permission.READ_MEDIA_IMAGES") || granted("android.permission.READ_MEDIA_VIDEO") -> "all"
            Build.VERSION.SDK_INT >= 34 && granted("android.permission.READ_MEDIA_VISUAL_USER_SELECTED") -> "partial"
            else -> "none"
        }
        else -> if (granted("android.permission.READ_EXTERNAL_STORAGE")) "all" else "none"
    }

    private fun hasAudio(): Boolean =
        if (Build.VERSION.SDK_INT >= 33) granted("android.permission.READ_MEDIA_AUDIO") else granted("android.permission.READ_EXTERNAL_STORAGE")

    private fun request(result: MethodChannel.Result, audio: Boolean) {
        if (permissionResult != null) { result.success(if (audio) hasAudio() else permission()); return }
        if (audio && hasAudio()) { result.success(true); return }
        if (!audio && permission() == "all") { result.success("all"); return }
        val names = when {
            Build.VERSION.SDK_INT >= 34 && !audio -> arrayOf(
                "android.permission.READ_MEDIA_IMAGES",
                "android.permission.READ_MEDIA_VIDEO",
                "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
            )
            Build.VERSION.SDK_INT >= 33 && !audio -> arrayOf("android.permission.READ_MEDIA_IMAGES", "android.permission.READ_MEDIA_VIDEO")
            Build.VERSION.SDK_INT >= 33 -> arrayOf("android.permission.READ_MEDIA_AUDIO")
            else -> arrayOf("android.permission.READ_EXTERNAL_STORAGE")
        }
        permissionResult = result
        permissionForAudio = audio
        activity.requestPermissions(names, REQ_PERMISSION)
    }

    /** From MainActivity.onRequestPermissionsResult. True when the request was ours. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQ_PERMISSION) return false
        val r = permissionResult
        permissionResult = null
        try {
            if (permissionForAudio) r?.success(hasAudio()) else r?.success(permission())
        } catch (_: Exception) {}
        return true
    }

    // ---- Reading the list -------------------------------------------------

    private fun baseUri(kind: String): Uri = when (kind) {
        "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        else -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    }

    /**
     * Up to [limit] rows of [kind] whose id is above [afterId], lowest id first.
     * [calls]: only audio files that sit in a call-recording folder.
     */
    private fun scan(kind: String, afterId: Long, limit: Int, calls: Boolean): ArrayList<HashMap<String, Any>> {
        val out = ArrayList<HashMap<String, Any>>()
        val cols = ArrayList<String>()
        cols.addAll(listOf("_id", "_data", "_display_name", "mime_type", "_size", "date_added", "date_modified"))
        // These three exist for every media kind only from Android 10.
        val extras = Build.VERSION.SDK_INT >= 29 || kind != "audio"
        if (extras) { cols.add("datetaken"); cols.add("bucket_display_name") }
        if (kind != "image") cols.add("duration")

        val where = StringBuilder("_id > ? AND _size > 0")
        if (Build.VERSION.SDK_INT >= 29) where.append(" AND is_pending = 0")
        if (calls) {
            where.append(
                " AND (_data LIKE '%call_rec%' OR _data LIKE '%/Call/%' OR _data LIKE '%CallRecord%'" +
                    " OR _data LIKE '%Call recordings%' OR _data LIKE '%/Recordings/Call%' OR _data LIKE '%PhoneRecord%')",
            )
        }
        val args = arrayOf(afterId.toString())
        val resolver = activity.contentResolver
        val cursor = if (Build.VERSION.SDK_INT >= 26) {
            val b = Bundle()
            b.putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, where.toString())
            b.putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
            b.putString(android.content.ContentResolver.QUERY_ARG_SQL_SORT_ORDER, "_id ASC")
            b.putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, limit)
            resolver.query(baseUri(kind), cols.toTypedArray(), b, null)
        } else {
            resolver.query(baseUri(kind), cols.toTypedArray(), where.toString(), args, "_id ASC LIMIT $limit")
        }
        cursor?.use { c ->
            val iId = c.getColumnIndex("_id")
            val iData = c.getColumnIndex("_data")
            val iName = c.getColumnIndex("_display_name")
            val iMime = c.getColumnIndex("mime_type")
            val iSize = c.getColumnIndex("_size")
            val iAdded = c.getColumnIndex("date_added")
            val iModified = c.getColumnIndex("date_modified")
            val iTaken = c.getColumnIndex("datetaken")
            val iBucket = c.getColumnIndex("bucket_display_name")
            val iDuration = c.getColumnIndex("duration")
            if (iId < 0 || iData < 0) return out
            // The limit is also enforced here: older Androids ignore it in the query.
            while (out.size < limit && c.moveToNext()) {
                val path = c.getString(iData) ?: ""
                val row = HashMap<String, Any>()
                row["id"] = c.getLong(iId)
                row["path"] = path
                row["name"] = (if (iName >= 0) c.getString(iName) else null) ?: path.substringAfterLast('/')
                row["mime"] = (if (iMime >= 0) c.getString(iMime) else null) ?: ""
                row["size"] = if (iSize >= 0) c.getLong(iSize) else 0L
                row["added"] = if (iAdded >= 0) c.getLong(iAdded) else 0L // seconds
                row["modified"] = if (iModified >= 0) c.getLong(iModified) else 0L // seconds
                row["taken"] = if (iTaken >= 0 && !c.isNull(iTaken)) c.getLong(iTaken) else 0L // milliseconds
                row["bucket"] = (if (iBucket >= 0) c.getString(iBucket) else null) ?: ""
                row["duration"] = if (iDuration >= 0 && !c.isNull(iDuration)) c.getLong(iDuration) else 0L
                out.add(row)
            }
        }
        return out
    }

    // ---- Changes ----------------------------------------------------------

    private val tellDart = Runnable {
        try { channel?.invokeMethod("changed", null) } catch (_: Exception) {}
    }

    /** From now on, say "changed" a few seconds after the gallery changes (one call for a burst). */
    private fun watch() {
        if (observer != null) return
        val o = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                main.removeCallbacks(tellDart)
                main.postDelayed(tellDart, 4000)
            }
        }
        try {
            activity.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, o)
            activity.contentResolver.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, o)
            // Call recordings are audio files: a new one is noticed too.
            activity.contentResolver.registerContentObserver(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, true, o)
            observer = o
        } catch (e: Exception) {
            Log.w(tag, "watch: $e")
        }
    }

    // ---- Deleting originals ------------------------------------------------

    private fun uriFor(key: String): Uri? {
        val parts = key.split(":")
        if (parts.size != 2) return null
        val id = parts[1].toLongOrNull() ?: return null
        return ContentUris.withAppendedId(baseUri(parts[0]), id)
    }

    /** For each key whose id still exists: the path the gallery has for it now. */
    private fun currentPaths(keys: List<String>): HashMap<String, String> {
        val out = HashMap<String, String>()
        val byKind = HashMap<String, ArrayList<String>>()
        for (k in keys) {
            val parts = k.split(":")
            if (parts.size != 2 || parts[1].toLongOrNull() == null) continue
            byKind.getOrPut(parts[0]) { ArrayList() }.add(parts[1])
        }
        for ((kind, ids) in byKind) {
            for (chunk in ids.chunked(300)) {
                val marks = chunk.joinToString(",") { "?" }
                val c = activity.contentResolver.query(baseUri(kind), arrayOf("_id", "_data"), "_id IN ($marks)", chunk.toTypedArray(), null)
                    ?: throw IllegalStateException("no answer from the gallery")
                c.use {
                    while (it.moveToNext()) out["$kind:${it.getLong(0)}"] = it.getString(1) ?: ""
                }
            }
        }
        return out
    }

    /** For each path the gallery lists: its key now ("image:123"). */
    private fun keysForPaths(paths: List<String>): HashMap<String, String> {
        val out = HashMap<String, String>()
        for (kind in listOf("image", "video", "audio")) {
            for (chunk in paths.chunked(200)) {
                val marks = chunk.joinToString(",") { "?" }
                val c = activity.contentResolver.query(baseUri(kind), arrayOf("_id", "_data"), "_data IN ($marks)", chunk.toTypedArray(), null)
                    ?: throw IllegalStateException("no answer from the gallery")
                c.use {
                    while (it.moveToNext()) {
                        val path = it.getString(1) ?: continue
                        if (!out.containsKey(path)) out[path] = "$kind:${it.getLong(0)}"
                    }
                }
            }
        }
        return out
    }

    /** Android's ready-made small picture for [key], written to [out] as JPEG. */
    private fun thumb(key: String, out: String, size: Int): Boolean {
        if (Build.VERSION.SDK_INT < 29 || out.isEmpty()) return false
        val uri = uriFor(key) ?: return false
        val bmp = activity.contentResolver.loadThumbnail(uri, android.util.Size(size, size), null)
        try {
            val f = java.io.File(out)
            f.parentFile?.mkdirs()
            val ok = f.outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 82, it) }
            if (!ok) f.delete()
            return ok
        } finally {
            bmp.recycle()
        }
    }

    /**
     * Deletes originals from the phone. [keys] are gallery ids ("image:123"),
     * [paths] the file BYTE believes each one is. An id is only put in front of
     * the user when the gallery still lists THAT file under it — ids differ
     * from phone to phone, and after a restore "image:123" can be someone
     * else's photo. Android then shows ONE dialog for the whole list; answers
     * true only when the user agreed and Android deleted them.
     */
    private fun delete(keys: List<String>, paths: List<String>, result: MethodChannel.Result) {
        if (deleteResult != null) { result.success(false); return }
        // Android 10 and older have no batch dialog, and BYTE holds no right to
        // delete other apps' files there: nothing is deleted.
        if (Build.VERSION.SDK_INT < 30) { result.success(false); return }
        Thread {
            val uris = ArrayList<Uri>()
            for ((i, key) in keys.withIndex()) {
                val uri = uriFor(key) ?: continue
                val want = paths.getOrNull(i) ?: continue
                try {
                    activity.contentResolver.query(uri, arrayOf("_data"), null, null, null)?.use { c ->
                        if (c.moveToFirst() && c.getString(0) == want) uris.add(uri)
                    }
                } catch (_: Exception) {}
            }
            main.post { ask(uris, result) }
        }.start()
    }

    private fun ask(uris: List<Uri>, result: MethodChannel.Result) {
        if (uris.isEmpty()) { result.success(true); return }
        if (deleteResult != null || Build.VERSION.SDK_INT < 30) { result.success(false); return }
        try {
            val pending = MediaStore.createDeleteRequest(activity.contentResolver, uris)
            deleteResult = result
            activity.startIntentSenderForResult(pending.intentSender, REQ_DELETE, null, 0, 0, 0)
        } catch (e: Exception) {
            Log.w(tag, "delete request: $e")
            deleteResult = null
            result.success(false)
        }
    }

    /** From MainActivity.onActivityResult. True when the result was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQ_DELETE) return false
        val r = deleteResult
        deleteResult = null
        try { r?.success(resultCode == android.app.Activity.RESULT_OK) } catch (_: Exception) {}
        return true
    }
}
