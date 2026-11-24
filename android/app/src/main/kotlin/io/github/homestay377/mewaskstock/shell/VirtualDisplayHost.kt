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
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import io.github.homestay377.mewaskstock.ocr.ScreenOcr
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

        // 不建本地 skeleton 屏：Mika 的 AgentDisplay 只用 shell 那块屏。
        // 两块 Display 抢同一个 Surface 会互相清帧，画面停在第一帧或全黑。
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
        runCatching { reader?.close() }
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

    /**
     * 读虚拟屏上的文字：本机 OCR，**不需要无障碍**。
     *
     * 返回的行带像素矩形；调用方要把矩形换算成「虚拟屏坐标」（用 [frameSize] 和预览缩放比）。
     */
    suspend fun ocrTextLines(): List<ScreenOcr.Line> {
        val bmp = preview(OCR_MAX_SHORT_SIDE) ?: return emptyList()
        return ScreenOcr.read(bmp)
    }

    /** 当前帧的原始尺寸；OCR 用的是缩放后的图，换算坐标要用它。 */
    fun frameSize(): Pair<Int, Int>? {
        val f = frame ?: return null
        return f.width to f.height
    }

    /** OCR 输入图的短边上限，判坐标换算用。 */
    fun ocrInputShortSide(): Int = OCR_MAX_SHORT_SIDE

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

        /** OCR 输入短边：1080 足够认清行情文字，再大会明显变慢。 */
        const val OCR_MAX_SHORT_SIDE = 800
    }
}
