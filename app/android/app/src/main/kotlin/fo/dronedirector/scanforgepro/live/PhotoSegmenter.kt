package fo.dronedirector.scanforgepro.live

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

/**
 * Separates the object from the background in finished photos (turntable
 * scans): the AI outlines the object in the middle of each photo and the
 * outline is saved to masks/ for the 3D engine.
 */
object PhotoSegmenter {
    fun run(context: Context, project: File, progress: (Int, Int) -> Unit): Int {
        val seg = ObjectSegmenter.create(context) ?: return 0
        val masks = File(project, "masks").apply { mkdirs() }
        val photos = File(project, "photos").listFiles()
            ?.filter { it.extension.lowercase() in listOf("jpg", "jpeg", "png") && !it.name.startsWith("LIVE_") }
            ?.sortedBy { it.name } ?: emptyList()
        var made = 0
        for ((i, f) in photos.withIndex()) {
            try {
                val out = File(masks, f.nameWithoutExtension + ".png")
                if (!out.exists()) {
                    val upright = uprightJpeg(f)
                    if (upright != null) {
                        val res = seg.segmentZoomed(upright.first, upright.second, upright.third, 0.5f, 0.55f)
                        if (res != null) {
                            val px = IntArray(res.mask.size) { if (res.mask[it].toInt() != 0) -0x1 else -0x1000000 }
                            val bmp = Bitmap.createBitmap(px, res.width, res.height, Bitmap.Config.ARGB_8888)
                            FileOutputStream(out).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                            bmp.recycle()
                            made++
                        }
                    }
                } else made++
            } catch (e: Throwable) {
                Log.w("ScanForgeSegment", "photo failed: ${f.name}", e)
            }
            progress(i + 1, photos.size)
        }
        seg.close()
        return made
    }

    /** Photo as it is shown (EXIF rotation applied), re-encoded; with its size. */
    private fun uprightJpeg(f: File): Triple<ByteArray, Int, Int>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(f.path, bounds)
        val longSide = maxOf(bounds.outWidth, bounds.outHeight)
        val opts = BitmapFactory.Options().apply { inSampleSize = maxOf(1, longSide / 2400) }
        var bmp = BitmapFactory.decodeFile(f.path, opts) ?: return null
        val rot = when (ExifInterface(f.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (rot != 0f) {
            val m = Matrix().apply { postRotate(rot) }
            val r = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
            bmp.recycle()
            bmp = r
        }
        val bos = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 92, bos)
        val w = bmp.width
        val h = bmp.height
        bmp.recycle()
        return Triple(bos.toByteArray(), w, h)
    }
}
