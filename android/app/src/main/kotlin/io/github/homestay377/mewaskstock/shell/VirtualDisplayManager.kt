package io.github.homestay377.mewaskstock.shell

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * 虚拟屏的会话：一个进程里只有一块（够用，也避免并行任务互抢 App）。
 *
 * 职责：保证「服务就绪 → 建屏 → 能启动 App」这条链路，并把结果告诉上层。
 * 退出时释放屏，不留下一个孤儿显示器（那会让后续建屏失败）。
 */
@SuppressLint("StaticFieldLeak")
object VirtualDisplayManager {

    enum class Phase { IDLE, NOT_READY, STARTING, READY, FAILED }

    data class Status(
        val phase: Phase,
        val displayId: Int = -1,
        val shellUid: Int = -1,
        val detail: String? = null,
    ) {
        val ready: Boolean get() = phase == Phase.READY && displayId >= 0
        fun toMap(): Map<String, Any?> = mapOf(
            "ok" to ready,
            "phase" to phase.name.lowercase(),
            "displayId" to displayId,
            "shellUid" to shellUid,
            "detail" to detail,
        )
    }

    @Volatile
    private var status = Status(Phase.IDLE)

    private var host: VirtualDisplayHost? = null
    private val main = Handler(Looper.getMainLooper())

    fun current(): Status = status

    /** 由 [ShellBridge] 在服务就绪/断开时调用。 */
    fun onShellChanged(service: IShellDisplay?) {
        if (service == null && status.ready) {
            // shell 没了，虚拟屏也就没了
            host?.stop(null)
            host = null
            status = Status(Phase.NOT_READY, detail = "shell disconnected")
        }
    }

    /**
     * 确保屏建好。[service] 为空说明 shell 服务还没连上。
     * 失败时把原因放进 [Status.detail]，让模型/用户知道是 Shizuku 没开还是系统拒绝。
     */
    fun ensure(context: Context, service: IShellDisplay?): Status {
        if (status.ready && host != null) return status
        if (service == null) {
            status = Status(Phase.NOT_READY, detail = "shell service unavailable (Shizuku off or not bound)")
            return status
        }
        status = Status(Phase.STARTING)
        val uid = runCatching { service.identity().firstOrNull() }.getOrNull() ?: -1
        if (uid != 2000 && uid != 0) {
            status = Status(Phase.FAILED, shellUid = uid, detail = "shell service runs as uid $uid, expected 2000 or 0")
            return status
        }
        val h = VirtualDisplayHost(context)
        val ok = runCatching { h.start(service) }.getOrElse {
            Log.w(TAG, "start virtual display failed", it)
            false
        }
        if (!ok) {
            status = Status(Phase.FAILED, shellUid = uid, detail = "createVirtualDisplay rejected")
            return status
        }
        host = h
        status = Status(Phase.READY, displayId = h.displayId, shellUid = uid)
        Log.i(TAG, "virtual display ready id=${h.displayId} shellUid=$uid")
        return status
    }

    fun frame(): android.graphics.Bitmap? = host?.currentFrame

    /** 当前帧的 PNG（给视觉模型/用户看）。 */
    fun screenshotPng(maxShortSide: Int = 720): ByteArray? {
        val bmp = host?.preview(maxShortSide) ?: return null
        return java.io.ByteArrayOutputStream().use { out ->
            bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 90, out)
            out.toByteArray()
        }
    }

    fun stop(service: IShellDisplay?) {
        host?.stop(service)
        host = null
        status = Status(Phase.IDLE)
    }

    private const val TAG = "VirtualDisplayMgr"
}
