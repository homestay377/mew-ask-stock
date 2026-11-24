package io.github.homestay377.mewaskstock.miniphone

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo

/**
 * 手机操控的无障碍服务。
 *
 * 能力范围（P0）：读屏（无障碍树 → 扁平元素表）、点击 / 长按 / 滑动 / 输入、全局按键（返回、主页、最近任务）。
 * 不做：虚拟屏、shell/root 身份、应用拉起（用 Intent，不靠无障碍）。
 *
 * 用户在「设置 → 无障碍 → 问股操控」里手动开启。AI 工具只在 [instance] 非空时下发给模型。
 *
 * 故意**不依赖 kotlinx.coroutines**：这里所有 API 都是"下发即返回"的同步调用，
 * 手势完成与否由读屏结果体现，Dart 侧本来也是"动作之后再 observe"。
 */
class MiniPhoneAccessibility : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        serviceInfo?.let { info ->
            // 很多 App 把展示结果的控件标成「对无障碍不重要」，不读它们就等于看不见
            var flags = info.flags or AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
            if (flags != info.flags) {
                info.flags = flags
                serviceInfo = info
            }
        }
        instance = this
        Log.i(TAG, "accessibility connected")
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        Log.i(TAG, "accessibility unbound")
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // P0 不订阅事件；读屏按需拉取
    }

    override fun onInterrupt() {}

    // ---------- 读屏 ----------

    fun windows(): List<AccessibilityWindowInfo> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return windowsOnAllDisplays[Display.DEFAULT_DISPLAY].orEmpty()
        }
        @Suppress("DEPRECATION")
        return windows.orEmpty()
    }

    fun topPackage(): String? {
        val apps = windows().filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
        val active = apps.firstOrNull { it.isActive } ?: apps.firstOrNull()
        return active?.root?.packageName?.toString()
    }

    /**
     * 把当前界面拍成扁平元素表 + 窗口层级。
     *
     * ref（`@e3`）按遍历顺序编号：同一次读屏内稳定，下一次重新编号。
     * 所以模型拿到 ref 要尽快用；跨轮次时靠 [clickRef] 的坐标兜底。
     */
    fun snapshot(fullResourceIds: Boolean = false): MiniScreen {
        val elements = ArrayList<MiniElement>()
        val windowsOut = ArrayList<MiniWindow>()
        var counter = 0

        for (w in windows()) {
            val root = w.root ?: continue
            val nodes = ArrayList<MiniNode>()

            fun walk(n: AccessibilityNodeInfo, depth: Int) {
                if (depth > MAX_DEPTH) return
                val name = textOrLabel(n)
                val interactive = n.isClickable || n.isEditable || n.isScrollable
                if (name.isNotEmpty() || interactive) {
                    val ref = "@e${++counter}"
                    val b = Rect()
                    n.getBoundsInScreen(b)
                    elements.add(
                        MiniElement(
                            ref = ref,
                            role = role(n),
                            name = name,
                            centerX = (b.left + b.right) / 2,
                            centerY = (b.top + b.bottom) / 2,
                            bounds = listOf(b.left, b.top, b.right, b.bottom),
                            resourceId = if (fullResourceIds) n.viewIdResourceName else null,
                            clickable = n.isClickable,
                            editable = n.isEditable,
                            scrollable = n.isScrollable,
                            focused = n.isFocused,
                            checked = isCheckedCompat(n),
                            enabled = n.isEnabled,
                        ),
                    )
                    nodes.add(MiniNode(role = role(n), ref = ref, depth = depth))
                }
                for (i in 0 until n.childCount) {
                    n.getChild(i)?.let { walk(it, depth + 1) }
                }
            }
            walk(root, 0)
            windowsOut.add(
                MiniWindow(
                    id = w.id,
                    type = w.type,
                    packageName = w.root?.packageName?.toString(),
                    active = w.isActive,
                    focused = w.isFocused,
                    nodes = nodes,
                ),
            )
        }

        val dm = resources.displayMetrics
        return MiniScreen(
            packageName = topPackage(),
            width = dm.widthPixels,
            height = dm.heightPixels,
            elements = elements,
            windows = windowsOut,
        )
    }

    private fun elementByRef(ref: String): MiniElement? = snapshot(fullResourceIds = true).elements.firstOrNull { it.ref == ref }

    /** 点 ref：先找可点击的祖先节点；节点不可点时退回按中心坐标点。 */
    fun clickRef(ref: String): Boolean {
        val e = elementByRef(ref) ?: return false
        val n = nodeAt(e.centerX, e.centerY)
        if (n != null) {
            var cur: AccessibilityNodeInfo? = n
            var guard = 0
            while (cur != null && guard++ < 12) {
                if (cur.isClickable) {
                    if (cur.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
                    break
                }
                cur = cur.parent
            }
        }
        // 自定义控件常见：节点不可点，直接点坐标
        return tap(e.centerX, e.centerY)
    }

    /** 往 ref 对应的输入框写文字；clearFirst 为 false 时追加在已有内容后面。 */
    fun typeRef(ref: String, text: String, clearFirst: Boolean): Boolean {
        val e = elementByRef(ref) ?: return false
        var target: AccessibilityNodeInfo? = nodeAt(e.centerX, e.centerY) ?: return false
        var guard = 0
        while (target != null && !target.isEditable && guard++ < 12) target = target.parent
        val node = target ?: return false
        node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        val merged = if (clearFirst) text else node.text?.toString().orEmpty() + text
        val args = android.os.Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, merged)
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun nodeAt(x: Int, y: Int): AccessibilityNodeInfo? {
        for (w in windows()) {
            val root = w.root ?: continue
            findAt(root, x, y, 0)?.let { return it }
        }
        return null
    }

    private fun findAt(n: AccessibilityNodeInfo, x: Int, y: Int, depth: Int): AccessibilityNodeInfo? {
        if (depth > MAX_DEPTH) return null
        val b = Rect()
        n.getBoundsInScreen(b)
        if (!b.contains(x, y)) return null
        for (i in 0 until n.childCount) {
            val child = n.getChild(i) ?: continue
            findAt(child, x, y, depth + 1)?.let { return it }
        }
        return n
    }

    /// isChecked 在 API 28+ 才不带 deprecation，但都在用；这里集中一处，方便以后换 Checkable 状态。
    @Suppress("DEPRECATION")
    private fun isCheckedCompat(n: AccessibilityNodeInfo): Boolean = n.isCheckable && n.isChecked

    private fun textOrLabel(n: AccessibilityNodeInfo): String {
        val t = n.text?.toString()?.trim().orEmpty()
        val s = t.ifEmpty { n.contentDescription?.toString()?.trim().orEmpty() }
        return s.take(MAX_TEXT)
    }

    private fun role(n: AccessibilityNodeInfo): String {
        val cls = n.className?.toString().orEmpty()
        return when {
            n.isEditable -> "input"
            cls.endsWith("Button") -> "button"
            cls.endsWith("ImageView") -> "image"
            cls.endsWith("Switch") || cls.endsWith("CheckBox") -> "toggle"
            cls.endsWith("RecyclerView") || cls.endsWith("ListView") || cls.endsWith("ScrollView") -> "list"
            cls.endsWith("TextView") -> "text"
            n.isScrollable -> "list"
            else -> "node"
        }
    }

    // ---------- 手势（无障碍 dispatchGesture，主屏坐标） ----------

    /**
     * 单击。这里**等比放大按压时长**：某些行情 App 用自定义 View 接 touch，
     * 太短的 down-up 会被判成滑动而丢掉点击。
     */
    fun tap(x: Int, y: Int): Boolean = stroke(x, y, x, y, TAP_MS)

    fun longPress(x: Int, y: Int, durationMs: Long): Boolean = stroke(x, y, x, y, durationMs)

    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long): Boolean =
        stroke(x1, y1, x2, y2, durationMs.coerceIn(60L, 5000L))

    private fun stroke(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long): Boolean {
        val path = Path().apply {
            moveTo(x1.toFloat(), y1.toFloat())
            if (x1 != x2 || y1 != y2) lineTo(x2.toFloat(), y2.toFloat())
        }
        val gesture = GestureDescription.StrokeDescription(path, 0, durationMs.coerceAtLeast(1L))
        return dispatchGesture(GestureDescription.Builder().addStroke(gesture).build(), null, null)
    }

    fun pressBack(): Boolean = performGlobalAction(GLOBAL_ACTION_BACK)

    fun pressHome(): Boolean = performGlobalAction(GLOBAL_ACTION_HOME)

    fun pressRecents(): Boolean = performGlobalAction(GLOBAL_ACTION_RECENTS)

    /** 主屏截图（安卓 11+）。返回逐像素可读的位图；调用线程上同步等待结果。 */
    fun screenshotPng(): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val latch = java.util.concurrent.CountDownLatch(1)
        var bytes: ByteArray? = null
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            mainExecutor,
            object : TakeScreenshotCallback {
                override fun onSuccess(result: ScreenshotResult) {
                    try {
                        val bmp = android.graphics.Bitmap.wrapHardwareBuffer(result.hardwareBuffer, result.colorSpace)
                        val copy = bmp?.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
                        bytes = copy?.let {
                            java.io.ByteArrayOutputStream().use { out ->
                                it.compress(android.graphics.Bitmap.CompressFormat.PNG, 90, out)
                                out.toByteArray()
                            }
                        }
                    } finally {
                        result.hardwareBuffer.close()
                        latch.countDown()
                    }
                }

                override fun onFailure(errorCode: Int) {
                    Log.w(TAG, "screenshot failed: $errorCode")
                    latch.countDown()
                }
            },
        )
        latch.await(3, java.util.concurrent.TimeUnit.SECONDS)
        return bytes
    }

    companion object {
        private const val TAG = "MiniPhoneA11y"
        private const val MAX_DEPTH = 40
        private const val MAX_TEXT = 200
        private const val TAP_MS = 90L

        /** 服务连着才非空；AI 工具只在它非空时下发。 */
        @Volatile
        var instance: MiniPhoneAccessibility? = null
            private set
    }
}
