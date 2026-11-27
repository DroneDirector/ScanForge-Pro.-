package fo.dronedirector.scanforgepro.live

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Auto scan's live 3D model: a signed distance volume stored in small blocks
 * that are only created where a surface is measured, so the scanned area can
 * be any size and shape. Phone depth frames build the shape; every saved photo
 * then marks which surface parts it sees, from which direction, and gives
 * them their real colour.
 *
 * World coordinates are ARCore's (metres, y up). Not thread safe: use from
 * one thread.
 */
class SparseTsdf(val voxel: Float) {
    class Block {
        val tsdf = FloatArray(512) { 1f }
        val weight = ByteArray(512)
        val color = IntArray(512)
        val colorScore = FloatArray(512)
        val bins = IntArray(512)       // directions photos saw this voxel from (bit mask)
    }

    class Stats(
        val surfels: Int, val objectSurfels: Int, val covered: Int, val photoColoured: Int,
        val uncoveredNormal: FloatArray, val uncoveredCenter: FloatArray, val uncovered: Int,
        val minY: Float, val maxY: Float,
    )

    private val blocks = HashMap<Long, Block>()
    val trunc = voxel * 3f
    val blockCount: Int get() = blocks.size
    var maxBlocks = 5000

    private fun key(bx: Int, by: Int, bz: Int): Long =
        ((bx + OFFSET).toLong() shl 42) or ((by + OFFSET).toLong() shl 21) or (bz + OFFSET).toLong()

    private fun block(ix: Int, iy: Int, iz: Int, create: Boolean): Block? {
        val k = key(ix shr 3, iy shr 3, iz shr 3)
        var b = blocks[k]
        if (b == null && create && blocks.size < maxBlocks) {
            b = Block()
            blocks[k] = b
        }
        return b
    }

    private fun local(ix: Int, iy: Int, iz: Int): Int = ((iz and 7) shl 6) or ((iy and 7) shl 3) or (ix and 7)

    /** TSDF value at a voxel, or NaN when never measured. */
    private fun value(ix: Int, iy: Int, iz: Int): Float {
        val b = block(ix, iy, iz, false) ?: return Float.NaN
        val i = local(ix, iy, iz)
        if (b.weight[i].toInt() == 0) return Float.NaN
        return b.tsdf[i]
    }

    fun clear() = blocks.clear()

    /**
     * Fuses one depth frame. Only surface points within [radius] of [center]
     * are used (everything when center is null).
     */
    fun integrate(depth: ArDepth, dcam: CamModel, center: FloatArray?, radius: Float, stride: Int = 1) {
        val r = dcam.r
        val c = dcam.center()
        val inv = 1f / voxel
        val r2 = radius * radius
        var v = 0
        while (v < depth.height) {
            var u = 0
            while (u < depth.width) {
                val d = depth.metres(u, v)
                if (d > 0.1f && d < 2.5f) {
                    val xn = (u - dcam.cx) / dcam.fx
                    val yn = (v - dcam.cy) / dcam.fy
                    // world direction of the ray for one metre of depth
                    val dx = r[0] * xn + r[3] * yn + r[6]
                    val dy = r[1] * xn + r[4] * yn + r[7]
                    val dz = r[2] * xn + r[5] * yn + r[8]
                    var keep = true
                    if (center != null) {
                        val sx = c[0] + dx * d - center[0]
                        val sy = c[1] + dy * d - center[1]
                        val sz = c[2] + dz * d - center[2]
                        keep = sx * sx + sy * sy + sz * sz <= r2
                    }
                    if (keep) {
                        val tr = max(trunc, 0.012f * d)
                        var z = d - tr
                        val step = voxel * 0.9f
                        while (z <= d + tr) {
                            val wx = c[0] + dx * z
                            val wy = c[1] + dy * z
                            val wz = c[2] + dz * z
                            val ix = floor(wx * inv).toInt()
                            val iy = floor(wy * inv).toInt()
                            val iz = floor(wz * inv).toInt()
                            val b = block(ix, iy, iz, true)
                            if (b != null) {
                                val i = local(ix, iy, iz)
                                val sdf = ((d - z) / tr).coerceIn(-1f, 1f)
                                val w = b.weight[i].toInt()
                                b.tsdf[i] = (b.tsdf[i] * w + sdf) / (w + 1)
                                if (w < 60) b.weight[i] = (w + 1).toByte()
                            }
                            z += step
                        }
                    }
                }
                u += stride
            }
            v += stride
        }
    }

