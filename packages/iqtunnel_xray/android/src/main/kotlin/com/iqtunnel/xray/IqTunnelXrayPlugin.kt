package com.iqtunnel.xray

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import libXray.LibXray

class IqTunnelXrayPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {

    private lateinit var appContext: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingConnectResult: MethodChannel.Result? = null
    private var pendingXrayJson: String? = null
    private var pendingInstallerPermissionResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "iq_tunnel/libxray")
        events = EventChannel(binding.binaryMessenger, "iq_tunnel/xray_events")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                IqTunnelVpnService.eventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                IqTunnelVpnService.eventSink = null
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "invoke" -> {
                    val request = call.arguments as? String
                        ?: throw IllegalArgumentException("A JSON request is required.")
                    result.success(LibXray.invoke(request))
                }
                "connect" -> requestVpnPermissionAndStart(call, result)
                "canInstallPackages" -> result.success(canInstallPackages())
                "requestInstallPackagesPermission" -> requestInstallPackagesPermission(result)
                "disconnect" -> {
                    val intent = Intent(appContext, IqTunnelVpnService::class.java)
                        .setAction(IqTunnelVpnService.ACTION_STOP)
                    // Complete the Flutter Future only after the native TUN/Core are closed.
                    IqTunnelVpnService.disconnectCallback = { result.success(null) }
                    appContext.startService(intent)
                }
                "isRunning" -> {
                    val request = """{"apiVersion":3,"method":"getXrayState","payload":{}}"""
                    val response = org.json.JSONObject(LibXray.invoke(request))
                    if (!response.optBoolean("success")) {
                        throw IllegalStateException("Could not read Xray state.")
                    }
                    result.success(response.optJSONObject("data")?.optBoolean("running") ?: false)
                }
                "getCoreVersion" -> {
                    val request = """{"apiVersion":3,"method":"xrayVersion","payload":{}}"""
                    val response = org.json.JSONObject(LibXray.invoke(request))
                    if (!response.optBoolean("success")) {
                        throw IllegalStateException("Could not read Xray version.")
                    }
                    result.success(response.optJSONObject("data")?.optString("version") ?: "")
                }
                "getTrafficStats" -> result.success(LibXray.getTrafficStats())
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            // Never include the native request payload or profile in an error.
            result.error("IQT_XRAY_ERROR", error.message ?: "Native Xray operation failed.", null)
        }
    }

    private fun canInstallPackages(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            appContext.packageManager.canRequestPackageInstalls()
    }

    private fun requestInstallPackagesPermission(result: MethodChannel.Result) {
        if (canInstallPackages()) {
            result.success(true)
            return
        }
        if (pendingInstallerPermissionResult != null) {
            result.error("IQT_INSTALL_PERMISSION_BUSY", "An installer permission request is already open.", null)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("IQT_INSTALL_PERMISSION", "Open IQ Tunnel to enable APK installation permission.", null)
            return
        }
        pendingInstallerPermissionResult = result
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.fromParts("package", appContext.packageName, null)
        )
        try {
            activity.startActivityForResult(intent, INSTALL_PERMISSION_REQUEST)
        } catch (error: Throwable) {
            pendingInstallerPermissionResult = null
            result.error("IQT_INSTALL_PERMISSION", "Android could not open the install permission settings.", null)
        }
    }

    private fun requestVpnPermissionAndStart(call: MethodCall, result: MethodChannel.Result) {
        val xrayJson = call.argument<String>("xrayJson")
        if (xrayJson.isNullOrBlank()) {
            result.error("IQT_INVALID_CONFIG", "Xray configuration is empty.", null)
            return
        }
        if (pendingConnectResult != null) {
            result.error("IQT_BUSY", "A VPN connection request is already running.", null)
            return
        }

        val prepareIntent = VpnService.prepare(appContext)
        if (prepareIntent != null) {
            val activity = activityBinding?.activity
            if (activity == null) {
                result.error("IQT_VPN_PERMISSION", "Open IQ Tunnel to grant VPN permission.", null)
                return
            }
            pendingConnectResult = result
            pendingXrayJson = xrayJson
            activity.startActivityForResult(prepareIntent, VPN_PERMISSION_REQUEST)
            return
        }
        startService(xrayJson, result)
    }

    private fun startService(xrayJson: String, result: MethodChannel.Result) {
        IqTunnelVpnService.connectionCallback = object : IqTunnelVpnService.ConnectionCallback {
            override fun onConnected() {
                pendingConnectResult = null
                pendingXrayJson = null
                result.success(null)
            }

            override fun onFailed(safeMessage: String) {
                pendingConnectResult = null
                pendingXrayJson = null
                result.error("IQT_XRAY_START_FAILED", safeMessage, null)
            }
        }
        val intent = Intent(appContext, IqTunnelVpnService::class.java)
            .setAction(IqTunnelVpnService.ACTION_START)
            .putExtra(IqTunnelVpnService.EXTRA_XRAY_JSON, xrayJson)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.startForegroundService(intent)
        } else {
            appContext.startService(intent)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == INSTALL_PERMISSION_REQUEST) {
            val result = pendingInstallerPermissionResult ?: return true
            pendingInstallerPermissionResult = null
            result.success(canInstallPackages())
            return true
        }
        if (requestCode != VPN_PERMISSION_REQUEST) return false
        val result = pendingConnectResult ?: return true
        if (resultCode != Activity.RESULT_OK) {
            pendingConnectResult = null
            pendingXrayJson = null
            result.error("IQT_VPN_PERMISSION_DENIED", "VPN permission was not granted.", null)
            return true
        }
        val config = pendingXrayJson
        if (config.isNullOrBlank()) {
            pendingConnectResult = null
            result.error("IQT_INVALID_CONFIG", "Xray configuration was lost.", null)
            return true
        }
        startService(config, result)
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)
    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        pendingInstallerPermissionResult = null
    }

    companion object {
        private const val VPN_PERMISSION_REQUEST = 49171
        private const val INSTALL_PERMISSION_REQUEST = 49173
    }
}

