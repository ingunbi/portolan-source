package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.drawscope.clipRect
import org.json.JSONObject
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.hypot

private val DIRS = listOf(0 to -1, 1 to 0, 0 to 1, -1 to 0)        // up, right, down, left
private val DIR_NAMES = listOf("up", "right", "down", "left")
private val BUILDINGS = listOf("교역소", "주점", "조선소", "항구", "여관", "왕궁", "조합", "NPC", "은행", "아이템", "교회", "점술가")
private const val STEP_NANOS = 100_000_000L                          // one pass of the walk loop

/** A townsperson: slots 0–3 walk (k is the facing), 4–7 stand (k: 0 man, 1 dog, 2 guard, 3 merchant). */
private class Folk(val slot: Int, val x: Int, val y: Int, val k: Int) { val walker get() = slot < 4 }

/** The walking town (docs/re/town_walk.md): a 24×24-tile window over the port map. */
@Composable
fun TownScreen(assets: Assets, game: GameState, host: EngineHost, hero: Int, port: Int, title: () -> Unit, onEnding: (Int) -> Unit, setSail: () -> Unit) {
    val town = assets.towns[port]
    if (town == null) { Text("이 항구의 지도를 찾을 수 없습니다.", color = Color.White); return }
    val harbor = town.doors["항구"] ?: (54 to 67)
    // Where the hero stands (top-left tile of the 2×2 sprite) and the window's top-left tile.
    var hx by remember { mutableIntStateOf(harbor.first) }
    var hy by remember { mutableIntStateOf(harbor.second + 1) }
    var camX by remember { mutableIntStateOf((harbor.first - 12).coerceIn(0, 72)) }
    var camY by remember { mutableIntStateOf((harbor.second - 13).coerceIn(0, 72)) }
    var face by remember { mutableIntStateOf(2) }
    var frame by remember { mutableIntStateOf(0) }
    var aim by remember { mutableStateOf<Int?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var building by remember { mutableStateOf<String?>(null) }
    var entry by remember { mutableStateOf<org.json.JSONObject?>(null) }
    var entering by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var fleetOpen by remember { mutableStateOf(false) }
    val sceneRun = remember { SceneRun(host, game, scope).also { it.onEnding = onEnding } }
    // The previous tile and camera, and when the step began, for the slide between tiles.
    var fromX by remember { mutableFloatStateOf(hx.toFloat()) }
    var fromY by remember { mutableFloatStateOf(hy.toFloat()) }
    var fromCX by remember { mutableFloatStateOf(camX.toFloat()) }
    var fromCY by remember { mutableFloatStateOf(camY.toFloat()) }
    var stepAt by remember { mutableLongStateOf(0L) }
    var now by remember { mutableLongStateOf(0L) }
    var folk by remember { mutableStateOf<List<Folk>>(emptyList()) }
    var prevFolk by remember { mutableStateOf<Map<Int, Pair<Int, Int>>>(emptyMap()) }
    var tickNow by remember { mutableIntStateOf(24) }
    var walking by remember { mutableStateOf(false) }
    // The door tile an event was already taken at: a locked door says so once, not at every pass.
    var doorAt by remember { mutableStateOf<Pair<Int, Int>?>(null) }

    /** What the engine reports of the town: the hero's tile and the window, the townsfolk (they glide with the hero). */
    fun applyTown(j: JSONObject, t: Long, jump: Boolean = false) {
        val tv = j.optJSONObject("town") ?: return
        val h = tv.getJSONArray("hero"); val c = tv.getJSONArray("camera")
        val nx = h.getInt(0); val ny = h.getInt(1); val ncx = c.getInt(0); val ncy = c.getInt(1)
        val near = !jump && abs(nx - hx) <= 1 && abs(ny - hy) <= 1 && abs(ncx - camX) <= 1 && abs(ncy - camY) <= 1
        val moved = nx != hx || ny != hy || ncx != camX || ncy != camY
        fromX = if (near) hx.toFloat() else nx.toFloat(); fromY = if (near) hy.toFloat() else ny.toFloat()
        fromCX = if (near) camX.toFloat() else ncx.toFloat(); fromCY = if (near) camY.toFloat() else ncy.toFloat()
        hx = nx; hy = ny; camX = ncx; camY = ncy
        if (moved && !jump) frame = frame xor 1
        prevFolk = if (jump) emptyMap() else folk.associate { it.slot to (it.x to it.y) }
        folk = tv.optJSONArray("folk")?.let { a -> List(a.length()) { a.getJSONObject(it).let { f -> Folk(f.getInt("slot"), f.getInt("x"), f.getInt("y"), f.getInt("k")) } } } ?: emptyList()
        tickNow = tv.optInt("tick", tickNow)
        stepAt = t
        if (j.has("face")) face = j.getInt("face")
        if (doorAt != null && doorAt != (hx to hy)) doorAt = null
    }

    /** A door: the engine decides whether it is open and lets the hero in (hours, the hour it takes, arrests). */
    fun openDoor(name: String) {
        val index = BUILDINGS.indexOf(name)
        if (!host.ready || index < 0) { building = name; entry = null; return }
        entering = true
        scope.launch {
            val j = host.call("town_enter", "building" to index, *walletArgs(game))
            entering = false
            applyWallet(j.optJSONObject("wallet"), game)
            fun text(o: org.json.JSONObject) = o.optJSONArray("lines")?.let { a -> (0 until a.length()).joinToString("\n") { a.getString(it) } } ?: ""
            if (!j.has("scene")) { message = text(j).ifEmpty { "들어갈 수 없습니다." }; return@launch }
            sceneRun.building = index
            sceneRun.onEntry = { e ->
                applyWallet(e.optJSONObject("wallet"), game)
                if (e.optBoolean("admitted")) { entry = e; building = name }
                else { val t = text(e); if (t.isNotEmpty()) message = t }
            }
            sceneRun.onDone = null
            sceneRun.take(j)
        }
    }

    LaunchedEffect(port) {
        if (host.ready) {
            val j = host.call("dock", "port" to port, *walletArgs(game))
            applyWallet(j.optJSONObject("wallet"), game)
            if (j.has("music")) Sound.base(j.getInt("music"))
            applyTown(host.call("town_view"), 0L, jump = true)
            walking = true
        }
    }

    LaunchedEffect(Unit) {
        var last = 0L
        while (true) {
            var t = 0L
            withFrameNanos { tt -> now = tt; t = tt }
            if (walking && message == null && building == null && !entering && sceneRun.scene == null && t - last >= STEP_NANOS) {
                last = t
                // One pass of the walk loop is the engine's: the step, the townsfolk, a bump, a door.
                val j = host.call("town_pass", "dir" to (aim ?: -1))
                if (message != null || building != null || entering || sceneRun.scene != null) continue
                applyTown(j, t)
                j.optJSONArray("talk")?.let { a ->
                    message = (0 until a.length()).joinToString("\n") { a.getString(it) }
                    aim = null
                }
                if (message == null && j.has("door") && doorAt != (hx to hy)) {
                    aim = null
                    doorAt = hx to hy
                    BUILDINGS.getOrNull(j.getInt("door"))?.let { openDoor(it) }
                }
            }
        }
    }

    val image = assets.image("portmaps/%03d.png".format(town.map))
    val sprite = assets.image("townchars/hero${minOf(hero, 5)}_${DIR_NAMES[face]}_$frame.png")

    Box(Modifier.fillMaxSize().background(Navy)) {
        Canvas(Modifier.fillMaxSize()) {
            val p = ((now - stepAt).toFloat() / STEP_NANOS).coerceIn(0f, 1f)
            fun lerp(a: Float, b: Int) = a + (b - a) * p
            val cx = lerp(fromCX, camX)
            val cy = lerp(fromCY, camY)
            val side = size.height
            val left = (size.width - side) / 2f
            val scale = side / 384f
            // The window: 24×24 tiles of 16 dots, cut from the 1536-dot map.
            if (image != null) {
                val sx = (cx * 16).coerceIn(0f, 1152f)
                val sy = (cy * 16).coerceIn(0f, 1152f)
                drawImage(image, srcOffset = IntOffset(sx.toInt(), sy.toInt()), srcSize = IntSize(384, 384),
                    dstOffset = IntOffset(left.toInt(), 0), dstSize = IntSize(side.toInt(), side.toInt()), filterQuality = FilterQuality.None)
                val subX = (sx - sx.toInt()) * scale
                val subY = (sy - sy.toInt()) * scale
                if (sprite != null) {
                    val x = left + (lerp(fromX, hx) - cx) * 16 * scale - subX
                    val y = (lerp(fromY, hy) - cy) * 16 * scale - subY
                    pixels(sprite, x, y, 32 * scale, 32 * scale)
                }
                // The townsfolk: walkers slide a tile in step with the hero, the standing flicker between two frames.
                clipRect(left, 0f, left + side, side) {
                    for (f in folk.sortedBy { it.y }) {
                        val name = if (f.walker) "walker_${if (f.slot and 1 == 0) "a" else "b"}_${DIR_NAMES[f.k and 3]}_${if ((f.x + f.y) % 2 == 0) 1 else 0}"
                        else "stand_${listOf("man", "dog", "guard", "merchant")[minOf(3, f.k)]}_${(frame + f.slot + (now / 333_333_333L).toInt()) % 2}"
                        val img = assets.image("townchars/$name.png") ?: continue
                        val from = if (f.walker) prevFolk[f.slot] else null
                        val fx = if (from != null && abs(from.first - f.x) <= 1 && abs(from.second - f.y) <= 1) from.first + (f.x - from.first) * p else f.x.toFloat()
                        val fy = if (from != null && abs(from.first - f.x) <= 1 && abs(from.second - f.y) <= 1) from.second + (f.y - from.second) * p else f.y.toFloat()
                        pixels(img, left + (fx - cx) * 16 * scale - subX, (fy - cy) * 16 * scale - subY, 32 * scale, 32 * scale)
                    }
                }
                // The time of day tints the town (night, dawn, dusk).
                val tint = when (intArrayOf(0, 1, 2, 2, 3, 0)[minOf(5, tickNow / 12)]) {
                    0 -> Color(0.05f, 0.08f, 0.3f, 0.45f); 1 -> Color(0.9f, 0.6f, 0.4f, 0.12f); 3 -> Color(0.95f, 0.45f, 0.2f, 0.18f); else -> null
                }
                if (tint != null) drawRect(tint, Offset(left, 0f), Size(side, side), blendMode = BlendMode.Multiply)
            }
        }
        Text(assets.portNames[port] ?: "", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.align(Alignment.TopStart).padding(20.dp))
        Row(Modifier.align(Alignment.TopEnd).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (host.ready && game.hasShip) GoldButton("함대") { fleetOpen = true }
            GoldButton("출항", prominent = true) { if (game.hasShip) setSail() else message = "배가 없습니다. 조선소에서 배를 구하거나 이야기를 진행해 주세요." }
            GoldButton("타이틀", onClick = title)
        }
        DirectionPad(face, Modifier.align(Alignment.BottomStart).padding(28.dp)) { aim = it }
        // Test aid for debug builds: open any door at once.
        if ((assets.context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0 && building == null && message == null && !entering) {
            Column(Modifier.align(Alignment.BottomEnd).padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp), horizontalAlignment = Alignment.End) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    SmallButton("금화 +20000", Modifier.width(150.dp)) { scope.launch { applyWallet(host.call("debug_gold", "amount" to 20000).optJSONObject("wallet"), game) } }
                    SmallButton("이야기 끄기", Modifier.width(150.dp)) { scope.launch { host.call("debug_story_off") } }
                    SmallButton("배 지급", Modifier.width(150.dp)) { scope.launch { applyWallet(host.call("debug_ship", *walletArgs(game)).optJSONObject("wallet"), game) } }
                }
                for (row in BUILDINGS.chunked(3)) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (n in row) if (town.doors.containsKey(n)) SmallButton(n, Modifier.width(150.dp)) { openDoor(n) }
                }
            }
        }
        if (fleetOpen) FleetSheet(host, game, assets, scope, atSea = false) { fleetOpen = false }
        building?.let { b ->
            BuildingPanel(game, host, assets, port, assets.portNames[port] ?: "", b, entry, onEnding,
                leave = {
                    scope.launch {
                        val farewell = if (host.ready) host.call("town_leave").optJSONArray("lines")?.let { a -> (0 until a.length()).joinToString("\n") { a.getString(it) } } ?: "" else ""
                        building = null
                        if (farewell.isNotEmpty()) message = farewell
                    }
                },
                setSail = { building = null; if (game.hasShip) setSail() else message = "배가 없습니다. 조선소에서 배를 구하거나 이야기를 진행해 주세요." })
        }
        SceneOverlay(sceneRun, assets)
        message?.let { m ->
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)).clickable {
                message = null
            }, contentAlignment = Alignment.Center) {
                Box(Modifier.clip(RoundedCornerShape(16.dp)).background(NavyLight).padding(28.dp)) {
                    Text(m + "\n\n(화면을 누르면 닫습니다)", color = Color.White, fontSize = 20.sp)
                }
            }
        }
    }
}

