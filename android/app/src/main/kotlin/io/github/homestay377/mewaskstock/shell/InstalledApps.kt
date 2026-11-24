package io.github.homestay377.mewaskstock.shell

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build

/**
 * 找出手机里能打开的 App。
 *
 * 口径与 Mika 一致（`AndroidScreen.launchableApps`）：问桌面能启动的那些，
 * 也就是 `queryIntentActivities(MAIN/LAUNCHER)` —— 系统应用、股票 App、聊天 App 都在里面。
 *
 * 额外做的事：把"可能跟行情有关"的标出来，方便模型在不认识包名时先缩小范围；
 * 但**不猜**哪个是"同花顺"，模型自己按名字挑，名字对不上就列出来问用户。
 */
object InstalledApps {

    data class App(val packageName: String, val label: String) {
        fun toMap(): Map<String, Any?> = mapOf("package" to packageName, "label" to label)
    }

    private var cache: List<App>? = null
    private var cachedAt = 0L

    /** 股票/行情相关的关键词，只用于排序与提示，不用于判定身份。 */
    private val MARKET_HINTS = listOf(
        "同花顺", "通达信", "雪球", "开盘啦", "东方财富", "大智慧", "老虎", "富途", "券",
        "股票", "证券", "行情", "炒股", "涨乐", "自选股", "韭菜", "雪盈",
    )

    fun list(context: Context, forceReload: Boolean = false): List<App> {
        val now = System.currentTimeMillis()
        cache?.let { if (!forceReload && now - cachedAt < 60_000) return it }
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = runCatching { pm.queryIntentActivities(intent, 0) }.getOrElse { emptyList() }
        val apps = resolved
            .mapNotNull { ri ->
                val pkg = ri.activityInfo?.packageName ?: return@mapNotNull null
                if (pkg == context.packageName) return@mapNotNull null
                val label = runCatching { ri.loadLabel(pm).toString() }.getOrDefault(pkg)
                App(pkg, label)
            }
            .distinctBy { it.packageName }
            .sortedBy { it.label }
        cache = apps
        cachedAt = now
        return apps
    }

    /**
     * 按用户/模型给的名字找 App。
     *
     * 三种命中方式，按可信度排序：包名完全相等 > 名字完全相等 > 名字包含（或包名包含）。
     * 返回所有候选，让模型自己挑，**不替它决定**。
     */
    fun find(context: Context, query: String, limit: Int = 10): List<App> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        val all = list(context)
        val exactPkg = all.filter { it.packageName.equals(q, ignoreCase = true) }
        if (exactPkg.isNotEmpty()) return exactPkg
        val exactLabel = all.filter { it.label.equals(q, ignoreCase = true) }
        if (exactLabel.isNotEmpty()) return exactLabel
        val lower = q.lowercase()
        return all.filter {
            it.label.lowercase().contains(lower) || it.packageName.lowercase().contains(lower)
        }.take(limit)
    }

    /** 行情类 App 优先（给模型一个"从哪找起"的提示，不作为结论）。 */
    fun marketRelated(context: Context): List<App> = list(context).filter { app ->
        MARKET_HINTS.any { h -> app.label.contains(h) }
    }

    /** App 是否装了（含没有桌面图标的系统/后台包）。 */
    fun installed(context: Context, packageName: String): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getApplicationInfo(packageName, PackageManager.ApplicationInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getApplicationInfo(packageName, 0)
        }
        true
    }.getOrDefault(false)

    fun appInfo(context: Context, packageName: String): ApplicationInfo? = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getApplicationInfo(packageName, PackageManager.ApplicationInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getApplicationInfo(packageName, 0)
        }
    }.getOrNull()
}
