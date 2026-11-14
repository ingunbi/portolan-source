package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * A 640×400 stage for the endings (END.EXE): pictures at screen positions, typed text, dialogue
 * windows and fades, run by a script. One tick is a count of the FMDRV timer, 60.3 Hz
 * (docs/re/endings.md).
 */
class Stage(private val assets: Assets, private val scope: CoroutineScope) {
    class Layer(val id: String, image: String, x: Float, y: Float, opacity: Float = 1f, val clip: FloatArray? = null, val top: Boolean = false) {
        var image by mutableStateOf(image)
        var x by mutableFloatStateOf(x)
        var y by mutableFloatStateOf(y)
        var opacity by mutableFloatStateOf(opacity)
    }

    class TextBox(val id: String, val text: String, val x: Float, val y: Float, val width: Float, val color: Color) {
        var shown by mutableIntStateOf(0)
    }

    val layers = mutableStateListOf<Layer>()
    /** Window frames as x, y, w, h. */
    val boxes = mutableStateListOf<FloatArray>()
    val texts = mutableStateListOf<TextBox>()
    var black by mutableFloatStateOf(1f)
    var white by mutableFloatStateOf(0f)
    private var keyHit = false

    fun key() { keyHit = true }
    fun image(path: String) = assets.image(path)
    fun launchSide(block: suspend () -> Unit): Job = scope.launch { block() }

    private fun ms(ticks: Double) = (ticks / 60.3 * 1000).toLong()

    /** A timer wait; a breakable one ends early on a key. */
    suspend fun wait(ticks: Double, breakable: Boolean = false) {
        if (breakable) keyHit = false
        val end = System.nanoTime() + ms(ticks) * 1_000_000
        while (System.nanoTime() < end && scope.isActive && !(breakable && keyHit)) delay(15)
    }

    suspend fun waitKey() {
        keyHit = false
        while (!keyHit && scope.isActive) delay(15)
    }

    fun put(id: String, image: String, x: Double, y: Double, opacity: Float = 1f, clip: FloatArray? = null, top: Boolean = false) {
        val l = Layer(id, image, x.toFloat(), y.toFloat(), opacity, clip, top)
        val k = layers.indexOfFirst { it.id == id }
        if (k >= 0) layers[k] = l else layers.add(l)
    }

    fun layer(id: String) = layers.firstOrNull { it.id == id }
    fun remove(id: String) { layers.removeAll { it.id == id } }
    fun clear() { layers.clear(); texts.clear(); boxes.clear() }

    /** A linear run of [ticks] ticks, reporting 0…1 on every frame. */
    suspend fun tween(ticks: Double, update: (Float) -> Unit) {
        val total = ms(ticks).coerceAtLeast(1)
        val start = System.nanoTime()
        while (scope.isActive) {
            val t = ((System.nanoTime() - start) / 1_000_000f / total).coerceIn(0f, 1f)
            update(t)
            if (t >= 1f) break
            androidx.compose.runtime.withFrameNanos { }
        }
    }

    /** A palette fade, sixteen steps at most, one per [ticksPerStep]. */
    suspend fun fade(to: Float, ticksPerStep: Double = 4.0, whiteChannel: Boolean = false) {
        val from = if (whiteChannel) white else black
        tween(16 * ticksPerStep) { t -> val v = from + (to - from) * t; if (whiteChannel) white = v else black = v }
    }

    /** The plane-by-plane dissolve (END 0x2DA4): 16 steps. */
    suspend fun dissolve(id: String, image: String, x: Double, y: Double, ticksPerStep: Double = 3.0) {
        put(id, image, x, y, opacity = 0f)
        val l = layer(id) ?: return
        tween(16 * ticksPerStep) { l.opacity = it }
    }

    /** Text typed a character at a time (Hangul take two ticks). */
    suspend fun type(id: String, text: String, x: Double, y: Double, width: Double, ticksPerChar: Double = 1.0, color: Color = Color.White) {
        texts.removeAll { it.id == id }
        val box = TextBox(id, text, x.toFloat(), y.toFloat(), width.toFloat(), color)
        texts.add(box)
        for (n in 1..maxOf(1, text.length)) {
            box.shown = n
            val c = text.getOrElse(n - 1) { ' ' }
            wait(ticksPerChar * (if (c.code < 128) 1 else 2), breakable = true)
            if (keyHit) { box.shown = text.length; keyHit = false; return }
        }
    }

