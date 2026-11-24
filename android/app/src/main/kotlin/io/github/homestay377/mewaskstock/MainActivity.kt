package io.github.homestay377.mewaskstock

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.homestay377.mewaskstock.miniphone.MiniPhoneBridge

class MainActivity : FlutterActivity() {
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
        // 手机操控：AI 读屏 / 点击 / 输入（需要用户在系统里打开无障碍服务）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MiniPhoneBridge.CHANNEL)
            .setMethodCallHandler(MiniPhoneBridge(applicationContext))
    }
}
