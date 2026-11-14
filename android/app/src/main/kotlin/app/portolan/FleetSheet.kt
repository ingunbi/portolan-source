package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject

private fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }
private fun JSONArray?.ints(): List<Int> = if (this == null) emptyList() else List(length()) { getInt(it) }

private val infoTabs = listOf("자함대정보", "함선정보", "인물정보", "주인공정보", "적하정보", "적하일람", "발견물정보", "항해도", "항해일지", "항구지도")
private val commandTabs = listOf("선장변경", "승무원편성", "승무원비율", "함선처분", "적하편성", "대열변경", "급여설정", "아이템", "감시")

@Composable
private fun SheetCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp), content = content)
}

@Composable
private fun Line(text: String, size: Int = 16, color: Color = Color.White, weight: FontWeight = FontWeight.Normal) =
    Text(text, color = color, fontSize = size.sp, fontWeight = weight)

@Composable
private fun Bar(label: String, value: Int, max: Int) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(label, color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp, modifier = Modifier.width(96.dp))
        Text("$value/$max", color = Color.White, fontSize = 14.sp, modifier = Modifier.width(92.dp))
        Box(Modifier.weight(1f).height(8.dp).clip(RoundedCornerShape(4.dp)).background(Color.White.copy(alpha = 0.12f))) {
            Box(Modifier.fillMaxWidth((value.toFloat() / maxOf(1, max)).coerceIn(0f, 1f)).fillMaxHeight().background(Gold))
        }
    }
}

/**
 * The fleet's commands (편성·지휘) and information screens (정보), as the engine reports them.
 * [atSea] opens the sighting list (감시) as well.
 */
@Composable
fun FleetSheet(host: EngineHost, game: GameState, assets: Assets, scope: CoroutineScope, atSea: Boolean, close: () -> Unit) {
    val st = remember { EngineState(host, game, scope, "fleet") }
    var tab by remember { mutableIntStateOf(0) }
    var leaving by remember { mutableStateOf(false) }
    var scuttle by remember { mutableStateOf<JSONObject?>(null) }
    var zoom by remember { mutableStateOf<JSONObject?>(null) }
    var info by remember { mutableStateOf<JSONObject?>(null) }
    LaunchedEffect(Unit) { st.post("fleet_open") }
    LaunchedEffect(tab) {
        // The sheet's opening request may still be running; a request made meanwhile is dropped, so wait for it.
        snapshotFlow { st.busy }.first { !it }
        if (tab < infoTabs.size) st.post("info_state") else st.post("fleet_state")
    }
    val f = st.state
    // The information figures stay while a later reply (an advice, a zoom) carries none of its own.
    LaunchedEffect(st.last) { st.last?.optJSONObject("info")?.let { info = it } }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.7f)).clickable(enabled = false) {}) {
        Column(Modifier.align(Alignment.Center).fillMaxHeight(0.94f).fillMaxWidth(0.92f).clip(RoundedCornerShape(20.dp)).background(NavyLight).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("함대", color = Gold, fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Text("금화 ${game.wallet.gold}", color = Gold, fontSize = 18.sp, modifier = Modifier.padding(end = 16.dp))
                GoldButton("닫기") { if ((f?.optInt("pool") ?: 0) > 0) leaving = true else st.post("fleet_close") { close() } }
            }
            // The information screens on one line, the commands on the next.
            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                for ((i, t) in infoTabs.withIndex()) if (t != "항구지도" || !atSea) SmallButton(t, prominent = tab == i) { tab = i }
            }
            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                for ((i, t) in commandTabs.withIndex()) if (t != "감시" || atSea) SmallButton(t, prominent = tab == infoTabs.size + i) { tab = infoTabs.size + i }
            }
            if (st.note.isNotEmpty()) Text(st.note, color = Color(0xFFFFE066), fontSize = 16.sp)
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (f == null) Text("장부를 펴는 중…", color = Color.White, fontSize = 18.sp)
                else when (tab) {
                    0 -> FleetInfo(f, info, assets)
                    1 -> ShipInfo(f, assets)
                    2 -> PersonInfo(info, assets)
                    3 -> HeroInfo(info)
                    4 -> CargoInfo(info)
                    5 -> CargoListInfo(info, st)
                    6 -> DiscoveryInfo(info, assets)
                    7 -> ChartInfo(info, assets) { col, row -> st.post("info_chart", "col" to col, "row" to row) { j -> j.optJSONObject("zoom")?.let { zoom = it } } }
                    8 -> LogbookInfo(info)
                    9 -> PortMapInfo(info, assets)
                    else -> when (tab - infoTabs.size) {
                        0 -> Captains(st, f)
                        1 -> CrewMove(st, f)
                        2 -> Shares(st, f)
                        3 -> Scuttle(f) { scuttle = it }
                        4 -> CargoMove(st, f)
                        5 -> Formation(st, f)
                        6 -> Pay(st, f)
                        7 -> Items(st, f) { zoom = it }
                        8 -> Sight(st, f)
                        else -> {}
                    }
                }
            }
        }
        zoom?.let { z ->
            Overlay {
                ZoomView(z)
                Spacer(Modifier.height(14.dp))
                SmallButton("돌아가기", prominent = true) { zoom = null }
            }
        }
        if (leaving) Overlay {
            Text(f?.optString("leaveText").orEmpty(), color = Color.White, fontSize = 20.sp)
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallButton("예", prominent = true) { leaving = false; st.post("fleet_close") { close() } }
                SmallButton("아니오") { leaving = false }
            }
        }
        scuttle?.let { s ->
            Overlay {
                Text(s.optString("scuttleAsk"), color = Color.White, fontSize = 20.sp)
                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    SmallButton("예", prominent = true) { scuttle = null; st.post("fleet_scuttle", "ship" to s.getInt("index")) }
                    SmallButton("아니오") { scuttle = null }
                }
            }
        }
    }
}

