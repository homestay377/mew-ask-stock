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
            // 把 shell 侧记下的具体原因带出来（哪一档标志位、什么异常），别再只说"被拒"
            val why = runCatching { service.lastError() }.getOrNull()
            status = Status(Phase.FAILED, shellUid = uid, detail = why ?: "createVirtualDisplay rejected")
            Log.w(TAG, "createDisplay failed: ${status.detail}")
            return status
        }
        host = h
        status = Status(Phase.READY, displayId = h.displayId, shellUid = uid)
        Log.i(TAG, "virtual display ready id=${h.displayId} shellUid=$uid")
        return status
    }

    fun frame(): android.graphics.Bitmap? = host?.currentFrame

    /**
     * 用本机 OCR 读虚拟屏上的文字，**不依赖无障碍**。
     *
     * 坐标换算：OCR 跑在缩放后的预览图上，返回的矩形要按 预览/整帧 的比例放大回虚拟屏像素，
     * 再取中心点给 `injectTap` 用。
     */
    suspend fun ocrLines(): List<OcrLine> {
        val h = host ?: return emptyList()
        val lines = runCatching { h.ocrTextLines() }.getOrElse {
            Log.w(TAG, "ocr failed", it)
            return emptyList()
        }
        if (lines.isEmpty()) return emptyList()
        val (fw, fh) = h.frameSize() ?: return emptyList()
        val shortSide = h.ocrInputShortSide()
        val scale = if (fw <= 0 || fh <= 0) 1f else {
            // 预览把短边压到 shortSide，长边等比例；用整帧短边反推缩放比
            val frameShort = minOf(fw, fh)
            if (frameShort <= shortSide) 1f else frameShort.toFloat() / shortSide
        }
        return lines.map { l ->
            val cx = ((l.rect.left + l.rect.right) / 2f * scale).toInt()
            val cy = ((l.rect.top + l.rect.bottom) / 2f * scale).toInt()
            OcrLine(
                text = l.text,
                cx = cx,
                cy = cy,
                left = (l.rect.left * scale).toInt(),
                top = (l.rect.top * scale).toInt(),
                right = (l.rect.right * scale).toInt(),
                bottom = (l.rect.bottom * scale).toInt(),
            )
        }
    }

    /** 一行 OCR 结果，坐标已换算成虚拟屏像素。 */
    data class OcrLine(
        val text: String,
        val cx: Int,
        val cy: Int,
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "text" to text,
            "center" to listOf(cx, cy),
            "bounds" to listOf(left, top, right, bottom),
        )
    }

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
