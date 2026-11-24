package io.github.homestay377.mewaskstock.shell

import android.content.Context
import android.os.Looper
import android.util.Log
import androidx.annotation.Keep

/**
 * Shizuku UserService 入口（A 路线）。
 *
 * Shizuku 会用反射实例化这个类（跑在 shell 身份的独立进程里），把 binder 交给 App。
 * 构造时必须先有主线程 Looper，否则内部任何 post 都会崩。
 */
@Keep
class ShizukuShellUserService private constructor(dummy: Boolean) : IShellDisplay.Stub() {

    private val delegate: ShellDisplayService = ShellDisplayService()

    /**
     * Shizuku 优先用这个构造（它会传 Context）。参数可空：无参版本走 [dummy] 那个。
     */
    @Keep
    constructor(context: Context?) : this(true) {
        ensureMainLooper()
        // Shizuku 给的 Context 自称是 android（uid 1000），必须包成"自称 shell"的才能建屏。
        // 关键点：不是换一个 Context，而是让 packageName/opPackageName/attributionSource 都变成 shell。
        val installed = runCatching {
            val base = context ?: ShellContext.create()
            ContextHolder.install(ShellContext.wrap(base))
            true
        }.getOrDefault(false)
        if (!installed) {
            runCatching { ContextHolder.install(ShellContext.create()) }
        }
        Log.i(TAG, "Shizuku user service created (uid=${android.os.Process.myUid()})")
    }

    override fun createDisplay(surface: android.view.Surface, width: Int, height: Int, dpi: Int): Int =
        delegate.createDisplay(surface, width, height, dpi)

    override fun releaseDisplay(displayId: Int) = delegate.releaseDisplay(displayId)

    override fun startApp(displayId: Int, packageName: String): Int = delegate.startApp(displayId, packageName)

    override fun topTaskId(displayId: Int): Int = delegate.topTaskId(displayId)

    override fun injectTap(displayId: Int, x: Int, y: Int): Boolean = delegate.injectTap(displayId, x, y)

    override fun injectSwipe(displayId: Int, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long): Boolean =
        delegate.injectSwipe(displayId, x1, y1, x2, y2, durationMs)

    override fun injectKey(displayId: Int, keyCode: Int): Boolean = delegate.injectKey(displayId, keyCode)

    override fun injectAsciiText(displayId: Int, text: String): Int = delegate.injectAsciiText(displayId, text)

    override fun identity(): IntArray = delegate.identity()

    override fun lastError(): String? = delegate.lastError()

    @Suppress("DEPRECATION")
    private fun ensureMainLooper() {
        if (Looper.myLooper() == null) Looper.prepareMainLooper()
    }

    private companion object {
        const val TAG = "ShizukuShell"
        const val PACKAGE = "io.github.homestay377.mewaskstock"
    }
}