/** The direction pad: one disc that follows every finger; the newest touch steers. */
@Composable
fun DirectionPad(facing: Int, modifier: Modifier = Modifier, onAim: (Int?) -> Unit) {
    var active by remember { mutableStateOf<Int?>(null) }
    Box(
        modifier.size(190.dp).clip(CircleShape).background(NavyLight.copy(alpha = 0.78f))
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    val order = mutableListOf<PointerId>()
                    while (true) {
                        val ev = awaitPointerEvent()
                        val center = Offset(size.width / 2f, size.height / 2f)
                        for (c in ev.changes) {
                            if (c.pressed && c.id !in order) order.add(c.id)
                            if (!c.pressed) order.remove(c.id)
                            c.consume()
                        }
                        var d: Int? = null
                        for (id in order.reversed()) {
                            val c = ev.changes.firstOrNull { it.id == id } ?: continue
                            val v = c.position - center
                            if (hypot(v.x, v.y) > 24f) { d = if (abs(v.x) > abs(v.y)) (if (v.x > 0) 1 else 3) else (if (v.y > 0) 2 else 0); break }
                        }
                        active = d
                        onAim(d)
                    }
                }
            },
        contentAlignment = Alignment.Center
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val r = size.minDimension / 2f
            val c = Offset(r, r)
            for (d in 0 until 4) {
                val (dx, dy) = DIRS[d]
                val lit = active == d
                val on = if (lit) Gold else if (active == null && facing == d) Gold.copy(alpha = 0.55f) else Color.White.copy(alpha = 0.18f)
                val k = c + Offset(dx * r * 0.62f, dy * r * 0.62f)
                drawCircle(on, radius = r * 0.26f, center = k)
            }
        }
    }
}
