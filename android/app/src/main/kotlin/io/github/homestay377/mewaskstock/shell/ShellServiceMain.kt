package io.github.homestay377.mewaskstock.shell

import android.os.Looper
import io.github.homestay377.mewaskstock.adb.ShellHelperHandoff
import android.util.Log
import java.io.File
import kotlin.system.exitProcess

/**
 * B 路线的进程入口：**以 shell 身份**（uid 2000）由 `app_process` 启动。
 *
 * ```
 * CLASSPATH=<base.apk> app_process /system/bin \
 *     --nice-name=<pkg>.shell \
 *     io.github.homestay377.mewaskstock.shell.ShellServiceMain <pkg>
 * ```
 *
 * 起来之后：
 * 1. 自建 Context（[ShellContext]，ActivityThread.systemMain）；
 * 2. 起一个回环 socket，把 binder 交给 App（[ShellHelperHandoff]）；
 * 3. binder 没人要了就退出，不在后台白占内存。
 *
 * 与 Shizuku 路线的区别只在"谁拉起这个进程"，[ShellDisplayService] 完全共用。
 */
object ShellServiceMain {

    private const val TAG = "ShellServiceMain"
    private const val IDLE_EXIT_MS = 5 * 60_000L

    @JvmStatic
    fun main(args: Array<String>) {
        val pkg = args.firstOrNull() ?: run {
            Log.e(TAG, "usage: ShellServiceMain <package>")
            exitProcess(2)
        }

        // ActivityThread.systemMain 需要主线程 Looper
        @Suppress("DEPRECATION")
        if (Looper.myLooper() == null) Looper.prepareMainLooper()

        // app_process 场景：自建 Context 并包成"自称 shell"
        val context = runCatching { ShellContext.create() }.getOrElse {
            Log.e(TAG, "cannot build shell context", it)
            exitProcess(3)
        }
        ContextHolder.install(context)

        val service = ShellDisplayService()
        val token = ShellHelperHandoff.newToken()

        // 把端口和口令写进 App 私有目录：App 收到 READY 后先读文件，再连。
        // 这里是 shell 身份：同一用户下 /data/data/<pkg> 对 shell 可读，其他 App 读不到。
        val targetDir = File("/data/data/$pkg/files/shell")
        runCatching {
            if (!targetDir.exists()) targetDir.mkdirs()
            File(targetDir, ShellHelperHandoff.FILE_TOKEN).writeText(token)
            targetDir.setReadable(true, false)
        }.onFailure { Log.w(TAG, "cannot write token file to $targetDir", it) }

        val (port, worker) = ShellHelperHandoff.serve(token) { service.asBinder()!! }
        runCatching { File(targetDir, ShellHelperHandoff.FILE_PORT).writeText("$port $token") }
            .onFailure { Log.w(TAG, "cannot write port file", it) }

        // 告诉 App 侧（经 adbd 的 exec 流）我们起来了
        println("MEW_SHELL_READY $port $token")
        System.out.flush()

        Log.i(TAG, "helper ready on 127.0.0.1:$port uid=${android.os.Process.myUid()}")

        // 主线程跑 Looper 处理 binder 调用；空闲太久自己退出
        val started = System.currentTimeMillis()
        val checker = Thread {
            while (true) {
                Thread.sleep(30_000)
                // 简化：没有绑定方的引用计数，只在超过 idle 时间且没有活跃调用时退出
                if (System.currentTimeMillis() - started > IDLE_EXIT_MS) {
                    Log.i(TAG, "idle for too long, exiting")
                    exitProcess(0)
                }
            }
        }
        checker.isDaemon = true
        checker.start()

        Looper.loop()
        worker.join(0)
    }
}
