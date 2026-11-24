package io.github.homestay377.mewaskstock.adb

import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log
import io.github.homestay377.mewaskstock.shell.IShellDisplay
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import kotlin.concurrent.thread

/**
 * 助手 ↔ App 的本地 binder 交接。
 *
 * 为什么要这么绕：shell 身份下用 `app_process` 起的进程没有正常 App 的进程登记，
 * 不能像普通 Service 那样被绑定；但又不能把 binder 写进文件。做法（Mika 同款思路）：
 *
 * 1. 助手在本机回环起一个 socket，**只监听 127.0.0.1**；
 * 2. 把「端口 + 一次性口令」写进 App 私有目录（真机上是 `/data/data/<pkg>/files/`，
 *    shell 和 App 都能读，其他 App 读不到）；
 * 3. App 连上后先发口令，助手核对无误才把 [IShellDisplay] 的 binder 交出去。
 *
 * 口令是随机且一次性的：就算有人抢在我们前面连上，也说不对口令。
 */
object ShellHelperHandoff {

    const val FILE_PORT = "port"
    const val FILE_TOKEN = "token"

    fun newToken(): String {
        val b = ByteArray(24)
        SecureRandom().nextBytes(b)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    }

    /** 助手侧：等 App 来取 binder，拿到后返回。 */
    fun serve(expectedToken: String, binderProvider: () -> IBinder): Pair<Int, Thread> {
        val server = ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
        val worker = thread(isDaemon = true, name = "shell-handoff") {
            try {
                server.use { s ->
                    val client = s.accept()
                    client.use { c ->
                        val input = DataInputStream(c.getInputStream())
                        val output = DataOutputStream(c.getOutputStream())
                        val given = (input.readUTF()).trim()
                        if (!same(given, expectedToken)) {
                            Log.w(TAG, "handoff token mismatch, refusing")
                            return@thread
                        }
                        // 交 binder：先写长度，再写 Parcel
                        val parcel = Parcel.obtain()
                        try {
                            parcel.writeStrongBinder(binderProvider())
                            val bytes = parcel.marshall()
                            output.writeInt(bytes.size)
                            output.write(bytes)
                            output.flush()
                            Log.i(TAG, "binder handed off (${bytes.size} bytes)")
                        } finally {
                            parcel.recycle()
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "handoff failed", e)
            }
        }
        return server.localPort to worker
    }

    private fun same(a: String, b: String): Boolean {
        val x = a.toByteArray()
        val y = b.toByteArray()
        return MessageDigest.isEqual(x, y)
    }

    private const val TAG = "ShellHandoff"
}

/** App 侧：连助手、核口令、取 binder。 */
object ShellHelperClient {

    /** 连上并取回服务；失败返回 null。 */
    fun attach(host: String, port: Int, token: String): IShellDisplay? {
        if (host != "127.0.0.1" && host != "::1") return null
        return try {
            Socket().use { s ->
                s.tcpNoDelay = true
                s.connect(java.net.InetSocketAddress(host, port), 4000)
                s.soTimeout = 4000
                val out = DataOutputStream(s.getOutputStream())
                out.writeUTF(token)
                out.flush()
                val input = DataInputStream(s.getInputStream())
                val len = input.readInt()
                if (len <= 0 || len > MAX_PARCEL) return null
                val bytes = ByteArray(len).also { input.readFully(it) }
                val parcel = Parcel.obtain()
                try {
                    parcel.unmarshall(bytes, 0, bytes.size)
                    parcel.setDataPosition(0)
                    val binder = parcel.readStrongBinder()
                    if (binder == null || !binder.pingBinder()) null else IShellDisplay.Stub.asInterface(binder)
                } finally {
                    parcel.recycle()
                }
            }
        } catch (e: Exception) {
            Log.w("ShellHelperClient", "attach failed", e)
            null
        }
    }

    fun detach(service: IShellDisplay?) {
        // binder 不需要显式解绑；助手进程会自己退出（见 ShellServiceMain）
        Looper.myQueue()
    }

    private const val MAX_PARCEL = 1024 * 1024
}
