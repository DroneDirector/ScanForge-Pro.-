package fo.dronedirector.scanforgepro.live

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Connects the Flutter Live Scan screen with ARCore. */
class LiveScanPlugin(private val activity: Activity, engine: FlutterEngine) {
    private var session: LiveScanSession? = null
    private var sink: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    init {
        engine.platformViewsController.registry.registerViewFactory("scanforge/arview", LiveScanViewFactory { session })
        EventChannel(engine.dartExecutor.binaryMessenger, "scanforge/live/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
                override fun onCancel(arguments: Any?) { sink = null }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "scanforge/live").setMethodCallHandler { call, result ->
            when (call.method) {
                "availability" -> {
                    val a = ArCoreApk.getInstance().checkAvailability(activity)
                    result.success(
                        when {
                            a == ArCoreApk.Availability.SUPPORTED_INSTALLED -> "supported"
                            a == ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD ||
                                a == ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED -> "install"
                            a.isTransient -> "checking"
                            else -> "unsupported"
                        })
                }
                "install" -> {
                    try {
                        val r = ArCoreApk.getInstance().requestInstall(activity, true)
                        result.success(if (r == ArCoreApk.InstallStatus.INSTALLED) "installed" else "requested")
                    } catch (e: Exception) {
                        result.success("failed")
                    }
                }
                "cameraPermission" -> {
                    if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else {
                        pendingPermission = result
                        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.CAMERA), REQUEST_CAMERA)
                    }
                }
                "open" -> {
                    session?.let { Thread { it.finish() }.start() }
                    val s = LiveScanSession(activity) { m -> sink?.success(m) }
                    val status = s.open(call.argument<String>("project") ?: "")
                    session = if (status.startsWith("ok")) s else null
                    result.success(status)
                }
                "tap" -> {
                    session?.tap((call.argument<Double>("x") ?: 0.0).toFloat(), (call.argument<Double>("y") ?: 0.0).toFloat())
                    result.success(null)
                }
                "shutter" -> { session?.shutter(); result.success(null) }
                "auto" -> { session?.auto = call.argument<Boolean>("on") ?: true; result.success(null) }
                "reset" -> { session?.resetTarget(); result.success(null) }
                "finish" -> {
                    val s = session
                    session = null
                    if (s == null) {
                        result.success(mapOf("photos" to 0, "rotation" to 90))
                    } else {
                        Thread {
                            val r = s.finish()
                            main.post { result.success(r) }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CAMERA) return false
        pendingPermission?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        pendingPermission = null
        return true
    }

    companion object {
        const val REQUEST_CAMERA = 4711
    }
}
