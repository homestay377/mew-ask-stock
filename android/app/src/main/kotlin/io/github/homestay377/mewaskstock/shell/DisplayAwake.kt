package io.github.homestay377.mewaskstock.shell

import android.annotation.SuppressLint
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import java.lang.reflect.Method
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * 让虚拟屏一直亮着。
 *
 * 带 `VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP` 建的屏（Android 13 起的可信屏）**自成一组**，
 * 有自己的息屏计时；而注入的输入不算"用户操作"，放着不管到点这组屏就睡了：
 * 画面不再合成、截图不变、点按没反应。
 *
 * 做法：屏在的时候，每 [PERIOD_MS] 替它报一次用户操作。周期远小于系统允许的最短息屏时间。
 * 报给**默认显示组**会让用户的主屏也一直不灭，所以只在屏真的自成一组时才报。
 *
 * 口径来源：Mika `cap/phone/shell/DisplayAwake.kt`（Apache-2.0）。
 */
internal object DisplayAwake {

    private const val TAG = "DisplayAwake"

    /** 报一次用户操作的周期。 */
    const val PERIOD_MS = 4_000L

    /** PowerManager.USER_ACTIVITY_EVENT_TOUCH。 */
    private const val EVENT_TOUCH = 2

    /** Display.DEFAULT_DISPLAY_GROUP（隐藏常量）。 */
    private const val DEFAULT_DISPLAY_GROUP = 0

    private val timer = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "vd-display-awake").apply { isDaemon = true }
    }

    private val running = HashMap<Int, ScheduledFuture<*>?>()

    /** 报不了就只试一次，之后屏照常用（不反复刷异常、不空转定时器）。 */
    @Volatile
    private var unavailable = false

    /** IPowerManager 上按屏报用户操作的那个重载；只有不带屏号的老重载时为 null。 */
    private val userActivity: Pair<Any, Method>? by lazy {
        runCatching {
            val binder = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String::class.java)
                .invoke(null, "power") as IBinder
            val power = Class.forName("android.os.IPowerManager\$Stub")
                .getMethod("asInterface", IBinder::class.java)
                .invoke(null, binder)!!
            val m = power.javaClass.methods.firstOrNull {
                it.name == "userActivity" && it.parameterTypes.contentEquals(PER_DISPLAY)
            } ?: error("no per-display userActivity")
            power to m
        }.onFailure { Log.w(TAG, "display keep-awake unavailable: ${it.message}") }.getOrNull()
    }

    private val PER_DISPLAY = arrayOf<Class<*>>(
        Int::class.javaPrimitiveType!!,
        Long::class.javaPrimitiveType!!,
        Int::class.javaPrimitiveType!!,
        Int::class.javaPrimitiveType!!,
    )

    /**
     * 这块屏要不要报：只有它真的自成一组时才报（读不到组号时按建屏时带没带标志算）。
     */
    fun needed(flags: Int, ownGroupFlag: Int, groupId: Int?): Boolean =
        flags and ownGroupFlag != 0 && (groupId ?: -1) != DEFAULT_DISPLAY_GROUP

    /** 读这块屏所在的显示组；读不到为 null。 */
    @SuppressLint("PrivateApi")
    fun displayGroup(displayId: Int): Int? = runCatching {
        val global = Class.forName("android.hardware.display.DisplayManagerGlobal")
            .getMethod("getInstance").invoke(null)!!
        val info = global.javaClass.getMethod("getDisplayInfo", Int::class.java).invoke(global, displayId)!!
        info.javaClass.getField("displayGroupId").getInt(info)
    }.getOrNull()

    fun start(displayId: Int) {
        if (unavailable) return
        val f = timer.scheduleWithFixedDelay(
            {
                if (displayId < 0 || !poke(displayId)) giveUp()
            },
            0,
            PERIOD_MS,
            TimeUnit.MILLISECONDS,
        )
        synchronized(running) {
            running.put(displayId, f)?.cancel(false)
        }
        // 第一次就报不了时 giveUp 可能早于登记跑完：补停一次
        if (unavailable) stopAll()
    }

    fun stop(displayId: Int) {
        synchronized(running) { running.remove(displayId) }?.cancel(false)
    }

    fun stopAll() {
        val all = synchronized(running) { running.values.toList().also { running.clear() } }
        all.forEach { it?.cancel(false) }
    }

    private fun poke(displayId: Int): Boolean {
        val (power, method) = userActivity ?: return false
        return try {
            method.invoke(power, displayId, SystemClock.uptimeMillis(), EVENT_TOUCH, 0)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "userActivity failed, display keep-awake off", t)
            false
        }
    }

    private fun giveUp() {
        unavailable = true
        stopAll()
    }
}