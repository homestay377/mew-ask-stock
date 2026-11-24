package io.github.homestay377.mewaskstock.adb

import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.interfaces.RSAPrivateCrtKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.RSAPrivateCrtKeySpec
import java.util.Base64
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509ExtendedTrustManager
import java.net.InetSocketAddress
import java.net.Socket

/**
 * 这台设备的 adb 身份：一个 RSA 2048 自签名证书 + 私钥。
 *
 * 无线调试配对时把公钥交给设备，之后 adbd 认这把证书就等于认我们。
 * 私钥只存在 App 私有目录，**不外传**；[clear] 就是"从这台手机上撤销"。
 */
class AdbIdentity(
    val keyPair: KeyPair,
    val certificate: X509Certificate,
) {
    /** adb 的公钥格式：`<base64(blob)> <user>@<host>`，blob 里是 RSA 公钥的 adb 编码。 */
    val adbPublicKey: String by lazy { encodeAdbPublicKey(keyPair) }

    companion object {
        private const val KEY_FILE = "adb_identity.pk8"

        /** 读已有身份；没有就生成一份并存盘。 */
        fun load(dir: File): AdbIdentity {
            val f = File(dir, KEY_FILE)
            if (f.exists()) {
                runCatching { fromPkcs8(f.readBytes()) }.onSuccess { return it }
                // 文件坏了就当没有，重新生成（会要求用户重新配对一次）
                f.delete()
            }
            val created = generate()
            dir.mkdirs()
            runCatching { f.writeBytes(created.keyPair.private.encoded) }
            return created
        }

        /** 生成本机专用身份。密钥长度 2048：adbd 只认 RSA，4096 在部分旧系统上握手很慢。 */
        fun generate(): AdbIdentity {
            val gen = KeyPairGenerator.getInstance("RSA")
            gen.initialize(2048, SecureRandom())
            val pair = gen.generateKeyPair()
            return AdbIdentity(pair, SelfSigned.certificate(pair))
        }

        fun fromPkcs8(pkcs8: ByteArray): AdbIdentity {
            val spec = PKCS8EncodedKeySpec(pkcs8)
            val kf = KeyFactory.getInstance("RSA")
            val priv = kf.generatePrivate(spec) as java.security.interfaces.RSAPrivateKey
            // PKCS#8 里带了 CRT 参数，直接拼回 KeyPair 需要公钥，只能从私钥推算 n/e
            val crt = priv as? RSAPrivateCrtKey ?: error("not a CRT RSA key")
            val pubSpec = java.security.spec.RSAPublicKeySpec(crt.modulus, crt.publicExponent)
            val pub = kf.generatePublic(pubSpec)
            val pair = KeyPair(pub, priv)
            return AdbIdentity(pair, SelfSigned.certificate(pair))
        }

        /** adb 公钥 blob：小端 "密钥长度/指数/模数" + 大端 "模数^n + 指数^e"。 */
        fun encodeAdbPublicKey(pair: KeyPair): String {
            val rsa = pair.public as java.security.interfaces.RSAPublicKey
            val n = rsa.modulus.toByteArray().stripLeadingZero()
            val e = rsa.publicExponent.toByteArray().stripLeadingZero()
            val bb = java.nio.ByteBuffer.allocate(4 * 2 + 4 + e.size + n.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            bb.putInt(0x12345678.toInt()) // 魔数：让 blob 不被当成 PEM 文本处理
            bb.putInt(e.size)
            bb.put(e)
            bb.putInt(n.size)
            bb.put(n)
            val encoded = Base64.getEncoder().encodeToString(bb.array())
            return "$encoded mew@ask-stock"
        }

        private fun ByteArray.stripLeadingZero(): ByteArray =
            if (size > 1 && this[0] == 0.toByte()) copyOfRange(1, size) else this
    }
}

/** 自签证书：adbd 不做链校验，只比对我们证书里的公钥，所以随便签个 10 年就够。 */
internal object SelfSigned {
    fun certificate(pair: KeyPair): X509Certificate {
        val keyInfo = pair.public.encoded
        val tbs = TBSCertificate.build(keyInfo)
        val sig = Signature.getInstance("SHA256withRSA")
        sig.initSign(pair.private)
        sig.update(tbs)
        val signature = sig.sign()
        val certBytes = TBSCertificate.asCertificate(tbs, signature)
        val factory = java.security.cert.CertificateFactory.getInstance("X.509")
        return factory.generateCertificate(certBytes.inputStream()) as X509Certificate
    }
}

/**
 * 手写的最小 DER 证书。
 *
 * 为什么不用 BouncyCastle：为了一个自签证书引一个大依赖不值得，而 adbd 不验证书内容，
 * 只从中取公钥，所以这里只需要保证 DER 结构合法（Android 的 CertificateFactory 能解析）。
 */
internal object TBSCertificate {

    fun build(publicKeyInfo: ByteArray): ByteArray {
        val version = der(0xA0.toByte(), der(0x02.toByte(), byteArrayOf(2))) // v3
        val serial = der(0x02.toByte(), randomSerial())
        val algo = der(0x06.toByte(), byteArrayOf(0x2A, 0x86.toByte(), 0x48, 0x86.toByte(), 0xF7.toByte(), 0x0D, 0x01, 0x01, 0x0B))
        val sigAlg = der(0x30.toByte(), algo)
        val name = name("CN=mew")
        val validity = der(
            0x30.toByte(),
            der(0x17.toByte(), "200101000000Z".toByteArray()),
            der(0x17.toByte(), "490101000000Z".toByteArray()),
        )
        return der(0x30.toByte(), version, serial, sigAlg, name, validity, name, publicKeyInfo)
    }

    fun asCertificate(tbs: ByteArray, signature: ByteArray): ByteArray {
        val algo = der(0x06.toByte(), byteArrayOf(0x2A, 0x86.toByte(), 0x48, 0x86.toByte(), 0xF7.toByte(), 0x0D, 0x01, 0x01, 0x0B))
        val sigAlg = der(0x30.toByte(), algo)
        val bitString = der(0x03.toByte(), byteArrayOf(0x00) + signature)
        return der(0x30.toByte(), tbs, sigAlg, bitString)
    }

    /** Name ::= SEQUENCE OF RDN；这里只需要一个 CN。 */
    private fun name(cn: String): ByteArray {
        val oidCn = der(0x06.toByte(), byteArrayOf(0x55, 0x04, 0x03)) // 2.5.4.3
        val value = der(0x0C.toByte(), cn.toByteArray())
        val attr = der(0x30.toByte(), oidCn, value)
        val set = der(0x31.toByte(), attr)
        return der(0x30.toByte(), set)
    }

    private fun randomSerial(): ByteArray {
        val b = ByteArray(8)
        SecureRandom().nextBytes(b)
        b[0] = (b[0].toInt() and 0x7f).toByte() // 正整数
        return b
    }

    fun der(tag: Byte, vararg parts: ByteArray): ByteArray {
        var content = 0
        for (p in parts) content += p.size
        val out = java.io.ByteArrayOutputStream()
        out.write(tag.toInt())
        writeLength(out, content)
        for (p in parts) out.write(p)
        return out.toByteArray()
    }

    private fun writeLength(out: java.io.ByteArrayOutputStream, len: Int) {
        if (len < 0x80) {
            out.write(len)
        } else {
            val bytes = BigInteger.valueOf(len.toLong()).toByteArray().let {
                if (it.size > 1 && it[0] == 0.toByte()) it.copyOfRange(1, it.size) else it
            }
            out.write(0x80 or bytes.size)
            out.write(bytes)
        }
    }
}

/** 双方都出示自签证书、互不校验链（与 adb 一致）。 */
class AdbTls(val identity: AdbIdentity) {

    val context: SSLContext by lazy {
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(arrayOf(FixedKeyManager(identity)), arrayOf(TrustAll), null)
        ctx
    }

    fun wrap(plain: Socket, target: InetSocketAddress, client: Boolean = true): SSLSocket {
        val host = target.address?.hostAddress ?: error("ADB address must be resolved")
        val s = context.socketFactory.createSocket(plain, host, target.port, true) as SSLSocket
        try {
            s.enabledProtocols = arrayOf("TLSv1.3")
            s.useClientMode = client
            if (!client) s.needClientAuth = true
            s.startHandshake()
        } catch (e: Exception) {
            s.close()
            throw e
        }
        return s
    }

    /** TLS 导出密钥；配对时的 SPAKE2 口令要用它。Android 上走隐藏的 SSLSockets。 */
    fun exportKeyingMaterial(socket: SSLSocket, label: String, length: Int): ByteArray {
        val cls = Class.forName("com.android.org.conscrypt.Conscrypt")
        val m = cls.getMethod(
            "exportKeyingMaterial",
            SSLSocket::class.java,
            String::class.java,
            ByteArray::class.java,
            Int::class.javaPrimitiveType,
        )
        return m.invoke(null, socket, label, null, length) as ByteArray
    }

    private class FixedKeyManager(private val identity: AdbIdentity) : X509ExtendedKeyManager() {
        override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> = arrayOf(ALIAS)
        override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String = ALIAS
        override fun chooseEngineClientAlias(
            keyType: Array<out String>?,
            issuers: Array<out Principal>?,
            engine: SSLEngine?,
        ): String = ALIAS

        override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> = arrayOf(ALIAS)
        override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String = ALIAS
        override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?): String =
            ALIAS

        override fun getCertificateChain(alias: String?): Array<X509Certificate> = arrayOf(identity.certificate)
        override fun getPrivateKey(alias: String?): PrivateKey = identity.keyPair.private
    }

    private object TrustAll : X509ExtendedTrustManager() {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) {}
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) {}
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) {}
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) {}
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    private companion object {
        const val ALIAS = "adb"
    }
}
