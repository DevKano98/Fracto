package com.fracta.fracta

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer

/**
 * Foreground service that holds MediaProjection and captures the screen on demand.
 * When the floating bubble is on, we can capture the current screen when user taps the bubble.
 */
class ScreenCaptureService : Service() {

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private val handler = Handler(Looper.getMainLooper())
    private var width = 1080
    private var height = 1920
    private var density = 1

    override fun onCreate() {
        super.onCreate()
        val dm = resources.displayMetrics
        width = dm.widthPixels
        height = dm.heightPixels
        density = dm.densityDpi
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, -1)
                val data = intent.getParcelableExtra<Intent>(EXTRA_DATA)
                if (data != null && resultCode != -1) {
                    startForegroundWithProjection(resultCode, data)
                } else {
                    stopSelf()
                }
            }
            ACTION_CAPTURE -> {
                captureScreen()
            }
            ACTION_STOP -> {
                stopCapture()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun startForegroundWithProjection(resultCode: Int, data: Intent) {
        val channelId = "fracta_screen_capture"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Screen capture",
                NotificationManager.IMPORTANCE_LOW
            ).apply { setShowBadge(false) }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Fracta")
            .setContentText("Screen capture active — tap bubble to verify")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            } else {
                0
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
        val projectionManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        mediaProjection = projectionManager.getMediaProjection(resultCode, data)
        mediaProjection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopCapture()
            }
        }, handler)
        setupVirtualDisplay()
    }

    private fun setupVirtualDisplay() {
        if (mediaProjection == null) return
        imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        virtualDisplay = mediaProjection!!.createVirtualDisplay(
            "FractaCapture",
            width,
            height,
            density,
            android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface,
            null,
            handler
        )
    }

    private fun captureScreen() {
        val reader = imageReader ?: run {
            sendBroadcast(Intent(ACTION_CAPTURE_DONE).apply {
                setPackage(packageName)
                putExtra(EXTRA_CAPTURE_PATH, null as String?)
            })
            return
        }
        var image: Image? = null
        try {
            image = reader.acquireLatestImage()
            if (image != null) {
                val bitmap = imageToBitmap(image)
                image.close()
                image = null
                if (bitmap != null) {
                    val file = File(cacheDir, "fracta_screen_${System.currentTimeMillis()}.jpg")
                    FileOutputStream(file).use { out ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    }
                    bitmap.recycle()
                    sendBroadcast(Intent(ACTION_CAPTURE_DONE).apply {
                        setPackage(packageName)
                        putExtra(EXTRA_CAPTURE_PATH, file.absolutePath)
                    })
                    return
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Capture failed", e)
        } finally {
            image?.close()
        }
        sendBroadcast(Intent(ACTION_CAPTURE_DONE).apply {
            setPackage(packageName)
            putExtra(EXTRA_CAPTURE_PATH, null as String?)
        })
    }

    private fun imageToBitmap(image: Image): Bitmap? {
        val planes = image.planes
        val buffer = planes[0].buffer
        buffer.rewind()
        val rowStride = planes[0].rowStride
        val pixelStride = planes[0].pixelStride
        val w = image.width
        val h = image.height
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        if (rowStride == pixelStride * w) {
            bitmap.copyPixelsFromBuffer(buffer)
        } else {
            val row = ByteArray(rowStride)
            val pixels = IntArray(w)
            var y = 0
            while (y < h && buffer.remaining() >= rowStride) {
                buffer.get(row)
                var x = 0
                var i = 0
                while (x < w && i + 3 < row.size) {
                    pixels[x] = (row[i + 3].toInt() and 0xff shl 24) or
                        (row[i].toInt() and 0xff shl 16) or
                        (row[i + 1].toInt() and 0xff shl 8) or
                        (row[i + 2].toInt() and 0xff)
                    x++
                    i += pixelStride
                }
                bitmap.setPixels(pixels, 0, w, 0, y, w, 1)
                y++
            }
        }
        return bitmap
    }

    private fun stopCapture() {
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        mediaProjection?.stop()
        mediaProjection = null
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "ScreenCaptureService"
        private const val NOTIFICATION_ID = 9001
        const val ACTION_START = "com.fracta.fracta.ScreenCaptureService.START"
        const val ACTION_CAPTURE = "com.fracta.fracta.ScreenCaptureService.CAPTURE"
        const val ACTION_STOP = "com.fracta.fracta.ScreenCaptureService.STOP"
        const val ACTION_CAPTURE_DONE = "com.fracta.fracta.CAPTURE_DONE"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_DATA = "data"
        const val EXTRA_CAPTURE_PATH = "capture_path"
    }
}
