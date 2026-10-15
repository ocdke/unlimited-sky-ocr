package com.dpg.dpg_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * DPG 平台通道。
 *
 * 提供给 Flutter 的能力:
 *   * `nativeLibDir` — 原生库目录 (用于定位 libonnxruntime.so)
 *   * `screenSize`   — 屏幕物理像素尺寸
 *   * `capture`      — 抓取一帧屏幕, 返回 RGBA 字节
 *   * `hasCapture`   — 是否已持有录屏授权 (避免每次都弹窗)
 *
 * 说明: MediaProjection 在 Android 14 (API 34) 及以上必须由
 * `foregroundServiceType="mediaProjection"` 的前台服务持有, 因此真正的
 * 抓帧逻辑放在 [MediaProjectionService] 中。
 */
class MainActivity : FlutterActivity() {

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        MediaProjectionService.onFrame = { frame ->
            val r = pendingResult
            pendingResult = null
            if (frame == null) {
                r?.error("capture_failed", "未能抓取到屏幕帧", null)
            } else {
                r?.success(
                    mapOf(
                        "pixels" to frame.pixels,
                        "width" to frame.width,
                        "height" to frame.height,
                        "stride" to frame.width * 4,
                    )
                )
            }
        }
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "nativeLibDir" -> result.success(applicationInfo.nativeLibraryDir)
                "hasCapture" -> result.success(MediaProjectionService.hasProjection())
                "screenSize" -> result.success(screenSize())
                "releaseCapture" -> {
                    MediaProjectionService.stopCapture(this)
                    result.success(true)
                }
                "capture" -> startCapture(result)
                "ensureModels" -> {
                    // 首次启动把 APK 内的原生 assets/models 解包到 filesDir
                    Thread {
                        val r = try {
                            mapOf("path" to ensureModels())
                        } catch (e: Exception) {
                            mapOf("error" to (e.message ?: "解包失败"))
                        }
                        runOnUiThread { result.success(r) }
                    }.start()
                }
                "minimizeApp" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "restoreApp" -> {
                    val i = Intent(this, MainActivity::class.java)
                        .addFlags(
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                Intent.FLAG_ACTIVITY_NEW_TASK
                        )
                    startActivity(i)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        MediaProjectionService.onFrame = null
        super.onDestroy()
    }

    private fun screenSize(): Map<String, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = wm.currentWindowMetrics.bounds
            mapOf("width" to b.width(), "height" to b.height())
        } else {
            val dm = android.util.DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(dm)
            mapOf("width" to dm.widthPixels, "height" to dm.heightPixels)
        }
    }

    private fun startCapture(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "上一次截图尚未完成", null)
            return
        }
        pendingResult = result
        // 已有授权则直接抓帧, 不再弹窗
        if (MediaProjectionService.hasProjection()) {
            MediaProjectionService.grabFrame()
            return
        }
        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        @Suppress("DEPRECATION")
        startActivityForResult(mgr.createScreenCaptureIntent(), REQ_CAPTURE)
    }

    @Deprecated("MediaProjection 授权回调必须用 onActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_CAPTURE) return
        val r = pendingResult ?: return
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult = null
            r.error("denied", "用户拒绝了屏幕录制授权", null)
            return
        }
        // 交给前台服务持有 MediaProjection 并抓帧; 结果通过 onFrame 回调
        MediaProjectionService.startAndGrab(this, resultCode, data)
    }

    /**
     * 把 APK 内的原生 assets/models 递归解包到 filesDir/models。
     *
     * 模型是作为**原生 assets** 打包的 (android/app/src/main/assets/models),
     * 不走 Flutter 的 asset 机制 —— 这样 Windows 构建不必也跟着打包一份模型。
     * Rust 侧只能读文件系统, 所以必须先解包。
     */
    private fun ensureModels(): String {
        val root = java.io.File(filesDir, "models")
        val marker = java.io.File(root, ".extracted")
        if (marker.exists()) return root.absolutePath

        fun copy(path: String) {
            val children = assets.list(path)
            if (children.isNullOrEmpty()) {
                val out = java.io.File(root, path.removePrefix("models/"))
                out.parentFile?.mkdirs()
                assets.open(path).use { input ->
                    out.outputStream().use { output -> input.copyTo(output) }
                }
            } else {
                for (c in children) copy("$path/$c")
            }
        }
        copy("models")
        marker.writeText("ok")
        return root.absolutePath
    }

    companion object {
        const val CHANNEL = "dpg/native"
        private const val REQ_CAPTURE = 0x4450
    }
}