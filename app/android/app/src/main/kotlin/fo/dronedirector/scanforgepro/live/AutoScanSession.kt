package fo.dronedirector.scanforgepro.live

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.google.ar.core.CameraConfig
import com.google.ar.core.CameraConfigFilter
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Auto scan: no points to collect and nothing to tap. The phone's depth
 * builds the object's shape live while you move around it, sharp photos are
 * saved automatically (with the phone's position and depth) and paint the
 * real colours onto the shape. The 3D engine then builds the final model
 * from photos + depth.
 *
 * Files: photos/AUTO_####.jpg, poses.txt, depth/AUTO_####.d16, depth.txt,
 * options.txt (keep_floor).
 */
class AutoScanSession(private val context: Context, private val emit: (Map<String, Any?>) -> Unit) : ArRenderSession {
    var session: Session? = null
        private set
    private val background = BackgroundRenderer()
    private val surfels = SurfelRenderer()
    private val main = Handler(Looper.getMainLooper())

    private lateinit var projectDir: File
    private lateinit var photosDir: File
    private lateinit var depthDir: File
    private lateinit var posesFile: File
    private lateinit var depthFile: File

    private val tsdf = SparseTsdf(VOXEL)
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val saver: ExecutorService = Executors.newSingleThreadExecutor()
    private val integrating = AtomicBoolean(false)
    private val extracting = AtomicBoolean(false)
    private val pendingSurfels = AtomicReference<FloatArray?>(null)
    private val photoCount = AtomicInteger(0)
    private val savedCount = AtomicInteger(0)

    @Volatile var removeFloor = true
    @Volatile private var stopped = false
    @Volatile private var roiCenter: FloatArray? = null
    @Volatile private var roiRadius = 0.6f
    @Volatile private var floorY: Float? = null
    @Volatile private var stats: SparseTsdf.Stats? = null
    @Volatile private var bestPercent = 0f
    @Volatile private var hasDepth = false

    private var viewW = 1
    private var viewH = 1
    private var imageW = 0
    private var imageH = 0
    private val view = FloatArray(16)
    private val proj = FloatArray(16)
    private val startTime = SystemClock.uptimeMillis()

    private var lastIntegrate = 0L
    private var lastExtract = 0L
    private var lastFloor = 0L
    private var lastPost = 0L
    private var lastKfTime = 0L
    private var lastKfCenter: FloatArray? = null
    private var lastKfForward: FloatArray? = null
    private val kfCenters = ArrayList<FloatArray>()
    private val kfAxes = ArrayList<FloatArray>()
    private val sharpHistory = ArrayDeque<Float>()
    private var prevCenter: FloatArray? = null
    private var prevForward: FloatArray? = null
    private var prevTime = 0L
    private var speed = 0f
    private var turnRate = 0f
    private var blockReason = ""
    private var lastPhotoTime = 0L

    // ------------------------------------------------------------------ setup
    fun open(project: String, keepFloor: Boolean): String {
        projectDir = File(project)
        photosDir = File(projectDir, "photos").apply { mkdirs() }
        depthDir = File(projectDir, "depth").apply { mkdirs() }
        posesFile = File(projectDir, "poses.txt")
        depthFile = File(projectDir, "depth.txt")
        removeFloor = !keepFloor
        val existing = photosDir.listFiles()?.count { it.name.startsWith("AUTO_") } ?: 0
        photoCount.set(existing)
        savedCount.set(existing)
        return try {
            val s = Session(context)
            val filter = CameraConfigFilter(s).setFacingDirection(CameraConfig.FacingDirection.BACK)
            val best = s.getSupportedCameraConfigs(filter).maxByOrNull { it.imageSize.width * it.imageSize.height }
            if (best != null) s.cameraConfig = best
            imageW = s.cameraConfig.imageSize.width
            imageH = s.cameraConfig.imageSize.height
            if (!s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                s.close()
                return "no_depth"
            }
            val cfg = Config(s)
            cfg.focusMode = Config.FocusMode.AUTO
            cfg.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
            cfg.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL
            cfg.lightEstimationMode = Config.LightEstimationMode.DISABLED
            cfg.depthMode = Config.DepthMode.AUTOMATIC
            s.configure(cfg)
            session = s
            if (!posesFile.exists()) posesFile.writeText("up 0 1 0\nsize $imageW $imageH\n")
            writeOptions()
            "ok"
        } catch (e: Throwable) {
            Log.w(TAG, "ARCore session failed", e)
            "error: ${e.javaClass.simpleName}"
        }
    }

    fun setRemoveFloor(on: Boolean) {
        removeFloor = on
        writeOptions()
        lastExtract = 0L
    }

    private fun writeOptions() {
        try { File(projectDir, "options.txt").writeText("keep_floor ${if (removeFloor) 0 else 1}\n") } catch (_: Throwable) {}
    }

    /** Starts over: forgets the live shape (saved photos stay). */
    fun restart() {
        worker.execute {
            tsdf.clear()
            bestPercent = 0f
            stats = null
            pendingSurfels.set(FloatArray(0))
        }
    }

    override fun resume() {
        try { session?.resume() } catch (e: Throwable) { Log.w(TAG, "resume failed", e) }
    }

    override fun pause() {
        try { session?.pause() } catch (_: Throwable) {}
    }

    fun finish(): Map<String, Any?> {
        stopped = true
        saver.shutdown()
        try { saver.awaitTermination(30, TimeUnit.SECONDS) } catch (_: InterruptedException) {}
        worker.shutdownNow()
        writeOptions()
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
        return mapOf("photos" to savedCount.get(), "rotation" to rotationDeg,
            "percent" to bestPercent.toDouble())
    }

    // ------------------------------------------------------------------ GL
    override fun onSurfaceCreated() {
        background.create()
        surfels.create()
        session?.setCameraTextureName(background.textureId)
    }

    override fun onSurfaceChanged(w: Int, h: Int, displayRotation: Int) {
        viewW = w
        viewH = h
        GLES20.glViewport(0, 0, w, h)
        session?.setDisplayGeometry(displayRotation, w, h)
    }

    override fun onDrawFrame() {
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
            cam = ArFrames.camModel(camera.pose, camera.imageIntrinsics)
            updateMotion(cam, now)
            if (now - lastIntegrate > 90 && !integrating.get()) {
                lastIntegrate = now
                fuseDepth(frame)
            }
            if (now - lastFloor > 1000) {
                lastFloor = now
                updateFloor(s)
            }
            maybeCapture(frame, cam, now)
        }
        if (now - lastExtract > 350 && !extracting.get()) {
            lastExtract = now
            extracting.set(true)
            val fy = floorY
            val fade = removeFloor
            val ctr = roiCenter
            worker.execute {
                try {
                    val res = tsdf.surfels(MAX_POINTS, fy, fade, ctr)
                    pendingSurfels.set(res.first)
                    stats = res.second
                    val st = res.second
                    if (st.objectSurfels >= 200) {
                        val p = st.covered.toFloat() / st.objectSurfels
                        if (p > bestPercent) bestPercent = p
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "surface update failed", e)
                } finally {
                    extracting.set(false)
                }
            }
        }
        pendingSurfels.getAndSet(null)?.let { surfels.upload(it) }
        val st = stats
        val bottom = floorY ?: (st?.minY ?: 0f)
        val top = if (st != null && st.objectSurfels > 0) st.maxY else bottom + 0.2f
        surfels.draw(view, proj, viewH, VOXEL, (now - startTime) / 1000f, bottom, top, tracking)

        if (now - lastPost > 150) {
            lastPost = now
            post(mapOf(
                "type" to "auto", "tracking" to tracking,
                "hint" to hint(camera, cam, tracking),
                "percent" to bestPercent.toDouble(),
                "photos" to photoCount.get(),
                "points" to (st?.objectSurfels ?: 0),
                "floor" to (floorY != null),
                "depth" to hasDepth,
            ))
        }
    }

    private fun post(m: Map<String, Any?>) { main.post { emit(m) } }

    // ------------------------------------------------------------------ live shape
    private fun fuseDepth(frame: Frame) {
        val depth = ArFrames.copyDepth(frame) ?: return
        hasDepth = true
        val dcam = ArFrames.camModel(frame.camera.pose, frame.camera.textureIntrinsics).scaled(depth.width, depth.height)
        if (roiCenter == null) {
            // the object is what the camera points at when the scan starts
            val u = depth.width / 2
            val v = depth.height / 2
            var d = 0f
            var k = 0
            for (dv in -3..3) for (du in -3..3) {
                val m = depth.metres((u + du).coerceIn(0, depth.width - 1), (v + dv).coerceIn(0, depth.height - 1))
                if (m > 0.1f && m < 2.5f) { d += m; k++ }
            }
            if (k < 10) return
            d /= k
            val r = dcam.r
            val c = dcam.center()
            roiCenter = floatArrayOf(c[0] + r[6] * d, c[1] + r[7] * d, c[2] + r[8] * d)
            roiRadius = SparseTsdf.clampRadius(0.9f * d)
        }
        val ctr = roiCenter
        val rad = roiRadius
        integrating.set(true)
        worker.execute {
            try {
                tsdf.integrate(depth, dcam, ctr, rad, if (depth.width > 320) 2 else 1)
            } catch (e: Throwable) {
                Log.w(TAG, "depth fusion failed", e)
            } finally {
                integrating.set(false)
            }
        }
    }

    /** The surface the object stands on: the highest ARCore table/floor plane under it. */
    private fun updateFloor(s: Session) {
        val ctr = roiCenter ?: return
        var best: Float? = null
        try {
            for (p in s.getAllTrackables(Plane::class.java)) {
                if (p.trackingState != TrackingState.TRACKING || p.subsumedBy != null) continue
                if (p.type != Plane.Type.HORIZONTAL_UPWARD_FACING) continue
                val y = p.centerPose.ty()
                if (y > ctr[1] + 0.01f) continue
                val under = p.isPoseInPolygon(Pose.makeTranslation(ctr[0], y, ctr[2]))
                val dx = p.centerPose.tx() - ctr[0]
                val dz = p.centerPose.tz() - ctr[2]
                if (!under && dx * dx + dz * dz > 0.8f * 0.8f) continue
                val b = best
                if (b == null || y > b) best = y
            }
        } catch (_: Throwable) {}
        if (best != null) floorY = best
    }

    /** Re-centres the scan area on the point all photos look at. */
    private fun updateCenter() {
        val n = kfCenters.size
        if (n < 5) return
        // least squares intersection of the optical axes
        val a = DoubleArray(9)
        val b = DoubleArray(3)
        for (k in 0 until n) {
            val d = kfAxes[k]
            val c = kfCenters[k]
            for (i in 0 until 3) for (j in 0 until 3) {
                val m = (if (i == j) 1.0 else 0.0) - d[i] * d[j]
                a[i * 3 + j] += m
                b[i] += m * c[j]
            }
        }
        val det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        if (det < 1e-3 * n * n * n) return  // all photos from about the same direction
        val inv = DoubleArray(9)
        inv[0] = (a[4] * a[8] - a[5] * a[7]) / det
        inv[1] = (a[2] * a[7] - a[1] * a[8]) / det
        inv[2] = (a[1] * a[5] - a[2] * a[4]) / det
        inv[3] = (a[5] * a[6] - a[3] * a[8]) / det
        inv[4] = (a[0] * a[8] - a[2] * a[6]) / det
        inv[5] = (a[2] * a[3] - a[0] * a[5]) / det
        inv[6] = (a[3] * a[7] - a[4] * a[6]) / det
        inv[7] = (a[1] * a[6] - a[0] * a[7]) / det
        inv[8] = (a[0] * a[4] - a[1] * a[3]) / det
        val p = FloatArray(3)
        for (i in 0 until 3) p[i] = (inv[i * 3] * b[0] + inv[i * 3 + 1] * b[1] + inv[i * 3 + 2] * b[2]).toFloat()
        val dists = ArrayList<Float>()
        for (c in kfCenters) {
            val dx = c[0] - p[0]; val dy = c[1] - p[1]; val dz = c[2] - p[2]
            dists.add(sqrt(dx * dx + dy * dy + dz * dz))
        }
        dists.sort()
        val med = dists[dists.size / 2]
        val old = roiCenter
        if (old != null) {
            val dx = old[0] - p[0]; val dy = old[1] - p[1]; val dz = old[2] - p[2]
            if (sqrt(dx * dx + dy * dy + dz * dz) > 1.2f * med) return  // implausible jump
        }
        roiCenter = p
        roiRadius = SparseTsdf.clampRadius(0.8f * med)
    }

    // ------------------------------------------------------------------ photos
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

    private fun maybeCapture(frame: Frame, cam: CamModel, now: Long) {
        if (now - lastKfTime < 250) return
        val ctr = roiCenter ?: run { blockReason = "start"; return }
        val pr = ArFrames.project(cam, ctr[0], ctr[1], ctr[2])
        if (pr == null || pr[0] < -0.2f * cam.width || pr[0] > 1.2f * cam.width ||
            pr[1] < -0.2f * cam.height || pr[1] > 1.2f * cam.height) { blockReason = "view"; return }
        val c = cam.center()
        val fwd = floatArrayOf(cam.r[6], cam.r[7], cam.r[8])
        val lc = lastKfCenter
        val lf = lastKfForward
        if (lc != null && lf != null) {
            val dx = c[0] - lc[0]; val dy = c[1] - lc[1]; val dz = c[2] - lc[2]
            val moved = sqrt(dx * dx + dy * dy + dz * dz)
            val turned = Math.toDegrees(acos((fwd[0] * lf[0] + fwd[1] * lf[1] + fwd[2] * lf[2]).coerceIn(-1f, 1f).toDouble()))
            val step = (roiRadius * 0.12f).coerceIn(0.015f, 0.06f)
            if (moved < step && turned < 7.0) { blockReason = "move"; return }
        }
        if (speed > 0.5f || turnRate > 60f) { blockReason = "fast"; return }
        val yuv = ArFrames.copyImage(frame) ?: run { blockReason = "image"; return }
        val sharp = ArFrames.sharpness(yuv)
        if (sharpHistory.size >= 4) {
            val sorted = sharpHistory.sorted()
            val median = sorted[sorted.size / 2]
            sharpHistory.addLast(sharp)
            if (sharpHistory.size > 15) sharpHistory.removeFirst()
            if (sharp < 0.5f * median) { blockReason = "blur"; return }
        } else {
            sharpHistory.addLast(sharp)
        }
        val depth = ArFrames.copyDepth(frame)
        val dcam = if (depth != null) ArFrames.camModel(frame.camera.pose, frame.camera.textureIntrinsics).scaled(depth.width, depth.height) else null
        blockReason = ""
        lastKfTime = now
        lastPhotoTime = now
        lastKfCenter = c
        lastKfForward = fwd
        kfCenters.add(c)
        kfAxes.add(fwd)
        if (kfCenters.size % 5 == 0) updateCenter()
        val n = photoCount.incrementAndGet()
        val name = String.format(Locale.US, "AUTO_%04d", n)
        val icam = cam.scaled(yuv.w, yuv.h)
        saver.execute { savePhoto(name, yuv, icam, depth, dcam) }
    }

    private fun savePhoto(name: String, yuv: ArYuv, cam: CamModel, depth: ArDepth?, dcam: CamModel?) {
        try {
            FileOutputStream(File(photosDir, "$name.jpg")).use { it.write(ArFrames.toJpeg(yuv)) }
            val line = StringBuilder("$name.jpg")
            for (v in floatArrayOf(cam.fx, cam.fy, cam.cx, cam.cy)) line.append(' ').append(v)
            for (v in cam.r) line.append(' ').append(v)
            for (v in cam.t) line.append(' ').append(v)
            synchronized(this) { posesFile.appendText(line.toString() + "\n") }
            if (depth != null && dcam != null) {
                val bb = ByteBuffer.allocate(8 + depth.data.size * 2).order(ByteOrder.LITTLE_ENDIAN)
                bb.putInt(depth.width)
                bb.putInt(depth.height)
                for (sv in depth.data) bb.putShort(sv)
                FileOutputStream(File(depthDir, "$name.d16")).use { it.write(bb.array()) }
                val dl = String.format(Locale.US, "%s.jpg %f %f %f %f %d %d\n", name, dcam.fx, dcam.fy, dcam.cx, dcam.cy,
                    depth.width, depth.height)
                synchronized(this) { depthFile.appendText(dl) }
            }
            savedCount.incrementAndGet()
            worker.execute {
                try { tsdf.markPhoto(cam, yuv, depth, dcam) } catch (e: Throwable) { Log.w(TAG, "marking failed", e) }
            }
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
        if (!hasDepth) return "Move the phone a little so depth can be measured"
        val ctr = roiCenter ?: return "Point the camera at the object"
        if (cam == null) return "Point the camera at the object"
        if (speed > 0.5f || turnRate > 60f) return "Move a little slower"
        val since = SystemClock.uptimeMillis() - lastPhotoTime
        if (since > 2500 && blockReason == "blur") return "Hold steady for a moment"
        if (since > 2500 && blockReason == "view") return "Keep the object in view"
        val c = cam.center()
        val dx = c[0] - ctr[0]; val dy = c[1] - ctr[1]; val dz = c[2] - ctr[2]
        val dist = sqrt(dx * dx + dy * dy + dz * dz)
        if (dist < 0.12f) return "Too close: keep about 15 cm or more away"
        val st = stats ?: return "Move slowly around the object"
        if (st.objectSurfels < 300) return "Move slowly around the object"
        if (dist > max(0.8f, 4f * roiRadius)) return "Move closer for more detail"
        val pct = bestPercent
        if (pct >= 0.9f) return "Looking good! Tap Done, or keep going for more detail"
        val n = st.uncoveredNormal
        val nl = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2])
        if (st.uncovered < 30 || nl < 0.15f) return "Fill in the red spots"
        val ny = n[1] / nl
        if (ny > 0.55f) return "Raise the phone and look down at the top"
        if (ny < -0.45f) return "Move lower to scan underneath"
        // which way to walk: towards where the missing surface faces
        val u = st.uncoveredCenter
        var cx = c[0] - u[0]
        var cz = c[2] - u[2]
        val cl = sqrt(cx * cx + cz * cz)
        var hx = n[0]
        var hz = n[2]
        val hl = sqrt(hx * hx + hz * hz)
        if (cl < 1e-4f || hl < 1e-4f) return "Fill in the red spots"
        cx /= cl; cz /= cl; hx /= hl; hz /= hl
        val dot = cx * hx + cz * hz
        if (dot > 0.6f) return "Fill in the red spots in front of you"
        if (dot < -0.4f) return "Walk around to the other side"
        val right = cam.r
        val side = (hx - cx) * right[0] + (hz - cz) * right[2]
        return if (side > 0f) "Move to the right around the object" else "Move to the left around the object"
    }

    companion object {
        private const val TAG = "ScanForgeAuto"
        private const val VOXEL = 0.005f
        private const val MAX_POINTS = 60000
    }
}
