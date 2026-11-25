package io.github.homestay377.mewaskstock

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 保活 + 悬浮图标。
 *
 * 为什么需要：小米这类系统在后台会按"重要程度"收进程，普通后台应用待久了就被清掉，
 * 虚拟屏、Shizuku 绑定、无障碍连接一起断。Android 上真正管用的是**前台服务**（带常驻通知），
 * 再配一个悬浮图标让用户随时看得到"它现在在干什么"、点一下就能回到 App。
 *
 * 悬浮图标本身是 `TYPE_APPLICATION_OVERLAY`，需要 `SYSTEM_ALERT_WINDOW`。
 * 用户不该自己去系统设置里翻：先用 shell 身份 `appops set ... allow` 直接授权
 * （和自动开无障碍同一套路），拿不到才退回去开系统授权页。
 */
class KeepAliveBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val status = call.argument<String>("status").orEmpty()
                Thread {
                    val overlay = ensureOverlay()
                    ChatGenerationService.hold(context, status)
                    main.post {
                        if (overlay) FloatingBadge.show(context, status)
                        result.success(mapOf("ok" to true, "overlay" to overlay))
                    }
                }.start()
            }

            "status" -> {
                val status = call.argument<String>("status").orEmpty()
                ChatGenerationService.updateStatus(context, status)
                main.post { FloatingBadge.update(status) }
                result.success(mapOf("ok" to true))
            }

            "stop" -> {
                ChatGenerationService.release(context)
                main.post { FloatingBadge.hide() }
                result.success(mapOf("ok" to true))
            }

            "badge" -> {
                // 只控制悬浮图标，不动保活
                val on = call.argument<Boolean>("on") ?: false
                val status = call.argument<String>("status").orEmpty()
                if (on) {
                    Thread {
                        val overlay = ensureOverlay()
                        main.post {
                            if (overlay) FloatingBadge.show(context, status)
                            result.success(mapOf("ok" to true, "overlay" to overlay))
                        }
                    }.start()
                } else {
                    main.post { FloatingBadge.hide() }
                    result.success(mapOf("ok" to true))
                }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * 有没有悬浮窗权限。授权本身由虚拟屏通道的 `grant_overlay` 用 shell 身份做掉
     * （那边拿得到 ShellRouter），这里只负责检查，拿不到才把用户送到系统授权页。
     */
    private fun ensureOverlay(): Boolean {
        if (Settings.canDrawOverlays(context)) return true
        // 退路：把用户送到授权页（只有这一次需要手动）
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
        return false
    }

    companion object {
        const val CHANNEL = "io.github.homestay377.mewaskstock/keep_alive"
    }
}

/** 一颗可拖动的悬浮图标：App 图标 + 一句"正在干什么"。 */
internal object FloatingBadge {

    private var view: View? = null
    private var label: TextView? = null
    private var windowManager: WindowManager? = null
    private var params: WindowManager.LayoutParams? = null

    fun show(context: Context, status: String) {
        if (!Settings.canDrawOverlays(context)) return
        if (view != null) {
            update(status)
            return
        }
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        val density = context.resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(6), dp(12), dp(6))
            background = GradientDrawable().apply {
                cornerRadius = dp(22).toFloat()
                setColor(0xCC1A1A1A.toInt())
                setStroke(dp(1), 0x33FFFFFF)
            }
        }
        val icon = ImageView(context).apply {
            setImageDrawable(runCatching { context.packageManager.getApplicationIcon(context.packageName) }.getOrNull())
            layoutParams = LinearLayout.LayoutParams(dp(30), dp(30))
        }
        val text = TextView(context).apply {
            this.text = status.ifBlank { "AI 正在操作" }
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 12f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(dp(8), 0, 0, 0)
            maxWidth = dp(180)
        }
        row.addView(icon)
        row.addView(text)

        val p = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(12)
            y = (context.resources.displayMetrics.heightPixels * 0.55).toInt()
        }

        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        row.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY
                    startX = p.x; startY = p.y
                    moved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (kotlin.math.abs(dx) > dp(6) || kotlin.math.abs(dy) > dp(6)) moved = true
                    if (moved) {
                        p.x = startX + dx.toInt()
                        p.y = startY + dy.toInt()
                        runCatching { wm.updateViewLayout(row, p) }
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) openApp(context)
                }
            }
            true
        }

        runCatching { wm.addView(row, p) }.onFailure { return }
        windowManager = wm
        params = p
        view = row
        label = text
    }

    fun update(status: String) {
        val t = label ?: return
        t.post { t.text = status.ifBlank { "AI 正在操作" } }
    }

    fun hide() {
        val v = view ?: return
        val wm = windowManager
        runCatching { wm?.removeView(v) }
        view = null
        label = null
        windowManager = null
        params = null
    }

    @SuppressLint("MissingPermission")
    private fun openApp(context: Context) {
        runCatching {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            context.startActivity(intent)
        }
    }
}