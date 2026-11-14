package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlin.math.*

private val WIND6 = listOf("북", "북동", "남동", "남", "남서", "북서")
private val Blue = Color(0xFF3A86FF)
private val Red = Color(0xFFE5484D)

/** The part of the sea with ships on it, at least 24×18 hexes (the original shows 13×12). */
private fun battleWindow(b: BattleSnap): IntArray {
    val live = b.units.filter { it.alive }
    val xs = live.map { it.x } + b.reach.keys.map { it % b.width }
    val ys = live.map { it.y } + b.reach.keys.map { it / b.width }
    var x0 = (xs.minOrNull() ?: 0) - 4; var x1 = (xs.maxOrNull() ?: b.width) + 4
    var y0 = (ys.minOrNull() ?: 0) - 4; var y1 = (ys.maxOrNull() ?: b.height) + 4
    if (x1 - x0 < 24) { val c = (x0 + x1) / 2; x0 = c - 12; x1 = c + 12 }
    if (y1 - y0 < 18) { val c = (y0 + y1) / 2; y0 = c - 9; y1 = c + 9 }
    x0 = max(0, x0); y0 = max(0, y0); x1 = min(b.width, x1); y1 = min(b.height, y1)
    return intArrayOf(x0, y0, x1 - x0, y1 - y0)
}

/** The window grown to fill the canvas (more sea around the ships, not bigger cells) and the cell size. */
private fun fitWindow(base: IntArray, w: Float, h: Float, b: BattleSnap): Pair<IntArray, Float> {
    val c = min(w / base[2], h / (base[3] + 0.5f))
    val cols = min(b.width, floor(w / c).toInt()).coerceAtLeast(base[2])
    val rows = min(b.height, floor(h / c - 0.5f).toInt()).coerceAtLeast(base[3])
    val x0 = (base[0] - (cols - base[2]) / 2).coerceIn(0, max(0, b.width - cols))
    val y0 = (base[1] - (rows - base[3]) / 2).coerceIn(0, max(0, b.height - rows))
    return intArrayOf(x0, y0, cols, rows) to c
}

/** One cell's rectangle: odd columns sit half a cell lower (HDAT.PUT's hex layout). */
private fun cellX(x: Int, vx: Int, c: Float) = (x - vx) * c
private fun cellY(x: Int, y: Int, vy: Int, c: Float) = (y - vy) * c + if (x and 1 == 1) c / 2 else 0f

private fun DrawScope.put(img: ImageBitmap?, x: Float, y: Float, w: Float, h: Float) {
    if (img == null) return
    val x0 = x.roundToInt(); val y0 = y.roundToInt()
    drawImage(img, srcOffset = IntOffset.Zero, srcSize = IntSize(img.width, img.height),
        dstOffset = IntOffset(x0, y0), dstSize = IntSize((x + w).roundToInt() - x0, (y + h).roundToInt() - y0), filterQuality = FilterQuality.None)
}

