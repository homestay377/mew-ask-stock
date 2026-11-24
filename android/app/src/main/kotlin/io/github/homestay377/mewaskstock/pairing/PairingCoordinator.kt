package io.github.homestay377.mewaskstock.pairing

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.github.homestay377.mewaskstock.adb.AdbDiscovery
import io.github.homestay377.mewaskstock.adb.AdbPairing
import io.github.homestay377.mewaskstock.adb.AdbServices
import io.github.homestay377.mewaskstock.adb.AdbStore
import io.github.homestay377.mewaskstock.adb.AdbTls

/**
 * 一次配对的全过程：准备通知 → 找端口 → （能读屏就自己读码）→ 配对 → 更新通知。
 *
 * 和 Mika 的 `PairingCoordinator` 一样的三个要点：
 * 1. **通知提前放**：切到系统设置后本进程可能被冻结，等找到窗口再发就发不出去；
 * 2. **无障碍优先**：能读屏就不打扰用户；
 * 3. **失败留在通知里重填**，不是把人踢回 App。
 *
 * 只在配对这段时间跑，结束就停。
 */
class PairingCoordinator(
    private val context: Context,
    private val store: AdbStore,
    private val discovery: AdbDiscovery,
) {

    private val handler = Handler(Looper.getMainLooper())
    private val reader = PairingCodeReader(context)

    @Volatile
    private var running = false

    @Volatile
    private var tried = HashSet<String>()

    @Volatile
    private var lastCode: String? = null

    /** 开始一次配对：先放通知（静音也行，重点是"能在通知栏里找到"），再后台找端口/读码。 */
    fun start() {
        if (running) return
        running = true
        tried = HashSet()
        lastCode = null

        // 关键：先把通知放出去，用户下拉通知栏就能输码
        PairingNotifier.showInput(context, null)
        PairingCodeReceiver.sink = PairingCodeSink { code, port -> pair(code, port) }

        Thread({ watchLoop() }, "pairing-watch").apply { isDaemon = true }.start()
    }

    fun stop() {
        running = false
        PairingCodeReceiver.sink = null
    }

    /** 后台轮询：找端口 + 试着读屏上的码。无障碍没开就只是等用户从通知填。 */
    private fun watchLoop() {
        var port: Int? = null
        while (running) {
            if (port == null) {
                val found = runCatching { discovery.find(AdbServices.PAIRING, timeoutMs = 3_000) }.getOrDefault(emptyList())
                port = found.firstOrNull()?.port
                if (port != null) {
                    Log.i(TAG, "pairing port $port")
                    // 找到端口就把通知上的副标题更新掉
                    if (!reader.available()) PairingNotifier.showInput(context, port)
                }
            }
            if (port != null && reader.available()) {
                val reading = runCatching { reader.read() }.getOrNull()
                val code = reading?.code
                if (code != null && code != lastCode && code !in tried) {
                    Log.i(TAG, "read a pairing code from the settings screen")
                    lastCode = code
                    val r = pair(code, reading.port ?: port)
                    if (r.ok) return
                }
            }
            Thread.sleep(1_200)
        }
    }

    /** 真正配对。通知栏输入和自动读码都走这里。 */
    fun pair(code: String, port: Int?): PairResult {
        val trimmed = code.trim()
        if (trimmed.isEmpty()) return PairResult(false, "配对码为空")
        tried.add(trimmed)
        PairingNotifier.showWorking(context, port)
        val tls = AdbTls(store.identity())
        val pairing = AdbPairing(tls)
        val candidates = when {
            port != null -> listOf(AdbDiscovery.Service("manual", "127.0.0.1", port))
            else -> runCatching { discovery.find(AdbServices.PAIRING, timeoutMs = 5_000) }.getOrDefault(emptyList())
        }
        if (candidates.isEmpty()) {
            return PairResult(false, "没找到配对端口：确认系统里的配对对话框还开着")
        }
        var lastError: String? = null
        for (c in candidates) {
            try {
                pairing.pair(c.host, c.port, trimmed)
                store.markPaired()
                running = false
                PairingCodeReceiver.sink = null
                PairingNotifier.showDone(context)
                Log.i(TAG, "paired")
                return PairResult(true)
            } catch (e: io.github.homestay377.mewaskstock.adb.AdbPairingException) {
                lastError = when (e.reason) {
                    io.github.homestay377.mewaskstock.adb.AdbPairingException.Reason.WRONG_CODE ->
                        "配对码不对，请重新抄一次（对话框里的码会变）"
                    io.github.homestay377.mewaskstock.adb.AdbPairingException.Reason.CONNECT_FAILED ->
                        "连不上配对端口 ${c.port}（对话框可能已关或端口变了）"
                    io.github.homestay377.mewaskstock.adb.AdbPairingException.Reason.TLS_FAILED ->
                        "TLS 握手失败（端口可能不是配对端口）"
                    io.github.homestay377.mewaskstock.adb.AdbPairingException.Reason.PROTOCOL ->
                        "配对协议错误：${e.message}"
                }
            } catch (e: Exception) {
                lastError = e.message ?: "配对失败"
                Log.w(TAG, "pair failed on ${c.port}", e)
            }
        }
        return PairResult(false, lastError)
    }

    private companion object {
        const val TAG = "PairingCoordinator"
    }
}
