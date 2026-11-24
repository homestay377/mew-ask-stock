package io.github.homestay377.mewaskstock.pairing

import android.content.Context
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import io.github.homestay377.mewaskstock.miniphone.MiniPhoneAccessibility

/**
 * 配对时**自动读屏上的 6 位码**——照 Mika 的 `PairingCodeReader` 思路。
 *
 * 为什么这一步最关键：系统那个「配对码」对话框一离开就没了，
 * 让用户"抄下码 → 切回 App → 输入"在人机交互上基本走不通。
 * 而配对期间无障碍本来就开着的话，直接读系统设置窗口上的数字就行，
 * 用户什么都不用做。
 *
 * 边界：
 * - 只读**系统设置**这个包的窗口，不碰别的 App；
 * - 只认纯 6 位数字，且必须唯一（屏上同时出现两个 6 位数就不猜）；
 * - 同一个码只试一次，错了等对话框刷新出新的码；
 * - 码不进日志。
 */
class PairingCodeReader(private val context: Context) {

    data class Reading(val code: String?, val port: Int?)

    /** 读一次当前屏幕上系统设置窗口里的配对码与端口。 */
    fun read(): Reading {
        val service = MiniPhoneAccessibility.instance ?: return Reading(null, null)
        val settingsPkgs = settingsPackages()
        val texts = ArrayList<String>()
        for (w in service.windows()) {
            val root = runCatching { w.root }.getOrNull() ?: continue
            val pkg = root.packageName?.toString().orEmpty()
            if (pkg !in settingsPkgs) continue
            collectTexts(root, texts)
        }
        return parse(texts)
    }

    /** 无障碍有没有开着（没开就只能走通知栏输入）。 */
    fun available(): Boolean = MiniPhoneAccessibility.instance != null

    private fun settingsPackages(): Set<String> {
        val out = HashSet<String>()
        // 常规 Settings 包 + 小米/三星等厂商可能的变体
        for (p in listOf(
            "com.android.settings",
            "com.miui.securitycenter",
            "com.samsung.android.settings",
            "com.coloros.settings",
            "com.oplus.settings",
        )) {
            if (installed(p)) out.add(p)
            // 设置页也可能由 sub-package 承载
        }
        return out
    }

    private fun installed(pkg: String): Boolean = runCatching {
        context.packageManager.getPackageInfo(pkg, 0)
        true
    }.getOrDefault(false)

    private fun collectTexts(root: AccessibilityNodeInfo, out: MutableList<String>) {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var seen = 0
        while (queue.isNotEmpty() && seen++ < MAX_NODES) {
            val n = queue.removeFirst()
            n.text?.toString()?.takeIf { it.isNotBlank() }?.let(out::add)
            n.contentDescription?.toString()?.takeIf { it.isNotBlank() }?.let(out::add)
            for (i in 0 until n.childCount) n.getChild(i)?.let(queue::add)
        }
    }

    companion object {
        private const val MAX_NODES = 400
        private const val TAG = "PairingCodeReader"
        private val CODE = Regex("""^\d{6}$""")
        private val IPV4_PORT = Regex("""(?<![\w.:])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d{1,5})(?![\w.:])""")
        private val IPV6_PORT = Regex("""\[[0-9A-Fa-f:.]*(?:%[\w.]+)?]:(\d{1,5})(?![\w.:])""")

        /** 纯函数，方便单测：从一堆文本里取唯一的 6 位数与端口。 */
        fun parse(texts: List<String>): Reading {
            val codes = texts.mapNotNull { t ->
                t.filterNot { it.isWhitespace() }.takeIf { CODE.matches(it) }
            }.toSet()
            val ports = texts.flatMap(::ports).toSet()
            return Reading(codes.singleOrNull(), ports.singleOrNull())
        }

        private fun ports(text: String): List<Int> {
            val v4 = IPV4_PORT.findAll(text)
                .filter { m -> (1..4).all { m.groupValues[it].toIntOrNull()?.let { v -> v <= 255 } == true } }
                .map { it.groupValues[5] }
            val v6 = IPV6_PORT.findAll(text).map { it.groupValues[1] }
            return (v4 + v6).mapNotNull { p -> p.toIntOrNull()?.takeIf { it in 1..65535 } }.toList()
        }
    }
}
