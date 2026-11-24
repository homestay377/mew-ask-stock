package io.github.homestay377.mewaskstock.shell

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Build
import android.os.IBinder
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface

/**
 * 虚拟屏与输入注入的全部实现。跑在 shell 身份进程里（Shizuku UserService 或 app_process 助手）。
 *
 * 所有"踩过的坑"都在这里，逐条写明来源：
 * - 建屏标志位（Mika `ShellDisplayOps.displayFlags` 实测口径）：不可信屏带 TRUSTED 会被系统以
 *   SecurityException 拒绝，所以先试可信、失败降级不可信。
 * - 全屏窗口模式：有的系统把新建的虚拟屏默认设成 freeform，App 缩成小窗且无障碍坐标会偏。
 * - 输入法策略 LOCAL：让输入法弹在虚拟屏上而不是用户主屏。
 * - 注入要 `setDisplayId`：按键按输入焦点路由，不认 event 上的 displayId，不定向会投到主屏。
 * - 启动用 `ActivityOptions.setLaunchDisplayId` + 反射 `startActivityAsUser`，失败退回 `am start --display`。
 */
class ShellDisplayService : IShellDisplay.Stub() {

    private val displays = HashMap<Int, VirtualDisplay>()
    private val lock = Any()

    override fun createDisplay(surface: Surface, width: Int, height: Int, dpi: Int): Int {
        val dm = displayManager() ?: run {
            lastError = "拿不到 DisplayManager（shell 进程上下文没建起来）"
            return -1
        }
        // 逐级降级：每一步都可能被不同厂商的系统拒绝（缺 ADD_TRUSTED_DISPLAY、
        // 不允许 OWN_CONTENT_ONLY、不允许 PUBLIC 等）。Mika 只降一次，这里多给几档。
        val plans = buildList {
            add("trusted" to displayFlags(Build.VERSION.SDK_INT, trusted = true))
            add("untrusted" to displayFlags(Build.VERSION.SDK_INT, trusted = false))
            add("minimal" to (FLAG_PUBLIC or FLAG_OWN_CONTENT_ONLY or FLAG_SUPPORTS_TOUCH))
            add("bare" to FLAG_PUBLIC)
        }
        for ((name, flags) in plans) {
            try {
                // 关键：必须用带 packageName 的重载，并传 com.android.shell。
                // 不带包名的重载会用 App 自己的包名，而这段代码以 shell（uid 2000）身份运行，
                // 系统校验就抛 SecurityException: packageName must match the owner uid。
                val vd = createVirtualDisplayWithOwner(dm, width, height, dpi, surface, flags)
                if (vd == null) {
                    lastError = "$name: createVirtualDisplay 返回 null"
                    Log.w(TAG, "createDisplay returned null ($name, flags=0x${flags.toString(16)})")
                    continue
                }
                val id = vd.display.displayId
                synchronized(lock) { displays[id] = vd }
                setFullscreenWindowingMode(id)
                setImePolicy(id)
                keepAwake(id, flags)
                Log.i(TAG, "createDisplay id=$id ${width}x$height via $name (flags=0x${flags.toString(16)})")
                lastError = null
                return id
            } catch (t: Throwable) {
                // 反射调用抛的是 InvocationTargetException，真正的异常在 cause 里
                val real = (t as? java.lang.reflect.InvocationTargetException)?.targetException ?: t
                lastError = "$name: ${real.javaClass.name}: ${real.message ?: real.javaClass.simpleName}【${lastOwnerInfo ?: "?"}】"
                Log.w(TAG, "createDisplay failed ($name, flags=0x${flags.toString(16)})", real)
            }
        }
        return -1
    }

