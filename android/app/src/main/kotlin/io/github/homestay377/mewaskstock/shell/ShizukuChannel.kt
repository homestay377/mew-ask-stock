package io.github.homestay377.mewaskstock.shell

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import rikka.shizuku.Shizuku

/**
 * Shizuku 通道（A 路线）。
 *
 * 只用官方 API；关键在**判断顺序**，这一条踩过坑：
 *
 * ```
 * pingBinder()      ← 服务在不在跑
 *   ↓ 在跑
 * checkSelfPermission()  ← 这个 App 有没有被授权
 * ```
 *
 * 反过来先查权限会出现：服务活着但还没绑 UserService 时 `checkSelfPermission()`
 * 返回 DENIED，App 就误报"没授权"，而用户明明刚在 Shizuku 里点过允许。
 * 所以这里**先判在不在跑，再判授权**，并且把两个值分开暴露，界面能说清缺哪一步。
 */
class ShizukuChannel(private val context: Context) {

    enum class Phase { NOT_INSTALLED, NOT_RUNNING, NEED_PERMISSION, BINDING, READY, FAILED }

    /**
     * [running] 服务在不在跑；[granted] 授权状态。
     * 两个分开报，别把"服务没起来"说成"没授权"。
     */
    data class Snapshot(
        val phase: Phase,
        val running: Boolean = false,
        val granted: Boolean = false,
        val detail: String? = null,
    ) {
        val ready: Boolean get() = phase == Phase.READY

        /** 给用户看的一句话，准确说出缺哪一步。 */
        fun describe(): String = when (phase) {
            Phase.NOT_INSTALLED -> "没装 Shizuku"
            Phase.NOT_RUNNING -> "Shizuku 服务没在运行（打开 Shizuku 点「启动服务」）"
            Phase.NEED_PERMISSION -> "还没给问股授权（在 Shizuku 的应用管理里点允许）"
            Phase.BINDING -> "正在绑定 Shizuku"
            Phase.READY -> "Shizuku 已就绪"
            Phase.FAILED -> detail ?: "Shizuku 绑定失败"
        }
    }

    @Volatile
    private var shell: IShellDisplay? = null

    @Volatile
    private var snapshot = Snapshot(Phase.NOT_INSTALLED)

    private var listener: ((Snapshot) -> Unit)? = null
    private var bindRequested = false
    private var watching = false

    private val binderReceived = Shizuku.OnBinderReceivedListener {
        Log.i(TAG, "shizuku binder received")
        refresh()
    }

    private val binderDead = Shizuku.OnBinderDeadListener {
        Log.i(TAG, "shizuku binder dead")
        shell = null
        bindRequested = false
        refresh()
    }

    private val permissionResult = Shizuku.OnRequestPermissionResultListener { code, granted ->
        Log.i(TAG, "shizuku permission result code=$code granted=$granted")
        if (code == REQUEST_CODE) {
            refresh()
            if (granted == android.content.pm.PackageManager.PERMISSION_GRANTED) bind()
        }
    }

    /** 开始监听 Shizuku 状态（App 启动时调一次）。 */
    fun watch(onChange: (Snapshot) -> Unit) {
        listener = onChange
        if (watching) return
        watching = true
        runCatching {
            Shizuku.addBinderReceivedListenerSticky(binderReceived)
            Shizuku.addBinderDeadListener(binderDead)
            Shizuku.addRequestPermissionResultListener(permissionResult)
        }.onFailure { Log.w(TAG, "cannot watch Shizuku", it) }
        refresh()
    }

    fun unwatch() {
        if (!watching) return
        watching = false
        runCatching {
            Shizuku.removeBinderReceivedListener(binderReceived)
            Shizuku.removeBinderDeadListener(binderDead)
            Shizuku.removeRequestPermissionResultListener(permissionResult)
        }
        listener = null
    }

    /**
     * 重新看一遍状态。
     *
     * 顺序很重要：先 `pingBinder()`（服务在不在跑），再 `checkSelfPermission()`（授没授权）。
     * 反过来的话，服务活着但还没绑 UserService 时权限会读成 DENIED，用户刚点过允许也会被说成"没授权"。
     */
    fun refresh(): Snapshot {
        if (!installed()) {
            publish(Snapshot(Phase.NOT_INSTALLED))
            return snapshot
        }
        val running = binderAlive()
        if (!running) {
            publish(Snapshot(Phase.NOT_RUNNING, running = false, granted = false))
            return snapshot
        }
        val granted = hasPermission()
        if (!granted) {
            publish(Snapshot(Phase.NEED_PERMISSION, running = true, granted = false))
            return snapshot
        }
        if (shell != null) {
            publish(Snapshot(Phase.READY, running = true, granted = true, detail = "uid=${runCatching { shell?.identity()?.firstOrNull() }.getOrNull()}"))
            return snapshot
        }
        publish(Snapshot(Phase.BINDING, running = true, granted = true))
        if (!bindRequested) bind()
        return snapshot
    }

