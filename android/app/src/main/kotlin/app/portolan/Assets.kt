package app.portolan

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import org.json.JSONObject

/** The game's pictures and data, read from the app's assets (the project's assets/ folder). */
class Assets(val context: Context) {
    private val images = HashMap<String, ImageBitmap?>()

    fun image(path: String): ImageBitmap? {
        if (images.containsKey(path)) return images[path]
        val img = try {
            context.assets.open(path).use { BitmapFactory.decodeStream(it)?.asImageBitmap() }
        } catch (e: Exception) { null }
        images[path] = img
        return img
    }

    fun bytes(path: String): ByteArray = context.assets.open(path).use { it.readBytes() }

    fun json(path: String): JSONObject = JSONObject(String(bytes(path), Charsets.UTF_8))

    /** The towns of all ports (assets/portmaps/portmaps.json and the NNN.tiles files). */
    val towns: Map<Int, TownMap> by lazy {
        val f = json("portmaps/portmaps.json")
        val buildings = f.getJSONArray("buildings").let { a -> List(a.length()) { a.getString(it) } }
        val walk = f.getJSONArray("walk").let { a -> List(a.length()) { i -> a.getJSONArray(i).let { w -> List(w.length()) { w.getInt(it) } } } }
        val tiles = HashMap<Int, ByteArray>()
        val out = HashMap<Int, TownMap>()
        val ports = f.getJSONArray("ports")
        for (i in 0 until ports.length()) {
            val p = ports.getJSONObject(i)
            val map = p.getInt("map")
            val t = tiles.getOrPut(map) { bytes("portmaps/%03d.tiles".format(map)) }
            if (t.size != TownMap.SIZE * TownMap.SIZE) continue
            val w = walk[p.getInt("chipSet")]
            val doors = HashMap<String, Pair<Int, Int>>()
            val d = p.getJSONObject("doors")
            for (name in buildings) if (d.has(name)) d.getJSONArray(name).let { doors[name] = it.getInt(0) to it.getInt(1) }
            out[p.getInt("port")] = TownMap(map, t, w[1], w[2], w[3], doors)
        }
        out
    }

    /** Port names (assets/ports.json). */
    val portNames: Map<Int, String> by lazy {
        val a = json("ports.json").getJSONArray("ports")
        (0 until a.length()).associate { a.getJSONObject(it).getInt("id") to a.getJSONObject(it).getString("name") }
    }
}

/** One town (TownWalk.swift): the 96×96 tile grid and the walkability thresholds. */
class TownMap(val map: Int, private val tiles: ByteArray, private val a: Int, private val b: Int, private val c: Int,
              val doors: Map<String, Pair<Int, Int>>) {
    companion object { const val SIZE = 96 }

    fun tile(x: Int, y: Int): Int =
        if (x !in 0 until SIZE || y !in 0 until SIZE) 0xFF else tiles[y * SIZE + x].toInt() and 0xFF

    /** Only the feet row of the 2×2 sprite is tested (0x5F6A / 0x5FF4). */
    fun walkable(x: Int, y: Int): Boolean {
        val l = tile(x, y + 1)
        val r = tile(x + 1, y + 1)
        return l < b && (r < a || (b <= r && r < c))
    }
}

/** MESSAGE.DAT lines (assets/text.json). */
private val messageLines = HashMap<Context, List<String>>()
fun Assets.message(n: Int): String {
    val lines = messageLines.getOrPut(context) {
        try { json("text.json").getJSONArray("message").let { a -> List(a.length()) { a.getString(it) } } } catch (e: Exception) { emptyList() }
    }
    return lines.getOrElse(n) { "" }
}
