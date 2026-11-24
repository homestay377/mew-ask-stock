package io.github.homestay377.mewaskstock.shell

import android.content.Context
import android.util.Log
import io.github.homestay377.mewaskstock.adb.WirelessDebugChannel

/**
 * 虚拟屏的服务来源：**Shizuku 和无线调试两条路，谁先就绪用谁**。
 *
 * 上层（VirtualDisplayManager / 工具层）只看 [service]，不关心 binder 是哪来的——
 * 两条路产出的是同一个 [IShellDisplay]。
 *
 * 选路顺序（抄 Mika 的 `ShellTransport.Auto` 语义，但状态机自己写）：
 * 1. Shizuku 已装、在跑、已授权 → 用 Shizuku（最省事，一次授权长期有效）；
 * 2. 否则若做过无线调试配对 → 拉起 app_process 助手；
 * 3. 都不行 → 把两条路各自缺什么如实报出来。
 */
class ShellRouter(
    private val context: Context,
    private val shizuku: ShizukuChannel,
    private val wireless: WirelessDebugChannel,
) {

    enum class Source { NONE, SHIZUKU, WIRELESS }

    data class State(
        val source: Source,
        val service: IShellDisplay?,
        /** 给用户/模型看的一句话。 */
        val note: String,
        val shizukuPhase: String,
        val wirelessPhase: String,
    )

    @Volatile
    private var state = State(Source.NONE, null, "还没准备好", "unknown", "not_paired")

    fun current(): State = state

    /** 选一个能用的来源；都不可用时把各自的问题拼出来。 */
    fun resolve(): State {
        // 1. Shizuku
        val s = shizuku.current()
        if (s.ready) {
            shizuku.service()?.let { svc ->
                state = State(Source.SHIZUKU, svc, "Shizuku 已就绪", s.phase.name.lowercase(), wireless.current().phase.name.lowercase())
                return state
            }
        }

        // 2. 无线调试
        val w = wireless.current()
        val existing = wireless.service()
        if (existing != null) {
            state = State(Source.WIRELESS, existing, "无线调试助手已就绪", s.phase.name.lowercase(), w.phase.name.lowercase())
            return state
        }
        if (wireless.current().phase != WirelessDebugChannel.Phase.FAILED) {
            val started = runCatching { wireless.startHelper() }.getOrElse {
                Log.w(TAG, "start helper failed", it)
                wireless.current()
            }
            val svc = wireless.service()
            if (svc != null) {
                state = State(Source.WIRELESS, svc, "无线调试助手已就绪", s.phase.name.lowercase(), started.phase.name.lowercase())
                return state
            }
        }

        val note = buildString {
            append("虚拟屏还开不了。")
            append("Shizuku：${describeShizuku(s)}；")
            append("无线调试：${w.detail ?: w.phase.name.lowercase()}")
        }
        state = State(Source.NONE, null, note, s.phase.name.lowercase(), w.phase.name.lowercase())
        return state
    }

    private fun describeShizuku(s: ShizukuChannel.Snapshot): String = when (s.phase) {
        ShizukuChannel.Phase.NOT_INSTALLED -> "没装"
        ShizukuChannel.Phase.NOT_RUNNING -> "服务没在运行"
        ShizukuChannel.Phase.NEED_PERMISSION -> "没授权"
        ShizukuChannel.Phase.BINDING -> "正在绑定"
        ShizukuChannel.Phase.READY -> "已就绪"
        ShizukuChannel.Phase.FAILED -> s.detail ?: "失败"
    }

    /** 让两个通道都重新看一遍状态。 */
    fun refresh() {
        shizuku.refresh()
        wireless.current()
    }

    private companion object {
        const val TAG = "ShellRouter"
    }
}
