package io.github.homestay377.mewaskstock

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.homestay377.mewaskstock.miniphone.MiniPhoneBridge
import io.github.homestay377.mewaskstock.shell.ShizukuChannel
import io.github.homestay377.mewaskstock.shell.VirtualDisplayBridge

class MainActivity : FlutterActivity() {

    /** Shizuku 通道整个 App 一份：watch 一次，所有页面共用。 */
    private var shizuku: ShizukuChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.homestay377.mewaskstock/chat_generation")
            .setMethodCallHandler { call, result ->
                val conversationId = call.argument<String>("conversationId")
                if (conversationId.isNullOrBlank()) {
                    result.error("missing_conversation", "A conversation id is required.", null)
                    return@setMethodCallHandler
                }
                try {
                    when (call.method) {
                        "start" -> ChatGenerationService.start(this, conversationId)
                        "stop" -> ChatGenerationService.stop(this, conversationId)
                        else -> {
                            result.notImplemented()
                            return@setMethodCallHandler
                        }
                    }
                    result.success(null)
                } catch (error: Exception) {
                    result.error("background_service", error.message, null)
                }
            }

        // 手机操控（无障碍，操作主屏）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MiniPhoneBridge.CHANNEL)
            .setMethodCallHandler(MiniPhoneBridge(applicationContext))

        // 虚拟屏（Shizuku 或无线调试助手，App 在后台屏上跑）
        val (bridge, sh, _) = VirtualDisplayBridge.create(applicationContext)
        shizuku = sh
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VirtualDisplayBridge.CHANNEL)
            .setMethodCallHandler(bridge)
    }

    override fun onDestroy() {
        shizuku?.unwatch()
        super.onDestroy()
    }
}
