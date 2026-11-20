package com.naveen.byteapp

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Recordings are 16 kHz mono 16-bit WAV (~1.9 MB per minute). AAC at 32 kbps
 * keeps speech perfectly clear at ~0.24 MB per minute — 8× smaller.
 * [wavToAac] shrinks a finished recording; [aacToWav] brings one back to PCM
 * so "Continue recording" can append to it. Both block: call off the main thread.
 */
object AudioCompress {
    private const val TAG = "BYTE/aac"
    private const val TIMEOUT_US = 10_000L
    /** Idle dequeue rounds (×TIMEOUT_US ≈ 10 s) after input EOS before we give up: a codec that never emits EOS must not spin forever. */
    private const val MAX_IDLE_ROUNDS = 1_000

    data class Wav(val sampleRate: Int, val channels: Int, val bits: Int, val dataOffset: Long, val dataLen: Long)

    fun readWavHeader(f: File): Wav? {
        RandomAccessFile(f, "r").use { raf ->
            if (raf.length() < 44) return null
            val head = ByteArray(44)
            raf.readFully(head)
            val bb = ByteBuffer.wrap(head).order(ByteOrder.LITTLE_ENDIAN)
            if (String(head, 0, 4) != "RIFF" || String(head, 8, 4) != "WAVE") return null
            val channels = bb.getShort(22).toInt()
            val rate = bb.getInt(24)
            val bits = bb.getShort(34).toInt()
            // Find the "data" chunk (BYTE writes it at 36, but be tolerant).
            var pos = 12L
            while (pos + 8 <= raf.length()) {
                raf.seek(pos)
                val c = ByteArray(8); raf.readFully(c)
                val id = String(c, 0, 4)
                val len = ByteBuffer.wrap(c, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
                if (id == "data") {
                    val avail = raf.length() - (pos + 8)
                    return Wav(rate, channels, bits, pos + 8, if (len <= 0L || len > avail) avail else len)
                }
                pos += 8 + len + (len and 1L)
            }
            return null
        }
    }

    /** Returns the new file size, or -1. */
    fun wavToAac(input: String, output: String, bitrate: Int = 32_000): Long {
        val inFile = File(input)
        val wav = readWavHeader(inFile) ?: run { Log.w(TAG, "not a wav: $input"); return -1 }
        if (wav.bits != 16) { Log.w(TAG, "unsupported bits ${wav.bits}"); return -1 }
        val out = File(output)
        if (out.exists()) out.delete()
        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null
        try {
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, wav.sampleRate, wav.channels).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 64 * 1024)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec = enc
            enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
            val mux = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            var track = -1
            var muxing = false
            val info = MediaCodec.BufferInfo()
            val bytesPerFrame = wav.channels * 2
            RandomAccessFile(inFile, "r").use { raf ->
                raf.seek(wav.dataOffset)
                var remaining = wav.dataLen
                var presentationUs = 0L
                var inputDone = false
                var outputDone = false
                var idle = 0
                while (!outputDone) {
                    if (!inputDone) {
                        val idx = enc.dequeueInputBuffer(TIMEOUT_US)
                        if (idx >= 0) {
                            val buf = enc.getInputBuffer(idx)!!
                            buf.clear()
                            val want = minOf(buf.capacity().toLong(), remaining, 16_384L).toInt()
                            if (want <= 0) {
                                enc.queueInputBuffer(idx, 0, 0, presentationUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                val chunk = ByteArray(want)
                                raf.readFully(chunk)
                                buf.put(chunk)
                                enc.queueInputBuffer(idx, 0, want, presentationUs, 0)
                                remaining -= want
                                presentationUs += (want / bytesPerFrame) * 1_000_000L / wav.sampleRate
                            }
                        }
                    }
                    val outIdx = enc.dequeueOutputBuffer(info, TIMEOUT_US)
                    when {
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            track = mux.addTrack(enc.outputFormat)
                            mux.start()
                            muxing = true
                            idle = 0
                        }
                        outIdx >= 0 -> {
                            val ob = enc.getOutputBuffer(outIdx)!!
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                            if (info.size > 0 && muxing) {
                                ob.position(info.offset); ob.limit(info.offset + info.size)
                                mux.writeSampleData(track, ob, info)
                            }
                            enc.releaseOutputBuffer(outIdx, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                            idle = 0
                        }
                        inputDone -> {
                            // No output this round and nothing left to feed: don't spin forever.
                            if (++idle > MAX_IDLE_ROUNDS) throw IllegalStateException("encoder produced no EOS")
                        }
                    }
                }
            }
            enc.stop()
            if (muxing) mux.stop()
            val size = out.length()
            if (size < 100) { out.delete(); return -1 }
            return size
        } catch (e: Exception) {
            Log.w(TAG, "wavToAac: $e")
            try { out.delete() } catch (_: Exception) {}
            return -1
        } finally {
            try { codec?.release() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
        }
    }

    /** AAC/M4A (or any decodable audio) → 16-bit PCM WAV. Returns the size, or -1. */
    fun aacToWav(input: String, output: String): Long {
        val out = File(output)
        if (out.exists()) out.delete()
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var raf: RandomAccessFile? = null
        try {
            extractor.setDataSource(input)
            var trackIdx = -1
            var fmt: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) { trackIdx = i; fmt = f; break }
            }
            if (trackIdx < 0 || fmt == null) return -1
            extractor.selectTrack(trackIdx)
            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            val dec = MediaCodec.createDecoderByType(mime)
            codec = dec
            dec.configure(fmt, null, null, 0)
            dec.start()
            var sampleRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val wavOut = RandomAccessFile(out, "rw")
            raf = wavOut
            wavOut.write(ByteArray(44)) // header later
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var dataLen = 0L
            var idle = 0
            while (!outputDone) {
                if (!inputDone) {
                    val idx = dec.dequeueInputBuffer(TIMEOUT_US)
                    if (idx >= 0) {
                        val buf = dec.getInputBuffer(idx)!!
                        val n = extractor.readSampleData(buf, 0)
                        if (n < 0) {
                            dec.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(idx, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = dec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val of = dec.outputFormat
                        sampleRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        idle = 0
                    }
                    outIdx >= 0 -> {
                        val ob = dec.getOutputBuffer(outIdx)!!
                        if (info.size > 0) {
                            val chunk = ByteArray(info.size)
                            ob.position(info.offset); ob.get(chunk)
                            wavOut.write(chunk)
                            dataLen += info.size
                        }
                        dec.releaseOutputBuffer(outIdx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                        idle = 0
                    }
                    inputDone -> {
                        if (++idle > MAX_IDLE_ROUNDS) throw IllegalStateException("decoder produced no EOS")
                    }
                }
            }
            if (dataLen <= 0L) throw IllegalStateException("no audio decoded") // catch below deletes the stub
            // WAV header (16-bit PCM).
            val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            h.put("RIFF".toByteArray()); h.putInt((36 + dataLen).toInt()); h.put("WAVE".toByteArray())
            h.put("fmt ".toByteArray()); h.putInt(16); h.putShort(1); h.putShort(channels.toShort())
            h.putInt(sampleRate); h.putInt(sampleRate * channels * 2); h.putShort((channels * 2).toShort()); h.putShort(16)
            h.put("data".toByteArray()); h.putInt(dataLen.toInt())
            wavOut.seek(0); wavOut.write(h.array())
            return 44 + dataLen
        } catch (e: Exception) {
            Log.w(TAG, "aacToWav: $e")
            try { out.delete() } catch (_: Exception) {}
            return -1
        } finally {
            try { raf?.close() } catch (_: Exception) {}
            try { codec?.stop(); codec?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }
}
