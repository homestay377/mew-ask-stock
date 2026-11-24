package io.github.homestay377.mewaskstock.shell

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import rikka.shizuku.Shizuku

/**
 * Shizuku 通道（A 路线）：检查安装/运行/授权，绑定 UserService 拿到 [IShellDisplay]。
 *
 * 只用官方 API（`dev.rikka.shizuku`），不反射 Shizuku 内部、不自作主张去启动 Shizuku。
 * 服务重连（Shizuku 重启）后会重新绑定；App 侧只需看 [state]。
 */
class ShizukuChannel(private val context: Context) {

    enum class Phase { NOT_INSTALLED, NOT_RUNNING, NEED_PERMISSION, BINDING, READY, FAILED }

    data class Snapshot(val phase: Phase, val detail: String? = null) {
        val ready: Boolean get() = phase == Phase.READY
    }

    @Volatile
    private var shell: IShellDisplay? = null

    @Volatile
    private var snapshot = Snapshot(Phase.NOT_INSTALLED)

    private var listener: ((Snapshot) -> Unit)? = null
    private var bindRequested = false
    private val binderReceived = Shizuku.OnBinderReceivedListener { refresh() }
    private val binderDead = Shizuku.OnBinderDeadListener { refresh() }
    private val permissionResult = Shizuku.OnRequestPermissionResultListener { code, granted ->
        if (code == REQUEST_CODE) refresh()
        if (granted == PackageManager.PERMISSION_GRANTED) bind()
    }
    private var watching = false

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

    /** 重新看一遍状态；必要时重绑。 */
    fun refresh() {
        val next = when {
            !installed() -> Snapshot(Phase.NOT_INSTALLED)
            !binderAlive() -> Snapshot(Phase.NOT_RUNNING)
            !hasPermission() -> Snapshot(Phase.NEED_PERMISSION)
            shell != null -> Snapshot(Phase.READY)
            else -> Snapshot(Phase.BINDING)
        }
        publish(next)
        if (next.phase == Phase.BINDING && !bindRequested) bind()
    }

    /** 把状态推给上层（也用于 UI 主动刷新）。 */
    fun current(): Snapshot = snapshot

    /** 请求授权（会弹 Shizuku 的对话框），随后自动绑定。 */
    fun requestPermission() {
        runCatching { Shizuku.requestPermission(REQUEST_CODE) }
            .onFailure { Log.w(TAG, "requestPermission failed", it) }
    }

    /** 打开 Shizuku 本体，让用户去启动服务。 */
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
            publish(Snapshot(Phase.FAILED, it.message))
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            bindRequested = false
            if (binder == null) {
                publish(Snapshot(Phase.FAILED, "null binder"))
                return
            }
            val iface = IShellDisplay.Stub.asInterface(binder)
            // 确认 binder 真的来自 shell 身份（uid 2000 或 root 0）
            val who = runCatching { iface?.identity()?.firstOrNull() }.getOrNull()
            if (who != null && who != 2000 && who != 0) {
                Log.w(TAG, "refusing binder from uid $who")
                shell = null
                publish(Snapshot(Phase.FAILED, "unexpected uid $who"))
                return
            }
            shell = iface
            publish(Snapshot(Phase.READY, "uid=$who"))
            Log.i(TAG, "Shizuku shell bound (uid=$who)")
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            shell = null
            bindRequested = false
            publish(Snapshot(Phase.BINDING, "disconnected"))
            refresh()
        }
    }

    private val userServiceArgs: Shizuku.UserServiceArgs by lazy {
        Shizuku.UserServiceArgs(ComponentName(context.packageName, ShizukuShellUserService::class.java.name))
            .daemon(false)
            .processNameSuffix("shell")
            .version(BuildConfigVersion())
    }

    @Suppress("DEPRECATION")
    private fun BuildConfigVersion(): Int = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionCode
    }.getOrDefault(1)

    private fun installed(): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(SHIZUKU_PACKAGE, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(SHIZUKU_PACKAGE, 0)
        }
        true
    }.getOrDefault(false)

    private fun binderAlive(): Boolean = runCatching {
        Shizuku.pingBinder()
    }.getOrDefault(false)

    private fun hasPermission(): Boolean = runCatching {
        !Shizuku.isPreV11() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    private companion object {
        const val TAG = "ShizukuChannel"
        const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        const val REQUEST_CODE = 7001
    }
}
