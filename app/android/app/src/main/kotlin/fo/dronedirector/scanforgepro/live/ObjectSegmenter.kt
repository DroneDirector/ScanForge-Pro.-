package fo.dronedirector.scanforgepro.live

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.tasks.components.containers.NormalizedKeypoint
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.interactivesegmenter.InteractiveSegmenter

/**
 * AI object selection: given a photo and a point on the object, returns a
 * mask of the whole object (on-device, MediaPipe Interactive Segmenter).
 */
class ObjectSegmenter private constructor(private val segmenter: InteractiveSegmenter) {

    /** Mask with 1 = object, 0 = background, size bitmap.width x bitmap.height, or null. */
    @Synchronized
    fun segment(bitmap: Bitmap, nx: Float, ny: Float): ByteArray? {
        return try {
            val image = BitmapImageBuilder(bitmap).build()
            val roi = InteractiveSegmenter.RegionOfInterest.create(
                NormalizedKeypoint.create(nx.coerceIn(0f, 1f), ny.coerceIn(0f, 1f))
            )
            val result = segmenter.segment(image, roi)
            val maskImage = result.categoryMask().orElse(null) ?: return null
            val w = maskImage.width
            val h = maskImage.height
            val buf = ByteBufferExtractor.extract(maskImage)
            val raw = ByteArray(w * h)
            buf.rewind()
            buf.get(raw, 0, minOf(raw.size, buf.remaining()))
            // the tapped point is on the object: use its value as "object"
            val ox = (nx * (w - 1)).toInt().coerceIn(0, w - 1)
            val oy = (ny * (h - 1)).toInt().coerceIn(0, h - 1)
            val objVal = raw[oy * w + ox]
            val out = ByteArray(w * h)
            var count = 0
            for (i in raw.indices) {
                if (raw[i] == objVal) { out[i] = 1; count++ }
            }
            val frac = count.toFloat() / (w * h)
            if (frac < 0.003f || frac > 0.9f) return null
            if (w != bitmap.width || h != bitmap.height) {
                // resample to the bitmap size (nearest)
                val res = ByteArray(bitmap.width * bitmap.height)
                for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                    res[y * bitmap.width + x] = out[(y * h / bitmap.height) * w + (x * w / bitmap.width)]
                }
                res
            } else out
        } catch (e: Throwable) {
            Log.w(TAG, "segmentation failed", e)
            null
        }
    }

    /** Object mask at "work" resolution (the photo scaled to at most workMax pixels). */
    class Result(val mask: ByteArray, val width: Int, val height: Int)

    /**
     * Zoomed AI detection: a first look at the whole photo finds roughly where
     * the object is; then the AI looks again at a full-resolution crop around
     * it, so far-away and small objects get a sharp outline. The outline is then
     * snapped to the real edges in the photo (guided filter).
     */
    fun segmentZoomed(jpeg: ByteArray, imgW: Int, imgH: Int, nx: Float, ny: Float, workMax: Int = 1280): Result? {
        try {
            val longSide = maxOf(imgW, imgH)
            // 1) coarse look
            val o0 = BitmapFactory.Options().apply { inSampleSize = maxOf(1, longSide / 512) }
            val b0 = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, o0) ?: return null
            val m0 = segment(b0, nx, ny)
            var rx0: Float; var rx1: Float; var ry0: Float; var ry1: Float
            if (m0 != null) {
                var x0 = b0.width; var x1 = -1; var y0 = b0.height; var y1 = -1
                for (y in 0 until b0.height) for (x in 0 until b0.width) {
                    if (m0[y * b0.width + x].toInt() == 0) continue
                    if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y
                }
                rx0 = x0.toFloat() / b0.width; rx1 = (x1 + 1f) / b0.width
                ry0 = y0.toFloat() / b0.height; ry1 = (y1 + 1f) / b0.height
            } else {
                rx0 = nx - 0.15f; rx1 = nx + 0.15f; ry0 = ny - 0.15f * imgW / imgH; ry1 = ny + 0.15f * imgW / imgH
            }
            b0.recycle()
            // 2) crop around it (35 % margin, at least 12 % of the photo)
            var cw = (rx1 - rx0) * imgW * 1.7f
            var ch = (ry1 - ry0) * imgH * 1.7f
            val minSide = 0.12f * longSide
            cw = maxOf(cw, minSide); ch = maxOf(ch, minSide)
            val cx = (rx0 + rx1) / 2 * imgW
            val cy = (ry0 + ry1) / 2 * imgH
            val rect = Rect(
                (cx - cw / 2).toInt().coerceIn(0, imgW - 2), (cy - ch / 2).toInt().coerceIn(0, imgH - 2),
                (cx + cw / 2).toInt().coerceIn(1, imgW), (cy + ch / 2).toInt().coerceIn(1, imgH),
            )
            if (rect.width() < 16 || rect.height() < 16) return null
            @Suppress("DEPRECATION")
            val dec = BitmapRegionDecoder.newInstance(jpeg, 0, jpeg.size, false) ?: return null
            val o1 = BitmapFactory.Options().apply { inSampleSize = maxOf(1, maxOf(rect.width(), rect.height()) / 768) }
            val crop = dec.decodeRegion(rect, o1)
            dec.recycle()
            val kx = (nx * imgW - rect.left) / rect.width()
            val ky = (ny * imgH - rect.top) / rect.height()
            var m1 = segment(crop, kx, ky)
            if (m1 == null) {
                crop.recycle()
                return null
            }
            // 3) snap to the real edges
            m1 = guidedRefine(crop, m1)
            // 4) place the crop mask into a work-resolution mask of the full photo
            val ws = minOf(1f, workMax.toFloat() / longSide)
            val ww = maxOf(8, (imgW * ws).toInt())
            val wh = maxOf(8, (imgH * ws).toInt())
            val out = ByteArray(ww * wh)
            val sx = crop.width.toFloat() / rect.width()
            val sy = crop.height.toFloat() / rect.height()
            val x0 = (rect.left * ws).toInt(); val x1 = minOf(ww, (rect.right * ws).toInt())
            val y0 = (rect.top * ws).toInt(); val y1 = minOf(wh, (rect.bottom * ws).toInt())
            var count = 0
            for (y in y0 until y1) for (x in x0 until x1) {
                val px = ((x / ws - rect.left) * sx).toInt().coerceIn(0, crop.width - 1)
                val py = ((y / ws - rect.top) * sy).toInt().coerceIn(0, crop.height - 1)
                if (m1[py * crop.width + px].toInt() != 0) { out[y * ww + x] = 1; count++ }
            }
            crop.recycle()
            if (count < 20) return null
            return Result(out, ww, wh)
        } catch (e: Throwable) {
            Log.w(TAG, "zoomed segmentation failed", e)
            return null
        }
    }

    /** Guided filter: makes the mask follow the brightness edges of the photo. */
    private fun guidedRefine(bmp: Bitmap, mask: ByteArray): ByteArray {
        val w = bmp.width
        val h = bmp.height
        val px = IntArray(w * h)
        bmp.getPixels(px, 0, w, 0, 0, w, h)
        val i = FloatArray(w * h) {
            val c = px[it]
            (0.299f * ((c shr 16) and 255) + 0.587f * ((c shr 8) and 255) + 0.114f * (c and 255)) / 255f
        }
        val p = FloatArray(w * h) { if (mask[it].toInt() != 0) 1f else 0f }
        val r = maxOf(2, maxOf(w, h) / 120)
        val eps = 0.0015f
        val ip = FloatArray(w * h) { i[it] * p[it] }
        val ii = FloatArray(w * h) { i[it] * i[it] }
        val mi = box(i, w, h, r); val mp = box(p, w, h, r)
        val mip = box(ip, w, h, r); val mii = box(ii, w, h, r)
        val a = FloatArray(w * h)
        val b = FloatArray(w * h)
        for (k in 0 until w * h) {
            val varI = mii[k] - mi[k] * mi[k]
            val cov = mip[k] - mi[k] * mp[k]
            a[k] = cov / (varI + eps)
            b[k] = mp[k] - a[k] * mi[k]
        }
        val ma = box(a, w, h, r); val mb = box(b, w, h, r)
        val out = ByteArray(w * h)
        for (k in 0 until w * h) if (ma[k] * i[k] + mb[k] > 0.5f) out[k] = 1
        return out
    }

    private fun box(src: FloatArray, w: Int, h: Int, r: Int): FloatArray {
        val integral = DoubleArray((w + 1) * (h + 1))
        for (y in 0 until h) {
            var row = 0.0
            for (x in 0 until w) {
                row += src[y * w + x]
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        val out = FloatArray(w * h)
        for (y in 0 until h) {
            val y0 = maxOf(0, y - r); val y1 = minOf(h, y + r + 1)
            for (x in 0 until w) {
                val x0 = maxOf(0, x - r); val x1 = minOf(w, x + r + 1)
                val s = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                out[y * w + x] = (s / ((x1 - x0) * (y1 - y0))).toFloat()
            }
        }
        return out
    }

    fun close() {
        try { segmenter.close() } catch (_: Throwable) {}
    }

    companion object {
        private const val TAG = "ScanForgeSegmenter"
        const val MODEL = "magic_touch.tflite"

        fun create(context: Context): ObjectSegmenter? {
            return try {
                context.assets.open(MODEL).close()
                val options = InteractiveSegmenter.InteractiveSegmenterOptions.builder()
                    .setBaseOptions(BaseOptions.builder().setModelAssetPath(MODEL).build())
                    .setOutputCategoryMask(true)
                    .setOutputConfidenceMasks(false)
                    .build()
                ObjectSegmenter(InteractiveSegmenter.createFromOptions(context, options))
            } catch (e: Throwable) {
                Log.w(TAG, "AI object selection not available", e)
                null
            }
        }
    }
}
