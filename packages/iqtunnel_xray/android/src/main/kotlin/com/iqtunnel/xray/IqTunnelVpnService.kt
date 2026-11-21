package com.iqtunnel.xray

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import libXray.DialerController
import libXray.LibXray
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class IqTunnelVpnService : VpnService() {

    interface ConnectionCallback {
        fun onConnected()
        fun onFailed(safeMessage: String)
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var vpnInterface: ParcelFileDescriptor? = null
    private var nativeStarted = false
    private var nativeStartAttempted = false
    private var dnsConfigured = false

    override fun onCreate() {
        super.onCreate()
        activeService = this
        if (dialerControllerRegistered.compareAndSet(false, true)) {
            LibXray.registerDialerController(processDialerController)
            LibXray.registerListenerController(processDialerController)
        }
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForeground(NOTIFICATION_ID, buildNotification("Starting secure tunnel"))
                val xrayJson = intent.getStringExtra(EXTRA_XRAY_JSON)
                if (xrayJson.isNullOrBlank()) {
                    failStart("Xray configuration is empty.")
                } else {
                    executor.execute { startTunnel(xrayJson) }
                }
            }
            ACTION_STOP -> executor.execute { stopTunnel() }
            else -> {
                stopForeground(true)
                stopSelf(startId)
            }
        }
        return START_NOT_STICKY
    }

    private fun startTunnel(xrayJson: String) {
        try {
            if (nativeStarted || vpnInterface != null) stopTunnelInternal()

            val dnsServers = listOf("1.1.1.1", "8.8.8.8")
            val config = JSONObject(xrayJson)

            val tunSettings = JSONObject()
                .put("name", "iqt0")
                .put("desc", "IQ Tunnel")
                .put("mtu", VPN_MTU)
                .put("gateway", JSONArray().put(IPV4_GATEWAY).put(IPV6_GATEWAY))
                .put("dns", JSONArray().put(dnsServers[0]).put(dnsServers[1]))

            val tunInbound = JSONObject()
                .put("tag", "iqt-tun")
                .put("protocol", "tun")
                .put("settings", tunSettings)

            val inbounds = JSONArray()
            val suppliedInbounds = config.optJSONArray("inbounds")
            if (suppliedInbounds != null) {
                for (index in 0 until suppliedInbounds.length()) {
                    val existing = suppliedInbounds.optJSONObject(index) ?: continue
                    if (existing.optString("protocol") != "tun") inbounds.put(existing)
                }
            }
            inbounds.put(tunInbound)
            config.put("inbounds", inbounds)

            val builder = Builder()
                .setSession("IQ Tunnel")
                .setMtu(VPN_MTU)
                .addAddress(IPV4_ADDRESS, 30)
                .addAddress(IPV6_ADDRESS, 126)
                .addRoute("0.0.0.0", 0)
                .addRoute("::", 0)

            dnsServers.forEach { builder.addDnsServer(it) }
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {
                // Socket protection below remains mandatory even if exclusion is unavailable.
            }

            val established = builder.establish()
                ?: throw IOException("Android did not establish the VPN interface.")
            vpnInterface = established

            // A single process-wide controller is registered once. Its active
            // service target changes across reconnects, avoiding leaked callback
            // instances in libXray's process-global dialer registry.
            LibXray.setDNS(processDialerController, dnsServers[0] + ":53")
            dnsConfigured = true
            LibXray.setTunFd(established.fd.toLong())
            nativeStartAttempted = true

            val request = JSONObject()
                .put("apiVersion", 3)
                .put("method", "runXray")
                .put("payload", JSONObject().put("xrayJson", config.toString()))
            val response = JSONObject(LibXray.invoke(request.toString()))
            if (!response.optBoolean("success")) {
                throw IOException("Xray could not start the VPN engine.")
            }

            nativeStarted = true
            publishState("connected")
            mainHandler.post {
                connectionCallback?.onConnected()
                connectionCallback = null
            }
            updateNotification("VPN tunnel connected")
        } catch (_: Throwable) {
            stopTunnelInternal()
            failStart("Could not establish the Xray VPN tunnel. Check the profile and device compatibility.")
        }
    }


    private fun stopTunnel() {
        stopTunnelInternal()
        publishState("disconnected")
        mainHandler.post {
            stopForeground(true)
            stopSelf()
            disconnectCallback?.invoke()
            disconnectCallback = null
        }
    }

    private fun stopTunnelInternal() {
        if (nativeStarted || nativeStartAttempted) {
            try {
                val request = """{"apiVersion":3,"method":"stopXray","payload":{}}"""
                LibXray.invoke(request)
            } catch (_: Throwable) {
                // Continue to close Android resources even if Core shutdown reports an error.
            }
        }
        nativeStarted = false
        nativeStartAttempted = false
        try {
            LibXray.resetTunFd()
        } catch (_: Throwable) {
            // Best-effort cleanup of the Go-process environment.
        }
        if (dnsConfigured) {
            try {
                LibXray.resetDNS()
            } catch (_: Throwable) {
                // Continue cleanup.
            }
        }
        dnsConfigured = false
        try {
            vpnInterface?.close()
        } catch (_: IOException) {
            // Descriptor may already be closed by Android.
        }
        vpnInterface = null
    }

    private fun failStart(safeMessage: String) {
        publishState("error", safeMessage)
        mainHandler.post {
            connectionCallback?.onFailed(safeMessage)
            connectionCallback = null
            stopForeground(true)
            stopSelf()
        }
    }

    private fun publishState(state: String, message: String? = null) {
        val event = mutableMapOf<String, Any>("status" to state)
        if (!message.isNullOrBlank()) event["message"] = message
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    private fun updateNotification(message: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(message))
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "IQ Tunnel VPN",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Shows the active IQ Tunnel VPN connection."
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(message: String): Notification {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_iqtunnel_notification)
                .setContentTitle("IQ Tunnel")
                .setContentText(message)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.drawable.ic_iqtunnel_notification)
                .setContentTitle("IQ Tunnel")
                .setContentText(message)
                .setOngoing(true)
                .build()
        }
    }

    override fun onRevoke() {
        executor.execute { stopTunnel() }
        super.onRevoke()
    }

    override fun onDestroy() {
        executor.execute {
            stopTunnelInternal()
            if (activeService === this) activeService = null
            executor.shutdown()
        }
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.iqtunnel.xray.START"
        const val ACTION_STOP = "com.iqtunnel.xray.STOP"
        const val EXTRA_XRAY_JSON = "xray_json"

        private const val VPN_MTU = 1500
        private const val NOTIFICATION_ID = 49172
        private const val CHANNEL_ID = "iq_tunnel_vpn"

        private const val IPV4_ADDRESS = "10.254.0.1"
        private const val IPV4_GATEWAY = "10.254.0.1/30"
        private const val IPV6_ADDRESS = "fd00:1:fd00:1::1"
        private const val IPV6_GATEWAY = "fd00:1:fd00:1::1/126"

        @Volatile
        var connectionCallback: ConnectionCallback? = null

        @Volatile
        var disconnectCallback: (() -> Unit)? = null

        @Volatile
        var eventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

        @Volatile
        private var activeService: IqTunnelVpnService? = null

        private val dialerControllerRegistered = AtomicBoolean(false)

        private val processDialerController = object : DialerController {
            override fun protectFd(fd: Long): Boolean {
                if (fd < 0 || fd > Int.MAX_VALUE) return false
                return activeService?.protect(fd.toInt()) ?: false
            }
        }

        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    }
}