// ---- information ------------------------------------------------------------------------------------

@Composable
private fun FleetInfo(f: JSONObject, info: JSONObject?, assets: Assets) {
    val ships = f.optJSONArray("ships").objs()
    val hero = info?.optJSONArray("people").objs().firstOrNull()
    if (hero != null) Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Face(assets, hero.optInt("face"), hero.optInt("nation"), 80)
        Column {
            Line("${info?.optString("family").orEmpty()}제독", 22, weight = FontWeight.Bold)
            Line("항해 레벨 ${hero.optInt("navLevel")}   전투 레벨 ${hero.optInt("battleLevel")}")
        }
    }
    if (ships.isEmpty()) { Line(info?.optString("empty").orEmpty()); return }
    for (s in ships) Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
        val pic = assets.image("sprites/ships/class_%02d.png".format(s.optInt("class")))
        Canvas(Modifier.size(96.dp, 72.dp).clip(RoundedCornerShape(4.dp))) { if (pic != null) pixels(pic, 0f, 0f, size.width, size.height) }
        Column {
            Line(s.optString("name") + "호", 18, weight = FontWeight.SemiBold)
            Line("${s.optString("className")} · 내구 ${s.optInt("hull")} · 선원 ${s.optInt("crew")} · 대포 ${s.optInt("guns")}", 14, Color.White.copy(alpha = 0.7f))
        }
    }
    val sum = f.optJSONObject("summary") ?: return
    SheetCard(Modifier.fillMaxWidth()) {
        Line("함대선회력 ${sum.optInt("rudder")}   선원 총수 ${sum.optInt("crew")}명")
        Line("함대추진력 ${sum.optInt("sail")}   총포문수 ${sum.optInt("guns")}")
        Line("함대내구력 ${sum.optInt("hull")}   전투력 ${sum.optInt("power")}")
    }
}

@Composable
private fun Face(assets: Assets, face: Int, nation: Int, height: Int) {
    val img = assets.portrait(face, nation)
    Canvas(Modifier.size((height * 0.8f).dp, height.dp).clip(RoundedCornerShape(6.dp)).background(Color.Black.copy(alpha = 0.3f))) {
        if (img != null) pixels(img, 0f, 0f, size.width, size.height)
    }
}

