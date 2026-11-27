package fo.dronedirector.scanforgepro.live

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import com.google.ar.core.CameraIntrinsics
import com.google.ar.core.Frame
import java.io.ByteArrayOutputStream
import kotlin.math.min

/** Copy of an ARCore depth image (millimetres, 0 = unknown). */
class ArDepth(val data: ShortArray, val width: Int, val height: Int) {
    fun metres(u: Int, v: Int): Float = (data[v * width + u].toInt() and 0xFFFF) / 1000f
}

/** Copy of an ARCore camera image (YUV 420). */
class ArYuv(
    val w: Int, val h: Int, val y: ByteArray, val u: ByteArray, val v: ByteArray,
    val yRow: Int, val uvRow: Int, val uvPixel: Int,
) {
    /** RGB colour at a pixel, packed as 0xRRGGBB. */
    fun rgb(px: Int, py: Int): Int {
        val x = px.coerceIn(0, w - 1)
        val yy = py.coerceIn(0, h - 1)
        val lum = (y[yy * yRow + x].toInt() and 0xFF).toFloat()
        val i = (yy / 2) * uvRow + (x / 2) * uvPixel
        val cb = (u[min(i, u.size - 1)].toInt() and 0xFF) - 128f
        val cr = (v[min(i, v.size - 1)].toInt() and 0xFF) - 128f
        val r = (lum + 1.402f * cr).toInt().coerceIn(0, 255)
        val g = (lum - 0.344f * cb - 0.714f * cr).toInt().coerceIn(0, 255)
        val b = (lum + 1.772f * cb).toInt().coerceIn(0, 255)
        return (r shl 16) or (g shl 8) or b
    }
}

object ArFrames {
    /** ARCore pose (OpenGL camera) -> world->camera with x right, y down, z forward. */
    fun camModel(pose: com.google.ar.core.Pose, intr: CameraIntrinsics): CamModel {
        val m = FloatArray(16)
        pose.toMatrix(m, 0)
        val r = floatArrayOf(
            m[0], m[1], m[2],
            -m[4], -m[5], -m[6],
            -m[8], -m[9], -m[10],
        )
        val c0 = m[12]
        val c1 = m[13]
        val c2 = m[14]
        val t = floatArrayOf(
            -(r[0] * c0 + r[1] * c1 + r[2] * c2),
            -(r[3] * c0 + r[4] * c1 + r[5] * c2),
            -(r[6] * c0 + r[7] * c1 + r[8] * c2),
        )
        val f = intr.focalLength
        val p = intr.principalPoint
        val d = intr.imageDimensions
        return CamModel(r, t, f[0], f[1], p[0], p[1], d[0], d[1])
    }

    /** Pixel (x, y) and depth of a world point, or null when behind the camera. */
    fun project(cam: CamModel, x: Float, y: Float, z: Float): FloatArray? {
        val r = cam.r
        val t = cam.t
        val zc = r[6] * x + r[7] * y + r[8] * z + t[2]
        if (zc <= 0.02f) return null
        val xc = r[0] * x + r[1] * y + r[2] * z + t[0]
        val yc = r[3] * x + r[4] * y + r[5] * z + t[1]
        return floatArrayOf(cam.fx * xc / zc + cam.cx, cam.fy * yc / zc + cam.cy, zc)
    }

    fun copyDepth(frame: Frame): ArDepth? {
        var img: Image? = null
        return try {
            img = frame.acquireDepthImage16Bits()
            val w = img.width
            val h = img.height
            val plane = img.planes[0]
            val buf = plane.buffer.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer()
            val rowShorts = plane.rowStride / 2
            val out = ShortArray(w * h)
            for (row in 0 until h) {
                buf.position(row * rowShorts)
                buf.get(out, row * w, w)
            }
            ArDepth(out, w, h)
        } catch (e: Throwable) {
            null
        } finally {
            img?.close()
        }
    }

    fun copyImage(frame: Frame): ArYuv? {
        var img: Image? = null
        return try {
            img = frame.acquireCameraImage()
            val p = img.planes
            fun bytes(b: java.nio.ByteBuffer): ByteArray {
                val a = ByteArray(b.remaining())
                b.get(a)
                return a
            }
            ArYuv(img.width, img.height, bytes(p[0].buffer), bytes(p[1].buffer), bytes(p[2].buffer),
                p[0].rowStride, p[1].rowStride, p[1].pixelStride)
        } catch (e: Throwable) {
            null
        } finally {
            img?.close()
        }
    }

    fun toJpeg(yuv: ArYuv, quality: Int = 93): ByteArray {
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
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), quality, out)
        return out.toByteArray()
    }

    /** Sharpness of the image centre (mean squared Laplacian). */
    fun sharpness(yuv: ArYuv): Float {
        val x0 = yuv.w / 4
        val x1 = yuv.w * 3 / 4
        val y0 = yuv.h / 4
        val y1 = yuv.h * 3 / 4
        var sum = 0.0
        var n = 0
        var yy = y0 + 2
        while (yy < y1 - 2) {
            var x = x0 + 2
            val row = yy * yuv.yRow
            while (x < x1 - 2) {
                val c = yuv.y[row + x].toInt() and 0xFF
                val l = (yuv.y[row + x - 2].toInt() and 0xFF) + (yuv.y[row + x + 2].toInt() and 0xFF) +
                    (yuv.y[row - 2 * yuv.yRow + x].toInt() and 0xFF) + (yuv.y[row + 2 * yuv.yRow + x].toInt() and 0xFF) - 4 * c
                sum += (l * l).toDouble()
                n++
                x += 4
            }
            yy += 4
        }
        return if (n > 0) (sum / n).toFloat() else 0f
    }
}
