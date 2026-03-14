package com.fracta.fracta

import android.app.Activity
import android.os.PowerManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "fracta/native"

    private var captureDoneReceiver: BroadcastReceiver? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val REQUEST_MEDIA_PROJECTION = 1001
    }

    @Deprecated("Deprecated in API 30")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_MEDIA_PROJECTION) {
            android.util.Log.d("MainActivity", "[FRACTA-CAPTURE] onActivityResult: resultCode=$resultCode (OK=${Activity.RESULT_OK}), data=${data != null}")
            if (resultCode == Activity.RESULT_OK && data != null) {
                android.util.Log.d("MainActivity", "[FRACTA-CAPTURE] ✅ User GRANTED screen capture permission — starting ScreenCaptureService")
                val serviceIntent = Intent(this, ScreenCaptureService::class.java).apply {
                    action = ScreenCaptureService.ACTION_START
                    putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
                    putExtra(ScreenCaptureService.EXTRA_DATA, data)
                }
                // Post so activity is fully in foreground (avoids background start crash on Android 12+ / MIUI)
                mainHandler.post {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        android.util.Log.d("MainActivity", "[FRACTA-CAPTURE] ScreenCaptureService start command sent")
                    } catch (e: Exception) {
                        android.util.Log.e("MainActivity", "[FRACTA-CAPTURE] ❌ Failed to start ScreenCaptureService", e)
                    }
                }
            } else {
                android.util.Log.w("MainActivity", "[FRACTA-CAPTURE] ❌ User DECLINED screen capture permission or dialog was dismissed")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openOverlaySettings" -> {
                    openOverlaySettings()
                    result.success(true)
                }
                "openBatteryOptimizationSettings" -> {
                    openBatteryOptimizationSettings()
                    result.success(true)
                }
                "requestBatteryExemption" -> {
                    requestBatteryExemption()
                    result.success(true)
                }
                "canDrawOverlays" -> {
                    result.success(Settings.canDrawOverlays(this))
                }
                "requestScreenCapturePermission" -> {
                    requestScreenCapturePermission()
                    result.success(true)
                }
                "captureScreen" -> {
                    captureScreen(result)
                }
                "isProjectionAlive" -> {
                    result.success(ScreenCaptureService.isProjectionAlive)
                }
                "stopScreenCapture" -> {
                    stopScreenCapture()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Overlay permission is requested only when user explicitly enables the bubble toggle
    }

    override fun onDestroy() {
        captureDoneReceiver?.let { unregisterReceiver(it) }
        captureDoneReceiver = null
        mainHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun openOverlaySettings() {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName")
        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        startActivity(intent)
    }

    private fun openBatteryOptimizationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        } else {
            @Suppress("DEPRECATION")
            Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun requestBatteryExemption() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = android.net.Uri.parse("package:$packageName")
                }
                try {
                    startActivity(intent)
                } catch (e: Exception) {
                    // Some OEMs block this intent — fall back to general settings
                    openBatteryOptimizationSettings()
                }
            }
        }
    }

    private fun requestScreenCapturePermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val intent = projectionManager.createScreenCaptureIntent()
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_MEDIA_PROJECTION)
    }

    private var captureTimeoutRunnable: Runnable? = null

    private fun captureScreen(result: MethodChannel.Result) {
        var replied = false
        fun reply(path: String?) {
            if (replied) return
            replied = true
            captureTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            captureTimeoutRunnable = null
            captureDoneReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
            captureDoneReceiver = null
            result.success(path)
        }
        captureDoneReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val path = intent?.getStringExtra(ScreenCaptureService.EXTRA_CAPTURE_PATH)
                reply(path)
            }
        }
        val filter = IntentFilter(ScreenCaptureService.ACTION_CAPTURE_DONE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(captureDoneReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(captureDoneReceiver, filter)
        }
        captureTimeoutRunnable = Runnable { reply(null) }
        mainHandler.postDelayed(captureTimeoutRunnable!!, 5000)
        val captureIntent = Intent(this, ScreenCaptureService::class.java).apply {
            action = ScreenCaptureService.ACTION_CAPTURE
        }
        startService(captureIntent)
    }

    private fun stopScreenCapture() {
        val intent = Intent(this, ScreenCaptureService::class.java).apply {
            action = ScreenCaptureService.ACTION_STOP
        }
        startService(intent)
    }
}