@Composable
private fun ShipInfo(f: JSONObject, assets: Assets) {
    val ships = f.optJSONArray("ships").objs()
    if (ships.isEmpty()) { Line(f.optString("noShips")); return }
    var pick by remember { mutableIntStateOf(0) }
    val s = ships[pick.coerceIn(0, ships.size - 1)]
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { for ((i, x) in ships.withIndex()) SmallButton(x.optString("name"), prominent = i == pick) { pick = i } }
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        val pic = assets.image("sprites/ships/class_%02d.png".format(s.optInt("class")))
        Canvas(Modifier.size(192.dp, 144.dp).clip(RoundedCornerShape(4.dp))) { if (pic != null) pixels(pic, 0f, 0f, size.width, size.height) }
        if (s.optInt("figurehead") > 0) {
            val fh = assets.image("sprites/figureheads/figurehead_%02d.png".format(s.optInt("figurehead")))
            Canvas(Modifier.size(72.dp).clip(RoundedCornerShape(4.dp))) { if (fh != null) pixels(fh, 0f, 0f, size.width, size.height) }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Line("물 ${s.optInt("water")} · 식량 ${s.optInt("food")} · 자재 ${s.optInt("lumber")} · 탄약 ${s.optInt("shot")}", 15)
            Line("${s.optString("className")}급", 14, Color.White.copy(alpha = 0.7f))
            Line(s.optString("name") + "호", 20, weight = FontWeight.Bold)
            Line("선장  ${s.optString("captain")}")
            Line("무장  ${s.optString("gunName")}" + if (s.optInt("gunType") == 0) "" else "  ${s.optInt("guns")}/${s.optInt("gunCap")}")
            Line("운항 ${s.optInt("sailors")}명 · 파수 ${s.optInt("watch")}명 · 갑판 ${s.optInt("deck")}명", 15)
            Line("운항요원 ${s.optInt("minCrew")}명 · 속도 ${s.optInt("knots")}KT", 15)
            val load = s.optInt("loadPercent")
            Line("적재율 ${load}%", 15, if (load > 79) Color(0xFFFF6B6B) else if (load > 30) Color(0xFFFFE066) else Color.White)
        }
    }
    SheetCard(Modifier.fillMaxWidth()) {
        Bar("내구", s.optInt("hull"), s.optInt("maxHull"))
        Bar("선회", s.optInt("rudder"), s.optInt("maxRudder"))
        Bar("추진", s.optInt("sail"), s.optInt("maxSail"))
        Bar("선원", s.optInt("crew"), s.optInt("crewCap"))
        Bar("사기", s.optInt("morale"), 100)
        Bar("적재", s.optInt("cargoLoad"), s.optInt("cargoCap"))
        Bar("하중", s.optInt("load"), s.optInt("capacity"))
    }
}

@Composable
private fun PersonInfo(info: JSONObject?, assets: Assets) {
    val people = info?.optJSONArray("people").objs()
    if (people.isEmpty()) return
    var pick by remember { mutableIntStateOf(0) }
    val p = people[pick.coerceIn(0, people.size - 1)]
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { for ((i, x) in people.withIndex()) SmallButton(x.optString("name"), prominent = i == pick) { pick = i } }
    Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Face(assets, p.optInt("face"), p.optInt("nation"), 100)
            if (p.optString("ship").isNotEmpty()) Line(p.optString("ship") + "호", 15)
            Line(p.optString("role"), 15, Gold)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Line(p.optString("name"), 22, weight = FontWeight.Bold)
            Line("연령 ${p.optInt("age")}세", 15)
            val stats = p.optJSONArray("stats").ints()
            val names = p.optJSONArray("statNames")
            for (i in stats.indices) Bar(names?.optString(i).orEmpty(), stats[i], 100)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Line(if (p.optInt("k") < 0) "작위 ${p.optString("title")}" else "급료 금화 ${p.optInt("salary")}닢 · 충성 ${p.optInt("loyalty")}", 15)
            Line("항해 레벨 ${p.optInt("navLevel")}   경험 ${p.optInt("navExp")}", 15)
            Line("전투 레벨 ${p.optInt("battleLevel")}   경험 ${p.optInt("battleExp")}", 15)
            Line("국적 ${p.optString("nationName")}", 15)
            Line("기능", 15, Color.White.copy(alpha = 0.7f))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for (s in p.optJSONArray("skills").objs()) Line(s.optString("name"), 15, if (s.optBoolean("has")) Color(0xFFFFE066) else Color.Gray)
            }
        }
    }
}

