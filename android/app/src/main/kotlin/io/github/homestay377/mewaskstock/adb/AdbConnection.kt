package io.github.homestay377.mewaskstock.adb

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLException
import kotlin.concurrent.thread

class AdbException(val reason: Reason, message: String, cause: Throwable? = null) : IOException(message, cause) {
    enum class Reason {
        /** 目标不是本机地址：建 Socket 前就拒绝，不能当网络故障重试。 */
        NOT_LOCAL,
        CONNECT_FAILED,
        TLS_FAILED,
        /** 设备不认这把证书（没配对、被撤销、或换过密钥）。 */
        UNAUTHORIZED,
        PROTOCOL,
    }
}

/**
 * 到 adbd 的一条连接。
 *
 * 本机无线调试的握手：发 CNXN → 设备回 STLS → 回 STLS 并用已配对证书做 TLS 1.3 →
 * 设备在 TLS 上回 CNXN。之后在上面多路复用流：OPEN → OKAY，每个 WRTE 都要等对方 OKAY。
 *
 * 只连 127.0.0.1 / ::1：这个通道是用来在本机拉起 shell 身份的助手，连外网地址既不必要也不安全。
 */
class AdbConnection private constructor(
    private val socket: Socket,
    private val input: DataInputStream,
    private val output: OutputStream,
    /** 设备横幅，形如 `device::ro.product.name=…;features=…`。 */
    val banner: String,
    private val peerMaxData: Int,
    private val timeoutMs: Int,
) : Closeable {

    private val streams = ConcurrentHashMap<Int, AdbStream>()
    private val nextId = AtomicInteger(1)

    @Volatile
    private var closed = false

    init {
        thread(isDaemon = true, name = "adb-reader") { readLoop() }
    }

    val isClosed: Boolean get() = closed

    /** 运行 `exec:`（不带 pty，拿到的是原始标准输出）。 */
    fun exec(command: String): AdbStream = open("exec:$command")

    fun open(destination: String): AdbStream {
        if (closed) throw IOException("adb connection closed")
        val s = AdbStream(nextId.getAndIncrement())
        streams[s.localId] = s
        send(AdbMessage(AdbMessage.OPEN, s.localId, 0, (destination + "\u0000").toByteArray(Charsets.UTF_8)))
        val ok = try {
            s.opened.get(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            streams.remove(s.localId)
            throw IOException("open '$destination' timed out", e)
        }
        if (!ok) {
            streams.remove(s.localId)
            throw IOException("device refused '$destination'")
        }
        return s
    }

    override fun close() {
        closed = true
        runCatching { socket.close() }
        streams.values.forEach { it.remoteClosed() }
        streams.clear()
    }

    private fun send(m: AdbMessage) {
        synchronized(output) {
            output.write(m.encode())
            output.flush()
        }
    }

    private fun readLoop() {
        try {
            while (!closed) {
                val m = AdbMessage.read(input) ?: break
                val s = streams[m.arg1] ?: continue
                when (m.command) {
                    AdbMessage.OKAY -> {
                        if (s.remoteId == 0) {
                            s.remoteId = m.arg0
                            s.opened.complete(true)
                        } else {
                            s.acks.release()
                        }
                    }
                    AdbMessage.WRTE -> {
                        s.incoming.put(m.data)
                        send(AdbMessage(AdbMessage.OKAY, s.localId, s.remoteId))
                    }
                    AdbMessage.CLSE -> {
                        streams.remove(s.localId)
                        s.opened.complete(false)
                        s.remoteClosed()
                    }
                    else -> Unit
                }
            }
        } catch (_: IOException) {
            // 连接断了：下面的 finally 统一收尾
        } finally {
            close()
        }
    }

    /** 一条流。 */
    inner class AdbStream internal constructor(val localId: Int) : Closeable {
        @Volatile
        internal var remoteId = 0

        internal val opened = CompletableFuture<Boolean>()
        internal val acks = Semaphore(0)
        internal val incoming = LinkedBlockingQueue<ByteArray>()

        @Volatile
        private var remoteGone = false

        @Volatile
        private var localClosed = false

        fun read(): ByteArray? {
            val b = incoming.take()
            if (b === EOF) {
                incoming.put(EOF)
                return null
            }
            return b
        }

        fun readAll(): ByteArray {
            val out = ByteArrayOutputStream()
            while (true) out.write(read() ?: return out.toByteArray())
        }

        fun readText(): String = readAll().toString(Charsets.UTF_8)

        fun write(data: ByteArray) {
            var pos = 0
            while (pos < data.size) {
                if (remoteGone || localClosed) throw IOException("stream closed")
                val n = minOf(peerMaxData, data.size - pos)
                send(AdbMessage(AdbMessage.WRTE, localId, remoteId, data.copyOfRange(pos, pos + n)))
                if (!acks.tryAcquire(timeoutMs.toLong(), TimeUnit.MILLISECONDS)) {
                    throw IOException("write not acknowledged")
                }
                if (remoteGone) throw IOException("stream closed")
                pos += n
            }
        }

        val inputStream: InputStream
            get() = object : InputStream() {
                private var buf = ByteArray(0)
                private var off = 0

                override fun read(): Int {
                    val one = ByteArray(1)
                    return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
                }

                override fun read(b: ByteArray, o: Int, len: Int): Int {
                    if (len == 0) return 0
                    while (off >= buf.size) {
                        buf = this@AdbStream.read() ?: return -1
                        off = 0
                    }
                    val n = minOf(len, buf.size - off)
                    System.arraycopy(buf, off, b, o, n)
                    off += n
                    return n
                }
            }

        internal fun remoteClosed() {
            remoteGone = true
            opened.complete(false)
            acks.release()
            incoming.put(EOF)
        }

        override fun close() {
            if (localClosed) return
            localClosed = true
            if (!remoteGone && !closed) runCatching { send(AdbMessage(AdbMessage.CLSE, localId, remoteId)) }
            streams.remove(localId)
            remoteClosed()
        }
    }

    companion object {
        private val EOF = ByteArray(0)
        private val HOST_BANNER = "host::\u0000".toByteArray(Charsets.US_ASCII)

        /** 只接受本机回环地址。 */
        fun localAddress(host: String, port: Int): InetSocketAddress? {
            val normalized = host.trim()
            return when (normalized) {
                "127.0.0.1", "localhost" -> InetSocketAddress("127.0.0.1", port)
                "::1" -> InetSocketAddress("::1", port)
                else -> null
            }
        }

        fun open(host: String, port: Int, tls: AdbTls, timeoutMs: Int = 10_000): AdbConnection {
            val target = localAddress(host, port)
                ?: throw AdbException(AdbException.Reason.NOT_LOCAL, "refusing to connect to $host: adb is local-only")
            val plain = Socket()
            try {
                plain.tcpNoDelay = true
                plain.connect(target, timeoutMs)
                plain.soTimeout = timeoutMs
            } catch (e: IOException) {
                plain.close()
                throw AdbException(AdbException.Reason.CONNECT_FAILED, "cannot connect to $host:$port", e)
            }
            try {
                return handshake(plain, target, tls, timeoutMs)
            } catch (e: Throwable) {
                runCatching { plain.close() }
                throw e
            }
        }

        private fun handshake(plain: Socket, target: InetSocketAddress, tls: AdbTls, timeoutMs: Int): AdbConnection {
            val out = plain.getOutputStream()
            out.write(AdbMessage(AdbMessage.CNXN, AdbMessage.VERSION, AdbMessage.MAX_PAYLOAD, HOST_BANNER).encode())
            out.flush()
            val first = AdbMessage.read(DataInputStream(plain.getInputStream()))
                ?: throw AdbException(AdbException.Reason.PROTOCOL, "device closed the connection")

            return when (first.command) {
                AdbMessage.CNXN -> finish(plain, DataInputStream(plain.getInputStream()), out, first, timeoutMs)
                AdbMessage.STLS -> {
                    out.write(AdbMessage(AdbMessage.STLS, AdbMessage.STLS_VERSION, 0).encode())
                    out.flush()
                    val ssl = try {
                        tls.wrap(plain, target, client = true)
                    } catch (e: IOException) {
                        throw AdbException(AdbException.Reason.TLS_FAILED, "TLS handshake failed", e)
                    }
                    val input = DataInputStream(ssl.inputStream)
                    // TLS 1.3 里设备拒绝客户端证书发生在握手之后，表现为读第一个包时出错或断开
                    val cnxn = try {
                        AdbMessage.read(input)
                    } catch (e: SSLException) {
                        throw AdbException(
                            AdbException.Reason.UNAUTHORIZED,
                            "device rejected our certificate (not paired?)",
                            e,
                        )
                    } catch (e: IOException) {
                        if (e is java.net.SocketTimeoutException) {
                            throw AdbException(AdbException.Reason.PROTOCOL, "no CNXN from device", e)
                        }
                        null
                    } ?: throw AdbException(AdbException.Reason.UNAUTHORIZED, "device closed after TLS (not paired?)")
                    if (cnxn.command != AdbMessage.CNXN) {
                        throw AdbException(AdbException.Reason.PROTOCOL, "expected CNXN, got $cnxn")
                    }
                    finish(ssl, input, ssl.outputStream, cnxn, timeoutMs)
                }
                AdbMessage.AUTH -> throw AdbException(
                    AdbException.Reason.UNAUTHORIZED,
                    "device asks for legacy RSA auth (not a wireless-debugging port?)",
                )
                else -> throw AdbException(AdbException.Reason.PROTOCOL, "unexpected $first")
            }
        }

        private fun finish(
            socket: Socket,
            input: DataInputStream,
            out: OutputStream,
            cnxn: AdbMessage,
            timeoutMs: Int,
        ): AdbConnection {
            socket.soTimeout = 0
            val banner = cnxn.data.toString(Charsets.UTF_8).trimEnd('\u0000')
            val maxData = if (cnxn.arg1 in 1..AdbMessage.MAX_PAYLOAD) cnxn.arg1 else 4096
            return AdbConnection(socket, input, out, banner, maxData, timeoutMs)
        }
    }
}
