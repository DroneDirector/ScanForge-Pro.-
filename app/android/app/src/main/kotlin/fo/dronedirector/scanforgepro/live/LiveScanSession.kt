package fo.dronedirector.scanforgepro.live

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.Image
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.google.ar.core.CameraConfig
import com.google.ar.core.CameraConfigFilter
import com.google.ar.core.CameraIntrinsics
import com.google.ar.core.Config
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Live Scan: ARCore tracking, automatic photo picking, live coverage grid.
 * Photos go to <project>/photos, camera positions to <project>/poses.txt and
 * AI object outlines to <project>/masks, which the 3D engine then uses.
 */
class LiveScanSession(private val context: Context, private val emit: (Map<String, Any?>) -> Unit) {
    var session: Session? = null
        private set
    val background = BackgroundRenderer()
    private val main = Handler(Looper.getMainLooper())

    private lateinit var projectDir: File
    private lateinit var photosDir: File
    private lateinit var masksDir: File
    private lateinit var posesFile: File

    @Volatile private var grid: CoverageGrid? = null
    @Volatile private var center: FloatArray? = null
    @Volatile var auto = true
    @Volatile private var pendingTap: FloatArray? = null
    @Volatile private var captureRequested = false
    @Volatile private var selecting = false
    @Volatile private var stopped = false

    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val saver: ExecutorService = Executors.newSingleThreadExecutor()
    private val integrating = AtomicBoolean(false)
    private val photoCount = AtomicInteger(0)
    private val savedCount = AtomicInteger(0)
    private var segmenter: ObjectSegmenter? = null
    private var segmenterTried = false

    private val kfDirs = ArrayList<FloatArray>()  // unit direction from object + distance
    private var lastKfTime = 0L
    private var lastIntegrate = 0L
    private var lastStats = 0L
    private var viewW = 1
    private var viewH = 1
    private var rotation = 0
    private var imageW = 0
    private var imageH = 0

    // motion
    private var prevCenter: FloatArray? = null
    private var prevForward: FloatArray? = null
    private var prevTime = 0L
    private var speed = 0f
    private var turnRate = 0f

    @Volatile private var lastStatsObj: CoverageGrid.Stats? = null
    private val view = FloatArray(16)
    private val proj = FloatArray(16)

    // ------------------------------------------------------------------ setup
    fun open(project: String): String {
        projectDir = File(project)
        photosDir = File(projectDir, "photos").apply { mkdirs() }
        masksDir = File(projectDir, "masks").apply { mkdirs() }
        posesFile = File(projectDir, "poses.txt")
        val existing = photosDir.listFiles()?.count { it.name.startsWith("LIVE_") } ?: 0
        photoCount.set(existing)
        savedCount.set(existing)
        return try {
            val s = Session(context)
            val filter = CameraConfigFilter(s).setFacingDirection(CameraConfig.FacingDirection.BACK)
            val configs = s.getSupportedCameraConfigs(filter)
            val best = configs.maxByOrNull { it.imageSize.width * it.imageSize.height }
            if (best != null) s.cameraConfig = best
            imageW = s.cameraConfig.imageSize.width
            imageH = s.cameraConfig.imageSize.height
            val cfg = Config(s)
            cfg.focusMode = Config.FocusMode.AUTO
            cfg.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
            cfg.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL
            cfg.lightEstimationMode = Config.LightEstimationMode.DISABLED
            cfg.depthMode = if (s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) Config.DepthMode.AUTOMATIC
            else Config.DepthMode.DISABLED
            s.configure(cfg)
            session = s
            if (!posesFile.exists()) posesFile.writeText("up 0 1 0\nsize $imageW $imageH\n")
            if (cfg.depthMode == Config.DepthMode.DISABLED) "ok_no_depth" else "ok"
        } catch (e: Throwable) {
            Log.w(TAG, "ARCore session failed", e)
            "error: ${e.javaClass.simpleName}"
        }
    }

    fun resume() {
        try { session?.resume() } catch (e: Throwable) { Log.w(TAG, "resume failed", e) }
    }

    fun pause() {
        try { session?.pause() } catch (_: Throwable) {}
    }

