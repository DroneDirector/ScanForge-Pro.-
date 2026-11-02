package fo.dronedirector.scanforgepro.live

import android.content.Context
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.view.View
import android.view.WindowManager
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/** The AR camera view shown inside the Flutter Live Scan screen. */
class LiveScanView(private val context: Context, private val live: LiveScanSession) : PlatformView, GLSurfaceView.Renderer {
    private val surface = GLSurfaceView(context).apply {
        preserveEGLContextOnPause = true
        setEGLContextClientVersion(2)
        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
    }

    init {
        surface.setRenderer(this)
        surface.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        live.resume()
        surface.onResume()
    }

    override fun getView(): View = surface

    override fun dispose() {
        surface.onPause()
        live.pause()
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        live.onSurfaceCreated()
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        @Suppress("DEPRECATION")
        val rotation = (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.rotation
        live.onSurfaceChanged(width, height, rotation)
    }

    override fun onDrawFrame(gl: GL10?) {
        live.onDrawFrame()
    }
}

class LiveScanViewFactory(private val sessionProvider: () -> LiveScanSession?) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val s = sessionProvider() ?: throw IllegalStateException("Live Scan session not open")
        return LiveScanView(context, s)
    }
}
