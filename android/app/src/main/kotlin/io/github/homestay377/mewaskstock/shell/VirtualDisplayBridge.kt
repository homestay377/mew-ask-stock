package io.github.homestay377.mewaskstock.shell

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.homestay377.mewaskstock.adb.AdbDiscovery
import io.github.homestay377.mewaskstock.adb.AdbStore
import io.github.homestay377.mewaskstock.adb.WirelessDebugChannel
import java.util.concurrent.Executors

/**
 * 虚拟屏 ↔ Flutter 的桥。
 *
 * 两件事：
 * 1. **状态**：Shizuku 装没装/跑没跑/授权没授权、无线调试配对没配对 → 让 UI 和模型知道缺哪一步；
 * 2. **操作**：建屏、在虚拟屏上打开 App、注入触摸/按键、截图。
 *
 * 服务来源由 [ShellRouter] 决定（Shizuku 优先，退到无线调试助手），这里不关心 binder 从哪来。
 */
class VirtualDisplayBridge(
    private val context: Context,
    private val shizuku: ShizukuChannel,
    private val wireless: WirelessDebugChannel,
    private val router: ShellRouter,
) : MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "vd-bridge") }

    companion object {
        const val CHANNEL = "io.github.homestay377.mewaskstock/virtual_display"

        /** App 侧组装：Shizuku + 无线调试 + 路由。 */
        fun create(context: Context): Triple<VirtualDisplayBridge, ShizukuChannel, ShellRouter> {
            val shizuku = ShizukuChannel(context)
            val store = AdbStore(context)
            val wireless = WirelessDebugChannel(context, store, AdbDiscovery(context))
            val router = ShellRouter(context, shizuku, wireless)
            return Triple(VirtualDisplayBridge(context, shizuku, wireless, router), shizuku, router)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ---------- 状态 ----------
            "status" -> {
                val s = shizuku.current()
                val w = wireless.current()
                val r = router.current()
                val vd = VirtualDisplayManager.current()
                result.success(
                    mapOf(
                        "shizuku" to s.phase.name.lowercase(),
                        "shizukuReady" to s.ready,
                        "shizukuDetail" to s.detail,
                        "wireless" to w.phase.name.lowercase(),
                        "wirelessReady" to w.ready,
                        "wirelessDetail" to w.detail,
                        "source" to r.source.name.lowercase(),
                        "routerNote" to r.note,
                        "display" to vd.toMap(),
                        "accessibility" to MiniPhoneA11yState.connected,
                    ),
                )
            }
            "request_permission" -> {
                shizuku.requestPermission()
                result.success(mapOf("ok" to true, "note" to "已弹出 Shizuku 授权请求"))
            }
            "open_shizuku" -> result.success(mapOf("ok" to shizuku.openShizukuApp()))

            // ---------- 无线调试配对（B 路线） ----------
            "pair_wireless" -> {
                val code = call.argument<String>("code").orEmpty().trim()
                val port = call.argument<Int>("port")
                if (code.isEmpty()) {
                    result.success(mapOf("ok" to false, "error" to "code_required", "detail" to "需要 6 位配对码"))
                    return
                }
                worker.execute {
                    val st = wireless.pair(code, port)
                    main.post {
                        result.success(
                            mapOf(
                                "ok" to (st.phase != WirelessDebugChannel.Phase.FAILED),
                                "phase" to st.phase.name.lowercase(),
                                "detail" to st.detail,
                            ),
                        )
                    }
                }
            }
            "start_wireless" -> worker.execute {
                val st = wireless.startHelper()
                val svc = wireless.service()
                main.post {
                    result.success(
                        mapOf(
                            "ok" to (svc != null),
                            "phase" to st.phase.name.lowercase(),
                            "detail" to st.detail,
                        ),
                    )
                }
            }
            "forget_wireless" -> {
                wireless.forget()
                result.success(mapOf("ok" to true))
            }

            // ---------- 屏 ----------
            "ensure_display" -> {
                val r = router.resolve()
                val svc = r.service
                if (svc == null) {
                    result.success(mapOf("ok" to false, "error" to "shell_unavailable", "detail" to r.note))
                    return
                }
                worker.execute {
                    val st = runCatching { VirtualDisplayManager.ensure(context, svc) }.getOrElse {
                        Log.w("VDBridge", "ensure failed", it)
                        VirtualDisplayManager.current()
                    }
                    main.post { result.success(st.toMap() + ("source" to r.source.name.lowercase())) }
                }
            }
            "release_display" -> {
                VirtualDisplayManager.stop(router.current().service)
                result.success(mapOf("ok" to true))
            }

            // ---------- 虚拟屏上的动作 ----------
            else -> {
                val r = router.current()
                val svc = r.service
                val display = VirtualDisplayManager.current()
                if (svc == null || !display.ready) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "error" to "detached",
                            "detail" to "虚拟屏没开：先调 ensure_display（${r.note}）",
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
                                            "detail" to "你正在主屏用这个 App，先切走再让我开（同一 App 不能同时在两块屏上）",
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