    /** Eye blinks or a lamp flame: frames shown in [order] (-1 = none), each for its ticks, until cancelled. */
    fun animate(id: String, frames: List<String>, at: Pair<Double, Double>, order: List<Int>, ticks: List<Double>): Job = scope.launch {
        var k = 0
        try {
            while (isActive) {
                val f = order[k % order.size]
                if (f < 0) remove(id) else put(id, frames[f], at.first, at.second)
                wait(ticks[k % ticks.size])
                k++
            }
        } finally { remove(id) }
    }
}

private fun JSONArray?.doubles(): List<Double> = if (this == null) emptyList() else List(length()) { getDouble(it) }
private fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else List(length()) { getString(it) }
private fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }

/** Draws the stage scaled to the screen, its faces and windows, typed text and the fades. */
@Composable
private fun StageView(stage: Stage, onKey: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black).clickable(indication = null, interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }) { onKey() }) {
        val density = LocalDensity.current
        val wPx = with(density) { maxWidth.toPx() }; val hPx = with(density) { maxHeight.toPx() }
        val s = minOf(wPx / 640f, hPx / 400f)
        val ox = (wPx - 640f * s) / 2; val oy = (hPx - 400f * s) / 2
        Canvas(Modifier.fillMaxSize()) {
            fun draw(l: Stage.Layer) {
                val img = stage.image(l.image) ?: return
                val x = ox + l.x * s; val y = oy + l.y * s
                val clip = l.clip
                if (clip != null) {
                    clipRect(ox + clip[0] * s, oy + clip[1] * s, ox + (clip[0] + clip[2]) * s, oy + (clip[1] + clip[3]) * s) {
                        drawImageFast(img, x, y, img.width * s, img.height * s, l.opacity)
                    }
                } else drawImageFast(img, x, y, img.width * s, img.height * s, l.opacity)
            }
            for (l in stage.layers) if (!l.top) draw(l)
            for (r in stage.boxes) {
                val tl = Offset(ox + r[0] * s, oy + r[1] * s); val sz = Size(r[2] * s, r[3] * s)
                drawRoundRect(Color(0xEB0D1433), tl, sz, CornerRadius(6f * s))
                drawRoundRect(Color(0xFFCCCCCC), tl, sz, CornerRadius(6f * s), style = Stroke(2f * s))
            }
            for (l in stage.layers) if (l.top) draw(l)
        }
        for (t in stage.texts) Text(
            t.text.take(t.shown), color = t.color, fontSize = with(density) { (15f * s).toSp() }, lineHeight = with(density) { (22f * s).toSp() },
            modifier = Modifier.offset { IntOffset((ox + t.x * s).toInt(), (oy + t.y * s).toInt()) }.width(with(density) { (t.width * s).toDp() })
        )
        Canvas(Modifier.fillMaxSize()) {
            if (stage.white > 0f) drawRect(Color.White.copy(alpha = stage.white.coerceIn(0f, 1f)))
            if (stage.black > 0f) drawRect(Color.Black.copy(alpha = stage.black.coerceIn(0f, 1f)))
        }
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawImageFast(img: androidx.compose.ui.graphics.ImageBitmap, x: Float, y: Float, w: Float, h: Float, alpha: Float) {
    drawImage(img, srcOffset = androidx.compose.ui.unit.IntOffset.Zero, srcSize = androidx.compose.ui.unit.IntSize(img.width, img.height),
        dstOffset = IntOffset(x.toInt(), y.toInt()), dstSize = androidx.compose.ui.unit.IntSize(w.toInt().coerceAtLeast(1), h.toInt().coerceAtLeast(1)),
        alpha = alpha, filterQuality = androidx.compose.ui.graphics.FilterQuality.None)
}

/** The ending sequence (END.EXE): homecoming, the diary, the staff roll. [finish] returns to the title. */
@Composable
fun EndingScreen(assets: Assets, host: EngineHost, code: Int, finish: () -> Unit) {
    val scope = rememberCoroutineScope()
    val stage = remember { Stage(assets, scope) }
    LaunchedEffect(Unit) {
        try { playEnding(stage, assets, host, code) } finally {
            Sound.scene(null)
            host.call("ending_finish", "code" to code)
            finish()
        }
    }
    StageView(stage) { stage.key() }
}

private suspend fun playEnding(s: Stage, assets: Assets, host: EngineHost, code: Int) {
    val data = try { JSONObject(String(assets.bytes("endings/endings.json"))) } catch (_: Exception) { return }
    val who = host.call("ending_info")
    val heroId = who.optInt("hero")
    val nation = who.optInt("nation")
    suspend fun fill(t: String): String = host.call("ending_text", "text" to t).optString("text", t)
    val hero = if (code == 0x0F) heroId else code
    val all = data.optJSONArray("endings") ?: return
    if (hero !in 0 until all.length()) return
    val e = all.getJSONObject(hero)
    val duke = code == 0x0F
    val windows = data.optJSONObject("windows") ?: JSONObject()

    // 1. Homecoming (0x14E8), song 19.
    Sound.scene(1)
    s.put("frame", "endings/endgrp_56.png", 0.0, 0.0)
    s.fade(0f, 1.0)
    val steps = (if (duke) data.optJSONObject("dukeEnding")?.optJSONArray("homecoming") else e.optJSONArray("homecoming")).objs()
    val open = mutableSetOf<String>()
    for (step in steps) {
        val say = step.optJSONObject("say")
        val pic = step.optJSONObject("picture")
        val narr = step.optJSONObject("narration")
        if (say != null && windows.has(say.optString("window"))) {
            val w = say.getString("window")
            val win = windows.getJSONObject(w)
            val f = win.getJSONArray("frame").doubles(); val face = win.getJSONArray("face").doubles(); val text = win.getJSONArray("text").doubles()
            if (w !in open) { s.boxes.add(floatArrayOf(f[0].toFloat(), f[1].toFloat(), f[2].toFloat(), f[3].toFloat())); open += w }
            val fv = say.opt("face")
            val id = when (fv) { is Int -> fv; is String -> if (fv == "ruler") 6 + minOf(5, nation) else hero; else -> 0 }
            s.put("face-$w", "endings/face_%02d.png".format(id), face[0], face[1], top = true)
            s.type("text-$w", fill(say.optString("text")), text[0], text[1], f[0] + f[2] - text[0] - 12)
            s.waitKey()
        } else if (step.has("closeWindows")) {
            s.boxes.clear(); s.texts.clear(); s.remove("face-top"); s.remove("face-bottom"); open.clear()
        } else if (pic != null) {
            val file = pic.optString("file").ifEmpty { e.optJSONArray("diary").objs().lastOrNull()?.optString("picture").orEmpty() }
            s.put("event", "endings/$file", pic.optDouble("x", 224.0), pic.optDouble("y", 96.0))
        } else if (narr != null) {
            val x = narr.optDouble("x", 192.0); val right = narr.optDouble("right", 432.0)
            s.type("narration", fill(narr.optString("text")), x, narr.optDouble("y", 248.0), right - x + 16)
            s.waitKey()
        }
    }
    s.fade(1f, 1.0)
    s.clear()

    // 2. Diary (story endings only, 0x566 / 0x598), song 22.
    Sound.scene(2)
    val pages = e.optJSONArray("diary").objs()
    if (!duke && pages.isNotEmpty()) {
        s.put("desk", "endings/endgrp_07.png", 0.0, 30.0)
        val lamp = s.animate("lamp", listOf("endings/endgrp_08.png", "endings/endgrp_09.png"), 480.0 to 30.0, listOf(0, 1), listOf(24.0, 24.0))
        s.fade(0f, 2.0)
        s.wait(300.0)
        for (p in pages) {
            s.dissolve("page", "endings/" + p.optString("picture"), 8.0, 100.0, 1.0)
            s.wait(120.0)
            s.dissolve("sepia", "endings/" + p.optString("sepia"), 8.0, 100.0, 6.0)
            s.remove("page")
            s.wait(60.0)
            val lines = p.optJSONArray("lines").strings().map { fill(it) }
            s.type("diary", lines.joinToString("\n"), 208.0, 100.0, 272.0, 3.0)
            s.wait(p.optDouble("holdTicks", 120.0), breakable = true)
            s.texts.clear()
            s.wait(60.0)
        }
        s.fade(1f, 5.0)
        lamp.cancel()
        s.clear()
    }

    // 3. Staff roll (0x6AA..0xB09).
    val portrait = e.optJSONObject("portrait") ?: JSONObject()
    val at = portrait.optJSONArray("drawAt").doubles().ifEmpty { listOf(256.0, 30.0) }
    val to = portrait.optJSONArray("slideTo").doubles().ifEmpty { listOf(0.0, 30.0) }
    s.put("portrait", "endings/" + portrait.optString("file", "endgrp_10.png"), at[0], at[1])
    s.fade(0f, 2.0)
    s.wait(20.0)
    s.layer("portrait")?.let { l -> s.tween((at[0] - to[0]) / 8) { l.x = (at[0] + (to[0] - at[0]) * it).toFloat() } }
    val loops = mutableListOf<Job>()
    e.optJSONObject("eyes")?.let { eyes ->
        val frames = eyes.optJSONArray("frames").strings(); val p = eyes.optJSONArray("at").doubles()
        if (frames.isNotEmpty() && p.size >= 2) loops += s.animate("eyes", frames.map { "endings/$it" }, p[0] to p[1], listOf(-1, 0, 1, 0), listOf(240.0, 6.0, 6.0, 6.0))
    }
    e.optJSONObject("sprite")?.let { sp ->
        val frames = sp.optJSONArray("frames").strings(); val p = sp.optJSONArray("at").doubles()
        val order = sp.optJSONArray("order")?.let { a -> List(a.length()) { a.getInt(it) } } ?: listOf(0, 1)
        val ticks = sp.optJSONArray("frameTicks")?.let { a -> List(a.length()) { a.getDouble(it) } } ?: listOf(12.0)
        if (frames.isNotEmpty() && p.size >= 2) loops += s.animate("sprite", frames.map { "endings/$it" }, p[0] to p[1], order, ticks)
    }
    // The epilogue panels scroll up through (384,210,240x160), a line every 6 ticks.
    val window = floatArrayOf(384f, 210f, 240f, 160f)
    s.put("epilogue1", "endings/endgrp_54.png", 384.0, 370.0, clip = window)
    s.put("epilogue2", "endings/endgrp_55.png", 384.0, 370.0 + 640, clip = window)
    val scroll = 640.0 * 2 + 160
    val scrolling = s.layer("epilogue1")?.let { a -> s.layer("epilogue2")?.let { b ->
        val y1 = a.y; val y2 = b.y
        scopeLaunch(s) { s.tween(scroll * 6) { t -> a.y = (y1 - scroll * t).toFloat(); b.y = (y2 - scroll * t).toFloat() } }
    } }
    for (k in 0 until 6) {
        s.dissolve("roll", "endings/endgrp_%02d.png".format(k), 392.0, 50.0, 6.0)
        s.wait(480.0)
    }
    s.wait(maxOf(0.0, scroll * 6 - 6 * (96 + 480)))
    scrolling?.cancel()
    loops.forEach { it.cancel() }
    val finalPic = portrait.optString("final"); val finalAt = portrait.optJSONArray("finalAt").doubles()
    if (finalPic.isNotEmpty() && finalAt.size >= 2) s.dissolve("final", "endings/$finalPic", finalAt[0], finalAt[1], 5.0)
    else e.optJSONObject("eyes")?.let { eyes ->
        val frames = eyes.optJSONArray("frames").strings(); val p = eyes.optJSONArray("at").doubles()
        if (frames.size >= 2 && p.size >= 2) { s.put("eyes", "endings/" + frames[0], p[0], p[1]); s.wait(6.0); s.put("eyes", "endings/" + frames[1], p[0], p[1]) }
    }
    s.wait(60.0)
    s.dissolve("roll", "endings/endgrp_06.png", 392.0, 50.0, 5.0)
    s.wait(60.0)
    for (id in listOf("portrait", "final", "eyes", "sprite", "epilogue1", "epilogue2")) s.remove(id)
    s.dissolve("fin", "endings/endgrp_53.png", 424.0, 250.0, 5.0)
    s.wait(60.0)
    Sound.scene(null)
    s.fade(1f, 11.0)
    s.clear()
    s.put("koei", "endings/endgrp_57.png", 216.0, 80.0)
    s.put("copy", "endings/endgrp_58.png", 184.0, 200.0)
    s.fade(0f)
    s.waitKey()
    s.fade(1f)
}

/** Runs [block] beside the script; the returned job can be cancelled. */
private fun scopeLaunch(s: Stage, block: suspend () -> Unit): Job = s.launchSide(block)
