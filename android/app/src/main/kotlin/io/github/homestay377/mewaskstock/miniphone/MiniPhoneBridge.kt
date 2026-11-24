package io.github.homestay377.mewaskstock.miniphone

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.homestay377.mewaskstock.shell.InstalledApps

/**
 * 无障碍服务 ↔ Flutter 的桥。Dart 侧工具调用都落到这里。
 *
 * 屏幕动作在主线程发（无障碍 API 要求），读屏与截图放后台线程。
 */
class MiniPhoneBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "mini-phone-io") }

    companion object {
        const val CHANNEL = "io.github.homestay377.mewaskstock/mini_phone"

        private fun offResult() = mapOf(
            "ok" to false,
            "error" to "accessibility_off",
            "message" to "无障碍服务未开启：请在 设置 → 无障碍 → 问股操控 打开",
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // 无障碍没连上也必须能回答 status / open_settings，否则工具层没法给出「去哪开」的引导
        when (call.method) {
            "status" -> {
                result.success(
                    mapOf(
                        "connected" to (MiniPhoneAccessibility.instance != null),
                        "sdk" to android.os.Build.VERSION.SDK_INT,
                    ),
                )
                return
            }
            "open_settings" -> {
                val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                val ok = runCatching { context.startActivity(intent) }.isSuccess
                result.success(if (ok) mapOf("ok" to true) else mapOf("ok" to false, "error" to "cannot_open"))
                return
            }
            "open_app" -> {
                launchApp(call.argument<String>("package").orEmpty(), result)
                return
            }
            "open_url" -> {
                launchUrl(call.argument<String>("url").orEmpty(), call.argument<String>("package"), result)
                return
            }
            // 列 App / 找 App 只问 PackageManager，不需要无障碍（虚拟屏开 App 前用它把名字换成包名）
            "list_apps" -> {
                worker.execute {
                    val apps = InstalledApps.list(context, forceReload = true).map { it.toMap() }
                    main.post { result.success(mapOf("ok" to true, "apps" to apps)) }
                }
                return
            }
            "find_app" -> {
                val query = call.argument<String>("query").orEmpty()
                worker.execute {
                    val exact = InstalledApps.find(context, query).map { it.toMap() }
                    val suggest = if (exact.isEmpty()) InstalledApps.marketRelated(context).map { it.toMap() } else emptyList()
                    main.post {
                        val payload = mutableMapOf<String, Any?>("ok" to true, "apps" to exact)
                        if (suggest.isNotEmpty()) {
                            payload["suggest"] = suggest
                            payload["detail"] = "没找到「$query」，下面是与行情相关的已装 App"
                        }
                        result.success(payload)
                    }
                }
                return
            }
        }

        val service = MiniPhoneAccessibility.instance
        if (service == null) {
            result.success(offResult())
            return
        }

        when (call.method) {
            "observe" -> {
                val full = call.argument<Boolean>("resourceIds") ?: false
                // displayId：默认主屏；传虚拟屏号就读那块屏上的界面
                val displayId = call.argument<Int>("displayId") ?: android.view.Display.DEFAULT_DISPLAY
                worker.execute {
                    val snap = runCatching { service.snapshot(full, displayId) }.getOrNull()
                    main.post {
                        result.success(snap?.toMap() ?: mapOf("ok" to false, "error" to "read_failed"))
                    }
                }
            }
            "screenshot" -> worker.execute {
                val png = runCatching { service.screenshotPng() }.getOrNull()
                main.post {
                    result.success(
                        if (png == null) mapOf("ok" to false, "error" to "screenshot_failed")
                        else mapOf("ok" to true, "base64" to android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP)),
                    )
                }
            }
            "tap_ref" -> {
                val ref = call.argument<String>("ref").orEmpty()
                main.post { result.success(mapOf("ok" to service.clickRef(ref))) }
            }
            "tap" -> {
                val x = call.argument<Int>("x") ?: 0
                val y = call.argument<Int>("y") ?: 0
                main.post { result.success(mapOf("ok" to service.tap(x, y))) }
            }
            "long_press" -> {
                val x = call.argument<Int>("x") ?: 0
                val y = call.argument<Int>("y") ?: 0
                val ms = (call.argument<Int>("durationMs") ?: 700).toLong()
                main.post { result.success(mapOf("ok" to service.longPress(x, y, ms))) }
            }
            "swipe" -> {
                val x1 = call.argument<Int>("x1") ?: 0
                val y1 = call.argument<Int>("y1") ?: 0
                val x2 = call.argument<Int>("x2") ?: 0
                val y2 = call.argument<Int>("y2") ?: 0
                val ms = (call.argument<Int>("durationMs") ?: 320).toLong()
                main.post { result.success(mapOf("ok" to service.swipe(x1, y1, x2, y2, ms))) }
            }
            "type_text" -> {
                val ref = call.argument<String>("ref").orEmpty()
                val text = call.argument<String>("text").orEmpty()
                val clear = call.argument<Boolean>("clear") ?: false
                main.post { result.success(mapOf("ok" to service.typeRef(ref, text, clear))) }
            }
            "back" -> main.post { result.success(mapOf("ok" to service.pressBack())) }
            "home" -> main.post { result.success(mapOf("ok" to service.pressHome())) }
            "recents" -> main.post { result.success(mapOf("ok" to service.pressRecents())) }
            else -> result.notImplemented()
        }
    }

    private fun launchApp(pkg: String, result: MethodChannel.Result) {
        if (pkg.isBlank()) {
            result.success(mapOf("ok" to false, "error" to "no_package"))
            return
        }
        val intent = context.packageManager.getLaunchIntentForPackage(pkg)
        if (intent == null) {
            result.success(mapOf("ok" to false, "error" to "not_installed", "message" to "$pkg 没有可启动的入口"))
            return
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        runCatching { context.startActivity(intent) }
            .onSuccess { result.success(mapOf("ok" to true)) }
            .onFailure { result.success(mapOf("ok" to false, "error" to "launch_failed", "message" to it.message)) }
    }

    private fun launchUrl(url: String, pkg: String?, result: MethodChannel.Result) {
        if (url.isBlank()) {
            result.success(mapOf("ok" to false, "error" to "no_url"))
            return
        }
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (!pkg.isNullOrBlank()) intent.setPackage(pkg)
        runCatching { context.startActivity(intent) }
            .onSuccess { result.success(mapOf("ok" to true)) }
            .onFailure {
                result.success(
                    mapOf("ok" to false, "error" to "no_handler", "message" to (it.message ?: "没有能打开这个链接的应用")),
                )
            }
    }
}
