package io.github.homestay377.mewaskstock.shell

import android.annotation.SuppressLint
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.os.Looper

/**
 * shell 身份下的 Context。
 *
 * **关键不是拿到一个 Context，而是让它"自称"属于 com.android.shell。**
 *
 * `ActivityThread.systemMain().getSystemContext()` 拿到的 Context 自称属于 `android`（uid 1000），
 * 而我们的进程是 uid 2000。系统校验 `packageName must match the owner uid` 比的是
 * **调用上下文声明的归属（AttributionSource）**，不是我们传进 API 的字符串——
 * 所以光是 `createVirtualDisplay(..., "com.android.shell")` 是没用的，
 * 必须让整个 Context 的 packageName / opPackageName / attributionSource 都变成 shell。
 *
 * 这是 Mika 的 ShellContext 做的事，也是前面几次建屏失败的真正原因。
 */
internal class ShellContext private constructor(base: Context) : ContextWrapper(base) {

    override fun getPackageName(): String = SHELL_PACKAGE

    override fun getOpPackageName(): String = SHELL_PACKAGE

    override fun getApplicationContext(): Context = this

    override fun getAttributionSource(): AttributionSource {
        // 只有 API 31+ 有 AttributionSource；低版本系统没有这项校验
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return super.getAttributionSource()
        return AttributionSource.Builder(SHELL_UID)
            .setPackageName(SHELL_PACKAGE)
            .build()
    }

    companion object {
        const val SHELL_PACKAGE = "com.android.shell"
        const val SHELL_UID = 2000

        /**
         * 造一个自称是 shell 的 Context。
         *
         * Shizuku UserService 进程通常已经有 ActivityThread；app_process 起的助手没有，
         * 这时按系统进程的方式自建一个（见 [newActivityThread]）。
         */
        @SuppressLint("PrivateApi", "DiscouragedPrivateApi")
        fun create(): Context {
            @Suppress("DEPRECATION")
            if (Looper.myLooper() == null) Looper.prepareMainLooper()

            val at = Class.forName("android.app.ActivityThread")
            val thread = runCatching { at.getMethod("currentActivityThread").invoke(null) }
                .getOrNull() ?: newActivityThread(at)
            val system = at.getDeclaredMethod("getSystemContext").invoke(thread) as Context
            return ShellContext(system)
        }

        /**
         * Shizuku 会给我们一个 Context（它的 UserService 构造参数）。
         * 直接包一层就能把它变成 shell 身份——比自己造便宜也更稳。
         */
        fun wrap(base: Context): Context = ShellContext(base)

        /** app_process 场景：手工造 ActivityThread 并登记成当前线程。 */
        @SuppressLint("PrivateApi", "DiscouragedPrivateApi", "SoonBlockedPrivateApi")
        private fun newActivityThread(at: Class<*>): Any {
            val thread = at.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
            at.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, thread)
            at.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(thread, true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                runCatching {
                    val cc = Class.forName("android.app.ConfigurationController")
                    val internal = Class.forName("android.app.ActivityThreadInternal")
                    val controller = cc.getDeclaredConstructor(internal)
                        .apply { isAccessible = true }
                        .newInstance(thread)
                    at.getDeclaredField("mConfigurationController").apply { isAccessible = true }.set(thread, controller)
                }
            }
            // 给 ActivityThread 装上 AppBindData，后续 getSystemContext 才走得通
            runCatching {
                val abd = Class.forName("android.app.ActivityThread\$AppBindData")
                val data = abd.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
                at.getDeclaredField("mBoundApplication").apply { isAccessible = true }.set(thread, data)
            }
            return thread
        }
    }
}
