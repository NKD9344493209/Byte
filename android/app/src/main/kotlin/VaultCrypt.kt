package com.naveen.byteapp

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.PushbackInputStream
import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The locks of the private space. Only standard building blocks from the
 * phone's own crypto library: AES-256-GCM, HMAC-SHA256, PBKDF2.
 *
 * A locked file ("sealed") looks like this:
 *
 *     "BYTELOCK" + 1 (version)          9 bytes
 *     salt                              16 random bytes
 *     pieces                            each: up to 1 MiB of the file, locked with AES-GCM (+16 bytes check)
 *
 * Every file gets its own key (made from the private key and the salt), and
 * every piece has its own number, with a mark on the last one. So a locked
 * file that was changed, cut short or put together from other pieces is
 * refused when it is opened, and a big video never has to fit in memory.
 *
 * No Android classes in here on purpose: this file is tested on a plain JVM.
 */
object VaultCrypt {
    const val CHUNK = 1 shl 20
    private const val TAG_BYTES = 16
    private const val SALT_BYTES = 16
    private val MAGIC = byteArrayOf('B'.code.toByte(), 'Y'.code.toByte(), 'T'.code.toByte(), 'E'.code.toByte(),
        'L'.code.toByte(), 'O'.code.toByte(), 'C'.code.toByte(), 'K'.code.toByte(), 1)
    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    private fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        for (p in parts) mac.update(p)
        return mac.doFinal()
    }

    /** PBKDF2-HMAC-SHA256, 32 bytes out: a PIN (plus salt) becomes a key, slowly on purpose. */
    fun kdf(pin: String, salt: ByteArray, rounds: Int): ByteArray {
        require(rounds >= 1) { "rounds" }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(pin.toByteArray(Charsets.UTF_8).let { if (it.isEmpty()) ByteArray(1) else it }, "HmacSHA256"))
        // One block is enough: the output of SHA-256 is exactly the 32 bytes we need.
        mac.update(salt)
        mac.update(byteArrayOf(0, 0, 0, 1))
        var u = mac.doFinal()
        val out = u.copyOf()
        for (i in 1 until rounds) {
            u = mac.doFinal(u)
            for (k in out.indices) out[k] = (out[k].toInt() xor u[k].toInt()).toByte()
        }
        return out
    }

    private fun gcm(mode: Int, key: ByteArray, nonce: ByteArray): Cipher {
        require(key.size == 32) { "key must be 32 bytes" }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, nonce))
        return c
    }

    /** A small secret locked with [key]: 12 random bytes, then the locked data and its check. */
    fun seal(key: ByteArray, plain: ByteArray): ByteArray {
        val nonce = randomBytes(12)
        return nonce + gcm(Cipher.ENCRYPT_MODE, key, nonce).doFinal(plain)
    }

    /** Opens what [seal] made. null when the key is wrong or the data was changed. */
    fun open(key: ByteArray, sealed: ByteArray): ByteArray? {
        if (sealed.size < 12 + TAG_BYTES) return null
        return try {
            gcm(Cipher.DECRYPT_MODE, key, sealed.copyOfRange(0, 12)).doFinal(sealed, 12, sealed.size - 12)
        } catch (_: GeneralSecurityException) {
            null
        }
    }

    private fun fileKey(master: ByteArray, salt: ByteArray): ByteArray = hmac(master, "BYTE file".toByteArray(Charsets.UTF_8), salt)

    /** Piece number [counter], marked when it is the last one of the file. */
    private fun pieceNonce(counter: Int, last: Boolean): ByteArray {
        val n = ByteArray(12)
        n[7] = if (last) 1 else 0
        n[8] = (counter ushr 24).toByte()
        n[9] = (counter ushr 16).toByte()
        n[10] = (counter ushr 8).toByte()
        n[11] = counter.toByte()
        return n
    }

    /** Fills [buf] as far as the stream goes; returns how many bytes were read (0 at the end). */
    private fun readFully(input: InputStream, buf: ByteArray): Int {
        var got = 0
        while (got < buf.size) {
            val n = input.read(buf, got, buf.size - got)
            if (n < 0) break
            got += n
        }
        return got
    }

    private fun more(input: PushbackInputStream): Boolean {
        val b = input.read()
        if (b < 0) return false
        input.unread(b)
        return true
    }

    fun isSealed(file: File): Boolean = try {
        FileInputStream(file).use { s ->
            val head = ByteArray(MAGIC.size)
            readFully(s, head) == MAGIC.size && head.contentEquals(MAGIC)
        }
    } catch (_: IOException) {
        false
    }

    /** Locks the stream [input] into [output] with the private key [master]. Returns the plain size. */
    fun sealStream(master: ByteArray, input: InputStream, output: java.io.OutputStream): Long {
        val salt = randomBytes(SALT_BYTES)
        val key = fileKey(master, salt)
        val src = PushbackInputStream(input, 1)
        output.write(MAGIC)
        output.write(salt)
        val buf = ByteArray(CHUNK)
        var counter = 0
        var total = 0L
        while (true) {
            val n = readFully(src, buf)
            val last = !more(src)
            output.write(gcm(Cipher.ENCRYPT_MODE, key, pieceNonce(counter, last)).doFinal(buf, 0, n))
            total += n
            if (last) break
            counter++
            if (counter == Int.MAX_VALUE) throw IOException("file too large")
        }
        return total
    }

    /**
     * Opens a locked stream into [output]. Returns the plain size.
     * Throws [GeneralSecurityException] when the key is wrong or the file was
     * changed or cut short, [IOException] when it is not a locked file at all.
     */
    fun openStream(master: ByteArray, input: InputStream, output: java.io.OutputStream): Long {
        val src = PushbackInputStream(input, 1)
        val head = ByteArray(MAGIC.size)
        if (readFully(src, head) != MAGIC.size || !head.contentEquals(MAGIC)) throw IOException("not a BYTE locked file")
        val salt = ByteArray(SALT_BYTES)
        if (readFully(src, salt) != SALT_BYTES) throw IOException("locked file is cut short")
        val key = fileKey(master, salt)
        val buf = ByteArray(CHUNK + TAG_BYTES)
        var counter = 0
        var total = 0L
        while (true) {
            val n = readFully(src, buf)
            if (n < TAG_BYTES) throw GeneralSecurityException("locked file is cut short")
            val last = !more(src)
            val plain = gcm(Cipher.DECRYPT_MODE, key, pieceNonce(counter, last)).doFinal(buf, 0, n)
            output.write(plain)
            total += plain.size
            if (last) break
            counter++
            if (counter == Int.MAX_VALUE) throw IOException("file too large")
        }
        return total
    }

    /**
     * Locks [src] into [dst]. The result is written under a temporary name
     * first, pushed all the way onto the disk, and only then given its real
     * name — so a half-written locked file can never be mistaken for a whole
     * one, and the plain file is never deleted before the locked one is
     * really there. [src] is left alone (and must not change meanwhile).
     */
    fun sealFile(master: ByteArray, src: File, dst: File): Long = viaPart(dst) { part ->
        val before = src.length()
        val n = BufferedInputStream(FileInputStream(src), 1 shl 16).use { i ->
            FileOutputStream(part).use { f ->
                val o = BufferedOutputStream(f, 1 shl 16)
                val total = sealStream(master, i, o)
                o.flush()
                f.fd.sync()
                total
            }
        }
        if (n != before || src.length() != before) throw IOException("${src.name} changed while it was being locked")
        n
    }

    /** Opens the locked [src] into [dst] (same care with the temporary name and the disk). */
    fun openFile(master: ByteArray, src: File, dst: File): Long = viaPart(dst) { part ->
        BufferedInputStream(FileInputStream(src), 1 shl 16).use { i ->
            FileOutputStream(part).use { f ->
                val o = BufferedOutputStream(f, 1 shl 16)
                val total = openStream(master, i, o)
                o.flush()
                f.fd.sync()
                total
            }
        }
    }

    /** A small locked file (a preview picture) opened straight into memory. */
    fun openBytes(master: ByteArray, src: File, limit: Long = 32L * 1024 * 1024): ByteArray {
        if (src.length() > limit) throw IOException("too big to open in memory")
        val out = java.io.ByteArrayOutputStream()
        BufferedInputStream(FileInputStream(src), 1 shl 16).use { i -> openStream(master, i, out) }
        return out.toByteArray()
    }

    private fun viaPart(dst: File, work: (File) -> Long): Long {
        dst.parentFile?.mkdirs()
        val part = File(dst.path + ".part")
        try {
            val n = work(part)
            if (dst.exists() && !dst.delete()) throw IOException("cannot replace ${dst.name}")
            if (!part.renameTo(dst)) throw IOException("cannot finish ${dst.name}")
            return n
        } finally {
            if (part.exists()) part.delete()
        }
    }
}
