package app.portolan

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import org.json.JSONObject

/**
 * Faces of minor characters, assembled from parts as MAIN.EXE does (docs/re/faces.md): per nation a
 * set of tops, bottoms, eyes, noses and mouths picked by the bits of person +0x1A. Eyes, nose and
 * mouth are OR-ed into the palette indices below them.
 */
class FaceComposer(private val assets: Assets) {
    private class Layer(val name: String, val shift: Int, val mask: Int, val x: Int, val y: Int, val w: Int, val h: Int, val copy: Boolean)

    private val width: Int
    private val height: Int
    private val palette: List<Int>
    private val layers: List<Layer>
    private val sets: List<JSONObject>
    private val parts = HashMap<String, ByteArray?>()
    private val cache = HashMap<Int, ImageBitmap?>()

    init {
        val j = try { assets.json("faces/faces.json") } catch (e: Exception) { JSONObject("""{"width":64,"height":80,"palette":[],"layers":[],"sets":[]}""") }
        width = j.getInt("width"); height = j.getInt("height")
        palette = j.getJSONArray("palette").let { a -> List(a.length()) { i -> a.getJSONArray(i).let { c -> (0xFF shl 24) or (c.getInt(0) shl 16) or (c.getInt(1) shl 8) or c.getInt(2) } } }
        layers = j.getJSONArray("layers").let { a ->
            List(a.length()) { i -> a.getJSONObject(i).let { l -> Layer(l.getString("name"), l.getInt("shift"), l.getInt("mask"), l.getInt("x"), l.getInt("y"), l.getInt("width"), l.getInt("height"), l.getString("blend") == "copy") } }
        }
        sets = j.getJSONArray("sets").let { a -> List(a.length()) { a.getJSONObject(it).getJSONObject("parts") } }
    }

    /** A part picture as palette indices, 255 for transparent. */
    private fun indices(name: String, w: Int, h: Int): ByteArray? = parts.getOrPut(name) {
        val bmp: Bitmap = try { assets.context.assets.open("faces/$name").use { BitmapFactory.decodeStream(it) } } catch (e: Exception) { null } ?: return@getOrPut null
        val px = IntArray(bmp.width * bmp.height)
        bmp.getPixels(px, 0, bmp.width, 0, 0, bmp.width, bmp.height)
        val out = ByteArray(w * h) { 255.toByte() }
        for (i in 0 until minOf(w * h, px.size)) {
            val c = px[i]
            if ((c ushr 24) <= 127) continue
            val r = (c shr 16) and 0xFF; val g = (c shr 8) and 0xFF; val b = c and 0xFF
            var best = 0; var bestD = Int.MAX_VALUE
            for ((k, p) in palette.withIndex()) {
                val d = Math.abs(((p shr 16) and 0xFF) - r) + Math.abs(((p shr 8) and 0xFF) - g) + Math.abs((p and 0xFF) - b)
                if (d < bestD) { bestD = d; best = k }
            }
            out[i] = best.toByte()
        }
        out
    }

    /** The face for a 14-bit value in nation set `set` (0...6). */
    fun face(value: Int, set: Int): ImageBitmap? {
        if (set !in sets.indices) return null
        val key = set shl 16 or (value and 0x3FFF)
        return cache.getOrPut(key) {
            val pix = IntArray(width * height)
            for (l in layers) {
                val k = (value shr l.shift) and l.mask
                val names = sets[set].optJSONArray(l.name) ?: continue
                if (k !in 0 until names.length()) continue
                val p = indices(names.getString(k), l.w, l.h) ?: continue
                for (y in 0 until l.h) for (x in 0 until l.w) {
                    val v = p[y * l.w + x].toInt() and 0xFF
                    val at = (l.y + y) * width + l.x + x
                    if (at >= pix.size || v == 255) continue
                    if (l.copy) pix[at] = v else if (v != 0) pix[at] = pix[at] or v
                }
            }
            val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bmp.setPixels(IntArray(pix.size) { palette.getOrElse(pix[it] and 7) { 0xFF000000.toInt() } }, 0, width, 0, 0, width, height)
            bmp.asImageBitmap()
        }
    }
}

private val composers = HashMap<android.content.Context, FaceComposer>()

/** A portrait by its person +0x1A value: KAO pictures, or a face assembled from parts. */
fun Assets.portrait(value: Int, nation: Int = 0): ImageBitmap? = when {
    value and 0xC000 != 0 -> composers.getOrPut(context) { FaceComposer(this) }.face(value and 0x3FFF, minOf(6, nation))
    value in 0..127 -> image("portraits/%03d.png".format(value))
    else -> null
}
