package fo.dronedirector.scanforgepro.live

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Pinhole camera, world -> camera (x right, y down, z forward), metres. */
class CamModel(
    val r: FloatArray,  // 3x3 row-major world -> camera
    val t: FloatArray,  // 3
    val fx: Float, val fy: Float, val cx: Float, val cy: Float,
    val width: Int, val height: Int,
) {
    fun center(): FloatArray = floatArrayOf(
        -(r[0] * t[0] + r[3] * t[1] + r[6] * t[2]),
        -(r[1] * t[0] + r[4] * t[1] + r[7] * t[2]),
        -(r[2] * t[0] + r[5] * t[1] + r[8] * t[2]),
    )

    fun scaled(w: Int, h: Int): CamModel {
        val sx = w.toFloat() / width
        val sy = h.toFloat() / height
        return CamModel(r, t, fx * sx, fy * sy, cx * sx, cy * sy, w, h)
    }
}

/**
 * A small live 3D volume around the object (vertical cylinder region).
 * Depth frames are fused into it to find the object's surface; every saved
 * photo then marks which surface parts it sees. This is what the hologram
 * and the "captured" percentage show - the same idea as the final model.
 */
class CoverageGrid(
    val cx: Float, val cz: Float, val radius: Float,
    val yMin: Float, val yMax: Float,
    private val floorY: Float = -1e9f,  // table height: never part of the object
    res: Int = 56,
) {
    val voxel: Float = max(2 * radius, yMax - yMin) / res
    val nx = ceil(2 * radius / voxel).toInt() + 1
    val ny = ceil((yMax - yMin) / voxel).toInt() + 1
    val nz = nx
    private val n = nx * ny * nz
    private val tsdf = FloatArray(n) { 1f }
    private val weight = FloatArray(n)
    private val kfCount = ByteArray(n)
    private val bestRes = FloatArray(n)  // best photo resolution, pixels per cm

    // viewing directions of saved photos: 24 around x 3 heights
    val dirBins = ByteArray(72)

    /** Number of AI outlines carved in; with enough, the outline shape counts as surface. */
    @Volatile var outlines = 0
        private set

    private fun idx(x: Int, y: Int, z: Int) = (z * ny + y) * nx + x
    private fun wx(x: Int) = cx - radius + x * voxel
    private fun wy(y: Int) = yMin + y * voxel
    private fun wz(z: Int) = cz - radius + z * voxel
    private fun inCylinder(x: Int, z: Int): Boolean {
        val dx = wx(x) - cx
        val dz = wz(z) - cz
        return dx * dx + dz * dz <= radius * radius
    }

    /** Fuses one depth frame (millimetres, 0 = unknown). [objectMask] optional, same size. */
    @Synchronized
    fun integrate(depth: ShortArray, cam: CamModel, objectMask: ByteArray? = null) {
        val r = cam.r
        val t = cam.t
        for (z in 0 until nz) for (x in 0 until nx) {
            if (!inCylinder(x, z)) continue
            val px = wx(x)
            val pz = wz(z)
            for (y in 0 until ny) {
                val py = wy(y)
                val zc = r[6] * px + r[7] * py + r[8] * pz + t[2]
                if (zc < 0.05f) continue
                val xc = r[0] * px + r[1] * py + r[2] * pz + t[0]
                val yc = r[3] * px + r[4] * py + r[5] * pz + t[1]
                val u = (cam.fx * xc / zc + cam.cx).toInt()
                val v = (cam.fy * yc / zc + cam.cy).toInt()
                if (u < 0 || v < 0 || u >= cam.width || v >= cam.height) continue
                val i = idx(x, y, z)
                val pi = v * cam.width + u
                if (objectMask != null && objectMask[pi].toInt() == 0) {
                    // outside the object outline: empty space
                    tsdf[i] = (tsdf[i] * weight[i] + 1f) / (weight[i] + 1f)
                    weight[i] = min(weight[i] + 1f, 60f)
                    continue
                }
                val dmm = depth[pi].toInt() and 0xFFFF
                if (dmm == 0) continue
                val d = dmm / 1000f
                val sdf = d - zc
                val trunc = max(2.5f * voxel, 0.012f * d)
                if (sdf < -trunc) continue
                val value = min(1f, sdf / trunc)
                tsdf[i] = (tsdf[i] * weight[i] + value) / (weight[i] + 1f)
                weight[i] = min(weight[i] + 1f, 60f)
            }
        }
    }

    private fun isCarved(i: Int) = weight[i] >= 2f && tsdf[i] > 0.6f

    private fun isSurface(x: Int, y: Int, z: Int): Boolean {
        if (wy(y) < floorY + 0.004f) return false
        val i = idx(x, y, z)
        if (weight[i] >= 3f && abs(tsdf[i]) < 0.5f) return true
        // small objects: depth is too coarse up close, so the outline shape
        // (space never carved away, next to carved space) is the surface
        if (outlines >= 3 && weight[i] == 0f && x > 0 && y > 0 && z > 0 && x < nx - 1 && y < ny - 1 && z < nz - 1) {
            return isCarved(idx(x + 1, y, z)) || isCarved(idx(x - 1, y, z)) || isCarved(idx(x, y + 1, z)) ||
                isCarved(idx(x, y - 1, z)) || isCarved(idx(x, y, z + 1)) || isCarved(idx(x, y, z - 1))
        }
        return false
    }

    /** Carves away everything outside the object's AI outline in a saved photo. */
    @Synchronized
    fun carve(mask: ByteArray, cam: CamModel) {
        val r = cam.r
        val t = cam.t
        for (z in 0 until nz) for (x in 0 until nx) {
            if (!inCylinder(x, z)) continue
            val px = wx(x)
            val pz = wz(z)
            for (y in 0 until ny) {
                val py = wy(y)
                val zc = r[6] * px + r[7] * py + r[8] * pz + t[2]
                if (zc < 0.03f) continue
                val u = (cam.fx * (r[0] * px + r[1] * py + r[2] * pz + t[0]) / zc + cam.cx).toInt()
                val v = (cam.fy * (r[3] * px + r[4] * py + r[5] * pz + t[1]) / zc + cam.cy).toInt()
                if (u < 0 || v < 0 || u >= cam.width || v >= cam.height) continue
                if (mask[v * cam.width + u].toInt() != 0) continue
                val i = idx(x, y, z)
                tsdf[i] = (tsdf[i] * weight[i] + 1f) / (weight[i] + 1f)
                weight[i] = min(weight[i] + 1f, 60f)
            }
        }
        outlines++
    }

    private fun normal(x: Int, y: Int, z: Int, out: FloatArray): Boolean {
        if (x < 1 || y < 1 || z < 1 || x >= nx - 1 || y >= ny - 1 || z >= nz - 1) return false
        out[0] = tsdf[idx(x + 1, y, z)] - tsdf[idx(x - 1, y, z)]
        out[1] = tsdf[idx(x, y + 1, z)] - tsdf[idx(x, y - 1, z)]
        out[2] = tsdf[idx(x, y, z + 1)] - tsdf[idx(x, y, z - 1)]
        if (weight[idx(x, y, z)] == 0f) {
            // outline surface: points towards the carved (empty) neighbours
            out[0] = (if (isCarved(idx(x + 1, y, z))) 1f else 0f) - (if (isCarved(idx(x - 1, y, z))) 1f else 0f)
            out[1] = (if (isCarved(idx(x, y + 1, z))) 1f else 0f) - (if (isCarved(idx(x, y - 1, z))) 1f else 0f)
            out[2] = (if (isCarved(idx(x, y, z + 1))) 1f else 0f) - (if (isCarved(idx(x, y, z - 1))) 1f else 0f)
        }
        val l = sqrt(out[0] * out[0] + out[1] * out[1] + out[2] * out[2])
        if (l < 1e-6f) return false
        out[0] /= l; out[1] /= l; out[2] /= l
        return true
    }

    /** Marks the surface parts a saved photo sees. [depth] (optional) is used to skip hidden parts. */
    @Synchronized
    fun markPhoto(cam: CamModel, depth: ShortArray?, depthCam: CamModel?) {
        val c = cam.center()
        // direction bin
        val dx = c[0] - cx
        val dz = c[2] - cz
        val dy = c[1] - (yMin + yMax) / 2
        val az = ((atan2(dx, dz) / (2 * Math.PI) + 1.0) % 1.0)
        val el = Math.toDegrees(atan2(dy.toDouble(), sqrt((dx * dx + dz * dz).toDouble())))
        val band = if (el < 20) 0 else if (el < 45) 1 else 2
        val seg = (az * 24).toInt().coerceIn(0, 23)
        dirBins[band * 24 + seg] = (min(dirBins[band * 24 + seg] + 1, 100)).toByte()

        val r = cam.r
        val t = cam.t
        val nrm = FloatArray(3)
        for (z in 0 until nz) for (x in 0 until nx) {
            if (!inCylinder(x, z)) continue
            for (y in 0 until ny) {
                if (!isSurface(x, y, z) || !normal(x, y, z, nrm)) continue
                val px = wx(x); val py = wy(y); val pz = wz(z)
                val zc = r[6] * px + r[7] * py + r[8] * pz + t[2]
                if (zc < 0.05f) continue
                val xc = r[0] * px + r[1] * py + r[2] * pz + t[0]
                val yc = r[3] * px + r[4] * py + r[5] * pz + t[1]
                val u = cam.fx * xc / zc + cam.cx
                val v = cam.fy * yc / zc + cam.cy
                if (u < 0 || v < 0 || u >= cam.width || v >= cam.height) continue
                // the outward normal points to increasing distance values
                val vx = c[0] - px; val vy = c[1] - py; val vz = c[2] - pz
                val vl = sqrt(vx * vx + vy * vy + vz * vz)
                if ((nrm[0] * vx + nrm[1] * vy + nrm[2] * vz) / vl < 0.05f) continue
                if (depth != null && depthCam != null) {
                    val du = (u * depthCam.width / cam.width).toInt()
                    val dv = (v * depthCam.height / cam.height).toInt()
                    if (du in 0 until depthCam.width && dv in 0 until depthCam.height) {
                        val dmm = depth[dv * depthCam.width + du].toInt() and 0xFFFF
                        if (dmm > 0 && dmm / 1000f < zc - 3 * voxel - 0.01f) continue  // hidden
                    }
                }
                val i = idx(x, y, z)
                kfCount[i] = min(kfCount[i] + 1, 100).toByte()
                val res = cam.fx / zc / 100f
                if (res > bestRes[i]) bestRes[i] = res
            }
        }
    }

    class Stats(val surface: Int, val captured: Int, val once: Int, val detail: Float, val directions: Float)

    @Synchronized
    fun stats(): Stats {
        var surface = 0; var captured = 0; var once = 0
        var detail = 0f
        for (z in 0 until nz) for (x in 0 until nx) {
            if (!inCylinder(x, z)) continue
            for (y in 0 until ny) {
                if (!isSurface(x, y, z)) continue
                surface++
                val k = kfCount[idx(x, y, z)].toInt()
                if (k >= 2) {
                    captured++
                    detail += min(1f, bestRes[idx(x, y, z)] / 40f)
                } else if (k == 1) once++
            }
        }
        var bins = 0
        // the middle and low rings matter most; the high ring adds the top
        for (b in 0 until 48) if (dirBins[b] > 0) bins++
        var high = 0
        for (b in 48 until 72) if (dirBins[b] > 0) high++
        val dirs = (bins / 48f) * 0.75f + (high / 24f) * 0.25f
        return Stats(surface, captured, once, if (captured > 0) detail / captured else 0f, dirs)
    }

    /** Surface points for the hologram: x, y, z, state (0 seen, 1 one photo, 2 captured). */
    @Synchronized
    fun surfacePoints(maxPoints: Int = 9000): FloatArray {
        val list = ArrayList<Float>()
        var count = 0
        for (z in 0 until nz) for (x in 0 until nx) {
            if (!inCylinder(x, z)) continue
            for (y in 0 until ny) {
                if (!isSurface(x, y, z)) continue
                count++
            }
        }
        val step = max(1, count / maxPoints)
        var k = 0
        for (z in 0 until nz) for (x in 0 until nx) {
            if (!inCylinder(x, z)) continue
            for (y in 0 until ny) {
                if (!isSurface(x, y, z)) continue
                if (k++ % step != 0) continue
                val kc = kfCount[idx(x, y, z)].toInt()
                list.add(wx(x)); list.add(wy(y)); list.add(wz(z))
                list.add(if (kc >= 2) 2f else if (kc == 1) 1f else 0f)
            }
        }
        return list.toFloatArray()
    }
}
