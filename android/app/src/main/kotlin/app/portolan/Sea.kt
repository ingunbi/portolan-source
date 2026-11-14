package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlinx.coroutines.launch
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.*
import org.json.JSONObject

const val WORLD_W = 2160
const val WORLD_H = 1080

class Port(val id: Int, val name: String, val x: Int, val y: Int)

/** The world (docs/re/seamap.md): the original 16×16 chip map, the passability mask and the ports. */
class SeaWorld(assets: Assets) {
    val chips: ByteArray = assets.bytes("seamap/chips.bin")
    val mask: ByteArray = assets.bytes("world_mask.bin")
    val atlas = assets.image("seamap/atlas_p0.png")
    val ports: List<Port>

    init {
        // Ports and villages show their chips from the start (the original reveals them when sighted).
        val idx = assets.json("seamap/index.json").getJSONArray("markers")
        for (i in 0 until idx.length()) {
            val m = idx.getJSONObject(i)
            val c = m.getJSONArray("chips")
            val x = m.getInt("x"); val y = m.getInt("y")
            for (k in 0 until 4) {
                val tx = x + (k % 2); val ty = y + (k / 2)
                if (tx in 0 until WORLD_W && ty in 0 until WORLD_H) chips[ty * WORLD_W + tx] = c.getInt(k).toByte()
            }
        }
        val a = assets.json("ports.json").getJSONArray("ports")
        ports = (0 until a.length()).map { a.getJSONObject(it).let { p -> Port(p.getInt("id"), p.getString("name"), p.getInt("x"), p.getInt("y")) } }
    }

    fun chip(x: Int, y: Int): Int =
        if (y !in 0 until WORLD_H) 0 else chips[y * WORLD_H.let { WORLD_W } + ((x % WORLD_W) + WORLD_W) % WORLD_W].toInt() and 0xFF

    fun isSea(x: Double, y: Double): Boolean {
        val iy = floor(y).toInt()
        if (iy !in 0 until WORLD_H) return false
        val ix = ((floor(x).toInt() % WORLD_W) + WORLD_W) % WORLD_W
        return mask[iy * WORLD_W + ix].toInt() == 0
    }

    /** The fleet's 2×2 footprint around (x, y) is all sea (seamap.md: 0x30AA0). */
    fun fits(x: Double, y: Double): Boolean {
        val tx = floor(x - 0.5); val ty = floor(y - 0.5)
        return isSea(tx, ty) && isSea(tx + 1, ty) && isSea(tx, ty + 1) && isSea(tx + 1, ty + 1)
    }

    /** The nearest sea spot to a port where the fleet fits. */
    fun berth(p: Port): Pair<Double, Double> {
        for (r in 0..12) for (dy in -r..r) for (dx in -r..r) {
            if (max(abs(dx), abs(dy)) != r) continue
            val x = p.x + dx + 0.5; val y = p.y + dy + 0.5
            if (fits(x, y)) return x to y
        }
        return p.x + 0.5 to p.y + 0.5
    }
}

/** The player's voyage: position and heading, the calendar, the weather, the ship's stores. */
class VoyageState(val nav: NavData) {
    var x = 0.0
    var y = 0.0
    var heading8 = 2
    var year = 1522
    var month = 4              // May (0-based)
    var dayOfMonth = 16
    var tick = 24
    var daysAtSea = 0
    var summerWinds = false
    var weather = Weather(0, 0, 0, 0)
    var speedUnits = 0
    var water by mutableIntStateOf(260)            // tenths of a barrel
    var food by mutableIntStateOf(80)
    val rng = Rng(7L)
    val ships = listOf(Flagship(nav.classes[5], sail = nav.classes[5].sail, rudder = nav.classes[5].rudder, crew = 15))
    val captain = Captain(navLevel = 1, seamanship = 75)
    private var pending = 0.0
    var sailing = false

