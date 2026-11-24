package io.github.homestay377.mewaskstock.adb

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 在本机发现无线调试 / 配对端口。
 *
 * 无线调试的端口每次开关都会变，写死没用，只能问 mDNS：adbd 会以
 * `_adb-tls-pairing._tcp`（配对对话框开着时）和 `_adb-tls-connect._tcp`（无线调试开着时）公布自己。
 *
 * 注意：同一服务可能查到好几条（关了又开、旧记录没清），**全部交出**，由调用方挨个试。
 */
class AdbDiscovery(private val context: Context) {

    data class Service(val name: String, val host: String, val port: Int)

    /** 找 [type] 的服务，最多等 [timeoutMs]；找到就返回（可能多条）。 */
    @Suppress("DEPRECATION") // NsdManager 的 resolveService/host 在 API 34 之后有替代，但旧的仍在用
    fun find(type: String, timeoutMs: Long = 8_000): List<Service> {
        val found = java.util.Collections.synchronizedList(ArrayList<Service>())
        val done = CountDownLatch(1)
        val nsd = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return emptyList()

        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "resolve failed for ${info.serviceName}: $errorCode")
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = info.host?.hostAddress ?: return
                // 只认本机回环（配对/连接都只在本机有效）
                if (!isLoopback(host)) return
                found.add(Service(info.serviceName, host, info.port))
                done.countDown()
            }
        }

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "start discovery failed for $serviceType: $errorCode")
                done.countDown()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

            override fun onDiscoveryStarted(serviceType: String) {}

            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onServiceFound(info: NsdServiceInfo) {
                runCatching { nsd.resolveService(info, resolveListener) }
            }

            override fun onServiceLost(info: NsdServiceInfo) {}
        }

        return try {
            nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            done.await(timeoutMs, TimeUnit.MILLISECONDS)
            // 稍等一下，让并发的 resolve 都回来
            Thread.sleep(400)
            found.toList()
        } catch (e: Exception) {
            Log.w(TAG, "discovery failed", e)
            emptyList()
        } finally {
            runCatching { nsd.stopServiceDiscovery(discoveryListener) }
        }
    }

    private fun isLoopback(host: String) = host == "127.0.0.1" || host == "::1" || host == "localhost"

    companion object {
        private const val TAG = "AdbDiscovery"
    }
}

/**
 * 身份与配对的持久化。
 *
 * - 私钥放 App 私有目录（`filesDir/adb/`），从不出这个 App；
 * - 记录"已配对"的标记，避免每次启动都去连一个不存在的服务；
 * - 用户点「撤销」= 删掉私钥和标记，下次要重新配对。
 */
class AdbStore(private val context: Context) {

    private val dir: File get() = File(context.filesDir, "adb").apply { mkdirs() }

    private val pairedFlag: File get() = File(dir, "paired")

    @Volatile
    private var cached: AdbIdentity? = null

    fun identity(): AdbIdentity {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            return AdbIdentity.load(dir).also { cached = it }
        }
    }

    fun isPaired(): Boolean = pairedFlag.exists()

    fun markPaired() {
        runCatching { pairedFlag.writeText(System.currentTimeMillis().toString()) }
    }

    fun forget() {
        synchronized(this) {
            cached = null
            runCatching { File(dir, "adb_identity.pk8").delete() }
            runCatching { pairedFlag.delete() }
        }
    }

    /** 这台机器上是否有可用的助手 APK 路径（就是用我们自己的 base.apk 当 classpath）。 */
    fun apkPath(): String? = context.applicationInfo?.sourceDir
}
