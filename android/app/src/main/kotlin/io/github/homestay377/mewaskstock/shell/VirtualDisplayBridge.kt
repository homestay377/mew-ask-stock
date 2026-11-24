package io.github.homestay377.mewaskstock.shell

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * 虚拟屏 ↔ Flutter 的桥。
 *
 * 两件事：
 * 1. **状态**：Shizuku 装没装、跑没跑、有没有授权 → 告诉 UI，让用户一眼看到还缺哪一步；
 * 2. **操作**：建屏、在虚拟屏上打开 App、在虚拟屏上点击/滑动/按键、截图。
 *
 * 所有动作都要求 `display` 参数是虚拟屏，**绝不碰主屏**（主屏那套在 MiniPhoneBridge 里）。
 */
class VirtualDisplayBridge(
    private val context: Context,
    private val shizuku: ShizukuChannel,
) : MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "vd-bridge") }

    companion object {
        const val CHANNEL = "io.github.homestay377.mewaskstock/virtual_display"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ---- 状态 ----
            "status" -> {
                val s = shizuku.current()
                val vd = VirtualDisplayManager.current()
                result.success(
                    mapOf(
                        "shizuku" to s.phase.name.lowercase(),
                        "shizukuReady" to s.ready,
                        "shizukuDetail" to s.detail,
                        "display" to vd.toMap(),
                        "accessibility" to (MiniPhoneA11yState.connected),
                    ),
                )
            }
            "request_permission" -> {
                shizuku.requestPermission()
                result.success(mapOf("ok" to true, "note" to "已弹出 Shizuku 授权请求"))
            }
            "open_shizuku" -> result.success(mapOf("ok" to shizuku.openShizukuApp()))
            "refresh" -> {
                shizuku.refresh()
                result.success(mapOf("ok" to true))
            }

            // ---- 屏 ----
            "ensure_display" -> {
                val svc = shizuku.service()
                if (svc == null) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "error" to "shell_unavailable",
                            "detail" to (shizuku.current().let { "${it.phase.name.lowercase()} ${it.detail ?: ""}" }),
                        ),
                    )
                    return
                }
                worker.execute {
                    val st = runCatching { VirtualDisplayManager.ensure(context, svc) }.getOrElse {
                        Log.w("VDBridge", "ensure failed", it)
                        VirtualDisplayManager.current()
                    }
                    main.post { result.success(st.toMap()) }
                }
            }
            "release_display" -> {
                VirtualDisplayManager.stop(shizuku.service())
                result.success(mapOf("ok" to true))
            }

            // ---- 虚拟屏上的动作 ----
            else -> {
                val svc = shizuku.service()
                val display = VirtualDisplayManager.current()
                if (svc == null || !display.ready) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "error" to "detached",
                            "detail" to "虚拟屏没开：先调 ensure_display（Shizuku 需要就绪并授权）",
                        ),
                    )
                    return
                }
                val id = display.displayId
                when (call.method) {
                    "start_app" -> {
                        val pkg = call.argument<String>("package").orEmpty()
                        if (pkg.isBlank()) {
                            result.success(mapOf("ok" to false, "error" to "no_package"))
                            return
                        }
                        worker.execute {
                            val code = runCatching { svc.startApp(id, pkg) }.getOrDefault(3)
                            main.post {
                                result.success(
                                    when (code) {
                                        0 -> mapOf("ok" to true, "displayId" to id)
                                        1 -> mapOf(
                                            "ok" to false,
                                            "error" to "in_use_on_main",
                                            "detail" to "你正在主屏使用这个 App，先切走再让我开（同一 App 不能同时在两块屏上）",
                                        )
                                        2 -> mapOf("ok" to false, "error" to "not_found", "detail" to "$pkg 没有可启动的界面")
                                        else -> mapOf("ok" to false, "error" to "launch_failed")
                                    },
                                )
                            }
                        }
                    }
                    "tap" -> {
                        val x = call.argument<Int>("x") ?: 0
                        val y = call.argument<Int>("y") ?: 0
                        main.post { result.success(mapOf("ok" to svc.injectTap(id, x, y))) }
                    }
                    "swipe" -> {
                        val x1 = call.argument<Int>("x1") ?: 0
                        val y1 = call.argument<Int>("y1") ?: 0
                        val x2 = call.argument<Int>("x2") ?: 0
                        val y2 = call.argument<Int>("y2") ?: 0
                        val ms = (call.argument<Int>("durationMs") ?: 320).toLong()
                        worker.execute {
                            val ok = runCatching { svc.injectSwipe(id, x1, y1, x2, y2, ms) }.getOrDefault(false)
                            main.post { result.success(mapOf("ok" to ok)) }
                        }
                    }
                    "press_key" -> {
                        val key = call.argument<String>("key").orEmpty()
                        val code = when (key) {
                            "back" -> android.view.KeyEvent.KEYCODE_BACK
                            "enter" -> android.view.KeyEvent.KEYCODE_ENTER
                            "home" -> android.view.KeyEvent.KEYCODE_HOME
                            "del" -> android.view.KeyEvent.KEYCODE_DEL
                            else -> -1
                        }
                        if (code < 0) {
                            result.success(mapOf("ok" to false, "error" to "unsupported_key"))
                            return
                        }
                        main.post { result.success(mapOf("ok" to svc.injectKey(id, code))) }
                    }
                    "screenshot" -> worker.execute {
                        val png = VirtualDisplayManager.screenshotPng()
                        main.post {
                            result.success(
                                if (png == null) {
                                    mapOf("ok" to false, "error" to "no_frame", "detail" to "虚拟屏还没产出一帧（App 可能还没启动）")
                                } else {
                                    mapOf(
                                        "ok" to true,
                                        "base64" to android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP),
                                    )
                                },
                            )
                        }
                    }
                    "top_task" -> worker.execute {
                        val t = runCatching { svc.topTaskId(id) }.getOrDefault(-1)
                        main.post { result.success(mapOf("ok" to (t >= 0), "taskId" to t)) }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}

/** 无障碍服务是否连着（虚拟屏读屏要靠它），避免 shell 包反向依赖 miniphone 包。 */
object MiniPhoneA11yState {
    @Volatile
    var connected: Boolean = false
}
