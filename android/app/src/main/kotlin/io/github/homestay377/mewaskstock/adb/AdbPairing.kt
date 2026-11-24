package io.github.homestay377.mewaskstock.adb

import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket

/** adbd 通过 mDNS 公布的服务类型。 */
object AdbServices {
    /** 「使用配对码配对」对话框开着时才公布。 */
    const val PAIRING = "_adb-tls-pairing._tcp"

    /** 无线调试开着时公布；端口每次开关无线调试都会变。 */
    const val CONNECT = "_adb-tls-connect._tcp"
}

class AdbPairingException(val reason: Reason, message: String, cause: Throwable? = null) : IOException(message, cause) {
    enum class Reason { CONNECT_FAILED, TLS_FAILED, WRONG_CODE, PROTOCOL }
}

/** HKDF-SHA256（RFC 5869）。salt 为空时按 RFC 用 32 个零字节。 */
object Hkdf {
    fun sha256(ikm: ByteArray, salt: ByteArray?, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt == null || salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var prev = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.update(prev)
            mac.update(info)
            mac.update(counter.toByte())
            prev = mac.doFinal()
            val n = minOf(prev.size, length - pos)
            System.arraycopy(prev, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }
}

/**
 * 配对通道上的 AES-128-GCM。
 *
 * 密钥 = HKDF(SPAKE2 密钥, 无 salt, "adb pairing_auth aes-128-gcm key", 16)；
 * 12 字节 nonce 前 8 字节是各自方向的序号（小端，从 0 起每条加一），其余为零；无附加数据，16 字节标签附在密文后。
 */
class PairingCipher(keyMaterial: ByteArray) {
    private val key = SecretKeySpec(Hkdf.sha256(keyMaterial, null, INFO, 16), "AES")
    private var encSeq = 0L
    private var decSeq = 0L

    fun encrypt(plain: ByteArray): ByteArray = run(Cipher.ENCRYPT_MODE, encSeq++, plain)

    /** 认证失败抛 [javax.crypto.AEADBadTagException]。 */
    fun decrypt(sealed: ByteArray): ByteArray = run(Cipher.DECRYPT_MODE, decSeq, sealed).also { decSeq++ }

    private fun run(mode: Int, seq: Long, data: ByteArray): ByteArray {
        val nonce = ByteArray(12)
        for (i in 0 until 8) nonce[i] = (seq ushr (8 * i)).toByte()
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(mode, key, GCMParameterSpec(128, nonce))
        return c.doFinal(data)
    }

    companion object {
        private val INFO = "adb pairing_auth aes-128-gcm key".toByteArray(Charsets.US_ASCII)
    }
}

/**
 * 无线调试的配对码配对（客户端）。
 *
 * 流程：TLS 1.3 → 导出 64 字节密钥("adb-label\0") → 口令 = 配对码 + 导出密钥 →
 * 交换 SPAKE2 消息 → 用协商出的 AES-GCM 互换 8192 字节 PeerInfo（我们发 adb 公钥，设备回 GUID）。
 * 每个包前 6 字节头：版本(1)、类型(0=SPAKE2,1=PEER_INFO)、负载长度(大端 uint32)。
 */
class AdbPairing(private val tls: AdbTls) {

    data class Peer(val type: Int, val data: String)

    fun pair(host: String, port: Int, code: String, timeoutMs: Int = 15_000): Peer {
        val target = AdbConnection.localAddress(host, port)
            ?: throw AdbPairingException(AdbPairingException.Reason.CONNECT_FAILED, "配对只支持本机地址")
        val socket = try {
            val plain = java.net.Socket()
            plain.tcpNoDelay = true
            plain.connect(target, timeoutMs)
            plain.soTimeout = timeoutMs
            tls.wrap(plain, target, client = true)
        } catch (e: SSLException) {
            throw AdbPairingException(AdbPairingException.Reason.TLS_FAILED, "TLS 握手失败", e)
        } catch (e: IOException) {
            throw AdbPairingException(AdbPairingException.Reason.CONNECT_FAILED, "连不上 $host:$port", e)
        }
        socket.use { return exchange(it, code) }
    }