@Composable
fun SmallButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, prominent: Boolean = false, onClick: () -> Unit) {
    Box(
        modifier.clip(RoundedCornerShape(12.dp))
            .background(if (!enabled) Color.White.copy(alpha = 0.07f) else if (prominent) Gold else Color(0xFF34496F))
            .clickable(enabled = enabled, onClick = onClick).defaultMinSize(minWidth = UiSize.Touch, minHeight = UiSize.Touch).padding(horizontal = 18.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, color = if (!enabled) Color.White.copy(alpha = 0.35f) else if (prominent) Color.Black.copy(alpha = 0.85f) else Color.White,
            fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** The battle: the hex sea, the orders of the flagship, the duel and the result. */
@Composable
fun BattleScreen(assets: Assets, host: EngineHost, start: BattleSnap, done: (SeaSnap) -> Unit) {
    var snap by remember { mutableStateOf(start) }
    var busy by remember { mutableStateOf(false) }
    var askDuel by remember { mutableStateOf<Int?>(null) }
    var showOrders by remember { mutableStateOf(false) }
    var clock by remember { mutableLongStateOf(0L) }
    val picks = remember { mutableStateListOf<Int>() }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) { while (true) withFrameNanos { clock = it } }

    fun run(cmd: String, vararg args: Pair<String, Any?>) {
        if (busy) return
        busy = true
        scope.launch {
            val j = host.call(cmd, *args)
            if (j.optBoolean("ok")) snap = BattleSnap(j)
            busy = false
        }
    }

    val b = snap
    val me = b.units.getOrNull(b.active)
    // The strike's frames play once, from the moment a new strike shows up.
    var strikeAt by remember { mutableLongStateOf(0L) }
    var strikeSeen by remember { mutableIntStateOf(-1) }
    if (b.strikeSerial != strikeSeen) { strikeSeen = b.strikeSerial; strikeAt = clock }
    LaunchedEffect(b.strikeSerial) { if (b.strikeSerial >= 0) Sound.strike(b.strikeBoarding) }
    LaunchedEffect(b.phase, b.endCode) {
        if (b.phase == "over") when (b.endCode) {
            0, 4, 6 -> { Sound.onFinished = { Sound.onFinished = null; Sound.base(17) }; Sound.base(Sound.FANFARE) }   // 0x1040D: the fanfare once, then the victory song
            5, 7 -> Sound.base(20)
        }
    }

    Box(Modifier.fillMaxSize().background(Color(0xFF0A1A2E))) {
        Row(Modifier.fillMaxSize().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val base = remember(b) { battleWindow(b) }
            Canvas(Modifier.weight(1f).fillMaxHeight().pointerInput(b, busy) {
                detectTapGestures { p ->
                    if (busy || b.phase != "command" || me == null) return@detectTapGestures
                    val (view, c) = fitWindow(base, size.width.toFloat(), size.height.toFloat(), b)
                    val col = floor(p.x / c).toInt()
                    val x = view[0] + col
                    val row = floor((p.y - if (x and 1 == 1) c / 2 else 0f) / c).toInt()
                    val y = view[1] + row
                    val target = b.targets.firstOrNull { b.units[it].x == x && b.units[it].y == y }
                    if (target != null) {
                        if (target in b.duelOffered) askDuel = target else run("battle_attack", "target" to target)
                    } else if (!b.moved && b.reach.containsKey(y * b.width + x)) {
                        run("battle_move", "x" to x, "y" to y)
                    }
                }
            }) {
                clock.let { }
                val (view, c) = fitWindow(base, size.width, size.height, b)
                val phase = ((clock / 1_000_000_000.0) / (17 / 18.2)).toInt() % 4
                for (y in (view[1] - 1) until (view[1] + view[3] + 1)) {
                    if (y !in 0 until b.height) continue
                    for (x in view[0] until (view[0] + view[2])) {
                        val chip = min(12, b.map[y * b.width + x] and 0x1F)
                        val base = "sprites/battle/chip_%02d".format(chip)
                        val img = (if (phase > 0) assets.image("${base}_p$phase.png") else null) ?: assets.image("$base.png")
                        put(img, cellX(x, view[0], c), cellY(x, y, view[1], c), c, c)
                    }
                }
                // Markers: reachable cells, enemies in range, enemies alongside.
                if (me != null && b.phase == "command") {
                    if (!b.moved) for (cell in b.reach.keys) {
                        val x = cell % b.width; val y = cell / b.width
                        put(assets.image("sprites/battle/mark_ship.png"), cellX(x, view[0], c), cellY(x, y, view[1], c), c, c)
                    }
                }
                for ((k, u) in b.units.withIndex()) {
                    if (u.hull <= 0 || u.flags and 0x40 != 0) continue
                    if (u.x !in view[0] until (view[0] + view[2]) || u.y !in view[1] until (view[1] + view[3])) continue
                    val set = (if (u.owner and 0x80 != 0) 0 else 1) + (if (u.sailOnly) 0 else 2)
                    val sx = cellX(u.x, view[0], c); val sy = cellY(u.x, u.y, view[1], c)
                    put(assets.image("sprites/battle/ship_${set}_${u.heading % 6}.png"), sx, sy, c, c)
                    if (k == b.active) drawRect(Color.Yellow, Offset(sx + 1, sy + 1), Size(c - 2, c - 2), style = Stroke(3f))
                }
                // Enemies that can be hit or boarded are marked over their ships.
                if (me != null && b.phase == "command") for (j in b.targets) {
                    val u = b.units[j]
                    put(assets.image(if (j in b.boardable) "sprites/battle/mark_board.png" else "sprites/battle/mark_fire.png"),
                        cellX(u.x, view[0], c), cellY(u.x, u.y, view[1], c), c, c)
                }
                // The latest strike: the cannonball, then the burst or the sabres.
                if (b.strikeTarget in b.units.indices) {
                    val t = b.units[b.strikeTarget]
                    val age = (clock - strikeAt) / 1e9 - (if (b.strikeBoarding) 0.0 else 0.25)
                    val tx = cellX(t.x, view[0], c); val ty = cellY(t.x, t.y, view[1], c)
                    if (age < 0 && b.units.indices.contains(b.strikeAttacker)) {
                        val a = b.units[b.strikeAttacker]
                        val f = (1 + age / 0.25).toFloat()
                        val ax = cellX(a.x, view[0], c) + c / 2; val ay = cellY(a.x, a.y, view[1], c) + c / 2
                        val bx = ax + (tx + c / 2 - ax) * f
                        val by = ay + (ty + c / 2 - ay) * f - sin(f * PI.toFloat()) * c * 0.8f
                        put(assets.image("sprites/battle/ball.png"), bx - c / 8, by - c / 8, c / 4, c / 4)
                    } else if (age in 0.0..0.6) {
                        val f = min(3, (age / 0.15).toInt())
                        if (b.strikeBoarding) put(assets.image("sprites/battle/board_${intArrayOf(0, 1, 2, 3, 1, 3, 0, 2)[(age / 0.075).toInt() % 8]}.png"), tx, ty, c, c)
                        else {
                            put(assets.image("sprites/battle/hit_$f.png"), tx, ty, c, c)
                            put(assets.image("sprites/battle/splash_$f.png"), tx + (if (b.strikeSerial and 1 == 0) 0f else c / 2), ty + c * 0.375f, c / 2, c * 0.625f)
                        }
                    }
                }
            }
            BattleSide(assets, b, me, busy, Modifier.width(330.dp).fillMaxHeight(),
                turn = { d -> run("battle_turn", "d" to d) },
                signal = { gather, attack -> run("battle_signal", "gather" to gather, "attack" to attack) },
                pass = { run("battle_pass") }, leave = { run("battle_leave") }, orders = { showOrders = true })
        }

        askDuel?.let { target ->
            Overlay {
                Text(assets.message(770).ifEmpty { "일기토를 신청하시겠습니까?" }, color = Color.White, fontSize = 20.sp)
                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    SmallButton("취소") { askDuel = null }
                    SmallButton("일기토") { askDuel = null; run("battle_attack", "target" to target, "challenge" to true) }
                    SmallButton("백병전", prominent = true) { askDuel = null; run("battle_attack", "target" to target, "challenge" to false) }
                }
            }
        }
        if (showOrders) OrdersPanel(b, { showOrders = false }) { cmd, args -> run(cmd, *args) }
        b.duel?.let { d -> if (b.phase == "duel") DuelPanel(assets, d) { m -> run("duel_move", "move" to m) } }
        b.result?.let { r ->
            if (b.phase == "over") ResultPanel(assets, r, picks) {
                if (busy) return@ResultPanel
                busy = true
                scope.launch {
                    val j = host.call("battle_close", "picks" to picks.toList())
                    busy = false
                    done(SeaSnap(j))
                }
            }
        }
    }
}

@Composable
fun Overlay(content: @Composable ColumnScope.() -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
        Column(Modifier.widthIn(max = 640.dp).clip(RoundedCornerShape(16.dp)).background(Navy).border(1.dp, Gold.copy(alpha = 0.5f), RoundedCornerShape(16.dp)).padding(24.dp),
            content = content)
    }
}