    /** Stops scanning, waits for photos to be written. Returns photo count and photo rotation. */
    fun finish(): Map<String, Any?> {
        stopped = true
        saver.shutdown()
        try { saver.awaitTermination(30, TimeUnit.SECONDS) } catch (_: InterruptedException) {}
        worker.shutdownNow()
        var rotationDeg = 90
        try {
            val id = session?.cameraConfig?.cameraId
            if (id != null) {
                val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                rotationDeg = cm.getCameraCharacteristics(id).get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            }
        } catch (_: Throwable) {}
        pause()
        try { session?.close() } catch (_: Throwable) {}
        session = null
        segmenter?.close()
        return mapOf("photos" to savedCount.get(), "rotation" to rotationDeg)
    }

    fun tap(x: Float, y: Float) { pendingTap = floatArrayOf(x, y) }
    fun shutter() { captureRequested = true }
    fun resetTarget() {
        grid = null
        center = null
        kfDirs.clear()
        emit(mapOf("type" to "selected", "cleared" to true))
    }

    // ------------------------------------------------------------------ GL
    fun onSurfaceCreated() {
        background.create()
        session?.setCameraTextureName(background.textureId)
    }

    fun onSurfaceChanged(w: Int, h: Int, displayRotation: Int) {
        viewW = w
        viewH = h
        rotation = displayRotation
        GLES20.glViewport(0, 0, w, h)
        session?.setDisplayGeometry(rotation, w, h)
    }

    fun onDrawFrame() {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val s = session ?: return
        if (stopped) return
        val frame = try { s.update() } catch (e: Throwable) { return }
        background.draw(frame)
        val camera = frame.camera
        val tracking = camera.trackingState == TrackingState.TRACKING
        camera.getViewMatrix(view, 0)
        camera.getProjectionMatrix(proj, 0, 0.03f, 100f)
        val now = SystemClock.uptimeMillis()

        var cam: CamModel? = null
        if (tracking) {
            cam = camModel(camera.pose, camera.imageIntrinsics)
            updateMotion(cam, now)
            pendingTap?.let {
                pendingTap = null
                startSelection(frame, it[0], it[1], camera.pose, cam)
            }
            if (grid != null && now - lastIntegrate > 180 && !integrating.get()) {
                lastIntegrate = now
                queueIntegration(frame, camera.pose, camera.textureIntrinsics)
            }
            if (grid != null) maybeCapture(frame, cam, now)
        }
        if (grid != null && now - lastStats > 500 && !integrating.get()) {
            lastStats = now
            val g = grid
            worker.execute {
                if (g != null) {
                    val st = g.stats()
                    lastStatsObj = st
                    val pts = g.surfacePoints()
                    post(mapOf(
                        "type" to "points", "data" to pts,
                        "captured" to capturedScore(st).toDouble(), "detail" to st.detail.toDouble(),
                        "bins" to g.dirBins.copyOf(), "surface" to st.surface,
                    ))
                }
            }
        }
        post(mapOf(
            "type" to "frame", "tracking" to tracking,
            "view" to view.copyOf(), "proj" to proj.copyOf(),
            "hint" to hint(camera, cam, tracking), "photos" to photoCount.get(),
            "selecting" to selecting, "auto" to auto,
        ))
    }

    private fun post(m: Map<String, Any?>) { main.post { emit(m) } }

    private fun capturedScore(st: CoverageGrid.Stats): Float {
        val surface = if (st.surface > 0) st.captured.toFloat() / st.surface else 0f
        return (0.55f * st.directions + 0.45f * surface).coerceIn(0f, 1f)
    }

    // ------------------------------------------------------------------ geometry helpers
    /** ARCore pose (OpenGL camera) -> world->camera with x right, y down, z forward. */
    private fun camModel(pose: com.google.ar.core.Pose, intr: CameraIntrinsics): CamModel {
        val m = FloatArray(16)
        pose.toMatrix(m, 0)
        val r = floatArrayOf(
            m[0], m[1], m[2],          // camera x axis (right)
            -m[4], -m[5], -m[6],       // camera y axis (down)
            -m[8], -m[9], -m[10],      // camera z axis (forward)
        )
        val c = floatArrayOf(m[12], m[13], m[14])
        val t = floatArrayOf(
            -(r[0] * c[0] + r[1] * c[1] + r[2] * c[2]),
            -(r[3] * c[0] + r[4] * c[1] + r[5] * c[2]),
            -(r[6] * c[0] + r[7] * c[1] + r[8] * c[2]),
        )
        val f = intr.focalLength
        val p = intr.principalPoint
        val d = intr.imageDimensions
        return CamModel(r, t, f[0], f[1], p[0], p[1], d[0], d[1])
    }

