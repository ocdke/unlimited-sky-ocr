package com.dpg.dpg_app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/** 一帧屏幕像素 (RGBA_8888, 紧凑排布) */
class Frame(val pixels: ByteArray, val width: Int, val height: Int)

/**
 * 持有 MediaProjection 的前台服务。
 *
 * Android 14 (API 34) 起, `MediaProjectionManager.getMediaProjection()` 要求调用方
 * 已经运行一个 `foregroundServiceType="mediaProjection"` 的前台服务, 否则直接抛
 * SecurityException。因此这里把投影、VirtualDisplay 与 ImageReader 都放在服务里,
 * 抓帧结果通过 [onFrame] 回调给 Activity。
 */
class MediaProjectionService : Service() {

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private val handler = Handler(Looper.getMainLooper())

    /** 是否正在等待一帧 (用于按需抓帧, 避免持续占用) */
    @Volatile
    private var waiting = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()

        if (projection == null) {
            val code = intent?.getIntExtra(EXTRA_CODE, Activity.RESULT_CANCELED)
                ?: Activity.RESULT_CANCELED
            @Suppress("DEPRECATION")
            val data: Intent? = intent?.getParcelableExtra(EXTRA_DATA)
            if (code != Activity.RESULT_OK || data == null) {
                deliver(null)
                return START_NOT_STICKY
            }
            val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val mp = try {
                mgr.getMediaProjection(code, data)
            } catch (e: Exception) {
                null
            }
            if (mp == null) {
                deliver(null)
                return START_NOT_STICKY
            }
            projection = mp
            mp.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    teardown()
                }
            }, handler)
            setupVirtualDisplay()
        }

        waiting = true
        return START_NOT_STICKY
    }

    private fun setupVirtualDisplay() {
        val mp = projection ?: return
        val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
        var w: Int
        var h: Int
        var density: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = wm.currentWindowMetrics.bounds
            w = b.width(); h = b.height()
            density = resources.configuration.densityDpi
        } else {
            val dm = android.util.DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(dm)
            w = dm.widthPixels; h = dm.heightPixels; density = dm.densityDpi
        }
        // 上限保护: 过大的虚拟显示会占用巨额显存
        val maxSide = 2560
        if (w > maxSide || h > maxSide) {
            val r = maxSide.toFloat() / maxOf(w, h)
            w = (w * r).toInt(); h = (h * r).toInt()
        }

        reader?.close()
        val ir = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader = ir
        ir.setOnImageAvailableListener({ r ->
            if (!waiting) {
                // 丢弃非请求帧, 但必须 close 否则缓冲区耗尽
                r.acquireLatestImage()?.close()
                return@setOnImageAvailableListener
            }
            waiting = false
            val image = r.acquireLatestImage()
            if (image == null) {
                deliver(null)
                return@setOnImageAvailableListener
            }
            val frame = try {
                imageToFrame(image)
            } catch (e: Exception) {
                null
            } finally {
                image.close()
            }
            deliver(frame)
        }, handler)

        virtualDisplay?.release()
        virtualDisplay = mp.createVirtualDisplay(
            "dpg-capture",
            w, h, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            ir.surface, null, handler
        )
    }

    /** RGBA_8888 Image -> 紧凑 RGBA 字节数组 (处理 rowStride 对齐填充) */
    private fun imageToFrame(image: Image): Frame {
        val plane = image.planes[0]
        val buf = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val w = image.width
        val h = image.height
        val out = ByteArray(w * h * 4)
        if (pixelStride == 4) {
            for (y in 0 until h) {
                buf.position(y * rowStride)
                val n = minOf(w * 4, buf.remaining())
                buf.get(out, y * w * 4, n)
            }
        } else {
            // 极端情况: 逐像素读取
            val px = ByteArray(pixelStride)
            for (y in 0 until h) {
                for (x in 0 until w) {
                    buf.position(y * rowStride + x * pixelStride)
                    buf.get(px, 0, minOf(4, pixelStride))
                    val o = (y * w + x) * 4
                    out[o] = px[0]
                    if (pixelStride > 1) out[o + 1] = px[1]
                    if (pixelStride > 2) out[o + 2] = px[2]
                    out[o + 3] = 0xFF.toByte()
                }
            }
        }
        return Frame(out, w, h)
    }

    private fun deliver(frame: Frame?) {
        val cb = onFrame
        handler.post { cb?.invoke(frame) }
    }

    private fun teardown() {
        virtualDisplay?.release(); virtualDisplay = null
        reader?.close(); reader = null
        projection = null
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "屏幕识别", NotificationManager.IMPORTANCE_MIN
                    )
                )
            }
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val n = builder
            .setContentTitle("DPG 屏幕识别")
            .setContentText("正在捕获屏幕用于识别")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    companion object {
        const val CHANNEL_ID = "dpg_capture"
        const val NOTIF_ID = 0x4450
        private const val EXTRA_CODE = "resultCode"
        private const val EXTRA_DATA = "resultData"

        /** 抓帧完成回调 (主线程); 由 MainActivity 注入 */
        @Volatile
        var onFrame: ((Frame?) -> Unit)? = null

        private var svc: MediaProjectionService? = null

        fun hasProjection(): Boolean = svc?.projection != null

        /** 首次: 用授权结果启动服务并立即抓一帧 */
        fun startAndGrab(context: Context, resultCode: Int, data: Intent) {
            val i = Intent(context, MediaProjectionService::class.java)
                .putExtra(EXTRA_CODE, resultCode)
                .putExtra(EXTRA_DATA, data)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        /** 已有投影: 直接请求下一帧 */
        fun grabFrame() {
            val s = svc
            if (s == null) {
                onFrame?.invoke(null)
                return
            }
            s.waiting = true
            // ImageReader 只在新帧到达时回调; 主动触发一次清理以确保拿到最新内容
            s.reader?.acquireLatestImage()?.close()
        }

        fun stopCapture(context: Context) {
            context.stopService(Intent(context, MediaProjectionService::class.java))
        }

        fun attach(instance: MediaProjectionService) {
            svc = instance
        }

        fun detach(instance: MediaProjectionService) {
            if (svc === instance) svc = null
        }
    }

    init {
        attach(this)
    }

    override fun onCreate() {
        super.onCreate()
        attach(this)
    }
}