@Composable
private fun BattleSide(assets: Assets, b: BattleSnap, me: BUnit?, busy: Boolean, modifier: Modifier,
                       turn: (Int) -> Unit, signal: (Boolean?, Boolean?) -> Unit, pass: () -> Unit,
                       leave: () -> Unit, orders: () -> Unit) {
    val ready = !busy && b.phase == "command" && me != null
    val flag = b.units.firstOrNull { it.player && it.flagship }
    Column(modifier.clip(RoundedCornerShape(16.dp)).background(NavyLight.copy(alpha = 0.9f)).padding(14.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("해전", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val wind = assets.image("sprites/battle/wind_${b.windDir % 6}.png")
            Canvas(Modifier.size(40.dp)) { put(wind, 0f, 0f, size.width, size.height) }
            Text("${b.tick / 3}시 · 바람 ${WIND6[b.windDir % 6]} ${b.windStrength}", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp)
        }
        if (me != null) {
            Text(if (b.moved) "공격할 적을 누르거나 턴을 마치세요." else "이동할 칸을 누르세요. 이동한 뒤 포격할 수 있습니다.",
                color = Color.White, fontSize = 14.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SmallButton("◀ 선회", Modifier.weight(1f), enabled = ready && !b.moved) { turn(-1) }
                SmallButton("선회 ▶", Modifier.weight(1f), enabled = ready && !b.moved) { turn(1) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SmallButton(if (me.flags and 1 != 0) "신호: 수세" else "신호: 공세", Modifier.weight(1f), enabled = ready) { signal(null, me.flags and 1 == 0) }
                SmallButton(if (me.flags and 4 != 0) "분산" else "집결", Modifier.weight(1f), enabled = ready) { signal(me.flags and 4 == 0, null) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SmallButton("정선 · 턴 종료", Modifier.weight(1f), enabled = ready, prominent = true, onClick = pass)
                SmallButton("이탈", Modifier.weight(1f), enabled = ready && b.canLeave, onClick = leave)
            }
            SmallButton("작전", Modifier.fillMaxWidth(), enabled = ready, onClick = orders)
        }
        if (flag != null) {
            Text(flag.name + "호", color = Gold, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text("내구도 ${flag.hull}/${flag.maxHull}   승무원 ${flag.crew}/${flag.maxCrew}\n조타 ${flag.rudder}   돛 ${flag.sails}   포탄 ${flag.shot}",
                color = Color.White, fontSize = 14.sp)
        }
        Text("교전 함대", color = Gold, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        for (u in b.units) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                Box(Modifier.padding(top = 5.dp).size(8.dp).clip(RoundedCornerShape(4.dp)).background(if (u.owner and 0x80 != 0) Blue else Red))
                Column {
                    Text(u.name, color = Color.White, fontSize = 14.sp)
                    Text(if (u.flags and 0x40 != 0) "이탈" else if (u.hull <= 0) "격침" else if (u.crew <= 0) "전투 불능" else "${u.hull}/${u.maxHull} · ${u.crew}명",
                        color = if (u.flags and 0x40 != 0) Gold else if (u.alive) Color.White.copy(alpha = 0.6f) else Red, fontSize = 14.sp)
                }
            }
        }
        if (b.log.isNotEmpty()) {
            Text("전투 기록", color = Gold, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            for (l in b.log) Text(l, color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)
        }
    }
}

@Composable
private fun OrdersPanel(b: BattleSnap, close: () -> Unit, run: (String, Array<Pair<String, Any?>>) -> Unit) {
    Overlay {
        Text("작전", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        val own = b.units.withIndex().filter { (k, u) -> k != b.active && u.owner == 0x80 && u.alive }
        if (own.isEmpty()) Text("지시할 아군 선박이 없습니다.", color = Color.White, fontSize = 16.sp)
        for ((k, u) in own) {
            Row(Modifier.padding(vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(u.name, color = Color.White, fontSize = 16.sp, modifier = Modifier.width(150.dp))
                SmallButton(if (u.flags and 2 != 0) "공격 방침 ▸ 퇴각" else "퇴각 방침 ▸ 공격") { run("battle_order", arrayOf("unit" to k, "attack" to (u.flags and 2 == 0))) }
                SmallButton(if (u.flags and 0x10 != 0) "포격 중심 ▸ 돌격" else "돌격 중심 ▸ 포격") { run("battle_order", arrayOf("unit" to k, "gunnery" to (u.flags and 0x10 == 0))) }
            }
        }
        Spacer(Modifier.height(14.dp))
        SmallButton("닫기", prominent = true, onClick = close)
    }
}

@Composable
fun DuelPanel(assets: Assets, d: org.json.JSONObject, move: (Int) -> Unit) {
    val turn = d.optInt("turn"); val playerIsA = d.optBoolean("playerIsA")
    val attacking = (turn % 2 == 0) == playerIsA
    val mine = if (playerIsA) d.optInt("meter") else 200 - d.optInt("meter")
    Overlay {
        Text("일기토  ${d.optString("nameA")} 對 ${d.optString("nameB")}", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("턴 ${turn + 1} : ${if (attacking) "공격" else "방어"}", color = Color.White, fontSize = 18.sp)
        Spacer(Modifier.height(8.dp))
        Box(Modifier.fillMaxWidth().height(12.dp).clip(RoundedCornerShape(6.dp)).background(Red.copy(alpha = 0.7f))) {
            Box(Modifier.fillMaxWidth(mine.coerceIn(0, 200) / 200f).fillMaxHeight().background(Blue))
        }
        val line = d.optString("line")
        if (line.isNotEmpty()) { Spacer(Modifier.height(8.dp)); Text(line, color = Color.White.copy(alpha = 0.75f), fontSize = 16.sp) }
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val names = if (attacking) listOf("찌른다", "벤다", "친다") else listOf("걷어낸다", "맞받는다", "비킨다")
            for (k in 0 until 3) SmallButton(names[k], Modifier.weight(1f), prominent = true) { move(k) }
        }
    }
}

@Composable
private fun ResultPanel(assets: Assets, r: org.json.JSONObject, picks: MutableList<Int>, close: () -> Unit) {
    val code = r.optInt("code")
    val victory = code == 4 || code == 6
    val pic = mapOf(4 to 53, 6 to 53, 8 to 53, 2 to 54, 3 to 54, 9 to 54, 1 to 55, 5 to 56, 7 to 56)[code]
    val gold = r.optInt("gold")
    val lines = r.optJSONArray("lines")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
    val capturable = r.optJSONArray("capturable")?.let { a -> List(a.length()) { a.getInt(it) } } ?: emptyList()
    val names = r.optJSONArray("capturableNames")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
    val may = r.optInt("mayTake")
    Overlay {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (victory) "해전 승리" else "해전 종료", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            if (gold > 0) Text("+${gold}닢", color = Gold, fontSize = 20.sp)
        }
        Spacer(Modifier.height(10.dp))
        val img = pic?.let { assets.image("sprites/battle/result_$it.png") }
        if (img != null) Canvas(Modifier.fillMaxWidth().height(if (capturable.isEmpty()) 220.dp else 130.dp)) {
            val h = size.height; val w = h * img.width / img.height
            put(img, (size.width - w) / 2f, 0f, w, h)
        }
        Column(Modifier.heightIn(max = 180.dp).verticalScroll(rememberScrollState())) {
            for (l in lines) Text(l, color = Color.White, fontSize = 16.sp)
            if (r.optInt("item", -1) >= 0) Text("전리품을 손에 넣었습니다.", color = Gold, fontSize = 16.sp)
        }
        if (capturable.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            Text("함대에 편입할 배를 고르세요 (최대 ${may}척)", color = Gold, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
                for ((i, k) in capturable.withIndex()) {
                    val on = k in picks
                    SmallButton((if (on) "✓ " else "") + names.getOrElse(i) { "선박" }, prominent = on) {
                        if (on) picks.remove(k) else if (picks.size < may) picks.add(k)
                    }
                }
            }
        }
        Spacer(Modifier.height(14.dp))
        SmallButton("확인", prominent = true, onClick = close)
    }
}
