package io.github.homestay377.mewaskstock.adb

import android.content.Context
import android.util.Log
import io.github.homestay377.mewaskstock.shell.IShellDisplay
import java.io.File

/**
 * B 路线：无线调试配对 + 用 `app_process` 以 shell 身份拉起助手，拿到 [IShellDisplay]。
 *
 * 为什么不用 Shizuku 也能做到：无线调试打开后，adbd 在本机公布一个 TLS 端口；
 * 配对一次（配对码）之后，我们就能在 adbd 上开 `exec:` 流跑任意命令——**命令以 uid 2000 执行**。
 * 于是可以：
 *
 * ```
 * CLASSPATH=<base.apk> app_process /system/bin --nice-name=<pkg>.shell \
 *     io.github.homestay377.mewaskstock.shell.ShellServiceMain <pkg>
 * ```
 *
 * 助手进程通过 binder 把 [IShellDisplay] 交回来（见 [ShellHelperMain]）。
 *
 * 与 Shizuku 的关系：**两条路产出同一个接口**，上层（VirtualDisplayManager / 工具层）完全不用区分。
 * Shizuku 断了可以退到这条；这条断了可以退到 Shizuku。
 */
class WirelessDebugChannel(
    private val context: Context,
    private val store: AdbStore,
    private val discovery: AdbDiscovery,
) {

    enum class Phase { NO_KEY, NOT_PAIRED, PAIRING, CONNECTING, READY, FAILED }

    data class Status(val phase: Phase, val detail: String? = null) {
        val ready: Boolean get() = phase == Phase.READY
    }

    data class Helper(val process: Process?, val service: IShellDisplay?, val pid: Int)

    @Volatile
    private var status = Status(Phase.NOT_PAIRED)

    @Volatile
    private var helper: Helper? = null

    @Volatile
    private var connection: AdbConnection? = null

    fun current(): Status = status

    fun service(): IShellDisplay? = helper?.service

    /**
     * 用配对码完成配对。
     *
     * 端口不能写死：adbd 每次开无线调试都换一个，只能从 mDNS 的 `_adb-tls-pairing._tcp` 取。
     * 若 [port] 给了就用给的（用户手填）。
     */
    fun pair(code: String, port: Int? = null): Status {
        val trimmed = code.trim()
        if (trimmed.isEmpty()) return fail("配对码为空")
        status = Status(Phase.PAIRING)

        val candidates = if (port != null) {
            listOf(AdbDiscovery.Service("manual", "127.0.0.1", port))
        } else {
            discovery.find(AdbServices.PAIRING)
        }
        if (candidates.isEmpty()) {
            return fail("没找到配对的端口。请在系统「无线调试」里点「使用配对码配对设备」，让对话框保持开着。")
        }

        val tls = AdbTls(store.identity())
        val pairing = AdbPairing(tls)
        var lastError: String? = null
        for (c in candidates) {
            try {
                val peer = pairing.pair(c.host, c.port, trimmed)
                store.markPaired()
                status = Status(Phase.NOT_PAIRED, "配对成功（设备 ${peer.data}），下一步连接")
                return status
            } catch (e: AdbPairingException) {
                lastError = when (e.reason) {
                    AdbPairingException.Reason.WRONG_CODE -> "配对码不对"
                    AdbPairingException.Reason.TLS_FAILED -> "TLS 握手失败（端口可能已换）"
                    AdbPairingException.Reason.CONNECT_FAILED -> "连不上端口 ${c.port}"
                    AdbPairingException.Reason.PROTOCOL -> "协议错误：${e.message}"
                }
                Log.w(TAG, "pairing failed on ${c.port}", e)
            } catch (e: Exception) {
                lastError = e.message
                Log.w(TAG, "pairing failed on ${c.port}", e)
            }
        }
        return fail(lastError ?: "配对失败")
    }

    /** 连上 adbd 并拉起助手（已配对才能用）。 */
    fun startHelper(): Status {
        if (helper?.service != null) {
            status = Status(Phase.READY)
            return status
        }
        if (!store.isPaired()) {
            status = Status(Phase.NOT_PAIRED, "还没配对：先在系统「无线调试」里用配对码配一次")
            return status
        }
        val apk = store.apkPath() ?: return fail("读不到自己的 APK 路径")

        // 先看有没有还在跑的助手（上次没清掉），有就直接用
        attachExisting()?.let {
            helper = it
            status = Status(Phase.READY, "复用已在运行的助手 pid=${it.pid}")
            return status
        }

        status = Status(Phase.CONNECTING)
        val conn = try {
            connectAny()
        } catch (e: AdbException) {
            return fail(
                when (e.reason) {
                    AdbException.Reason.UNAUTHORIZED -> "设备不认我们的证书（可能撤销过授权，需要重新配对）"
                    AdbException.Reason.CONNECT_FAILED -> "连不上无线调试端口（无线调试没开？）"
                    AdbException.Reason.TLS_FAILED -> "TLS 握手失败"
                    AdbException.Reason.NOT_LOCAL -> "只支持本机连接"
                    AdbException.Reason.PROTOCOL -> "协议错误：${e.message}"
                },
            )
        } ?: return fail("没找到无线调试端口。请确认系统「无线调试」是开着的。")
        connection = conn

        // 拉起助手：app_process 用 shell 身份运行，classpath 就是我们的 APK
        val command = "${CLASSPATH_PREFIX}${apk} app_process /system/bin " +
            "--nice-name=$HELPER_NAME $HELPER_MAIN ${context.packageName}"
        val stream = try {
            conn.exec(command)
        } catch (e: Exception) {
            return fail("起助手失败：${e.message}")
        }
        Log.i(TAG, "helper command sent")

        // 轮询：助手起来后我们会收到 binder（通过 ServiceManager 找不到，走文件/端口更复杂）
        // 这里简化：popen 的 stdout 里会打印 "READY <port> <token>"，我们再连本地端口拿 binder
        val deadline = System.currentTimeMillis() + HELPER_BOOT_MS
        var port = -1
        var token = ""
        while (System.currentTimeMillis() < deadline) {
            val line = runCatching { readLineWithTimeout(stream, 1500) }.getOrNull()
            if (line != null) {
                Log.i(TAG, "helper says: $line")
                if (line.startsWith(READY_PREFIX)) {
                    val parts = line.substring(READY_PREFIX.length).trim().split(' ')
                    port = parts.getOrNull(0)?.toIntOrNull() ?: -1
                    token = parts.getOrNull(1).orEmpty()
                    break
                }
            }
        }
        if (port <= 0) {
            runCatching { stream.close() }
            return fail("助手没起来（等 ${HELPER_BOOT_MS / 1000} 秒没收到就绪信号）")
        }
        val svc = ShellHelperClient.attach("127.0.0.1", port, token)
        if (svc == null) {
            runCatching { stream.close() }
            return fail("连不上助手（端口 $port）")
        }
        val pid = runCatching { svc.identity().lastOrNull() }.getOrNull() ?: -1
        helper = Helper(null, svc, pid)
        status = Status(Phase.READY, "助手已就绪 pid=$pid")
        return status
    }

    fun stop() {
        runCatching { ShellHelperClient.detach(helper?.service) }
        helper = null
        runCatching { connection?.close() }
        connection = null
        status = if (store.isPaired()) Status(Phase.NOT_PAIRED) else Status(Phase.NOT_PAIRED, "未配对")
    }

    fun forget() {
        stop()
        store.forget()
        status = Status(Phase.NOT_PAIRED, "已解除配对（下次要重新配对）")
    }

    // ---------- 内部 ----------

    /** 已有助手在跑就直接连（助手端口和口令写在私有目录里）。 */
    private fun attachExisting(): Helper? {
        val f = File(context.filesDir, "$HELPER_NAME.port")
        if (!f.exists()) return null
        val text = runCatching { f.readText().trim() }.getOrNull() ?: return null
        val parts = text.split(' ')
        val port = parts.getOrNull(0)?.toIntOrNull() ?: return null
        val token = parts.getOrNull(1).orEmpty()
        val svc = ShellHelperClient.attach("127.0.0.1", port, token) ?: return null
        val pid = runCatching { svc.identity().lastOrNull() }.getOrNull() ?: -1
        return Helper(null, svc, pid)
    }

    private fun connectAny(): AdbConnection? {
        val tls = AdbTls(store.identity())
        val ports = discovery.find(AdbServices.CONNECT).map { it.port }.ifEmpty { listOf(5555, 5037) }
        var last: AdbException? = null
        for (p in ports) {
            try {
                return AdbConnection.open("127.0.0.1", p, tls)
            } catch (e: AdbException) {
                last = e
                Log.w(TAG, "connect failed on $p", e)
            }
        }
        if (last != null) throw last
        return null
    }

    private fun readLineWithTimeout(stream: AdbConnection.AdbStream, timeoutMs: Int): String? {
        // AdbStream 的 read 会阻塞；用单独线程 + 超时
        var result: String? = null
        val t = Thread {
            result = runCatching { stream.read()?.toString(Charsets.UTF_8) }.getOrNull()
        }
        t.isDaemon = true
        t.start()
        t.join(timeoutMs.toLong())
        return result
    }

    private fun fail(message: String): Status {
        status = Status(Phase.FAILED, message)
        return status
    }

    private companion object {
        const val TAG = "WirelessDebug"
        const val HELPER_NAME = "mewaskstock.shell"
        const val HELPER_MAIN = "io.github.homestay377.mewaskstock.shell.ShellServiceMain"
        const val CLASSPATH_PREFIX = "CLASSPATH="
        const val READY_PREFIX = "MEW_SHELL_READY "
        const val HELPER_BOOT_MS = 20_000L
    }
}