    private fun daysIn(m: Int, y: Int): Int {
        val leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
        return intArrayOf(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[m] + (if (m == 1 && leap) 1 else 0)
    }

    fun rollWeather() {
        val z = NavData.zone(x.toInt().coerceIn(0, WORLD_W - 1), y.toInt().coerceIn(0, WORLD_H - 1))
        val w = (if (summerWinds) nav.windSummer else nav.windWinter)[z]
        weather = Rules.roll(w, nav.current[z], rng)
    }

    /** The calendar and the day's upkeep at sea (0x190F9, 0x18F98). */
    private fun endOfDay() {
        daysAtSea++
        dayOfMonth++
        if (dayOfMonth >= daysIn(month, year)) {
            dayOfMonth = 0; month++
            if (month == 12) { month = 0; year++ }
            if (month % 6 == 2) summerWinds = month == 2
        }
        for (ship in ships) {
            val use = ship.crew * 100 / 100 + 1
            water -= minOf(use, water)
            food -= minOf(use, food)
        }
    }

    /** One of the 72 ticks of a day (0x30DF9): weather, speed, then the day roll. Returns the move in tiles. */
    fun gameTick(heading: Int): Pair<Double, Double> {
        if (tick % NavData.WEATHER_INTERVAL == 0) rollWeather()
        speedUnits = Rules.fleetSpeed(ships, captain, heading, weather.windDir, weather.windStrength, nav)
        val c = NavData.DX[heading].toDouble(); val s = NavData.DY[heading].toDouble()
        val norm = maxOf(kotlin.math.abs(c), kotlin.math.abs(s))
        val cx = NavData.DX[weather.currentDir] * weather.currentStrength
        val cy = NavData.DY[weather.currentDir] * weather.currentStrength
        val mx = (c / norm * speedUnits + cx) / NavData.TILE_UNITS
        val my = (s / norm * speedUnits + cy) / NavData.TILE_UNITS
        tick++
        if (tick >= NavData.TICKS_PER_DAY) { tick = 0; endOfDay() }
        return mx to my
    }

    /** Advances the clock by dt seconds and returns the distance moved in ticks' worth. */
    fun advance(dt: Double, heading: Int, onMove: (Double, Double) -> Unit) {
        pending += dt * NavData.TICKS_PER_DAY / NavData.SECONDS_PER_DAY
        while (pending >= 1) {
            pending -= 1
            val (mx, my) = gameTick(heading)
            onMove(mx, my)
        }
    }

    val dateText get() = "${year}년 ${month + 1}월 ${dayOfMonth + 1}일"
}

private const val SPEED = 3.2          // tiles a second (the original's day clock is much slower)
private val HEADING = listOf(0 to -1, 1 to -1, 1 to 0, 1 to 1, 0 to 1, -1 to 1, -1 to 0, -1 to -1)

private val NATION_COLORS = listOf(Color(0xFF3385F2), Color(0xFFF2CC33), Color(0xFF33BF66), Color(0xFFEBEBF2), Color(0xFF9959D9), Color(0xFFFA8C33), Color(0xFFD92626))

/** What the engine reported goes into the app's own voyage and purse. */
private fun applySnap(s: SeaSnap, game: GameState) {
    val v = game.voyage
    v.x = s.x; v.y = s.y; v.heading8 = s.heading8; v.speedUnits = s.speedUnits
    v.year = s.year; v.month = s.month; v.dayOfMonth = s.day; v.tick = s.tick; v.daysAtSea = s.daysAtSea
    v.weather = Weather(s.windDir, s.windStrength, s.currentDir, s.currentStrength)
    v.water = s.water; v.food = s.food; v.ships[0].crew = s.crew
    game.wallet.gold = s.gold; game.wallet.shot = s.shot; game.wallet.guns = s.guns
}

@Composable
fun SeaScreen(assets: Assets, world: SeaWorld, game: GameState, host: EngineHost, hero: Int, dock: (Port) -> Unit, title: () -> Unit, over: () -> Unit = title) {
    val voyage = game.voyage
    var tick by remember { mutableLongStateOf(0L) }
    var stick by remember { mutableStateOf<Int?>(null) }
    var course by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var newCourse by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var frame by remember { mutableIntStateOf(0) }
    var fleets by remember { mutableStateOf<List<Fleet>>(emptyList()) }
    var encounter by remember { mutableStateOf<Encounter?>(null) }
    var battle by remember { mutableStateOf<BattleSnap?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    var gameOver by remember { mutableStateOf("") }
    var alarm by remember { mutableStateOf<List<String>>(emptyList()) }
    var event by remember { mutableIntStateOf(0) }
    var fleetOpen by remember { mutableStateOf(false) }
    var landable by remember { mutableStateOf(false) }
    var ashore by remember { mutableStateOf(false) }
    var shore by remember { mutableStateOf<JSONObject?>(null) }
    var shoreAsk by remember { mutableStateOf<JSONObject?>(null) }
    var portList by remember { mutableStateOf<JSONObject?>(null) }
    var fleetMenu by remember { mutableStateOf<Fleet?>(null) }
    var hailOpen by remember { mutableStateOf(false) }
    val engine = host.ready
    val debuggable = (assets.context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    val scope = rememberCoroutineScope()
    val sceneRun = remember { SceneRun(host, game, scope) }
    val near = remember(tick / 6) { world.ports.firstOrNull { p -> hypot(p.x - voyage.x, p.y - voyage.y) < 3.2 && assets.towns.containsKey(p.id) } }

    fun take(s: SeaSnap) {
        // A reply that is no sea report (the end of a scene brings only the scene's own state): ask for the sea.
        if (!s.raw.has("x")) {
            if (s.ok) scope.launch { take(SeaSnap(host.call("state"))) }
            return
        }
        applySnap(s, game)
        fleets = s.fleets; encounter = s.encounter
        event = s.event
        if (s.raw.has("landable")) { landable = s.landable; ashore = s.ashore }
        if (s.alarm.isNotEmpty()) { alarm = s.alarm; Sound.sfx("sea_event") }
        for (c in s.sounds) Sound.cue(c)
        if (s.scene != null) sceneRun.take(s.raw)
        if (s.note.isNotEmpty()) note = s.note else if (s.notice.isNotEmpty()) note = s.notice
        if (s.gameOver.isNotEmpty()) gameOver = s.gameOver
    }
    /** An answer to an encounter (or a tap on a fleet) that the engine works out. */
    fun ask(cmd: String, vararg args: Pair<String, Any?>) {
        scope.launch { take(SeaSnap(host.call(cmd, *args))) }
    }
    val hail = remember { Clerk(host, game, scope) }
    /** 상륙 (0x34651): a village to search, open coast, a port to put into, or nothing to land on. */
    fun goAshore() {
        scope.launch {
            val j = host.call("ashore_start", "dockable" to (near != null))
            take(SeaSnap(j))
            when (j.optString("kind")) {
                "dock" -> near?.let { dock(it) }
                "village", "coast" -> shore = j
                "coastAsk" -> shoreAsk = j
            }
        }
    }
    fun beginBattle() {
        scope.launch {
            val j = host.call("battle_begin")
            if (j.has("scene")) { encounter = null; sceneRun.take(j) }
            else if (j.has("units")) { battle = BattleSnap(j); encounter = null }
            else take(SeaSnap(host.call("state")))
        }
    }

    LaunchedEffect(Unit) {
        // What follows a scene at sea: a battle that begins, or the sea again.
        sceneRun.onAfter = { j -> if (j.has("units")) { battle = BattleSnap(j); encounter = null } else take(SeaSnap(j)) }
    }
    LaunchedEffect(encounter != null || battle != null) {
        Sound.base(if (encounter != null || battle != null) 16 else Sound.seaSong(hero))
    }
    LaunchedEffect(event, encounter != null || battle != null, alarm.isEmpty()) {
        Sound.storm(event == 1 && encounter == null && battle == null && alarm.isEmpty())
    }
    DisposableEffect(Unit) { onDispose { Sound.storm(false) } }
    LaunchedEffect(note) { if (note != null) { kotlinx.coroutines.delay(3500); note = null } }

    LaunchedEffect(Unit) {
        if (engine) {
            take(SeaSnap(host.call("enter_sea", "x" to voyage.x, "y" to voyage.y)))
        }
        var last = 0L
        while (true) {
            var dt = 0.0
            withFrameNanos { t ->
                dt = if (last == 0L) 0.0 else ((t - last) / 1e9).coerceAtMost(0.1)
                last = t
                tick = t
                frame = ((t / 400_000_000L) % 2).toInt()
            }
            if (engine) {
                if (encounter != null || battle != null || gameOver.isNotEmpty() || sceneRun.scene != null || alarm.isNotEmpty() || fleetOpen ||
                    shore != null || shoreAsk != null || portList != null || fleetMenu != null || hailOpen) continue
                val send = newCourse; newCourse = null
                val s = SeaSnap(host.call("tick", "dt" to dt, "stick" to (stick ?: -1), "course" to send?.let { listOf(it.first, it.second) }))
                if (s.ok) take(s)
                course?.let { (cx, cy) -> if (hypot(cx - voyage.x, cy - voyage.y) < 0.8 || (s.speedUnits == 0 && stick == null && send == null)) course = null }
                continue
            }
            // No engine (it failed to start): the app's own port of the sea rules.
            var dir: Pair<Double, Double>? = null
            stick?.let { h -> voyage.heading8 = h; HEADING[h].let { (dx, dy) -> dir = dx.toDouble() to dy.toDouble() }; course = null }
            course?.let { (cx, cy) ->
                val dx = cx - voyage.x; val dy = cy - voyage.y
                if (hypot(dx, dy) < 0.4) course = null else {
                    dir = dx to dy
                    val a = atan2(dx, -dy)
                    voyage.heading8 = (((a / (PI / 4)).roundToInt() % 8) + 8) % 8
                }
            }
            if (dir != null) {
                voyage.sailing = true
                voyage.advance(dt, voyage.heading8) { mx, my ->
                    val nx = voyage.x + mx; val ny = voyage.y + my
                    when {
                        world.fits(nx, ny) -> { voyage.x = nx; voyage.y = ny }
                        world.fits(nx, voyage.y) -> voyage.x = nx
                        world.fits(voyage.x, ny) -> voyage.y = ny
                        else -> course = null
                    }
                    voyage.x = ((voyage.x % WORLD_W) + WORLD_W) % WORLD_W
                }
            } else { voyage.sailing = false; voyage.speedUnits = 0 }
        }
    }

    val classes = game.nav.classes
    fun sprite(set: Int, heading: Int, order: Int) =
        assets.image("sprites/ships/world_${set}_${intArrayOf(0, 1, 1, 1, 2, 3, 3, 3)[heading and 7]}_${(frame + order) and 1}.png")
    val ship = sprite(if (voyage.ships[0].cls.oars) 0 else 1, voyage.heading8, 0)

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Canvas(Modifier.fillMaxSize().pointerInput(Unit) {
            detectTapGestures { p ->
                if (encounter != null || battle != null) return@detectTapGestures
                // A tap sets a course toward that spot of the sea; on a fleet that is close it attacks.
                val side = size.height.toFloat()
                val left = (size.width - side) / 2f
                val tile = side / 24f
                val lx = (p.x - left) / tile; val ly = p.y / tile
                if (lx !in 0f..24f) return@detectTapGestures
                val tx = voyage.x + (lx - 12); val ty = voyage.y + (ly - 12)
                var dxw = { fx: Int -> ((fx + 0.5 - voyage.x + WORLD_W * 1.5) % WORLD_W) - WORLD_W / 2.0 }
                val hit = fleets.firstOrNull { f -> hypot(dxw(f.x) - (tx - voyage.x), f.y + 0.5 - ty) < 1.6 }
                if (hit != null && hit.near && engine) fleetMenu = hit
                else { course = tx to ty; newCourse = course }
            }
        }) {
            tick.let { }
            val side = size.height
            val left = (size.width - side) / 2f
            val tile = side / 24f
            val cx = voyage.x - 12
            val cy = (voyage.y - 12).coerceIn(0.0, (WORLD_H - 24).toDouble())
            val bx = floor(cx).toInt(); val by = floor(cy).toInt()
            val fx = ((cx - bx) * tile).toFloat(); val fy = ((cy - by) * tile).toFloat()
            val atlas = world.atlas
            if (atlas != null) {
                val t = ceil(tile).toInt() + 1
                for (j in 0..24) for (i in 0..24) {
                    val id = world.chip(bx + i, by + j)
                    drawImage(atlas, srcOffset = IntOffset((id % 16) * 16, (id / 16) * 16), srcSize = IntSize(16, 16),
                        dstOffset = IntOffset((left + i * tile - fx).roundToInt(), (j * tile - fy).roundToInt()), dstSize = IntSize(t, t),
                        filterQuality = FilterQuality.None)
                }
            }
            // Other fleets in sight, each with its nation's pennant.
            for (f in fleets) {
                var dx = f.x + 0.5 - voyage.x
                if (dx > WORLD_W / 2) dx -= WORLD_W; if (dx < -WORLD_W / 2) dx += WORLD_W
                val px = left + (voyage.x + dx - cx).toFloat() * tile; val py = (f.y + 0.5 - cy).toFloat() * tile
                val oars = classes.getOrNull(f.cls)?.oars ?: false
                val img = sprite(2 + (if (oars) 0 else 1), f.heading, f.id)
                if (img != null) drawImage(img, srcOffset = IntOffset.Zero, srcSize = IntSize(32, 32),
                    dstOffset = IntOffset((px - tile).roundToInt(), (py - tile).roundToInt()), dstSize = IntSize((tile * 2).roundToInt(), (tile * 2).roundToInt()),
                    filterQuality = FilterQuality.None)
                drawRect(NATION_COLORS[f.nation.coerceIn(0, 6)], Offset(px - 4f, py - tile - 12f), Size(18f, 9f))
                if (f.near) drawCircle(Color.White.copy(alpha = 0.55f), radius = tile * 1.5f, center = Offset(px, py), style = Stroke(2f))
            }
            // The player's fleet (a 2×2-tile sprite) in the middle of the window.
            if (ship != null) {
                val sx = left + (voyage.x - 1 - cx).toFloat() * tile
                val sy = ((voyage.y - 1 - cy)).toFloat() * tile
                drawImage(ship, srcOffset = IntOffset.Zero, srcSize = IntSize(32, 32),
                    dstOffset = IntOffset(sx.roundToInt(), sy.roundToInt()), dstSize = IntSize((tile * 2).roundToInt(), (tile * 2).roundToInt()),
                    filterQuality = FilterQuality.None)
            }
            // Course marker.
            course?.let { (px, py) ->
                val sx = left + (px - cx).toFloat() * tile; val sy = ((py - cy)).toFloat() * tile
                drawCircle(Gold, radius = 10f, center = Offset(sx, sy), style = Stroke(4f))
            }
        }
        SeaStatus(voyage, game.wallet, tick, Modifier.align(Alignment.TopStart).padding(16.dp))
        MiniMap(assets, voyage, tick, Modifier.align(Alignment.TopEnd).padding(top = 92.dp, end = 16.dp))
        Row(Modifier.align(Alignment.TopEnd).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (engine && game.hasShip && encounter == null && battle == null) {
                GoldButton(if (ashore) "상륙지" else if (landable) "상륙 · 탐색" else "상륙", prominent = landable || ashore) { goAshore() }
                GoldButton("항구이동") { scope.launch { portList = host.call("port_list") } }
                GoldButton("함대") { fleetOpen = true }
            }
            GoldButton("타이틀", onClick = title)
        }
        note?.let { Text(it, color = Color.White, fontSize = 18.sp, modifier = Modifier.align(Alignment.TopCenter).padding(top = 20.dp)
            .clip(androidx.compose.foundation.shape.RoundedCornerShape(12.dp)).background(NavyLight.copy(alpha = 0.92f)).padding(horizontal = 18.dp, vertical = 10.dp)) }
        if (encounter == null && battle == null) near?.let { p ->
            GoldButton("${p.name} 입항", Modifier.align(Alignment.BottomCenter).padding(32.dp), prominent = true) { dock(p) }
        }
        if (engine && debuggable && encounter == null && battle == null) {
            Column(Modifier.align(Alignment.BottomEnd).padding(24.dp), verticalArrangement = Arrangement.spacedBy(6.dp), horizontalAlignment = Alignment.End) {
                SmallButton("시험:해안", Modifier.width(150.dp)) { scope.launch { take(SeaSnap(host.call("debug_warp", "to" to "coast"))) } }
                SmallButton("시험:함대", Modifier.width(150.dp)) {
                    scope.launch {
                        val s = SeaSnap(host.call("debug_warp", "to" to "fleet"))
                        take(s)
                        fleetMenu = s.fleets.firstOrNull { it.near }
                    }
                }
                SmallButton("시험:교전", Modifier.width(150.dp)) {
                    scope.launch {
                        host.call("debug_arm")
                        take(SeaSnap(host.call("debug_encounter")))
                    }
                }
            }
        }
        HelmPad(Modifier.align(Alignment.BottomStart).padding(28.dp), voyage.heading8) { stick = it }

        encounter?.let { e ->
            Overlay {
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    val face = if (e.face in 0..127) assets.image("portraits/%03d.png".format(e.face)) else null
                    if (face != null) Canvas(Modifier.size(64.dp, 80.dp)) { pixels(face, 0f, 0f, size.width, size.height) }
                    Column {
                        Text(e.enemy, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                        Text("${e.nation} 함대 · 전투력 ${e.theirs} (아군 ${e.ours})", color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp)
                    }
                }
                Spacer(Modifier.height(12.dp))
                Column(Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
                    for (l in e.lines) Text(l, color = Color.White, fontSize = 18.sp)
                }
                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (e.defending) {
                        SmallButton("교전", prominent = true) { beginBattle() }
                        SmallButton("도망") { ask("flee") }
                        SmallButton("항복") { ask("surrender") }
                    } else if (e.merchantOffer) {
                        SmallButton("받아들인다", prominent = true) {
                            scope.launch {
                                val j = host.call("battle_accept_offer")
                                if (j.optBoolean("ok")) { battle = BattleSnap(j); encounter = null }
                            }
                        }
                        SmallButton("거절한다") { beginBattle() }
                    } else {
                        SmallButton("전투 개시", prominent = true) { beginBattle() }
                    }
                }
            }
        }
        // Storm and fog over the sea.
        if (event == 1) Box(Modifier.fillMaxSize().background(Color(0xFF0A1830).copy(alpha = 0.45f)))
        if (event == 3) Box(Modifier.fillMaxSize().background(Color(0xFFCCD6E0).copy(alpha = 0.38f)))
        if (alarm.isNotEmpty()) Overlay {
            Text(alarm.first(), color = Gold, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            for (l in alarm.drop(1)) Text(l, color = Color.White, fontSize = 20.sp, lineHeight = 28.sp)
            Spacer(Modifier.height(16.dp))
            SmallButton("계속", prominent = true) { alarm = emptyList() }
        }
        SceneOverlay(sceneRun, assets)
        fleetMenu?.let { f ->
            FleetMenu(f, talk = {
                fleetMenu = null
                scope.launch {
                    val j = host.call("hail_fleet", "fleet" to f.id)
                    take(SeaSnap(j))
                    hail.take(j)
                    hailOpen = hail.lines.isNotEmpty() || hail.ask != null
                }
            }, attack = { fleetMenu = null; ask("attack_fleet", "fleet" to f.id) }, close = { fleetMenu = null })
        }
        if (hailOpen) Overlay {
            TalkBox(hail)
            if (hail.ask == null) { Spacer(Modifier.height(14.dp)); SmallButton("닫기", prominent = true) { hailOpen = false } }
        }
        shoreAsk?.let { a ->
            Overlay {
                Text(a.optString("text"), color = Color.White, fontSize = 20.sp)
                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    SmallButton("예", prominent = true) {
                        shoreAsk = null
                        scope.launch {
                            val j = host.call("ashore_coast", "x" to a.optInt("x"), "y" to a.optInt("y"))
                            take(SeaSnap(j)); shore = j
                        }
                    }
                    SmallButton("아니오") { shoreAsk = null }
                }
            }
        }
        shore?.let { st ->
            ShoreScreen(host, assets, scope, st, take = { j -> take(SeaSnap(j)) }) {
                shore = null
                scope.launch { take(SeaSnap(host.call("state"))) }
            }
        }
        portList?.let { l ->
            PortList(host, scope, l, take = { j -> take(SeaSnap(j)) }) { portList = null }
        }
        if (fleetOpen) FleetSheet(host, game, assets, scope, atSea = true) {
            fleetOpen = false
            scope.launch { take(SeaSnap(host.call("state"))) }
        }
        battle?.let { b ->
            BattleScreen(assets, host, b) { s -> battle = null; stick = null; course = null; take(s) }
        }
        if (gameOver.isNotEmpty()) Overlay {
            Text("항해 종료", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            Text(gameOver, color = Color.White, fontSize = 18.sp)
            Spacer(Modifier.height(16.dp))
            SmallButton("타이틀로", prominent = true, onClick = over)
        }
    }
}

/** The helm: one disc, eight headings; hold a direction to sail, let go to drop anchor. */
@Composable
fun HelmPad(modifier: Modifier = Modifier, heading: Int, onStick: (Int?) -> Unit) {
    var active by remember { mutableStateOf<Int?>(null) }
    Box(
        modifier.size(210.dp).clip(CircleShape).background(NavyLight.copy(alpha = 0.78f))
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
                            if (hypot(v.x, v.y) > 26f) { d = (((atan2(v.x, -v.y) / (PI / 4)).roundToInt() % 8) + 8) % 8; break }
                        }
                        active = d
                        onStick(d)
                    }
                }
            },
        contentAlignment = Alignment.Center
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val r = size.minDimension / 2f
            for (h in 0 until 8) {
                val (dx, dy) = HEADING[h]
                val l = hypot(dx.toFloat(), dy.toFloat())
                val on = if (active == h) Gold else if (active == null && heading == h) Gold.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.2f)
                drawCircle(on, radius = r * (if (h % 2 == 0) 0.17f else 0.11f), center = Offset(r + dx / l * r * 0.68f, r + dy / l * r * 0.68f))
            }
        }
    }
}