    fun current(): Snapshot = snapshot

    /** 请求授权（会弹 Shizuku 对话框）。 */
    fun requestPermission() {
        runCatching {
            if (isPreV11()) {
                // Shizuku v11 之前的授权是装 App 时给的，不需要请求
                Log.i(TAG, "pre-v11 Shizuku: permission is granted at install")
                return
            }
            Shizuku.requestPermission(REQUEST_CODE)
        }.onFailure { Log.w(TAG, "requestPermission failed", it) }
    }

    /** 打开 Shizuku 本体，让用户去启动服务 / 改授权。 */
    fun openShizukuApp(): Boolean = runCatching {
        context.packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE)?.let {
            it.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(it)
            true
        } ?: false
    }.getOrDefault(false)

    /** 已绑定的服务；没就绪为 null。 */
    fun service(): IShellDisplay? = shell

    private fun publish(s: Snapshot) {
        if (s == snapshot) return
        snapshot = s
        Log.i(TAG, "state ${s.phase} running=${s.running} granted=${s.granted} ${s.detail ?: ""}")
        runCatching { listener?.invoke(s) }
    }

    private fun bind() {
        if (bindRequested) return
        if (!hasPermission()) {
            requestPermission()
            return
        }
        bindRequested = true
        runCatching {
            Shizuku.bindUserService(userServiceArgs, connection)
        }.onFailure {
            Log.w(TAG, "bindUserService failed", it)
            bindRequested = false
            publish(Snapshot(Phase.FAILED, running = true, granted = true, detail = it.message))
        }
    }

    private val connection = object : android.content.ServiceConnection {
        override fun onServiceConnected(name: android.content.ComponentName?, binder: android.os.IBinder?) {
            bindRequested = false
            if (binder == null) {
                publish(Snapshot(Phase.FAILED, running = true, granted = true, detail = "null binder"))
                return
            }
            val iface = IShellDisplay.Stub.asInterface(binder)
            // 确认 binder 真的来自 shell 身份（uid 2000）或 root（uid 0）
            val who = runCatching { iface?.identity()?.firstOrNull() }.getOrNull()
            if (who != null && who != 2000 && who != 0) {
                Log.w(TAG, "refusing binder from uid $who")
                shell = null
                publish(Snapshot(Phase.FAILED, running = true, granted = true, detail = "binder 来自 uid $who，不是 shell"))
                return
            }
            shell = iface
            publish(Snapshot(Phase.READY, running = true, granted = true, detail = "uid=$who"))
            Log.i(TAG, "Shizuku shell bound (uid=$who)")
        }

        override fun onServiceDisconnected(name: android.content.ComponentName?) {
            shell = null
            bindRequested = false
            publish(Snapshot(Phase.BINDING, running = true, granted = true, detail = "disconnected"))
            refresh()
        }
    }

    private val userServiceArgs: Shizuku.UserServiceArgs by lazy {
        Shizuku.UserServiceArgs(
            android.content.ComponentName(context.packageName, ShizukuShellUserService::class.java.name),
        )
            .daemon(false)
            .processNameSuffix("shell")
            .version(versionCode())
    }

    @Suppress("DEPRECATION")
    private fun versionCode(): Int = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionCode
    }.getOrDefault(1)

    private fun installed(): Boolean = runCatching {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(
                SHIZUKU_PACKAGE,
                android.content.pm.PackageManager.PackageInfoFlags.of(0),
            )
        } else {
            context.packageManager.getPackageInfo(SHIZUKU_PACKAGE, 0)
        }
        true
    }.getOrDefault(false)

    private fun binderAlive(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    private fun isPreV11(): Boolean = runCatching { Shizuku.isPreV11() }.getOrDefault(false)

    private fun hasPermission(): Boolean = runCatching {
        if (Shizuku.isPreV11()) return true
        Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    private companion object {
        const val TAG = "ShizukuChannel"
        const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        const val REQUEST_CODE = 7001
    }
}
