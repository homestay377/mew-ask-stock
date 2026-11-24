package io.github.homestay377.mewaskstock.adb

import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * edwards25519 点运算（扩展齐次坐标 X:Y:Z:T），公式与编码按 RFC 8032 §5.1。
 *
 * 只给配对的 SPAKE2 用：一次配对只有几个标量乘，BigInteger 足够；不追求常数时间——
 * 私钥一次一用，配对码本来就在局域网对话框里可见。
 */
internal class EdPoint private constructor(
    private val x: BigInteger,
    private val y: BigInteger,
    private val z: BigInteger,
    private val t: BigInteger,
) {
    operator fun plus(o: EdPoint): EdPoint {
        val a = (y - x) * (o.y - o.x) % P
        val b = (y + x) * (o.y + o.x) % P
        val c = t * D2 % P * o.t % P
        val d = z * TWO * o.z % P
        val e = b - a
        val f = d - c
        val g = d + c
        val h = b + a
        return EdPoint(e * f % P, g * h % P, f * g % P, e * h % P)
    }

    operator fun unaryMinus() = EdPoint(P - x.mod(P), y, z, P - t.mod(P))

    operator fun minus(o: EdPoint) = this + (-o)

    fun times(k: BigInteger): EdPoint {
        require(k.signum() >= 0)
        var acc = IDENTITY
        for (i in k.bitLength() - 1 downTo 0) {
            acc += acc
            if (k.testBit(i)) acc += this
        }
        return acc
    }

    /** 32 字节：y 小端，最高位放 x 的奇偶。 */
    fun encode(): ByteArray {
        val zi = z.mod(P).modInverse(P)
        val ax = x * zi % P
        val ay = (y * zi).mod(P)
        val out = toLe(ay, 32)
        if (ax.mod(P).testBit(0)) out[31] = (out[31].toInt() or 0x80).toByte()
        return out
    }

    override fun equals(other: Any?): Boolean = other is EdPoint &&
        (x * other.z - other.x * z).mod(P).signum() == 0 &&
        (y * other.z - other.y * z).mod(P).signum() == 0

    override fun hashCode(): Int = encode().contentHashCode()

    companion object {
        // 不用 BigInteger.TWO：安卓 13 才有这个字段
        private val TWO = BigInteger.valueOf(2)
        val P: BigInteger = TWO.pow(255) - BigInteger.valueOf(19)

        /** 素数阶子群的阶。 */
        val L: BigInteger = TWO.pow(252) + BigInteger("27742317777372353535851937790883648493")
        private val D: BigInteger = (BigInteger.valueOf(-121665) * BigInteger.valueOf(121666).modInverse(P)).mod(P)
        private val D2 = D * TWO % P
        private val SQRT_M1: BigInteger = TWO.modPow((P - BigInteger.ONE).shiftRight(2), P)

        val IDENTITY = EdPoint(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)

        val BASE: EdPoint = requireNotNull(
            decode(hex("5866666666666666666666666666666666666666666666666666666666666666")),
        )

        /** RFC 8032 §5.1.3；不在曲线上或编码不规范返回 null。 */
        fun decode(bytes: ByteArray): EdPoint? {
            if (bytes.size != 32) return null
            val raw = bytes.copyOf()
            val sign = (raw[31].toInt() ushr 7) and 1
            raw[31] = (raw[31].toInt() and 0x7f).toByte()
            val y = fromLe(raw)
            if (y >= P) return null
            val yy = y * y % P
            val u = (yy - BigInteger.ONE).mod(P)
            val v = (D * yy + BigInteger.ONE) % P
            val v3 = v * v % P * v % P
            val v7 = v3 * v3 % P * v % P
            var x = u * v3 % P * (u * v7 % P).modPow((P - BigInteger.valueOf(5)).shiftRight(3), P) % P
            val vxx = v * x % P * x % P
            x = when {
                vxx == u -> x
                vxx == (P - u).mod(P) -> x * SQRT_M1 % P
                else -> return null
            }
            if (x.signum() == 0 && sign == 1) return null
            if (x.testBit(0) != (sign == 1)) x = P - x
            return EdPoint(x, y, BigInteger.ONE, x * y % P)
        }

        fun fromLe(b: ByteArray): BigInteger = BigInteger(1, b.reversedArray())

        fun toLe(n: BigInteger, len: Int): ByteArray {
            val be = n.toByteArray()
            val out = ByteArray(len)
            for (i in 0 until minOf(len, be.size)) out[i] = be[be.size - 1 - i]
            return out
        }

        fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
}

/**
 * adb 无线配对用的 SPAKE2 变体（edwards25519 + SHA-512）。
 *
 * **必须与设备端逐字节一致**，几个坑：
 * - 私钥 = (64 字节随机数 mod L) × 8（乘余因子）；
 * - 口令标量 = SHA-512(口令) mod L，再按低三位加 L、2L、4L，使它成为 8 的倍数；
 * - 发送 P* = 私钥·B + 口令标量·(甲用 M、乙用 N)；
 * - 共享密钥 = SHA-512(每段带 8 字节小端长度前缀：甲名、乙名、甲消息、乙消息、私钥·(Q*−口令标量·对方常量)、SHA-512(口令))。
 *
 * 名字含结尾 NUL。
 */
class Spake2(
    private val role: Role,
    private val myName: ByteArray,
    private val theirName: ByteArray,
) {
    enum class Role { ALICE, BOB }

    private var privateKey: BigInteger? = null
    private var passwordScalar: BigInteger? = null
    private var passwordHash: ByteArray? = null
    private var myMsg: ByteArray? = null
    private var done = false

    fun generateMessage(password: ByteArray, random: SecureRandom = SecureRandom()): ByteArray =
        generateMessage(password, ByteArray(64).also { random.nextBytes(it) })

    internal fun generateMessage(password: ByteArray, seed: ByteArray): ByteArray {
        check(myMsg == null) { "message already generated" }
        require(seed.size == 64)
        val priv = EdPoint.fromLe(seed).mod(EdPoint.L).shiftLeft(3)
        val hash = MessageDigest.getInstance("SHA-512").digest(password)
        var s = EdPoint.fromLe(hash).mod(EdPoint.L)
        if (s.testBit(0)) s += EdPoint.L
        if (s.testBit(1)) s += EdPoint.L.shiftLeft(1)
        if (s.testBit(2)) s += EdPoint.L.shiftLeft(2)
        val mask = (if (role == Role.ALICE) M else N).times(s)
        val msg = (EdPoint.BASE.times(priv) + mask).encode()
        privateKey = priv
        passwordScalar = s
        passwordHash = hash
        myMsg = msg
        return msg.copyOf()
    }

    /** 返回 64 字节共享密钥；对方的点不在曲线上抛 [IllegalArgumentException]。 */
    fun processMessage(theirMsg: ByteArray): ByteArray {
        val msg = checkNotNull(myMsg) { "generateMessage first" }
        check(!done) { "already processed" }
        require(theirMsg.size == 32) { "peer message must be 32 bytes" }
        val qStar = requireNotNull(EdPoint.decode(theirMsg)) { "peer point not on curve" }
        val peerMask = (if (role == Role.ALICE) N else M).times(passwordScalar!!)
        val shared = (qStar - peerMask).times(privateKey!!).encode()
        val sha = MessageDigest.getInstance("SHA-512")

        fun put(b: ByteArray) {
            val len = ByteArray(8)
            var l = b.size.toLong()
            for (i in 0 until 8) {
                len[i] = (l and 0xff).toByte()
                l = l ushr 8
            }
            sha.update(len)
            sha.update(b)
        }
        if (role == Role.ALICE) {
            put(myName); put(theirName); put(msg); put(theirMsg)
        } else {
            put(theirName); put(myName); put(theirMsg); put(msg)
        }
        put(shared)
        put(passwordHash!!)
        done = true
        return sha.digest()
    }

    companion object {
        internal val M = requireNotNull(
            EdPoint.decode(EdPoint.hex("5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e")),
        )
        internal val N = requireNotNull(
            EdPoint.decode(EdPoint.hex("10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778")),
        )
    }
}
