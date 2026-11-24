package io.github.homestay377.mewaskstock.shell

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Looper
import kotlin.system.exitProcess

/**
 * shell 身份下的 Context 自建。
 *
 * app_process 起的进程没有 Application、没有 Looper，也没有正常 App 的进程登记；
 * 但用 ActivityThread.systemMain() 拿到的这套 Context 足以调 DisplayManager、PackageManager、
 * ActivityTaskManager，这正是 Mika 的 ShellContext 做的事（`CLASSPATH=<apk> app_process`）。
 */
internal object ShellContext {

    @SuppressLint("PrivateApi")
    fun create(): Context {
        // 一定要先有主线程 Looper：ActivityThread.systemMain 内部会用
        @Suppress("DEPRECATION")
        if (Looper.myLooper() == null) Looper.prepareMainLooper()
        // ActivityThread 是 @hide，只能按名字反射
        val cls = Class.forName("android.app.ActivityThread")
        val at = cls.getMethod("systemMain").invoke(null)!!
        val get = at.javaClass.getMethod("getSystemContext")
        val system = get.invoke(at) as Context
        // 拿到「shell」这个包的身份：包名 com.android.shell、uid 2000
        return system
    }

    /** 把 Context 装进 [ContextHolder]，顺便验证它能不能解析我们自己的包（验证权限是否真的够）。 */
    fun install(ownPackage: String): Boolean = runCatching {
        val ctx = create()
        ContextHolder.install(ctx)
        // 能读到自己这个包的 ApplicationInfo，说明 PackageManager 用得通
        readAppInfo(ctx, ownPackage) != null
    }.getOrElse { false }

    private fun readAppInfo(ctx: Context, pkg: String): ApplicationInfo? = runCatching {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            ctx.packageManager.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            ctx.packageManager.getApplicationInfo(pkg, 0)
        }
    }.getOrNull()

    /** 进程入口：[args] = 目标包名（用于校验 Context），`--nice-name` 由 app_process 处理。 */
    @JvmStatic
    fun main(args: Array<String>) {
        val pkg = args.firstOrNull()
        if (pkg == null) {
            exitProcess(2)
        }
        if (!install(pkg)) {
            exitProcess(3)
        }
        // binder 线程池由 Binder 自己管；这里只要主线程跑起来接 Shizuku/助手的调用
        Looper.loop()
    }
}