private val WIND_NAMES = listOf("북", "북동", "동", "남동", "남", "남서", "서", "북서")

@Composable
fun SeaStatus(v: VoyageState, wallet: Wallet, tick: Long, modifier: Modifier = Modifier) {
    tick.let { }
    Column(modifier.clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp)).background(NavyLight.copy(alpha = 0.88f)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(v.dateText, color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text("바람 ${WIND_NAMES[v.weather.windDir]} ${v.weather.windStrength}   해류 ${WIND_NAMES[v.weather.currentDir]} ${v.weather.currentStrength}",
            color = Color(0xFF78D6FF), fontSize = 14.sp)
        Text("속력 ${"%.1f".format(v.speedUnits / 2.0)}노트   항해 ${v.daysAtSea}일째", color = Color.White, fontSize = 14.sp)
        Text("식수 ${v.water / 10}통   식량 ${v.food / 10}통", color = if (v.water <= 0 || v.food <= 0) Color(0xFFFF6B6B) else Color.White, fontSize = 14.sp)
        Text("자금 ${wallet.gold}닢   승무원 ${v.ships[0].crew}명   포탄 ${wallet.shot}", color = Gold, fontSize = 14.sp)
        Text("동경 ${v.x.toInt()}  북위 ${v.y.toInt()}", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
    }
}

/** The whole world in small (assets/minimap.png) with the fleet marked. */
@Composable
private fun MiniMap(assets: Assets, voyage: VoyageState, tick: Long, modifier: Modifier) {
    val img = assets.image("minimap.png")
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp)
    Canvas(modifier.size(236.dp, 118.dp).clip(shape).background(Navy.copy(alpha = 0.6f))
        .border(1.dp, Gold.copy(alpha = 0.4f), shape)) {
        tick.let { }
        if (img != null) drawImage(img, srcOffset = IntOffset.Zero, srcSize = IntSize(img.width, img.height),
            dstOffset = IntOffset.Zero, dstSize = IntSize(size.width.toInt(), size.height.toInt()), filterQuality = FilterQuality.Low)
        val cx = (voyage.x / WORLD_W * size.width).toFloat(); val cy = (voyage.y / WORLD_H * size.height).toFloat()
        drawCircle(Color.White, 6f, Offset(cx, cy))
        drawCircle(Color.Red, 4.5f, Offset(cx, cy))
    }
}