    /**
     * Marks the surface seen by a saved photo: direction bins and colour.
     * [icam] is the photo camera, [dcam] the matching depth camera.
     */
    fun markPhoto(icam: CamModel, yuv: ArYuv?, depth: ArDepth?, dcam: CamModel?) {
        val cc = icam.center()
        for ((k, b) in blocks) {
            val bx = ((k shr 42) and MASK).toInt() - OFFSET
            val by = ((k shr 21) and MASK).toInt() - OFFSET
            val bz = (k and MASK).toInt() - OFFSET
            for (i in 0 until 512) {
                if (b.weight[i].toInt() < 2) continue
                val t = b.tsdf[i]
                if (abs(t) > 0.6f) continue
                val px = ((bx shl 3) + (i and 7) + 0.5f) * voxel
                val py = ((by shl 3) + ((i shr 3) and 7) + 0.5f) * voxel
                val pz = ((bz shl 3) + (i shr 6) + 0.5f) * voxel
                val ip = ArFrames.project(icam, px, py, pz) ?: continue
                if (ip[0] < 0f || ip[1] < 0f || ip[0] >= icam.width || ip[1] >= icam.height) continue
                // hidden behind something else?
                if (depth != null && dcam != null) {
                    val dp = ArFrames.project(dcam, px, py, pz) ?: continue
                    val du = dp[0].toInt()
                    val dv = dp[1].toInt()
                    if (du < 0 || dv < 0 || du >= depth.width || dv >= depth.height) continue
                    val dm = depth.metres(du, dv)
                    if (dm > 0f && dp[2] - dm > max(2.5f * voxel, 0.04f * dm)) continue
                }
                // direction from the surface to the camera, as one of 26 bins
                var vx = cc[0] - px
                var vy = cc[1] - py
                var vz = cc[2] - pz
                val len = sqrt(vx * vx + vy * vy + vz * vz)
                if (len < 1e-4f) continue
                vx /= len; vy /= len; vz /= len
                val qx = if (vx > 0.38f) 2 else if (vx < -0.38f) 0 else 1
                val qy = if (vy > 0.38f) 2 else if (vy < -0.38f) 0 else 1
                val qz = if (vz > 0.38f) 2 else if (vz < -0.38f) 0 else 1
                val bin = qx * 9 + qy * 3 + qz
                b.bins[i] = b.bins[i] or (1 shl bin)
                if (yuv != null) {
                    // nearer and more central views give the best colour
                    val ox = ip[0] / icam.width - 0.5f
                    val oy = ip[1] / icam.height - 0.5f
                    val score = (1f / ip[2]) * (1f - 0.8f * (ox * ox + oy * oy))
                    if (score > b.colorScore[i]) {
                        b.colorScore[i] = score
                        val sx = (ip[0] * yuv.w / icam.width).toInt()
                        val sy = (ip[1] * yuv.h / icam.height).toInt()
                        b.color[i] = yuv.rgb(sx, sy)
                    }
                }
            }
        }
    }