@Composable
private fun HeroInfo(info: JSONObject?) {
    val h = info?.optJSONObject("hero") ?: return
    Row(horizontalArrangement = Arrangement.spacedBy(40.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Line("소지금", 19, Gold, FontWeight.Bold)
            Line("금화: ${h.optInt("gold")}")
            Line("금괴: ${h.optInt("bars")}")
            Spacer(Modifier.height(8.dp))
            Line("명성", 19, Gold, FontWeight.Bold)
            for (x in h.optJSONArray("fame").objs()) Line("${x.optString("name")}: ${x.optInt("value")}")
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Line("공헌도", 19, Gold, FontWeight.Bold)
            for (x in h.optJSONArray("standing").objs()) Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(x.optString("nation"), color = Color.White, fontSize = 16.sp, modifier = Modifier.width(100.dp))
                Text("${x.optInt("value")}", color = if (x.optBoolean("against")) Color(0xFFFF6B6B) else Color.White, fontSize = 16.sp)
            }
        }
    }
}

@Composable
private fun CargoInfo(info: JSONObject?) {
    val c = info?.optJSONArray("cargo").objs()
    if (c.isEmpty()) { Line("싣고 있는 교역품이 없습니다."); return }
    SheetCard(Modifier.fillMaxWidth()) { for (x in c) Row { Text(x.optString("name"), color = Color.White, fontSize = 16.sp, modifier = Modifier.width(160.dp)); Text("${x.optInt("amount")}", color = Gold, fontSize = 16.sp) } }
}

// ---- commands ---------------------------------------------------------------------------------------

@Composable
private fun Captains(st: EngineState, f: JSONObject) {
    val people = f.optJSONArray("people").objs()
    for (s in f.optJSONArray("ships").objs()) SheetCard(Modifier.fillMaxWidth()) {
        Line(s.optString("name") + "호" + if (s.optBoolean("flagship")) "  기함" else "", 18, weight = FontWeight.SemiBold)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (p in people) SmallButton(p.optString("name"), prominent = p.optString("name") == s.optString("captain"), enabled = !st.busy) {
                st.post("fleet_captain", "ship" to s.getInt("index"), "person" to p.getInt("person"))
            }
        }
    }
}

@Composable
private fun CrewMove(st: EngineState, f: JSONObject) {
    Line("남은 승무원 ${f.optInt("pool")}명", 19, Gold, FontWeight.Bold)
    for (s in f.optJSONArray("ships").objs()) SheetCard(Modifier.fillMaxWidth()) {
        val i = s.getInt("index"); val crew = s.getInt("crew"); val pool = f.optInt("pool")
        Line("${s.optString("name")}호   $crew / ${s.optInt("crewCap")}명   사기 ${s.optInt("morale")}", 17)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (d in listOf(-10, -1, 1, 10)) SmallButton(if (d > 0) "+$d" else "$d", enabled = !st.busy) { st.post("fleet_crew", "ship" to i, "crew" to crew + d) }
            SmallButton("전원", enabled = !st.busy) { st.post("fleet_crew", "ship" to i, "crew" to minOf(s.getInt("crewCap"), crew + pool)) }
            SmallButton("0", enabled = !st.busy) { st.post("fleet_crew", "ship" to i, "crew" to 0) }
        }
    }
}

