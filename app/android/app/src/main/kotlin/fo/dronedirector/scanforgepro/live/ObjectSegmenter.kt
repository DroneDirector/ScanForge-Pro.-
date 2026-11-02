package fo.dronedirector.scanforgepro.live

import android.content.Context
import android.graphics.Bitmap
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
