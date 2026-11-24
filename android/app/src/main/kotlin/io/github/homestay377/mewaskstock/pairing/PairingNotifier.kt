package io.github.homestay377.mewaskstock.pairing

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * 配对码的通知栏输入。**照 Mika 的做法**：配对一开始就放一条带输入框的通知，
 * 用户下拉通知栏直接输码，不用离开系统设置里那个「配对码」对话框。
 *
 * 为什么必须这样：那个对话框是系统弹窗，一离开就没了；
 * 而切到别的 App 之后后台进程还可能被系统冻结，所以**通知必须提前放好**，
 * 等到发现配对窗口再发就晚了（这也是 Mika 写注释强调的点）。
 */
object PairingNotifier {

    const val KEY_CODE = "pairing_code"
    const val EXTRA_PORT = "pairing_port"

    private const val CHANNEL_ID = "pairing_code"
    private const val CHANNEL_NAME = "配对码输入"
    private const val ID = 4401
    private const val TAG = "PairingNotifier"
    private const val TIMEOUT_MS = 10 * 60_000L

    /**
     * 建频道。重要程度建成 HIGH：系统设置里的配对对话框在上层，
     * 通知要能弹出来让人看到（用户自己调低了不强行改回去）。
     */
    fun ensureChannel(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH).apply {
                description = "无线调试配对时输入 6 位码"
                enableVibration(true)
                setShowBadge(false)
            },
        )
    }

    /**
     * 显示「输入配对码」通知。
     *
     * [port] 已知就带上（直接配对）；未知也行（接收端会再找一次）。
     * [error] 是上一次没成功的原因，输入框照样留着让用户重填。
     */
    fun showInput(context: Context, port: Int?, error: String? = null) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(context)

        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, Class.forName("io.github.homestay377.mewaskstock.MainActivity"))
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val input = RemoteInput.Builder(KEY_CODE)
            .setLabel("6 位配对码")
            .setAllowFreeFormInput(true)
            .build()

        // RemoteInput 要把结果塞回 Intent，必须是 MUTABLE
        val reply = PendingIntent.getBroadcast(
            context,
            1,
            Intent(context, PairingCodeReceiver::class.java).apply {
                if (port != null) putExtra(EXTRA_PORT, port)
            },
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val action = Notification.Action.Builder(null, "配对", reply)
            .addRemoteInput(input)
            .setAllowGeneratedReplies(false)
            .setSemanticAction(Notification.Action.SEMANTIC_ACTION_REPLY)
            .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setAuthenticationRequired(false) }
            .build()

        val body = error ?: "在系统设置的「配对码」对话框里抄下 6 位码，填到这里（不用关那个窗口）"

        val n = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("输入配对码")
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_STATUS)
            .setOngoing(true)
            .setOnlyAlertOnce(false)
            .setTimeoutAfter(TIMEOUT_MS)
            .addAction(action)
            .apply { if (port != null) setSubText("已找到配对端口 $port") }
            .build()

        runCatching { nm.notify(ID, n) }.onFailure { Log.w(TAG, "notify failed", it) }
    }

    /** 配对进行中：换成不可输入的进度条，免得用户重复填。 */
    fun showWorking(context: Context, port: Int?) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(context)
        val n = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("正在配对…")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter(TIMEOUT_MS)
            .apply { if (port != null) setSubText("端口 $port") }
            .build()
        runCatching { nm.notify(ID, n) }
    }

    /** 配对成功：留一条几秒后自动消失的。 */
    fun showDone(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        val n = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("配对成功")
            .setContentText("可以回来启动助手了")
            .setAutoCancel(true)
            .setTimeoutAfter(8_000L)
            .build()
        runCatching { nm.notify(ID + 1, n) }
    }

    fun cancel(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        runCatching { nm.cancel(ID) }
    }
}

/**
 * 通知输入框的落点：从 RemoteInput 取码，交给 [PairingCodeSink]（由 VirtualDisplayBridge 注册）。
 */
class PairingCodeReceiver : BroadcastReceiver() {

    companion object {
        /** 谁收到码谁配对。由上层注册，避免这个 receiver 依赖 shell 实现。 */
        @Volatile
        var sink: PairingCodeSink? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        val code = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(PairingNotifier.KEY_CODE)
            ?.toString()
            ?.trim()
            .orEmpty()
        if (code.isEmpty()) return
        val port = intent.getIntExtra(PairingNotifier.EXTRA_PORT, -1).takeIf { it > 0 }
        val target = sink
        if (target == null) {
            PairingNotifier.showInput(context, port, "没有可用的配对通道，请回到 App 里重试")
            return
        }
        PairingNotifier.showWorking(context, port)
        // BroadcastReceiver 里不能长时间干活：起线程跑，跑完再更新通知
        Thread {
            val result = target.pairWithCode(code, port)
            if (result.ok) {
                PairingNotifier.showDone(context)
            } else {
                PairingNotifier.showInput(context, port, result.message ?: "配对失败，请重试")
            }
        }.start()
    }
}

/** 配对结果。 */
data class PairResult(val ok: Boolean, val message: String? = null)

/** 通知栏收到的码往哪送。 */
fun interface PairingCodeSink {
    fun pairWithCode(code: String, port: Int?): PairResult
}