@Composable
private fun Shares(st: EngineState, f: JSONObject) {
    for (s in f.optJSONArray("ships").objs()) SheetCard(Modifier.fillMaxWidth()) {
        Line("${s.optString("name")}호 · ${s.optInt("crew")}명", 17, weight = FontWeight.SemiBold)
        val heads = listOf(s.optInt("sailors"), s.optInt("watch"), s.optInt("deck"))
        val shares = listOf(s.optInt("sailorShare"), s.optInt("watchShare"), s.optInt("deckShare"))
        for (r in 0 until 3) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(listOf("운항", "파수", "갑판")[r], color = Color.White, fontSize = 16.sp, modifier = Modifier.width(48.dp))
            SmallButton("−", enabled = !st.busy) { st.post("fleet_share", "ship" to s.getInt("index"), "row" to r, "up" to false) }
            Box(Modifier.width(220.dp).height(8.dp).clip(RoundedCornerShape(4.dp)).background(Color.White.copy(alpha = 0.12f))) {
                Box(Modifier.fillMaxWidth(shares[r] / 100f).fillMaxHeight().background(Gold))
            }
            SmallButton("+", enabled = !st.busy) { st.post("fleet_share", "ship" to s.getInt("index"), "row" to r, "up" to true) }
            Text("${heads[r]}명 : ${shares[r]}%", color = Color.White, fontSize = 16.sp)
        }
    }
    Text("운항은 속도, 파수는 시야, 갑판은 전투 인원이 됩니다.", color = Color.White.copy(alpha = 0.55f), fontSize = 14.sp)
}

@Composable
private fun Scuttle(f: JSONObject, ask: (JSONObject) -> Unit) {
    val ships = f.optJSONArray("ships").objs()
    if (ships.size < 2) Line(f.optString("noShips"))
    for (s in ships) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(s.optString("name") + "호", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(160.dp))
        Text("선원 ${s.optInt("crew")}명 · 적재 ${s.optInt("cargoLoad")}통", color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp, modifier = Modifier.weight(1f))
        SmallButton("처분", enabled = ships.size > 1 && !s.optBoolean("flagship")) { ask(s) }
    }
}

@Composable
private fun CargoMove(st: EngineState, f: JSONObject) {
    val ships = f.optJSONArray("ships").objs()
    if (ships.isEmpty()) { Line(f.optString("noShips")); return }
    var from by remember { mutableIntStateOf(0) }
    var to by remember { mutableIntStateOf(if (ships.size > 1) 1 else 0) }
    var kind by remember { mutableIntStateOf(0) }
    var count by remember { mutableIntStateOf(0) }
    for (s in ships) SheetCard(Modifier.fillMaxWidth()) {
        Line("${s.optString("name")}호   적재 여유 ${s.optInt("free")}통", 17, weight = FontWeight.SemiBold)
        Line("물 ${s.optInt("water")} · 식량 ${s.optInt("food")} · 자재 ${s.optInt("lumber")} · 탄약 ${s.optInt("shot")}", 14)
        val holds = s.optJSONArray("holds").objs()
        if (holds.isNotEmpty()) Line(holds.joinToString(" · ") { "${it.optString("name")} ${it.optInt("amount")}" }, 14, Color.White.copy(alpha = 0.7f))
    }
    val src = ships.getOrNull(from.coerceIn(0, ships.size - 1)) ?: return
    val kinds = listOf("물" to 0, "식량" to 1, "자재" to 2, "탄약" to 3) + src.optJSONArray("holds").objs().map { it.optString("name") to 4 + it.optInt("good") }
    val k = kinds.getOrElse(kind) { kinds[0] }
    val have = when (k.second) { 0 -> src.optInt("water"); 1 -> src.optInt("food"); 2 -> src.optInt("lumber"); 3 -> src.optInt("shot")
        else -> src.optJSONArray("holds").objs().firstOrNull { 4 + it.optInt("good") == k.second }?.optInt("amount") ?: 0 }
    val room = if (to < ships.size && to != from) ships[to].optInt("free") else have
    val most = minOf(have, room)
    Line("보낼 배", 14, Color.White.copy(alpha = 0.7f))
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((i, s) in ships.withIndex()) SmallButton(s.optString("name"), prominent = i == from) { from = i; kind = 0; count = 0 }
    }
    Line("적하", 14, Color.White.copy(alpha = 0.7f))
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((i, x) in kinds.withIndex()) SmallButton(x.first, prominent = i == kind) { kind = i; count = 0 }
    }
    Line("받을 배", 14, Color.White.copy(alpha = 0.7f))
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((i, s) in ships.withIndex()) SmallButton(s.optString("name"), prominent = i == to) { to = i; count = 0 }
        SmallButton("버린다", prominent = to >= ships.size) { to = ships.size; count = 0 }
    }
    val n = count.coerceIn(0, most)
    IntPicker("수량", n, 0..maxOf(0, most), "통") { count = it }
    SmallButton(if (to >= ships.size) "버리기" else "옮기기", prominent = true, enabled = n > 0 && from != to && !st.busy) {
        st.post("fleet_cargo", "from" to from, "to" to to, "kind" to k.second, "amount" to n); count = 0
    }
}

