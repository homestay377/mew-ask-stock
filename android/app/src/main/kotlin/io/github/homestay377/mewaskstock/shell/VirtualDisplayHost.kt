package io.github.homestay377.mewaskstock.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import kotlin.math.max
import kotlin.math.min

/**
 * App 侧的虚拟屏宿主：拿到 [IShellDisplay] 后建屏、收画面、把画面给 UI 看。
 *
 * 画面只用来看（预览、必要时给视觉模型）；**数据以无障碍树为准** ——
 * 树能拿到文字与 ref，图像只能猜，两者成本和可靠性差一个量级。
 *
 * 帧率刻意压到 ≤10/秒：虚拟屏的每一帧都是整屏合成，太高会明显吃 CPU 和电。
 */
class VirtualDisplayHost(private val context: Context) {

    data class Frame(val bitmap: Bitmap, val atMs: Long)

    @Volatile
    var displayId: Int = -1
        private set

    @Volatile
    private var frame: Bitmap? = null

    private var reader: ImageReader? = null
    private var skeleton: VirtualDisplay? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var pending = false
    private var lastProcessed = 0L

    val running: Boolean get() = displayId >= 0
    val currentFrame: Bitmap? get() = frame

    /**
     * 建屏。[service] 是 shell 身份的服务。
     * 尺寸按主屏像素走（App 在虚拟屏上看到的就是同样大小的界面），DPI 跟随系统。
     */
    fun start(service: IShellDisplay): Boolean {
        if (running) return true
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val metrics = context.resources.displayMetrics
        val w = metrics.widthPixels.takeIf { it > 0 } ?: 1080
        val h = metrics.heightPixels.takeIf { it > 0 } ?: 2400
        val dpi = metrics.densityDpi.takeIf { it in 72..1000 } ?: 420

        val t = HandlerThread("vd-frames").apply { start() }
        thread = t
        val hd = Handler(t.looper)
        handler = hd
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader = r

        // 让画面也能被本地 SurfaceFlinger 合成（有些系统要求 Surface 处于"已连接"状态才开始出帧）
        skeleton = runCatching {
            dm.createVirtualDisplay("mew-ask-skeleton", w, h, dpi, r.surface, 0)
        }.getOrNull()

        r.setOnImageAvailableListener({ onFrame(it) }, hd)

        val id = runCatching { service.createDisplay(r.surface, w, h, dpi) }.getOrDefault(-1)
        if (id < 0) {
            Log.w(TAG, "createDisplay failed")
            stop(service)
            return false
        }
        displayId = id
        Log.i(TAG, "virtual display $id (${w}x$h @$dpi)")
        return true
    }

    fun stop(service: IShellDisplay?) {
        val id = displayId
        displayId = -1
        frame = null
        runCatching { if (id >= 0) service?.releaseDisplay(id) }
        runCatching { skeleton?.release() }
        runCatching { reader?.close() }
        skeleton = null
        reader = null
        thread?.quitSafely()
        thread = null
        handler = null
    }

    /** 把当前帧缩成给定短边，供预览/视觉模型用。 */
    fun preview(maxShortSide: Int = 720): Bitmap? {
        val src = frame ?: return null
        val short = min(src.width, src.height)
        if (short <= maxShortSide) return src
        val scale = maxShortSide.toFloat() / short
        val w = max(1, (src.width * scale).toInt())
        val h = max(1, (src.height * scale).toInt())
        return Bitmap.createScaledBitmap(src, w, h, true)
    }

    /** 没有无障碍树可读时（部分 App 不暴露），用本机 OCR 兜底读文字。返回每行文字的矩形与内容。 */
    fun ocrTextLines(maxLines: Int = 120): List<Triple<String, Rect, Array<Int>>> {
        val bmp = preview(1080) ?: return emptyList()
        // 占位：真正的 OCR 用 ML Kit 或系统 TextClassifier；P0 先返回空，
        // 让上层继续走无障碍树（树读不到时再考虑接 OCR）。
        return emptyList()
    }

    private fun onFrame(r: ImageReader) {
        if (displayId < 0) return
        // 限速：不足 100ms 就记下来，等下一轮取最新帧（旧帧自动丢弃）
        val now = SystemClock.uptimeMillis()
        val wait = 100 - (now - lastProcessed)
        if (wait > 0) {
            if (!pending) {
                pending = true
                handler?.postDelayed({ pending = false; drain(r) }, wait)
            }
            return
        }
        drain(r)
    }

    private fun drain(r: ImageReader) {
        lastProcessed = SystemClock.uptimeMillis()
        val image = runCatching { r.acquireLatestImage() }.getOrNull() ?: return
        try {
            val plane = image.planes.firstOrNull() ?: return
            val buffer = plane.buffer
            val pixelStride = plane.pixelStride
            val rowStride = plane.rowStride
            val rowPadding = rowStride - pixelStride * image.width
            val w = image.width + rowPadding / pixelStride
            val padded = Bitmap.createBitmap(w, image.height, Bitmap.Config.ARGB_8888)
            padded.copyPixelsFromBuffer(buffer)
            val cropped = if (rowPadding == 0) padded else Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
            frame = cropped
        } finally {
            image.close()
        }
    }

    private companion object {
        const val TAG = "VirtualDisplayHost"
    }
}