    private fun updateMotion(cam: CamModel, now: Long) {
        val c = cam.center()
        val fwd = floatArrayOf(cam.r[6], cam.r[7], cam.r[8])
        val pc = prevCenter
        val pf = prevForward
        if (pc != null && pf != null && now > prevTime) {
            val dt = (now - prevTime) / 1000f
            val dx = c[0] - pc[0]; val dy = c[1] - pc[1]; val dz = c[2] - pc[2]
            val v = sqrt(dx * dx + dy * dy + dz * dz) / dt
            val dot = (fwd[0] * pf[0] + fwd[1] * pf[1] + fwd[2] * pf[2]).coerceIn(-1f, 1f)
            val w = Math.toDegrees(acos(dot).toDouble()).toFloat() / dt
            speed = speed * 0.7f + v * 0.3f
            turnRate = turnRate * 0.7f + w * 0.3f
        }
        prevCenter = c
        prevForward = fwd
        prevTime = now
    }

    private fun steady() = speed < 0.12f && turnRate < 22f

    private fun project(cam: CamModel, p: FloatArray): FloatArray? {
        val r = cam.r; val t = cam.t
        val zc = r[6] * p[0] + r[7] * p[1] + r[8] * p[2] + t[2]
        if (zc <= 0.02f) return null
        val xc = r[0] * p[0] + r[1] * p[1] + r[2] * p[2] + t[0]
        val yc = r[3] * p[0] + r[4] * p[1] + r[5] * p[2] + t[1]
        return floatArrayOf(cam.fx * xc / zc + cam.cx, cam.fy * yc / zc + cam.cy, zc)
    }

    // ------------------------------------------------------------------ depth
    private class DepthCopy(val data: ShortArray, val width: Int, val height: Int)

    private fun copyDepth(frame: Frame): DepthCopy? {
        var img: Image? = null
        return try {
            img = frame.acquireDepthImage16Bits()
            val w = img.width
            val h = img.height
            val plane = img.planes[0]
            val buf = plane.buffer.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer()
            val rowShorts = plane.rowStride / 2
            val out = ShortArray(w * h)
            for (y in 0 until h) {
                buf.position(y * rowShorts)
                buf.get(out, y * w, w)
            }
            DepthCopy(out, w, h)
        } catch (e: Throwable) {
            null
        } finally {
            img?.close()
        }
    }

    private fun queueIntegration(frame: Frame, pose: com.google.ar.core.Pose, tex: CameraIntrinsics) {
        val g = grid ?: return
        val depth = copyDepth(frame) ?: return
        val dcam = camModel(pose, tex).scaled(depth.width, depth.height)
        integrating.set(true)
        worker.execute {
            try { g.integrate(depth.data, dcam) } finally { integrating.set(false) }
        }
    }

    // ------------------------------------------------------------------ camera image
    private class YuvCopy(val w: Int, val h: Int, val y: ByteArray, val u: ByteArray, val v: ByteArray,
                          val yRow: Int, val uvRow: Int, val uvPixel: Int)

    private fun copyImage(frame: Frame): YuvCopy? {
        var img: Image? = null
        return try {
            img = frame.acquireCameraImage()
            val p = img.planes
            fun bytes(b: java.nio.ByteBuffer): ByteArray { val a = ByteArray(b.remaining()); b.get(a); return a }
            YuvCopy(img.width, img.height, bytes(p[0].buffer), bytes(p[1].buffer), bytes(p[2].buffer),
                p[0].rowStride, p[1].rowStride, p[1].pixelStride)
        } catch (e: Throwable) {
            null
        } finally {
            img?.close()
        }
    }