@Composable
private fun Formation(st: EngineState, f: JSONObject) {
    val ships = f.optJSONArray("ships").objs()
    if (ships.size < 2) Line(f.optString("noShips"))
    for ((i, s) in ships.withIndex()) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("${i + 1}번", color = Color.White, fontSize = 16.sp, modifier = Modifier.width(44.dp))
        Text(s.optString("name") + "호", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(160.dp))
        Text(s.optString("captain"), color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp, modifier = Modifier.width(140.dp))
        if (i > 0) {
            fun move(d: Int) {
                val order = (1 until ships.size).toMutableList()
                val t = order[i - 1]; order[i - 1] = order[i - 1 + d]; order[i - 1 + d] = t
                st.post("fleet_order", "order" to order)
            }
            SmallButton("↑", enabled = i > 1 && !st.busy) { move(-1) }
            SmallButton("↓", enabled = i < ships.size - 1 && !st.busy) { move(1) }
        }
    }
}

@Composable
private fun Pay(st: EngineState, f: JSONObject) {
    val officers = f.optJSONArray("officers").objs()
    if (officers.isEmpty()) Line("동료가 없습니다.")
    val pay = remember { mutableStateMapOf<Int, Int>() }
    for (o in officers) {
        val k = o.getInt("k"); val salary = o.getInt("salary")
        val p = (pay[k] ?: salary).coerceIn(minOf(salary, 2000), 2000)
        SheetCard(Modifier.fillMaxWidth()) {
            Line("${o.optString("name")}   충성 ${o.optInt("loyalty")}   월급 ${salary}닢", 17, weight = FontWeight.SemiBold)
            IntPicker("월급", p, minOf(salary, 2000)..2000, "닢", step = 10) { pay[k] = it }
            SmallButton("설정", enabled = !st.busy) { st.post("fleet_pay", "officer" to k, "to" to p); pay.remove(k) }
        }
    }
}

@Composable
private fun Items(st: EngineState, f: JSONObject, onMap: (JSONObject) -> Unit) {
    val items = f.optJSONArray("items").objs()
    if (items.isEmpty()) Line("아이템이 없습니다.")
    var shown by remember { mutableIntStateOf(-1) }
    for (it in items) SheetCard(Modifier.fillMaxWidth()) {
        val id = it.getInt("id")
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(it.optString("name"), color = if (shown == id) Gold else Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f).clickable { shown = if (shown == id) -1 else id })
            if (it.optBoolean("equipped")) Text("장비중", color = Color(0xFFFFE066), fontSize = 14.sp)
            if (it.optInt("slot") >= 0) SmallButton(if (it.optBoolean("equipped")) "해제" else "장비", enabled = !st.busy) { st.post("fleet_equip", "id" to id) }
            SmallButton("사용", enabled = !st.busy) { st.post("fleet_use", "id" to id) { j -> j.optJSONObject("zoom")?.let(onMap) } }
        }
        if (shown == id && it.optString("text").isNotEmpty()) Text(it.optString("text"), color = Color.White.copy(alpha = 0.75f), fontSize = 14.sp)
    }
}

@Composable
private fun Sight(st: EngineState, f: JSONObject) {
    val sight = f.optJSONArray("sight").objs()
    if (sight.isEmpty()) Line(f.optString("noSight"))
    for (s in sight) SmallButton(s.optString("name"), enabled = !st.busy) { st.post("fleet_inspect", "fleet" to s.getInt("id")) }
}