    /**
     * Surface points for display: x, y, z, r, g, b, a, kind per point
     * (kind 0 = object, 1 = surface underneath). Colours: red = only seen
     * live, yellow = one photo direction, green = two, real colour = three or
     * more.
     */
    fun surfels(maxCount: Int, floorY: Float?, fadeFloor: Boolean, center: FloatArray?): Pair<FloatArray, Stats> {
        val out = FloatArray(maxCount * 8)
        var n = 0
        var obj = 0
        var covered = 0
        var photo = 0
        var unc = 0
        val un = FloatArray(3)
        val uc = FloatArray(3)
        var minY = Float.MAX_VALUE
        var maxY = -Float.MAX_VALUE
        val floorLimit = if (floorY != null) floorY + 1.5f * voxel else -Float.MAX_VALUE
        for ((k, b) in blocks) {
            val bx = ((k shr 42) and MASK).toInt() - OFFSET
            val by = ((k shr 21) and MASK).toInt() - OFFSET
            val bz = (k and MASK).toInt() - OFFSET
            for (i in 0 until 512) {
                if (b.weight[i].toInt() < 2) continue
                val t = b.tsdf[i]
                if (abs(t) >= 1f) continue
                val ix = (bx shl 3) + (i and 7)
                val iy = (by shl 3) + ((i shr 3) and 7)
                val iz = (bz shl 3) + (i shr 6)
                // a surface crosses towards one of the positive neighbours?
                var ex = 0f; var ey = 0f; var ez = 0f
                var found = false
                val nxv = value(ix + 1, iy, iz)
                val nyv = value(ix, iy + 1, iz)
                val nzv = value(ix, iy, iz + 1)
                if (!nxv.isNaN() && t * nxv <= 0f && t != nxv) { ex = t / (t - nxv); found = true }
                else if (!nyv.isNaN() && t * nyv <= 0f && t != nyv) { ey = t / (t - nyv); found = true }
                else if (!nzv.isNaN() && t * nzv <= 0f && t != nzv) { ez = t / (t - nzv); found = true }
                if (!found) continue
                val px = (ix + 0.5f + ex) * voxel
                val py = (iy + 0.5f + ey) * voxel
                val pz = (iz + 0.5f + ez) * voxel
                val isFloor = py < floorLimit
                val nb = Integer.bitCount(b.bins[i])
                if (!isFloor) {
                    obj++
                    if (py < minY) minY = py
                    if (py > maxY) maxY = py
                    if (nb >= 2) covered++
                    if (nb >= 3) photo++
                    if (nb < 2) {
                        // outward normal from the distance field gradient
                        val gx = gradient(ix, iy, iz, 0)
                        val gy = gradient(ix, iy, iz, 1)
                        val gz = gradient(ix, iy, iz, 2)
                        val gl = sqrt(gx * gx + gy * gy + gz * gz)
                        if (gl > 1e-6f) { un[0] += gx / gl; un[1] += gy / gl; un[2] += gz / gl }
                        uc[0] += px; uc[1] += py; uc[2] += pz
                        unc++
                    }
                }
                if (n >= maxCount) continue
                var rr: Float; var gg: Float; var bb: Float
                when {
                    nb >= 3 && b.colorScore[i] > 0f -> {
                        val c = b.color[i]
                        rr = ((c shr 16) and 0xFF) / 255f; gg = ((c shr 8) and 0xFF) / 255f; bb = (c and 0xFF) / 255f
                    }
                    nb >= 2 -> { rr = 0.20f; gg = 0.90f; bb = 0.45f }
                    nb == 1 -> { rr = 1.00f; gg = 0.80f; bb = 0.20f }
                    else -> { rr = 1.00f; gg = 0.27f; bb = 0.27f }
                }
                var a = 0.95f
                if (isFloor && fadeFloor) { rr = 0.55f; gg = 0.55f; bb = 0.60f; a = 0.22f }
                val o = n * 8
                out[o] = px; out[o + 1] = py; out[o + 2] = pz
                out[o + 3] = rr; out[o + 4] = gg; out[o + 5] = bb; out[o + 6] = a
                out[o + 7] = if (isFloor) 1f else 0f
                n++
            }
        }
        if (unc > 0) for (j in 0 until 3) { un[j] /= unc; uc[j] /= unc }
        val stats = Stats(n, obj, covered, photo, un, uc, unc,
            if (obj > 0) minY else 0f, if (obj > 0) maxY else 0f)
        return Pair(if (n == maxCount) out else out.copyOf(n * 8), stats)
    }

    private fun gradient(ix: Int, iy: Int, iz: Int, axis: Int): Float {
        val a: Float
        val b: Float
        when (axis) {
            0 -> { a = value(ix + 1, iy, iz); b = value(ix - 1, iy, iz) }
            1 -> { a = value(ix, iy + 1, iz); b = value(ix, iy - 1, iz) }
            else -> { a = value(ix, iy, iz + 1); b = value(ix, iy, iz - 1) }
        }
        if (a.isNaN() || b.isNaN()) return 0f
        return a - b
    }

    companion object {
        private const val OFFSET = 1 shl 20
        private const val MASK = (1L shl 21) - 1
        fun clampRadius(r: Float) = min(1.5f, max(0.2f, r))
    }
}
