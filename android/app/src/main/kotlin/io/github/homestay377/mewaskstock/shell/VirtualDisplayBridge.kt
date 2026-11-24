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
import io.github.homestay377.mewaskstock.pairing.PairingCodeReader
import io.github.homestay377.mewaskstock.pairing.PairingCodeReceiver
import io.github.homestay377.mewaskstock.pairing.PairingCodeSink
import io.github.homestay377.mewaskstock.pairing.PairingCoordinator
import io.github.homestay377.mewaskstock.pairing.PairingNotifier
import java.util.concurrent.Executors
import kotlinx.coroutines.runBlocking

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
    private val pairing: PairingCoordinator,
) : MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "vd-bridge") }

    companion object {
        const val CHANNEL = "io.github.homestay377.mewaskstock/virtual_display"

        /** App 侧组装：Shizuku + 无线调试 + 路由。 */
        fun create(context: Context): VirtualDisplayBridge {
            val shizuku = ShizukuChannel(context)
            val store = AdbStore(context)
            val discovery = AdbDiscovery(context)
            val wireless = WirelessDebugChannel(context, store, discovery)
            val router = ShellRouter(context, shizuku, wireless)
            val pairing = PairingCoordinator(context, store, discovery)
            // 通知栏输入框的落点接上
            PairingCodeReceiver.sink = PairingCodeSink { code, port -> pairing.pair(code, port) }
            // 开始监听 Shizuku 状态（服务起来/断掉都会刷新）
            shizuku.watch { }
            return VirtualDisplayBridge(context, shizuku, wireless, router, pairing)
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
                        "shizukuRunning" to s.running,
                        "shizukuGranted" to s.granted,
                        "shizukuDetail" to s.detail,
                        "wireless" to w.phase.name.lowercase(),
                        "wirelessReady" to w.ready,
                        "wirelessDetail" to w.detail,
                        "source" to r.source.name.lowercase(),
                        "routerNote" to r.note,
                        "shizukuText" to s.describe(),
                        "display" to vd.toMap(),
                        "displaySize" to VirtualDisplayManager.size(),
                        "accessibility" to (io.github.homestay377.mewaskstock.miniphone.MiniPhoneAccessibility.instance != null),
                    ),
                )
            }
            "request_permission" -> {
                shizuku.requestPermission()
                result.success(mapOf("ok" to true, "note" to "已弹出 Shizuku 授权请求"))
            }
            "open_shizuku" -> result.success(mapOf("ok" to shizuku.openShizukuApp()))

            // ---------- 无线调试配对（B 路线） ----------
            // 配对会话：先放通知栏输入框，再后台找端口/自动读码
            "begin_pairing" -> {
                val port = call.argument<Int>("port")
                pairing.start()
                if (port != null) PairingNotifier.showInput(context, port)
                result.success(
                    mapOf(
                        "ok" to true,
                        "autoRead" to PairingCodeReader(context).available(),
                        "note" to if (PairingCodeReader(context).available()) {
                            "已开始配对：我会直接读系统设置上的 6 位码并自动配对；读不到就下拉通知栏手动填"
                        } else {
                            "已开始配对：请下拉通知栏，在「输入配对码」里填 6 位码（不用关掉设置里的对话框）"
                        },
                    ),
                )
            }
            // 直接打开无线调试页面，省得用户自己翻
            "open_wireless_settings" -> {
                val intent = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                } else {
                    android.content.Intent(android.provider.Settings.ACTION_SETTINGS)
                }.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                val ok = runCatching { context.startActivity(intent) }.isSuccess
                result.success(if (ok) mapOf("ok" to true) else mapOf("ok" to false, "error" to "cannot_open"))
            }
            "end_pairing" -> {
                pairing.stop()
                PairingNotifier.cancel(context)
                result.success(mapOf("ok" to true))
            }
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
                    "frame_fingerprint" -> {
                        // 帧在 App 进程里（ImageReader），所以指纹也在 App 侧算，不走 shell 服务
                        val value = runCatching { VirtualDisplayManager.fingerprint() }.getOrDefault("")
                        result.success(mapOf("ok" to true, "value" to value))
                    }
                    // 用 shell 身份把本应用的无障碍服务写进 secure 设置——用户不用自己去系统里点。
                    // 逐条纪律（先读后合并、组件名两种写法、写完回读）都在 AccessibilityEnabler 里。
                    "enable_accessibility" -> {
                        worker.execute {
                            val component = "${context.packageName}/.miniphone.MiniPhoneAccessibility"
                            val r = AccessibilityEnabler.enable(component) { cmd ->
                                runCatching { svc.execShell(cmd) }.getOrDefault("")
                            }
                            main.post { result.success(r.toMap()) }
                        }
                    }
                    "inject_ascii_text" -> {
                        val text = call.argument<String>("text").orEmpty()
                        if (text.isEmpty()) {
                            result.success(mapOf("ok" to false, "error" to "no_text"))
                            return
                        }
                        worker.execute {
                            val code = runCatching { svc.injectAsciiText(id, text) }.getOrDefault(0)
                            main.post {
                                result.success(
                                    when (code) {
                                        1 -> mapOf("ok" to true, "sent" to "all")
                                        2 -> mapOf("ok" to false, "error" to "partial", "sent" to "partial")
                                        else -> mapOf("ok" to false, "error" to "not_sent")
                                    },
                                )
                            }
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
                    // 读虚拟屏上的文字（本机 OCR，不需要无障碍）。返回带坐标的行。
                    "ocr" -> worker.execute {
                        val lines = runCatching {
                            runBlocking { VirtualDisplayManager.ocrLines() }
                        }.getOrElse {
                            Log.w("VDBridge", "ocr failed", it)
                            emptyList()
                        }
                        main.post {
                            result.success(
                                mapOf(
                                    "ok" to true,
                                    "count" to lines.size,
                                    "lines" to lines.map { it.toMap() },
                                ),
                            )
                        }
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