    /**
     * 调 `createVirtualDisplay(name, w, h, dpi, surface, flags, packageName)`。
     *
     * packageName 必须是**调用者 uid 对应的包**：我们跑在 shell（uid 2000）里，
     * 所以要传 `com.android.shell`。传 App 自己的包名会被系统以
     * `SecurityException: packageName must match the owner uid` 拒绝。
     *
     * 这个重载 API 33 才有；更早的系统没有 uid 校验，退回不带包名的那个。
     */
    @SuppressLint("PrivateApi")
    private fun createVirtualDisplayWithOwner(
        dm: DisplayManager,
        width: Int,
        height: Int,
        dpi: Int,
        surface: Surface,
        flags: Int,
    ): VirtualDisplay? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return dm.createVirtualDisplay(NAME, width, height, dpi, surface, flags)
        }
        // 精确匹配签名：(String, int, int, int, Surface, int, String)
        val want = arrayOf<Class<*>>(
            String::class.java, Int::class.javaPrimitiveType!!, Int::class.javaPrimitiveType!!,
            Int::class.javaPrimitiveType!!, Surface::class.java, Int::class.javaPrimitiveType!!,
            String::class.java,
        )
        val m = DisplayManager::class.java.declaredMethods.firstOrNull {
            it.name == "createVirtualDisplay" && it.parameterTypes.contentEquals(want)
        } ?: run {
            Log.w(TAG, "no createVirtualDisplay(name,w,h,dpi,surface,flags,packageName) on this ROM")
            return dm.createVirtualDisplay(NAME, width, height, dpi, surface, flags)
        }
        m.isAccessible = true
        // 包名必须是**当前进程 uid 对应的包**。shizuku/无线调试给的身份不一定是 2000，
        // 所以按真实 uid 反查，而不是写死 com.android.shell。
        val uid = android.os.Process.myUid()
        val owner = packageForUid(uid)
        lastOwnerInfo = "uid=$uid pkg=$owner"
        Log.i(TAG, "createVirtualDisplay owner=$lastOwnerInfo")
        return m.invoke(dm, NAME, width, height, dpi, surface, flags, owner) as? VirtualDisplay
    }

    /**
     * 用 uid 反查该 uid 对应的包名。
     *
     * 这张表里内建 uid 也有对应包：2000 = `com.android.shell`，0 = `android`（root），
     * 1000 = `android`。普通 App 的 uid 走 PackageManager。
     */
    @SuppressLint("PrivateApi")
    private fun packageForUid(uid: Int): String {
        // 先用通用表查（能覆盖 1000/2000 等系统 uid）
        val known = when (uid) {
            0 -> "android"
            1000 -> "android"
            2000 -> "com.android.shell"
            else -> null
        }
        if (known != null) return known
        val viaPm = runCatching {
            context()?.packageManager?.getPackagesForUid(uid)?.firstOrNull()
        }.getOrNull()
        if (!viaPm.isNullOrEmpty()) return viaPm
        // 最后兜底：认成 App 自己的包（普通身份下正确）
        return context()?.packageName ?: "com.android.shell"
    }

    /** 最近一次建屏失败的原因，App 侧会读出来给用户看。 */
    override fun lastError(): String? = lastError

    @Volatile
    private var lastError: String? = null

    /** 最近一次建屏用的 owner 身份（uid + 包名），排查用。 */
    @Volatile
    private var lastOwnerInfo: String? = null

    override fun releaseDisplay(displayId: Int) {
        DisplayAwake.stop(displayId)
        val vd = synchronized(lock) { displays.remove(displayId) }
        runCatching { vd?.release() }.onFailure { Log.w(TAG, "releaseDisplay failed", it) }
    }

    /**
     * 屏建好之后让它别睡（见 [DisplayAwake]）。
     *
     * 只有这一块屏真的自成一组（带了 OWN_DISPLAY_GROUP）时才替它报用户操作：
     * 报到默认组会把用户的主屏也一直点着不灭。
     */
    private fun keepAwake(displayId: Int, flags: Int) {
        val group = DisplayAwake.displayGroup(displayId)
        if (!DisplayAwake.needed(flags, FLAG_OWN_DISPLAY_GROUP, group)) {
            Log.i(TAG, "display $displayId shares the default display group; keep-awake skipped (group=$group, flags=0x${flags.toString(16)})")
            return
        }
        DisplayAwake.start(displayId)
        Log.i(TAG, "display $displayId keep-awake on (group=$group)")
    }

    override fun startApp(displayId: Int, packageName: String): Int {
        if (!own(displayId)) return START_ERROR
        // 用户正在主屏用这个 App 就别动：一块 App 不能同时出现在两块屏上，系统会把整个任务挪过来。
        if (inUseOnMainScreen(packageName)) return START_IN_USE_ON_MAIN
        val launch = context()?.packageManager?.getLaunchIntentForPackage(packageName) ?: return START_NOT_FOUND
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val options = android.app.ActivityOptions.makeBasic().setLaunchDisplayId(displayId).toBundle()
        // 正路：直接让系统以 shell 身份启动到指定屏
        runCatching {
            val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
            val m = atm.javaClass.methods.first {
                it.name == "startActivityAsUser" && it.parameterTypes.size == 12
            }
            val r = m.invoke(
                atm, null, SHELL_PACKAGE, null, launch, null, null, null,
                0, 0, null, options, USER_CURRENT,
            ) as Int
            if (r >= 0) return START_OK
            Log.w(TAG, "startActivityAsUser returned $r for $packageName")
        }.onFailure { Log.w(TAG, "startActivityAsUser unavailable, falling back to am start", it) }
        // 退路：am start --display（大多数系统都行，慢一点）
        val cmp = launch.component?.flattenToShortString() ?: return START_ERROR
        return if (runCommand("am", "start", "--display", displayId.toString(), "-n", cmp) == 0) START_OK else START_ERROR
    }

    override fun topTaskId(displayId: Int): Int = runCatching {
        val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
        val info = Class.forName("android.app.ActivityTaskManager\$StackInfo")
        val list = atm.javaClass.getMethod("getAllStackInfosOnDisplay", Int::class.java)
            .invoke(atm, displayId) as? List<*> ?: return -1
        if (list.isEmpty()) -1 else {
            val top = list.first() as Any
            top.javaClass.getMethod("getTaskId").invoke(top) as? Int ?: -1
        }
    }.getOrDefault(-1)

    override fun injectTap(displayId: Int, x: Int, y: Int): Boolean = injectTapAt(displayId, x, y, TAP_MS)

    override fun injectSwipe(displayId: Int, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long): Boolean {
        val steps = SWIPE_STEPS
        val ms = durationMs.coerceIn(120, 4000)
        val downTime = SystemClock.uptimeMillis()
        var ok = false
        try {
            for (i in 0..steps) {
                val t = i.toFloat() / steps
                val x = x1 + (x2 - x1) * t
                val y = y1 + (y2 - y1) * t
                val action = when (i) {
                    0 -> MotionEvent.ACTION_DOWN
                    steps -> MotionEvent.ACTION_UP
                    else -> MotionEvent.ACTION_MOVE
                }
                val ev = MotionEvent.obtain(downTime, downTime + (ms * t).toLong(), action, x, y, 0)
                ev.source = InputDevice.SOURCE_TOUCHSCREEN
                try {
                    if (inject(ev, displayId, waitForFinish = false)) ok = true
                } finally {
                    ev.recycle()
                }
                // 按时间轴走，让 App 看到真实速度
                if (i < steps) SystemClock.sleep((ms / steps).coerceAtLeast(1))
            }
        } finally {
            // 手指一定要抬起来
            val up = MotionEvent.obtain(downTime, downTime + ms, MotionEvent.ACTION_UP, x2.toFloat(), y2.toFloat(), 0)
            up.source = InputDevice.SOURCE_TOUCHSCREEN
            runCatching { inject(up, displayId, false) }
            up.recycle()
        }
        return ok
    }

    private fun injectTapAt(displayId: Int, x: Int, y: Int, holdMs: Long): Boolean {
        if (!own(displayId)) return false
        val now = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x.toFloat(), y.toFloat(), 0)
        val up = MotionEvent.obtain(now, now + holdMs, MotionEvent.ACTION_UP, x.toFloat(), y.toFloat(), 0)
        return try {
            down.source = InputDevice.SOURCE_TOUCHSCREEN
            up.source = InputDevice.SOURCE_TOUCHSCREEN
            val a = inject(down, displayId, false)
            val b = inject(up, displayId, false)
            if (a && b) true else injectTapShell(displayId, x, y) // 注入被拒时退回 input 命令
        } finally {
            down.recycle()
            up.recycle()
        }
    }

    private fun injectTapShell(displayId: Int, x: Int, y: Int): Boolean =
        runCommand("input", "-d", displayId.toString(), "tap", x.toString(), y.toString()) == 0

    override fun injectKey(displayId: Int, keyCode: Int): Boolean {
        if (!own(displayId)) return false
        if (!ALLOWED_KEYS.contains(keyCode)) {
            Log.w(TAG, "refused key $keyCode")
            return false
        }
        val now = SystemClock.uptimeMillis()
        val down = KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0, 0, -1, 0, 0, InputDevice.SOURCE_KEYBOARD)
        val up = KeyEvent.changeAction(down, KeyEvent.ACTION_UP)
        val ok = inject(down, displayId, waitForFinish = true) && inject(up, displayId, waitForFinish = true)
        // 返回键是最常用的一个：注入没成就用 input keyevent 兜一次
        return ok || runCommand("input", "-d", displayId.toString(), "keyevent", keyCode.toString()) == 0
    }

    override fun injectAsciiText(displayId: Int, text: String): Int {
        if (displayId <= Display.DEFAULT_DISPLAY || !own(displayId)) return ASCII_NOT_SENT
        val payload = text.filter { it.code in 0x20..0x7E }
        if (payload.isEmpty()) {
            Log.w(TAG, "injectAsciiText: nothing printable (中文需要输入法，这条路只送 ASCII)")
            return ASCII_NOT_SENT
        }
        val events = runCatching {
            KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(payload.toCharArray())
        }.getOrNull()?.takeIf { it.isNotEmpty() } ?: return ASCII_NOT_SENT
        for (e in events) {
            if (!own(displayId)) return ASCII_UNCONFIRMED
            e.source = InputDevice.SOURCE_KEYBOARD
            // 送到一半失败就停下：已经打进去的前缀不能换条路重发，否则会重复
            if (!inject(e, displayId, waitForFinish = true)) return ASCII_UNCONFIRMED
        }
        return ASCII_DISPATCHED
    }

    override fun identity(): IntArray = intArrayOf(Process.myUid(), Process.myPid())

    // ---------- 内部 ----------

    private fun own(displayId: Int): Boolean = synchronized(lock) { displayId in displays }

    @SuppressLint("PrivateApi")
    private fun inject(event: InputEvent, displayId: Int, waitForFinish: Boolean): Boolean = try {
        // 按键按焦点路由、不认 event 上的 displayId；不定向会投给主屏焦点窗口
        event.javaClass.getMethod("setDisplayId", Int::class.java).invoke(event, displayId)
        val im = inputManager()
        val mode = when {
            waitForFinish -> INJECT_WAIT_FOR_FINISH
            event is KeyEvent -> INJECT_WAIT_FOR_RESULT
            else -> INJECT_ASYNC
        }
        im.javaClass.getMethod("injectInputEvent", InputEvent::class.java, Int::class.java)
            .invoke(im, event, mode) as Boolean
    } catch (t: Throwable) {
        Log.w(TAG, "injectInputEvent failed", t)
        false
    }

    /** API 34 起注入入口在 InputManagerGlobal，更早在 InputManager。 */
    @SuppressLint("PrivateApi")
    private fun inputManager(): Any = runCatching {
        Class.forName("android.hardware.input.InputManagerGlobal").getMethod("getInstance").invoke(null)!!
    }.getOrElse {
        Class.forName("android.hardware.input.InputManager").getMethod("getInstance").invoke(null)!!
    }

    /** 有的系统把新建的虚拟屏默认设成 freeform，App 会缩成小窗、无障碍坐标也随之偏。 */
    @SuppressLint("PrivateApi")
    private fun setFullscreenWindowingMode(displayId: Int) {
        runCatching {
            val wm = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null)!!
            wm.javaClass.getMethod("setWindowingMode", Int::class.java, Int::class.java).invoke(wm, displayId, 1)
        }.onFailure {
            Log.w(TAG, "setWindowingMode failed, falling back to wm")
            runCommand("wm", "set-display-windowing-mode", "-d", displayId.toString(), "1")
        }
    }

    /** 输入法弹在这块屏上，不要跑到用户主屏。LOCAL = 0。 */
    @SuppressLint("PrivateApi")
    private fun setImePolicy(displayId: Int) {
        runCatching {
            val wm = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null)!!
            wm.javaClass.getMethod("setDisplayImePolicy", Int::class.java, Int::class.java).invoke(wm, displayId, IME_LOCAL)
        }.onFailure { Log.w(TAG, "setDisplayImePolicy failed", it) }
    }

    private fun inUseOnMainScreen(packageName: String): Boolean = runCatching {
        val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
        val stacks = atm.javaClass.getMethod("getAllStackInfosOnDisplay", Int::class.java)
            .invoke(atm, Display.DEFAULT_DISPLAY) as? List<*> ?: return false
        stacks.any { s ->
            runCatching { s!!.javaClass.getMethod("getTopActivity").invoke(s) as? ComponentName }.getOrNull()
                ?.packageName == packageName
        }
    }.getOrDefault(false)

    private fun displayManager(): DisplayManager? = ContextHolder.displayManager

    private fun context(): Context? = ContextHolder.context

    private fun runCommand(vararg argv: String): Int = runCatching {
        val p = ProcessBuilder(*argv).redirectErrorStream(true).start()
        p.inputStream.readBytes()
        p.waitFor()
    }.getOrDefault(-1)

    private companion object {
        const val TAG = "ShellDisplay"
        const val NAME = "mew-ask"
        const val SHELL_PACKAGE = "com.android.shell"

        /** 建屏时的 owner 包名：必须是我们自己 uid（2000）对应的包。 */
        const val OWNER_PACKAGE = SHELL_PACKAGE
        const val USER_CURRENT = -2 // UserHandle.USER_CURRENT
        const val TAP_MS = 90L
        const val SWIPE_STEPS = 14
        const val IME_LOCAL = 0
        const val INJECT_ASYNC = 0
        const val INJECT_WAIT_FOR_RESULT = 1
        const val INJECT_WAIT_FOR_FINISH = 2

        /** injectAsciiText 的返回码。 */
        const val ASCII_NOT_SENT = 0
        const val ASCII_DISPATCHED = 1
        const val ASCII_UNCONFIRMED = 2

        const val START_OK = 0
        const val START_IN_USE_ON_MAIN = 1
        const val START_NOT_FOUND = 2
        const val START_ERROR = 3

        /** 只放行导航、方向、回车、退格这类键；音量、电源一律不碰。 */
        val ALLOWED_KEYS = setOf(
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_HOME, KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_DEL, KeyEvent.KEYCODE_FORWARD_DEL, KeyEvent.KEYCODE_TAB,
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_SPACE, KeyEvent.KEYCODE_ESCAPE,
        )

        // VirtualDisplay 的标志位。**全部写死数值**（Mika 同款口径）：
        // 这些常量大部分是 @hide 或在不同 API 级别数值不同，引用 DisplayManager 的字段
        // 会得到"看起来对、实际错"的值——第一次建屏被拒就是这个原因。
        const val FLAG_PUBLIC = 1 shl 0
        const val FLAG_OWN_CONTENT_ONLY = 1 shl 3
        const val FLAG_SUPPORTS_TOUCH = 1 shl 6
        const val FLAG_ROTATES_WITH_CONTENT = 1 shl 7
        const val FLAG_DESTROY_CONTENT_ON_REMOVAL = 1 shl 8
        const val FLAG_TRUSTED = 1 shl 10
        const val FLAG_OWN_DISPLAY_GROUP = 1 shl 11
        const val FLAG_ALWAYS_UNLOCKED = 1 shl 12
        const val FLAG_TOUCH_FEEDBACK_DISABLED = 1 shl 13
        const val FLAG_OWN_FOCUS = 1 shl 14
        const val FLAG_STEAL_TOP_FOCUS_DISABLED = 1 shl 16

        /**
         * Public API 的那几个常量加上隐藏的。可信屏才允许带 TRUSTED/OWN_DISPLAY_GROUP/ALWAYS_UNLOCKED，
         * 安卓 14 起可信屏才有 OWN_FOCUS/STEAL_TOP_FOCUS_DISABLED（后者让虚拟屏不抢主屏焦点）。
         */
        fun displayFlags(sdk: Int, trusted: Boolean): Int {
            var flags = FLAG_PUBLIC or FLAG_OWN_CONTENT_ONLY or
                FLAG_SUPPORTS_TOUCH or FLAG_ROTATES_WITH_CONTENT or FLAG_DESTROY_CONTENT_ON_REMOVAL
            if (sdk >= Build.VERSION_CODES.TIRAMISU) {
                flags = flags or FLAG_TOUCH_FEEDBACK_DISABLED
                if (trusted) flags = flags or FLAG_TRUSTED or FLAG_OWN_DISPLAY_GROUP or FLAG_ALWAYS_UNLOCKED
            }
            if (sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && trusted) {
                flags = flags or FLAG_OWN_FOCUS or FLAG_STEAL_TOP_FOCUS_DISABLED
            }
            return flags
        }
    }
}

/**
 * shell 进程里没有 Application 对象，Context 要靠 ActivityThread 自建。
 * Shizuku UserService 会传进来一个；app_process 助手要自己造（见 [ShellContext]）。
 */
internal object ContextHolder {
    @Volatile
    var context: Context? = null

    @Volatile
    var displayManager: DisplayManager? = null

    fun install(ctx: Context) {
        context = ctx
        // 不能用 getSystemService：那样拿到的是绑系统上下文的实例，包名与 shell uid 对不上
        displayManager = runCatching {
            val cls = DisplayManager::class.java
            val ctor = cls.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }
            ctor.newInstance(ctx)
        }.getOrNull() ?: ctx.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
    }
}
