package io.github.homestay377.mewaskstock.shell

/**
 * 用 shell 身份把本应用的无障碍服务写进 `secure` 设置。
 *
 * 为什么要这样：读屏靠无障碍树才拿得到精确控件和 ref（OCR 只能给文字和坐标，
 * 而且打不了中文）。让用户自己去系统设置里翻三层再点开关，正是被抱怨的那类"麻烦"。
 * Mika 的做法就是拿 shell 身份（`WRITE_SECURE_SETTINGS`）自己写：
 * `settings put secure enabled_accessibility_services …` + `accessibility_enabled 1`。
 *
 * 三条纪律：
 * 1. **先读整张列表再合并**——别的无障碍服务（TalkBack、输入法、其他助手）不能被顶掉；
 * 2. 组件名有两种写法（`包名/.类名` 与 `包名/完整类名`），比较前统一展开；
 * 3. 写完**回读校验**，不把"命令跑过了"当成"真的生效了"。
 *
 * 口径来源：Mika `core/device/shell/RecoveryPermissions.kt`（Apache-2.0）。
 */
internal object AccessibilityEnabler {

    data class Result(
        val ok: Boolean,
        val component: String,
        val list: String,
        val detail: String? = null,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "ok" to ok,
            "component" to component,
            "list" to list,
            "detail" to detail,
        )
    }

    /** `exec` 以 shell 身份跑一条命令，返回合并了 stderr 的输出（末尾带 `__exit=` 行）。 */
    fun enable(component: String, exec: (String) -> String): Result {
        val want = expand(component)
        val before = entries(value(exec(READ_LIST)))
        val alreadyThere = before.any { expand(it) == want }
        val merged = if (alreadyThere) before else before + component
        val joined = merged.joinToString(":")

        val put = exec("settings put secure ${KEY_LIST} ${quote(joined)}")
        exec("settings put secure accessibility_enabled 1")

        val after = entries(value(exec(READ_LIST)))
        val on = value(exec("settings get secure accessibility_enabled"))
        val applied = after.any { expand(it) == want } && on == "1"
        return Result(
            ok = applied,
            component = component,
            list = joined,
            detail = if (applied) {
                null
            } else {
                "写入后没生效（accessibility_enabled=$on，列表现有 ${after.size} 项；命令输出：${value(put).take(200)}）"
            },
        )
    }

    private const val KEY_LIST = "enabled_accessibility_services"
    private const val READ_LIST = "settings get secure $KEY_LIST"

    /** 去掉末尾的 `__exit=` / `__error=` 行，剩下的就是命令的输出。 */
    private fun value(out: String): String = out.lineSequence()
        .filterNot { it.startsWith("__exit=") || it.startsWith("__error=") }
        .joinToString("\n")
        .trim()

    private fun entries(raw: String): List<String> =
        raw.split(':').map { it.trim() }.filter { it.isNotEmpty() && it != "null" }

    /** `包名/.类名` 与 `包名/完整类名` 是同一个组件，比较前统一成后者。 */
    private fun expand(c: String): String {
        if ('/' !in c) return c
        val pkg = c.substringBefore('/')
        val cls = c.substringAfter('/')
        return if (cls.startsWith('.')) "$pkg/$pkg$cls" else c
    }

    private fun quote(s: String): String = "'" + s.replace("'", "'\\''") + "'"
}