    private fun toJpeg(yuv: YuvCopy): ByteArray {
        val w = yuv.w
        val h = yuv.h
        val nv21 = ByteArray(w * h * 3 / 2)
        for (row in 0 until h) System.arraycopy(yuv.y, row * yuv.yRow, nv21, row * w, w)
        var o = w * h
        for (row in 0 until h / 2) for (col in 0 until w / 2) {
            val i = row * yuv.uvRow + col * yuv.uvPixel
            nv21[o++] = yuv.v[min(i, yuv.v.size - 1)]
            nv21[o++] = yuv.u[min(i, yuv.u.size - 1)]
        }
        val out = ByteArrayOutputStream()
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), 93, out)
        return out.toByteArray()
    }

    private fun segmenterOrNull(): ObjectSegmenter? {
        if (!segmenterTried) {
            segmenterTried = true
            segmenter = ObjectSegmenter.create(context)
        }
        return segmenter
    }

    // ------------------------------------------------------------------ object selection
    private fun startSelection(frame: Frame, x: Float, y: Float, pose: com.google.ar.core.Pose, cam: CamModel) {
        if (selecting) return
        val depth = copyDepth(frame)
        if (depth == null) {
            post(mapOf("type" to "message", "text" to "Move the phone a little so depth can be measured, then tap again"))
            return
        }
        val texN = FloatArray(2)
        frame.transformCoordinates2d(Coordinates2d.VIEW, floatArrayOf(x, y), Coordinates2d.TEXTURE_NORMALIZED, texN)
        val imgN = FloatArray(2)
        frame.transformCoordinates2d(Coordinates2d.VIEW, floatArrayOf(x, y), Coordinates2d.IMAGE_NORMALIZED, imgN)
        val dcam = camModel(pose, frame.camera.textureIntrinsics).scaled(depth.width, depth.height)
        var tableY: Float? = null
        val hits = frame.hitTest(x, y)
        val hitY = hits.firstOrNull()?.hitPose?.ty()
        session?.getAllTrackables(Plane::class.java)?.forEach { p ->
            if (p.trackingState == TrackingState.TRACKING && p.type == Plane.Type.HORIZONTAL_UPWARD_FACING) {
                val py = p.centerPose.ty()
                if (hitY == null || py < hitY - 0.004f) tableY = max(tableY ?: -1e9f, py)
            }
        }
        val yuv = copyImage(frame)
        val hitPoint = hits.firstOrNull()?.hitPose?.let { floatArrayOf(it.tx(), it.ty(), it.tz()) }
        selecting = true
        worker.execute {
            try { select(depth, dcam, texN, imgN, yuv, cam, tableY, hitPoint) } catch (e: Throwable) {
                Log.w(TAG, "selection failed", e)
            } finally { selecting = false }
        }
    }

    private fun select(depth: DepthCopy, dcam: CamModel, texN: FloatArray, imgN: FloatArray, yuv: YuvCopy?,
                       cam: CamModel, tableY: Float?, hitPoint: FloatArray?) {
        val w = depth.width
        val h = depth.height
        val seedX = (texN[0] * w).toInt().coerceIn(0, w - 1)
        val seedY = (texN[1] * h).toInt().coerceIn(0, h - 1)
        fun world(u: Int, v: Int, d: Float): FloatArray {
            val xc = (u - dcam.cx) / dcam.fx * d
            val yc = (v - dcam.cy) / dcam.fy * d
            val r = dcam.r; val t = dcam.t
            val a = xc - t[0]; val b = yc - t[1]; val c = d - t[2]
            return floatArrayOf(r[0] * a + r[3] * b + r[6] * c, r[1] * a + r[4] * b + r[7] * c, r[2] * a + r[5] * b + r[8] * c)
        }
        fun depthAt(u: Int, v: Int) = (depth.data[v * w + u].toInt() and 0xFFFF) / 1000f

        // 1) AI outline (if available), mapped into the depth image
        var objMask: BooleanArray? = null
        var aiUsed = false
        var aiWidthPx = 0f   // object width in the camera image (pixels of the full image)
        var aiHeightPx = 0f
        val seg = segmenterOrNull()
        if (seg != null && yuv != null) {
            val jpeg = toJpeg(yuv)
            val opts = BitmapFactory.Options().apply { inSampleSize = max(1, yuv.w / 480) }
            val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, opts)
            val m = if (bmp != null) seg.segment(bmp, imgN[0], imgN[1]) else null
            if (m != null && bmp != null) {
                var x0 = bmp.width; var x1 = -1; var y0 = bmp.height; var y1 = -1
                for (yy in 0 until bmp.height) for (xx in 0 until bmp.width) {
                    if (m[yy * bmp.width + xx].toInt() == 0) continue
                    if (xx < x0) x0 = xx
                    if (xx > x1) x1 = xx
                    if (yy < y0) y0 = yy
                    if (yy > y1) y1 = yy
                }
                if (x1 >= x0) {
                    aiWidthPx = (x1 - x0 + 1f) * cam.width / bmp.width
                    aiHeightPx = (y1 - y0 + 1f) * cam.height / bmp.height
                }
                val icam = cam.scaled(bmp.width, bmp.height)
                val mask = BooleanArray(w * h)
                for (v in 0 until h) for (u in 0 until w) {
                    val d = depthAt(u, v)
                    val dd = if (d > 0) d else 1f
                    val p = project(icam, world(u, v, dd)) ?: continue
                    val iu = p[0].toInt(); val iv = p[1].toInt()
                    if (iu in 0 until bmp.width && iv in 0 until bmp.height && m[iv * bmp.width + iu].toInt() != 0) mask[v * w + u] = true
                }
                objMask = mask
                aiUsed = true
            }
            bmp?.recycle()
        }

        // 2) object pixels: AI outline, else depth flood fill from the tapped point
        val inObj = BooleanArray(w * h)
        val queue = ArrayDeque<Int>()
        val seedD = depthAt(seedX, seedY)
        if (objMask != null) {
            for (i in 0 until w * h) if (objMask[i] && depthAt(i % w, i / w) > 0) inObj[i] = true
        } else if (seedD > 0) {
            inObj[seedY * w + seedX] = true
            queue.add(seedY * w + seedX)
            while (queue.isNotEmpty()) {
                val i = queue.removeFirst()
                val u = i % w; val v = i / w
                val d0 = depthAt(u, v)
                for ((du, dv) in arrayOf(1 to 0, -1 to 0, 0 to 1, 0 to -1)) {
                    val nu = u + du; val nv = v + dv
                    if (nu !in 0 until w || nv !in 0 until h) continue
                    val j = nv * w + nu
                    if (inObj[j]) continue
                    val d1 = depthAt(nu, nv)
                    if (d1 <= 0 || kotlin.math.abs(d1 - d0) > max(0.015f, 0.03f * d0)) continue
                    if (tableY != null && world(nu, nv, d1)[1] < tableY + 0.006f) continue
                    inObj[j] = true
                    queue.add(j)
                }
            }
        }
        val pts = ArrayList<FloatArray>()
        val outline = ArrayList<Float>()
        for (v in 0 until h) for (u in 0 until w) {
            val i = v * w + u
            if (!inObj[i]) continue
            val d = depthAt(u, v)
            val p = world(u, v, d)
            if (tableY != null && p[1] < tableY + 0.004f) continue
            pts.add(p)
            val edge = u == 0 || v == 0 || u == w - 1 || v == h - 1 ||
                !inObj[i - 1] || !inObj[i + 1] || !inObj[i - w] || !inObj[i + w]
            if (edge) { outline.add(p[0]); outline.add(p[1]); outline.add(p[2]) }
        }
        var cxw: Float
        var czw: Float
        var minY: Float
        var maxY: Float
        var rVis = 0f
        if (pts.size >= 6) {
            var sx = 0f; var sz = 0f; minY = Float.MAX_VALUE; maxY = -Float.MAX_VALUE
            for (p in pts) { sx += p[0]; sz += p[2]; minY = min(minY, p[1]); maxY = max(maxY, p[1]) }
            cxw = sx / pts.size
            czw = sz / pts.size
            for (p in pts) { val dx = p[0] - cxw; val dz = p[2] - czw; rVis = max(rVis, sqrt(dx * dx + dz * dz)) }
        } else if (hitPoint != null) {
            // small object: depth is too coarse; size it from the AI outline (or a small default)
            val c0 = cam.center()
            val dist = sqrt((hitPoint[0] - c0[0]) * (hitPoint[0] - c0[0]) + (hitPoint[1] - c0[1]) * (hitPoint[1] - c0[1]) +
                (hitPoint[2] - c0[2]) * (hitPoint[2] - c0[2]))
            val wM = if (aiWidthPx > 0) aiWidthPx * dist / cam.fx else 0.04f
            val hM = if (aiHeightPx > 0) aiHeightPx * dist / cam.fy else 0.05f
            cxw = hitPoint[0]
            czw = hitPoint[2]
            rVis = (wM / 2).coerceIn(0.01f, 0.3f)
            minY = tableY ?: (hitPoint[1] - hM / 2)
            maxY = max(hitPoint[1] + hM / 2, minY + hM)
            outline.clear()
        } else {
            post(mapOf("type" to "message", "text" to "Couldn't find an object there. Move a little closer and tap the object again."))
            return
        }
        // the camera sees the front half: move the centre back along the view direction
        val c = cam.center()
        var vx = cxw - c[0]; var vz = czw - c[2]
        val vl = sqrt(vx * vx + vz * vz).coerceAtLeast(1e-4f)
        vx /= vl; vz /= vl
        cxw += vx * rVis * 0.45f
        czw += vz * rVis * 0.45f
        val radius = (rVis * 1.4f + 0.015f).coerceIn(0.025f, 1.6f)
        val bottom = (tableY ?: minY) - 0.01f
        val top = maxY + max(0.03f, 0.25f * (maxY - bottom))
        val g = CoverageGrid(cxw, czw, radius, bottom, top)
        val maskBytes = ByteArray(w * h) { if (inObj[it] || !aiUsed) 1.toByte() else 0.toByte() }
        g.integrate(depth.data, dcam, if (aiUsed) maskBytes else null)
        grid = g
        center = floatArrayOf(cxw, (bottom + top) / 2, czw)
        kfDirs.clear()
        // keep the outline light for drawing
        val step = max(1, outline.size / 3 / 700)
        val ol = ArrayList<Float>()
        var k = 0
        while (k < outline.size) { ol.add(outline[k]); ol.add(outline[k + 1]); ol.add(outline[k + 2]); k += 3 * step }
        post(mapOf(
            "type" to "selected", "center" to floatArrayOf(cxw, bottom, czw), "radius" to radius.toDouble(),
            "bottom" to bottom.toDouble(), "top" to top.toDouble(), "outline" to ol.toFloatArray(), "ai" to aiUsed,
        ))
    }

    // ------------------------------------------------------------------ photos
    private fun maybeCapture(frame: Frame, cam: CamModel, now: Long) {
        val ctr = center ?: return
        val g = grid ?: return
        if (now - lastKfTime < 450) return
        val manual = captureRequested
        if (!manual && (!auto || !steady())) return
        val pr = project(cam, ctr) ?: return
        if (!manual && (pr[0] < cam.width * 0.15f || pr[0] > cam.width * 0.85f ||
                    pr[1] < cam.height * 0.15f || pr[1] > cam.height * 0.85f)) return
        val c = cam.center()
        var dx = c[0] - ctr[0]; var dy = c[1] - ctr[1]; var dz = c[2] - ctr[2]
        val dist = sqrt(dx * dx + dy * dy + dz * dz)
        dx /= dist; dy /= dist; dz /= dist
        val apparent = g.radius * cam.fx / dist / cam.width
        if (!manual && (apparent < 0.05f || apparent > 1.4f || dist < 0.1f)) return
        if (!manual) {
            var novel = true
            for (k in kfDirs) {
                val ang = Math.toDegrees(acos((dx * k[0] + dy * k[1] + dz * k[2]).coerceIn(-1f, 1f).toDouble()))
                val ratio = max(dist, k[3]) / min(dist, k[3])
                if (ang < 8.0 && !(ang >= 3.0 && ratio > 1.35f)) { novel = false; break }
            }
            if (!novel) return
        }
        captureRequested = false
        val yuv = copyImage(frame) ?: return
        val depth = copyDepth(frame)
        val dcam = if (depth != null) camModel(frame.camera.pose, frame.camera.textureIntrinsics).scaled(depth.width, depth.height) else null
        lastKfTime = now
        kfDirs.add(floatArrayOf(dx, dy, dz, dist))
        val n = photoCount.incrementAndGet()
        val name = String.format(Locale.US, "LIVE_%04d", n)
        val icam = cam.scaled(yuv.w, yuv.h)
        post(mapOf("type" to "photo", "photos" to n))
        saver.execute { savePhoto(name, yuv, icam, depth, dcam, g, ctr) }
    }

    private fun savePhoto(name: String, yuv: YuvCopy, cam: CamModel, depth: DepthCopy?, dcam: CamModel?,
                          g: CoverageGrid, ctr: FloatArray) {
        try {
            val jpeg = toJpeg(yuv)
            FileOutputStream(File(photosDir, "$name.jpg")).use { it.write(jpeg) }
            val line = StringBuilder("$name.jpg")
            for (v in floatArrayOf(cam.fx, cam.fy, cam.cx, cam.cy)) line.append(' ').append(v)
            for (v in cam.r) line.append(' ').append(v)
            for (v in cam.t) line.append(' ').append(v)
            synchronized(this) { posesFile.appendText(line.toString() + "\n") }
            g.markPhoto(cam, depth?.data, dcam)
            savedCount.incrementAndGet()

            // AI outline of the object for this photo (helps plain or dark objects)
            val seg = segmenterOrNull() ?: return
            val pc = project(cam, ctr) ?: return
            val opts = BitmapFactory.Options().apply { inSampleSize = max(1, yuv.w / 640) }
            val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, opts) ?: return
            val mask = seg.segment(bmp, pc[0] / cam.width, pc[1] / cam.height)
            if (mask != null) {
                g.carve(mask, cam.scaled(bmp.width, bmp.height))
                val pixels = IntArray(mask.size) { if (mask[it].toInt() != 0) -0x1 else -0x1000000 }
                val mb = Bitmap.createBitmap(pixels, bmp.width, bmp.height, Bitmap.Config.ARGB_8888)
                FileOutputStream(File(masksDir, "$name.png")).use { mb.compress(Bitmap.CompressFormat.PNG, 100, it) }
                mb.recycle()
            }
            bmp.recycle()
        } catch (e: Throwable) {
            Log.w(TAG, "saving photo failed", e)
        }
    }

    // ------------------------------------------------------------------ hints
    private fun hint(camera: com.google.ar.core.Camera, cam: CamModel?, tracking: Boolean): String {
        if (!tracking) {
            return when (camera.trackingFailureReason) {
                TrackingFailureReason.INSUFFICIENT_LIGHT -> "Too dark: add more light"
                TrackingFailureReason.EXCESSIVE_MOTION -> "Move the phone more slowly"
                TrackingFailureReason.INSUFFICIENT_FEATURES -> "Point at the object and its surroundings"
                else -> "Move the phone slowly to start tracking"
            }
        }
        if (selecting) return "Finding the object…"
        val ctr = center
        if (grid == null || ctr == null || cam == null) return "Tap the object you want to scan"
        val pr = project(cam, ctr)
        if (pr == null || pr[0] < 0 || pr[0] > cam.width || pr[1] < 0 || pr[1] > cam.height) return "Point the camera at the object"
        val c = cam.center()
        val dist = sqrt((c[0] - ctr[0]) * (c[0] - ctr[0]) + (c[1] - ctr[1]) * (c[1] - ctr[1]) + (c[2] - ctr[2]) * (c[2] - ctr[2]))
        val apparent = grid!!.radius * cam.fx / dist / cam.width
        if (dist < 0.12f) return "Too close: keep about 15 cm or more away"
        if (apparent < 0.12f) return if (grid!!.radius < 0.06f) "Move closer (about 15–25 cm for small objects)" else "Move closer"
        if (apparent > 1.2f) return "Step back a little"
        if (!steady()) return "Move slowly and hold steady"
        val st = lastStatsObj ?: return "Walk slowly around the object"
        val bins = grid!!.dirBins
        var mid = 0; var high = 0
        for (b in 0 until 48) if (bins[b] > 0) mid++
        for (b in 48 until 72) if (bins[b] > 0) high++
        val score = capturedScore(st)
        return when {
            mid < 34 -> "Walk slowly around the object"
            high < 12 -> "Now raise the phone and look down at the top"
            score < 0.85f -> "Fill in the red spots"
            else -> "Great! Tap Done to build the 3D model"
        }
    }

    companion object {
        private const val TAG = "ScanForgeLive"
    }
}