    private fun exchange(socket: SSLSocket, code: String): Peer {
        val exported = tls.exportKeyingMaterial(socket, EXPORT_LABEL, EXPORT_LENGTH)
        val auth = PairingAuth.client(code.toByteArray(Charsets.UTF_8) + exported)
        val input = DataInputStream(socket.inputStream)
        val output = socket.outputStream

        writePacket(output, TYPE_SPAKE2, auth.message)
        val theirMsg = readPacket(input, TYPE_SPAKE2)
            ?: throw protocol("连接在密钥交换时被关闭")
        try {
            auth.initCipher(theirMsg)
        } catch (e: IllegalArgumentException) {
            throw protocol("密钥交换消息不合法：${e.message}")
        }

        val info = ByteArray(PEER_INFO_SIZE)
        info[0] = PEER_RSA_PUB_KEY
        val key = tls.identity.adbPublicKey.toByteArray(Charsets.UTF_8)
        check(key.size < PEER_INFO_SIZE - 1) { "adb 公钥太长" }
        System.arraycopy(key, 0, info, 1, key.size)
        writePacket(output, TYPE_PEER_INFO, auth.encrypt(info))

        val theirEncrypted = readPacket(input, TYPE_PEER_INFO)
            ?: throw protocol("连接在交换身份时被关闭")
        val theirInfo = try {
            auth.decrypt(theirEncrypted)
        } catch (e: javax.crypto.AEADBadTagException) {
            throw AdbPairingException(AdbPairingException.Reason.WRONG_CODE, "配对码不对", e)
        }
        val type = theirInfo[0].toInt()
        val data = theirInfo.copyOfRange(1, theirInfo.size).toString(Charsets.UTF_8).trimEnd('\u0000')
        return Peer(type, data)
    }

    private fun writePacket(out: OutputStream, type: Int, payload: ByteArray) {
        val header = ByteBuffer.allocate(HEADER).put(PACKET_VERSION).put(type.toByte()).putInt(payload.size).array()
        out.write(header)
        out.write(payload)
        out.flush()
    }

    private fun readPacket(input: DataInputStream, expectedType: Int): ByteArray? {
        val header = ByteArray(HEADER)
        try {
            input.readFully(header)
        } catch (_: EOFException) {
            return null
        }
        val bb = ByteBuffer.wrap(header)
        bb.get() // version
        val type = bb.get().toInt()
        if (type != expectedType) throw protocol("期望包类型 $expectedType，收到 $type")
        val len = bb.getInt()
        if (len < 0 || len > PEER_INFO_SIZE + 64) throw protocol("包长度异常：$len")
        return ByteArray(len).also { input.readFully(it) }
    }

    private fun protocol(message: String) = AdbPairingException(AdbPairingException.Reason.PROTOCOL, message)

    private companion object {
        const val HEADER = 6
        const val PACKET_VERSION: Byte = 1
        const val TYPE_SPAKE2 = 0
        const val TYPE_PEER_INFO = 1
        const val PEER_RSA_PUB_KEY: Byte = 0
        const val PEER_INFO_SIZE = 8192
        const val EXPORT_LENGTH = 64
        const val EXPORT_LABEL = "adb-label\u0000"
    }
}

/** 配对认证：SPAKE2 交换后得到密钥，再建 [PairingCipher]。 */
class PairingAuth private constructor(role: Spake2.Role, password: ByteArray) {
    private val spake = if (role == Spake2.Role.ALICE) {
        Spake2(role, CLIENT_NAME, SERVER_NAME)
    } else {
        Spake2(role, SERVER_NAME, CLIENT_NAME)
    }
    val message: ByteArray = spake.generateMessage(password)
    private var cipher: PairingCipher? = null

    fun initCipher(theirMessage: ByteArray) {
        check(cipher == null)
        cipher = PairingCipher(spake.processMessage(theirMessage))
    }

    fun encrypt(data: ByteArray) = checkNotNull(cipher).encrypt(data)

    fun decrypt(data: ByteArray) = checkNotNull(cipher).decrypt(data)

    companion object {
        private val CLIENT_NAME = "adb pair client\u0000".toByteArray(Charsets.US_ASCII)
        private val SERVER_NAME = "adb pair server\u0000".toByteArray(Charsets.US_ASCII)

        fun client(password: ByteArray) = PairingAuth(Spake2.Role.ALICE, password)
    }
}
