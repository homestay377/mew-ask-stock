package io.github.homestay377.mewaskstock.ocr

import android.graphics.Bitmap
import android.graphics.Rect
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/**
 * 本机 OCR：把虚拟屏的一帧认成「一行文字 + 矩形」。
 *
 * 为什么需要它：虚拟屏的画面只能"看"，系统不会告诉我们上面写了什么。
 * 无障碍树能给，但用户不一定开；而 OCR 不需要任何额外权限、离线可用，
 * 是 Mika 的默认读屏方式（`PhoneOcr`），也是这里的主路径。
 *
 * 中英两套模型并行跑：行情界面是中英数字混排（"上证指数 3200.11 +0.52%"），
 * 只用英文模型会把中文整行丢掉。
 */
object ScreenOcr {

    private const val TAG = "ScreenOcr"

    /** 一行识别结果；[rect] 是这一行在传入图片里的像素矩形。 */
    data class Line(val text: String, val rect: Rect)

    private val chinese by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }
    private val latin by lazy {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }

    /**
     * 认一帧。[bitmap] 不会被回收（调用方可能还要用）。
     * 两套模型都失败时返回空表，并把错误记进日志——**不当成"屏幕上没字"**。
     */
    suspend fun read(bitmap: Bitmap): List<Line> {
        if (bitmap.isRecycled || bitmap.width <= 0 || bitmap.height <= 0) return emptyList()
        val image = InputImage.fromBitmap(bitmap, 0)
        val zh = runCatching { recognize(chinese, image) }
            .onFailure { Log.w(TAG, "chinese OCR failed", it) }
            .getOrDefault(emptyList())
        val en = runCatching { recognize(latin, image) }
            .onFailure { Log.w(TAG, "latin OCR failed", it) }
            .getOrDefault(emptyList())
        // 中文优先，英文补上中文模型漏掉的纯英文/数字行（按矩形重叠去重）
        val merged = ArrayList<Line>(zh)
        for (line in en) {
            val dup = merged.any { l ->
                val a = l.rect
                val b = line.rect
                val overlapW = (minOf(a.right, b.right) - maxOf(a.left, b.left)).coerceAtLeast(0)
                val overlapH = (minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)).coerceAtLeast(0)
                val inter = overlapW.toLong() * overlapH
                val smaller = minOf(a.width().toLong() * a.height(), b.width().toLong() * b.height()).coerceAtLeast(1)
                inter * 100 / smaller >= 60 // 六成以上重叠算同一行
            }
            if (!dup) merged.add(line)
        }
        // 从上到下、从左到右，模型读数顺序和屏幕一致
        return merged.sortedWith(compareBy({ it.rect.top }, { it.rect.left }))
    }

    private suspend fun recognize(
        recognizer: com.google.mlkit.vision.text.TextRecognizer,
        image: InputImage,
    ): List<Line> = suspendCoroutine { cont ->
        recognizer.process(image)
            .addOnSuccessListener { result ->
                val lines = ArrayList<Line>()
                for (block in result.textBlocks) {
                    for (line in block.lines) {
                        val text = line.text.trim()
                        if (text.isEmpty()) continue
                        val b = line.boundingBox ?: continue
                        lines.add(Line(text, Rect(b)))
                    }
                }
                cont.resume(lines)
            }
            .addOnFailureListener { cont.resume(emptyList()) }
    }

    /** 关掉识别器（进程退出前调一次即可）。 */
    fun close() {
        runCatching { chinese.close() }
        runCatching { latin.close() }
    }
}
