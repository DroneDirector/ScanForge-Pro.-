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
    private var trackingSince = 0L
    @Volatile private var autoSelectDone = false
    /** Scan box: bottom centre x, y, z, yaw (rad), width, depth, height (metres). */
    @Volatile private var box: FloatArray? = null
    @Volatile private var scanning = false
    @Volatile private var selectedAt = 0L
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

    /** Tap on the object; [useAi] = let the AI guess the object's outline. */
    /** Sets the scan box (from the sliders) and rebuilds the live volume around it. */
    fun applyBox(b: FloatArray) {
        box = b.copyOf()
        val r = (0.5f * sqrt(b[4] * b[4] + b[5] * b[5]) * 1.15f).coerceIn(0.02f, 1.0f)
        val g = CoverageGrid(b[0], b[2], r, b[1] - 0.008f, b[1] + b[6] * 1.15f + 0.01f, floorY = b[1])
        val old = grid
        if (old != null) for (i in 0 until 72) g.dirBins[i] = old.dirBins[i]
        grid = g
        center = floatArrayOf(b[0], b[1] + b[6] / 2, b[2])
        if (selectedAt == 0L) selectedAt = SystemClock.uptimeMillis()
        post(mapOf("type" to "box", "box" to b.copyOf()))
    }

    fun startScan() {
        val b = box ?: return
        scanning = true
        try {
            File(projectDir, "box.txt").writeText(String.format(Locale.US, "%f %f %f %f %f %f %f\n",
                b[0], b[1], b[2], b[3], b[4], b[5], b[6]))
        } catch (_: Throwable) {}
        post(mapOf("type" to "scanning", "on" to true))
    }

    fun tap(x: Float, y: Float, useAi: Boolean) { pendingTap = floatArrayOf(x, y, if (useAi) 1f else 0f) }
    fun shutter() { captureRequested = true }
    fun resetTarget() {
        autoSelectDone = true
        box = null
        scanning = false
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
        diagnostics(now, tracking)
        if (!tracking) trackingSince = 0L
        if (tracking) {
            cam = camModel(camera.pose, camera.imageIntrinsics)
            updateMotion(cam, now)
            pendingTap?.let {
                pendingTap = null
                val b = box
                if (b != null && !scanning) {
                    // move the box to where the table/object was tapped
                    val hit = frame.hitTest(it[0], it[1]).firstOrNull()
                    if (hit != null) {
                        val nb = b.copyOf()
                        nb[0] = hit.hitPose.tx(); nb[2] = hit.hitPose.tz()
                        applyBox(nb)
                    }
                } else if (b == null) {
                    startSelection(frame, it[0], it[1], camera.pose, cam, it.size < 3 || it[2] > 0.5f)
                }
            }
            if (trackingSince == 0L) trackingSince = now
            maybeCapture(frame, cam, now)
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

    @Volatile private var bestScore = 0f

    /** Captured share; never goes down while scanning the same object. */
    private fun capturedScore(st: CoverageGrid.Stats): Float {
        // dome coverage: depends only on where photos were taken, so it is steady
        val now = st.directions.coerceIn(0f, 1f)
        if (now > bestScore) bestScore = now
        return bestScore
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
    @Volatile private var useAiGuess = true

    private fun startSelection(frame: Frame, x: Float, y: Float, pose: com.google.ar.core.Pose, cam: CamModel,
                               useAi: Boolean = true) {
        useAiGuess = useAi
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
        var imageMask: ByteArray? = null
        var imageMaskCam: CamModel? = null
        var aiWidthPx = 0f   // object width in the camera image (pixels of the full image)
        var aiHeightPx = 0f
        val seg = if (useAiGuess) segmenterOrNull() else null
        if (seg != null && yuv != null) {
            val jpeg = toJpeg(yuv)
            val res = seg.segmentZoomed(jpeg, yuv.w, yuv.h, imgN[0], imgN[1])
            if (res != null) {
                val m = res.mask
                var x0 = res.width; var x1 = -1; var y0 = res.height; var y1 = -1
                for (yy in 0 until res.height) for (xx in 0 until res.width) {
                    if (m[yy * res.width + xx].toInt() == 0) continue
                    if (xx < x0) x0 = xx
                    if (xx > x1) x1 = xx
                    if (yy < y0) y0 = yy
                    if (yy > y1) y1 = yy
                }
                if (x1 >= x0) {
                    aiWidthPx = (x1 - x0 + 1f) * cam.width / res.width
                    aiHeightPx = (y1 - y0 + 1f) * cam.height / res.height
                }
                val icam = cam.scaled(res.width, res.height)
                imageMask = m
                imageMaskCam = icam
                val mask = BooleanArray(w * h)
                for (v in 0 until h) for (u in 0 until w) {
                    val d = depthAt(u, v)
                    val dd = if (d > 0) d else 1f
                    val p = project(icam, world(u, v, dd)) ?: continue
                    val iu = p[0].toInt(); val iv = p[1].toInt()
                    if (iu in 0 until res.width && iv in 0 until res.height && m[iv * res.width + iu].toInt() != 0) mask[v * w + u] = true
                }
                objMask = mask
                aiUsed = true
            }
        }

        // AI outline that covers a large part of the view is the table, not the object
        if (objMask != null) {
            var n = 0; var valid = 0
            for (i in 0 until w * h) if (depth.data[i].toInt() != 0) { valid++; if (objMask[i]) n++ }
            if (valid > 0 && n > 0.35f * valid) { objMask = null; aiUsed = false; imageMask = null }
        }

        // 2) table height: the most common height among the measured points below the tapped one
        val seedD = depthAt(seedX, seedY)
        val seedP = if (seedD > 0) world(seedX, seedY, seedD) else hitPoint
        var table = tableY
        if (table == null && seedP != null) {
            val hist = HashMap<Int, Int>()
            for (v in 0 until h step 2) for (u in 0 until w step 2) {
                val d = depthAt(u, v)
                if (d <= 0) continue
                val y = world(u, v, d)[1]
                if (y < seedP[1] - 0.004f) { val bin = kotlin.math.floor(y * 250f).toInt(); hist[bin] = (hist[bin] ?: 0) + 1 }
            }
            val best = hist.maxByOrNull { it.value }
            if (best != null && best.value > 40) table = (best.key + 0.5f) / 250f
        }
        if (table != null && seedP != null && seedP[1] < table + 0.006f && objMask == null) {
            post(mapOf("type" to "message", "text" to "That looks like the table. Tap the object itself."))
            return
        }
        val floorCut = (table ?: -1e9f) + 0.006f
        fun nearSeed(p: FloatArray): Boolean {
            val sp = seedP ?: return true
            val dx = p[0] - sp[0]; val dz = p[2] - sp[2]
            return dx * dx + dz * dz < 0.3f * 0.3f
        }

        // 3) object pixels: AI outline, else depth flood fill from the tapped point
        val inObj = BooleanArray(w * h)
        val queue = ArrayDeque<Int>()
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
                    if (d1 <= 0 || kotlin.math.abs(d1 - d0) > max(0.012f, 0.025f * d0)) continue
                    val wp = world(nu, nv, d1)
                    if (wp[1] < floorCut || !nearSeed(wp)) continue
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
            if (p[1] < floorCut - 0.002f || !nearSeed(p)) { inObj[i] = false; continue }
            pts.add(p)
        }
        for (v in 1 until h - 1) for (u in 1 until w - 1) {
            val i = v * w + u
            if (!inObj[i]) continue
            if (!inObj[i - 1] || !inObj[i + 1] || !inObj[i - w] || !inObj[i + w]) {
                val p = world(u, v, depthAt(u, v))
                outline.add(p[0]); outline.add(p[1]); outline.add(p[2])
            }
        }
        var cxw: Float
        var czw: Float
        var minY: Float
        var maxY: Float
        var rVis: Float
        if (pts.size >= 6) {
            var sx = 0f; var sz = 0f; minY = Float.MAX_VALUE
            val ys = FloatArray(pts.size)
            for ((k, p) in pts.withIndex()) { sx += p[0]; sz += p[2]; minY = min(minY, p[1]); ys[k] = p[1] }
            ys.sort()
            maxY = ys[(ys.size * 0.97f).toInt().coerceAtMost(ys.size - 1)]
            cxw = sx / pts.size
            czw = sz / pts.size
            val rs = FloatArray(pts.size) { val dx = pts[it][0] - cxw; val dz = pts[it][2] - czw; sqrt(dx * dx + dz * dz) }
            rs.sort()
            rVis = rs[(rs.size * 0.95f).toInt().coerceAtMost(rs.size - 1)]
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
            minY = table ?: (hitPoint[1] - hM / 2)
            maxY = max(hitPoint[1] + hM / 2, minY + hM)
            outline.clear()
        } else {
            val hp = hitPoint
            if (hp != null) {
                // nothing measurable: start with a 10 cm box the user can adjust
                applyBox(floatArrayOf(hp[0], table ?: hp[1], hp[2], 0f, 0.1f, 0.1f, 0.1f))
                post(mapOf("type" to "message", "text" to "Adjust the box so it fits the object"))
            } else {
                post(mapOf("type" to "message", "text" to "Couldn't find the table there. Move the phone a little and tap again."))
            }
            return
        }
        // the camera sees the front half: move the centre back along the view direction
        val c = cam.center()
        var vx = cxw - c[0]; var vz = czw - c[2]
        val vl = sqrt(vx * vx + vz * vz).coerceAtLeast(1e-4f)
        vx /= vl; vz /= vl
        cxw += vx * rVis * 0.4f
        czw += vz * rVis * 0.4f
        val radius = (rVis * 1.25f + 0.01f).coerceIn(0.02f, 0.6f)
        val bottom = (table ?: minY) - 0.008f
        val top = maxY + max(0.015f, 0.2f * (maxY - bottom))
        // scan box fitted to the object, turned to face the camera
        run {
            val bw = (2f * rVis * 1.15f + 0.01f).coerceIn(0.02f, 1.2f)
            val bh = ((maxY - (table ?: minY)) * 1.05f + 0.005f).coerceIn(0.01f, 1.5f)
            val yaw = kotlin.math.atan2(vx, vz)
            box = floatArrayOf(cxw, table ?: minY, czw, yaw, bw, bw, bh)
            post(mapOf("type" to "box", "box" to box!!.copyOf()))
        }
        val g = CoverageGrid(cxw, czw, radius, bottom, top, floorY = table ?: (minY - 0.01f))
        val maskBytes = ByteArray(w * h) { if (inObj[it] || !aiUsed) 1.toByte() else 0.toByte() }
        g.integrate(depth.data, dcam, if (aiUsed) maskBytes else null)
        val im = imageMask
        val imc = imageMaskCam
        if (aiUsed && im != null && imc != null) g.carve(im, imc)
        val st0 = g.stats()
        lastStatsObj = st0
        selectedAt = SystemClock.uptimeMillis()
        grid = g
        post(mapOf(
            "type" to "points", "data" to g.surfacePoints(), "captured" to 0.0, "detail" to 0.0,
            "bins" to g.dirBins.copyOf(), "surface" to st0.surface,
        ))
        center = floatArrayOf(cxw, (bottom + maxY) / 2, czw)
        kfDirs.clear()
        bestScore = 0f
        // keep the outline light for drawing
        val step = max(1, outline.size / 3 / 700)
        val ol = ArrayList<Float>()
        var k = 0
        while (k < outline.size) { ol.add(outline[k]); ol.add(outline[k + 1]); ol.add(outline[k + 2]); k += 3 * step }
        post(mapOf(
            "type" to "selected", "center" to floatArrayOf(cxw, bottom, czw), "radius" to radius.toDouble(),
            "bottom" to bottom.toDouble(), "top" to top.toDouble(), "objectTop" to maxY.toDouble(), "outline" to ol.toFloatArray(), "ai" to aiUsed,
        ))
    }

    // ------------------------------------------------------------------ photos
    // ---- capture state
    private var lastKfCenter: FloatArray? = null
    private var lastKfForward: FloatArray? = null
    private val sharpHistory = ArrayDeque<Float>()
    @Volatile private var blockReason = ""
    private var lastPhotoTime = 0L
    private val reasonCounts = HashMap<String, Int>()
    private var lastDiag = 0L

    private fun block(reason: String) {
        blockReason = reason
        reasonCounts[reason] = (reasonCounts[reason] ?: 0) + 1
    }

    /** Sharpness of the camera image (mean squared Laplacian of the centre). */
    private fun sharpness(yuv: YuvCopy): Float {
        val x0 = yuv.w / 4; val x1 = yuv.w * 3 / 4
        val y0 = yuv.h / 4; val y1 = yuv.h * 3 / 4
        var sum = 0.0
        var n = 0
        var y = y0 + 2
        while (y < y1 - 2) {
            var x = x0 + 2
            val row = y * yuv.yRow
            while (x < x1 - 2) {
                val c = yuv.y[row + x].toInt() and 0xFF
                val l = (yuv.y[row + x - 2].toInt() and 0xFF) + (yuv.y[row + x + 2].toInt() and 0xFF) +
                    (yuv.y[row - 2 * yuv.yRow + x].toInt() and 0xFF) + (yuv.y[row + 2 * yuv.yRow + x].toInt() and 0xFF) - 4 * c
                sum += (l * l).toDouble()
                n++
                x += 4
            }
            y += 4
        }
        return if (n > 0) (sum / n).toFloat() else 0f
    }

    /**
     * Takes a photo every time the phone has moved a few centimetres or turned
     * a few degrees, as long as the picture is sharp and the object (if chosen)
     * is in view. Simple rules, so photos keep coming while walking around.
     */
    private fun maybeCapture(frame: Frame, cam: CamModel, now: Long) {
        if (now - lastKfTime < 300) return
        val manual = captureRequested
        if (!manual && !auto) return
        val c = cam.center()
        val fwd = floatArrayOf(cam.r[6], cam.r[7], cam.r[8])
        val ctr = center
        val g = grid
        // only after the object is recognised and its hologram dots are showing
        if (g == null || ctr == null || !scanning) { block("select"); return }
        if (!manual) {
            if (ctr != null) {
                val pr = project(cam, ctr)
                val margin = 0.3f
                if (pr == null || pr[0] < -margin * cam.width || pr[0] > (1 + margin) * cam.width ||
                    pr[1] < -margin * cam.height || pr[1] > (1 + margin) * cam.height) { block("view"); return }
            }
            val lc = lastKfCenter
            val lf = lastKfForward
            if (lc != null && lf != null) {
                val dx = c[0] - lc[0]; val dy = c[1] - lc[1]; val dz = c[2] - lc[2]
                val moved = sqrt(dx * dx + dy * dy + dz * dz)
                val turned = Math.toDegrees(acos((fwd[0] * lf[0] + fwd[1] * lf[1] + fwd[2] * lf[2]).coerceIn(-1f, 1f).toDouble()))
                // small objects need smaller steps
                val step = if (g != null) (g.radius * 0.35f).coerceIn(0.012f, 0.05f) else 0.03f
                if (moved < step && turned < 6.0) { block("move"); return }
            }
            if (speed > 0.5f || turnRate > 60f) { block("fast"); return }
        }
        val yuv = copyImage(frame) ?: run { block("image"); return }
        val sharp = sharpness(yuv)
        if (!manual && sharpHistory.size >= 4) {
            val sorted = sharpHistory.sorted()
            val median = sorted[sorted.size / 2]
            if (sharp < 0.5f * median) { block("blur"); sharpHistory.addLast(sharp); if (sharpHistory.size > 15) sharpHistory.removeFirst(); return }
        }
        sharpHistory.addLast(sharp)
        if (sharpHistory.size > 15) sharpHistory.removeFirst()
        captureRequested = false
        blockReason = ""
        val depth = copyDepth(frame)
        val dcam = if (depth != null) camModel(frame.camera.pose, frame.camera.textureIntrinsics).scaled(depth.width, depth.height) else null
        lastKfTime = now
        lastPhotoTime = now
        lastKfCenter = c
        lastKfForward = fwd
        run {
            var dx = c[0] - ctr[0]; var dy = c[1] - ctr[1]; var dz = c[2] - ctr[2]
            val dist = sqrt(dx * dx + dy * dy + dz * dz)
            dx /= dist; dy /= dist; dz /= dist
            kfDirs.add(floatArrayOf(dx, dy, dz, dist))
        }
        val n = photoCount.incrementAndGet()
        val name = String.format(Locale.US, "LIVE_%04d", n)
        val icam = cam.scaled(yuv.w, yuv.h)
        post(mapOf("type" to "photo", "photos" to n))
        saver.execute { savePhoto(name, yuv, icam, depth, dcam, g, ctr) }
    }

    private fun diagnostics(now: Long, tracking: Boolean) {
        if (now - lastDiag < 2000) return
        lastDiag = now
        try {
            val line = String.format(Locale.US, "%d tracking=%s photos=%d speed=%.2f turn=%.0f selected=%s blocked=%s\n",
                now / 1000, tracking, photoCount.get(), speed, turnRate, grid != null, reasonCounts.toString())
            File(projectDir, "live_log.txt").appendText(line)
            reasonCounts.clear()
        } catch (_: Throwable) {}
    }

    private fun savePhoto(name: String, yuv: YuvCopy, cam: CamModel, depth: DepthCopy?, dcam: CamModel?,
                          g: CoverageGrid?, ctr: FloatArray?) {
        try {
            val jpeg = toJpeg(yuv)
            FileOutputStream(File(photosDir, "$name.jpg")).use { it.write(jpeg) }
            val line = StringBuilder("$name.jpg")
            for (v in floatArrayOf(cam.fx, cam.fy, cam.cx, cam.cy)) line.append(' ').append(v)
            for (v in cam.r) line.append(' ').append(v)
            for (v in cam.t) line.append(' ').append(v)
            synchronized(this) { posesFile.appendText(line.toString() + "\n") }
            savedCount.incrementAndGet()

            // AI outline of the object for this photo (helps plain or dark objects)
            var mask: ByteArray? = null
            var mcam: CamModel? = null
            val seg = if (useAiGuess) segmenterOrNull() else null
            val pc = if (ctr != null) project(cam, ctr) else null
            if (seg != null && pc != null && g != null) {
                val res = seg.segmentZoomed(jpeg, cam.width, cam.height, pc[0] / cam.width, pc[1] / cam.height)
                if (res != null) {
                    var n = 0
                    for (b in res.mask) if (b.toInt() != 0) n++
                    if (n <= 0.5f * res.mask.size) {  // else the outline grabbed the table: ignore
                        mask = res.mask
                        mcam = cam.scaled(res.width, res.height)
                        val pixels = IntArray(res.mask.size) { if (res.mask[it].toInt() != 0) -0x1 else -0x1000000 }
                        val mb = Bitmap.createBitmap(pixels, res.width, res.height, Bitmap.Config.ARGB_8888)
                        FileOutputStream(File(masksDir, "$name.png")).use { mb.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        mb.recycle()
                    }
                }
            }
            // fuse this photo's depth (only inside the object outline when there is one)
            val omask = mask
            val ocam = mcam
            if (g == null) return
            if (depth != null && dcam != null) {
                var dmask: ByteArray? = null
                if (omask != null && ocam != null) {
                    dmask = ByteArray(depth.width * depth.height)
                    for (v in 0 until depth.height) for (u in 0 until depth.width) {
                        val dmm = depth.data[v * depth.width + u].toInt() and 0xFFFF
                        val d = if (dmm > 0) dmm / 1000f else 0.5f
                        val xc = (u - dcam.cx) / dcam.fx * d
                        val yc = (v - dcam.cy) / dcam.fy * d
                        val r = dcam.r; val t = dcam.t
                        val a = xc - t[0]; val b = yc - t[1]; val cz = d - t[2]
                        val wp = floatArrayOf(r[0] * a + r[3] * b + r[6] * cz, r[1] * a + r[4] * b + r[7] * cz, r[2] * a + r[5] * b + r[8] * cz)
                        val ip = project(ocam, wp) ?: continue
                        val iu = ip[0].toInt(); val iv = ip[1].toInt()
                        if (iu in 0 until ocam.width && iv in 0 until ocam.height && omask[iv * ocam.width + iu].toInt() != 0)
                            dmask[v * depth.width + u] = 1
                    }
                }
                g.integrate(depth.data, dcam, dmask)
            }
            if (omask != null && ocam != null) g.carve(omask, ocam)
            g.markPhoto(cam, depth?.data, dcam)
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
        val since = SystemClock.uptimeMillis() - lastPhotoTime
        if (auto && since > 2500) {
            when (blockReason) {
                "fast" -> return "Move a little slower"
                "blur" -> return "Hold steady for a moment (photo was blurry)"
                "view" -> return "Keep the object in view"
                "image" -> return "Waiting for the camera…"
            }
        }
        val ctr = center
        if (box == null || grid == null || ctr == null || cam == null) return "Tap the object to place the scan box"
        if (!scanning) return "Fit the box around the object, then tap Start"

        val pr = project(cam, ctr)
        val margin = if (pr != null) grid!!.radius * cam.fx / pr[2] else 0f
        if (pr == null || pr[0] < -margin || pr[0] > cam.width + margin || pr[1] < -margin || pr[1] > cam.height + margin)
            return "Point the camera at the object"
        val c = cam.center()
        val dist = sqrt((c[0] - ctr[0]) * (c[0] - ctr[0]) + (c[1] - ctr[1]) * (c[1] - ctr[1]) + (c[2] - ctr[2]) * (c[2] - ctr[2]))
        val apparent = grid!!.radius * cam.fx / dist / cam.width
        if (dist < 0.12f) return "Too close: keep about 15 cm or more away"
        if (apparent < 0.12f) return if (grid!!.radius < 0.06f) "Move closer (about 15–25 cm for small objects)" else "Move closer"
        if (apparent > 1.2f) return "Step back a little"
        if (speed > 0.5f || turnRate > 60f) return "Move a little slower"
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
