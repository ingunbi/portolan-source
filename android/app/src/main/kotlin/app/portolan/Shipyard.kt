package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

private fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }
private fun JSONArray?.ints(): List<Int> = if (this == null) emptyList() else List(length()) { getInt(it) }

/** The shipyard's state as the engine reports it, and the deals made with it. */
class Yard(private val host: EngineHost, private val game: GameState, private val scope: CoroutineScope) {
    var state by mutableStateOf<JSONObject?>(null)
    var note by mutableStateOf("")
    var busy by mutableStateOf(false)

    fun take(j: JSONObject) {
        j.optJSONObject("yard")?.let { state = it }
        note = j.optString("note")
        applyWallet(j.optJSONObject("wallet"), game)
    }

    fun gold(): Int = game.wallet.gold

    fun post(cmd: String, vararg args: Pair<String, Any?>) {
        if (busy) return
        busy = true
        scope.launch { take(host.call(cmd, *args)); busy = false }
    }
}

/** A number with a slider and step buttons. */
@Composable
fun IntPicker(label: String, value: Int, range: IntRange, unit: String, step: Int = 1, modifier: Modifier = Modifier, onChange: (Int) -> Unit) {
    val hi = maxOf(range.first, range.last)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = modifier.fillMaxWidth()) {
        Text(label, color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp, modifier = Modifier.width(56.dp))
        SmallButton("−") { onChange((value - step).coerceIn(range.first, hi)) }
        QtySlider(value.toFloat().coerceIn(range.first.toFloat(), hi.toFloat()), { onChange((Math.round(it / step) * step).coerceIn(range.first, hi)) },
            range.first.toFloat()..maxOf(hi, range.first + 1).toFloat(), Modifier.weight(1f))
        SmallButton("+") { onChange((value + step).coerceIn(range.first, hi)) }
        Text("$value$unit", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(96.dp))
    }
}

@Composable
private fun NameField(value: String, hint: String, onChange: (String) -> Unit) {
    Box(Modifier.width(240.dp).clip(RoundedCornerShape(10.dp)).border(1.dp, Gold.copy(alpha = 0.5f), RoundedCornerShape(10.dp)).padding(12.dp)) {
        if (value.isEmpty()) Text(hint, color = Color.White.copy(alpha = 0.35f), fontSize = 18.sp)
        BasicTextField(value, { onChange(it.take(12)) }, textStyle = TextStyle(color = Color.White, fontSize = 18.sp), cursorBrush = SolidColor(Gold), singleLine = true)
    }
}

@Composable
private fun Row2(selected: Boolean, onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(if (selected) Gold.copy(alpha = 0.18f) else Color.Transparent)
        .clickable(onClick = onClick).padding(horizontal = 10.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, content = content)
}

@Composable
fun ShipyardPanel(yard: Yard, assets: Assets, clerk: Clerk, game: GameState) {
    var tab by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { yard.post("yard_state") }
    val s = yard.state
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for ((i, t) in listOf("중고선 구입", "함선 건조", "개조", "수리 · 매각", "무장", "공업투자").withIndex())
                SmallButton(t, prominent = tab == i) { tab = i; yard.note = "" }
        }
        if (yard.note.isNotEmpty()) Text(yard.note, color = Color(0xFFFFE066), fontSize = 18.sp)
        if (s == null) Text("조선소 장부를 펴는 중…", color = Color.White, fontSize = 18.sp)
        else Column(Modifier.verticalScroll(rememberScrollState())) {
            when (tab) {
                0 -> UsedShips(yard, s, assets)
                1 -> BuildShips(yard, s, assets)
                2 -> Refit(yard, s)
                3 -> FleetRepair(yard, s)
                4 -> Cannons(yard, s)
                else -> InvestBox(clerk)
            }
        }
    }
}

@Composable
private fun ShipSpecs(k: JSONObject, assets: Assets) {
    val img = assets.image("sprites/ships/class_%02d.png".format(k.getInt("class")))
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
        if (img != null) Canvas(Modifier.size(128.dp, 96.dp).clip(RoundedCornerShape(6.dp))) { pixels(img, 0f, 0f, size.width, size.height) }
        Text(k.optString("desc"), color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp, modifier = Modifier.widthIn(max = 520.dp))
    }
}

@Composable
private fun UsedShips(yard: Yard, s: JSONObject, assets: Assets) {
    val stock = s.optJSONArray("stock").objs()
    val ships = s.optJSONArray("ships").objs()
    var pick by remember { mutableIntStateOf(0) }
    var offer by remember { mutableIntStateOf(0) }
    var trade by remember { mutableIntStateOf(0) }
    var name by remember { mutableStateOf("") }
    val sel = stock.getOrNull(pick)
    LaunchedEffect(pick, stock.size) { sel?.let { offer = (it.getInt("floor") + 9) / 10 * 10; name = "" } }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (stock.isEmpty()) Text(s.optString("noStock"), color = Color.White.copy(alpha = 0.6f), fontSize = 18.sp)
        for ((k, c) in stock.withIndex()) Row2(k == pick, { pick = k }) {
            Text(c.getString("name"), color = Color.White, fontSize = 18.sp, fontWeight = if (k == pick) FontWeight.Bold else FontWeight.Normal, modifier = Modifier.width(150.dp))
            Text("선원 ${c.getInt("crew")} · 대포 ${c.getInt("guns")} · 적재 ${c.getInt("cargo")} · 내구 ${c.getInt("hull")}", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text("${c.getInt("price")}닢", color = Gold, fontSize = 18.sp)
        }
        if (sel != null) {
            ShipSpecs(sel, assets)
            val needsTrade = s.optBoolean("needsTrade")
            val credit = if (needsTrade) ships.getOrNull(trade)?.getInt("value")?.div(2) ?: 0 else 0
            val most = minOf(sel.getInt("price"), (yard.gold() + credit))
            if (needsTrade) {
                Text(s.optString("tradeMessage"), color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("내줄 배", color = Color.White, fontSize = 16.sp)
                    for ((i, sh) in ships.withIndex()) SmallButton("${sh.getString("name")} (+${sh.getInt("value") / 2}닢)", prominent = trade == i) { trade = i }
                }
            }
            IntPicker("제시액", minOf(offer, most), 0..most, "닢", 10) { offer = it }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                NameField(name, "배 이름") { name = it }
                SmallButton("구입", enabled = most > 0 && !s.optBoolean("banned") && !yard.busy, prominent = true) {
                    yard.post("yard_buy", "slot" to sel.getInt("slot"), "offer" to minOf(offer, most), "tradeIn" to (if (needsTrade) trade else -1), "name" to name)
                }
            }
        }
    }
}

@Composable
private fun BuildShips(yard: Yard, s: JSONObject, assets: Assets) {
    val list = s.optJSONArray("buildable").objs()
    val order = s.optJSONObject("order")
    var cls by remember { mutableIntStateOf(0) }
    var mat by remember { mutableIntStateOf(0) }
    var crew by remember { mutableIntStateOf(0) }
    var guns by remember { mutableIntStateOf(0) }
    var offer by remember { mutableIntStateOf(0) }
    var name by remember { mutableStateOf("") }
    val c = list.getOrNull(cls)
    val mats = c?.optJSONArray("materials").objs()
    val m = mats.getOrNull(mat)
    LaunchedEffect(cls, list.size) { c?.let { crew = it.getInt("crew"); guns = it.getInt("guns"); mat = minOf(2, mats.size - 1).coerceAtLeast(0); name = "" } }
    LaunchedEffect(mat, cls, list.size) { m?.let { offer = (it.getInt("floor") + 9) / 10 * 10 } }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (order != null) {
            Text("${order.getString("name")} · ${order.getString("class")} · ${order.getString("material")}", color = Gold, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Text("선원 ${order.getInt("crew")} · 대포 ${order.getInt("guns")} · 적재 ${order.getInt("cargo")} · 내구 ${order.getInt("hull")}", color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp)
            if (order.getInt("daysLeft") > 0) Text(order.getString("waiting"), color = Color.White, fontSize = 18.sp)
            else { Text(order.getString("ready"), color = Color.White, fontSize = 18.sp); SmallButton("인수", prominent = true) { yard.post("yard_delivery") } }
        } else if (list.isEmpty()) {
            Text(s.optString("noBuild"), color = Color.White.copy(alpha = 0.6f), fontSize = 18.sp)
        } else {
            Text(s.optString("buildAsk"), color = Color.White, fontSize = 16.sp)
            for ((k, b) in list.withIndex()) Row2(k == cls, { cls = k }) {
                Text(b.getString("name"), color = Color.White, fontSize = 18.sp, fontWeight = if (k == cls) FontWeight.Bold else FontWeight.Normal, modifier = Modifier.weight(1f))
                Text("${b.getInt("days")}일", color = Color.White.copy(alpha = 0.6f), fontSize = 16.sp)
            }
            if (c != null && m != null) {
                ShipSpecs(c, assets)
                Text(s.optString("materialAsk"), color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for ((k, mm) in mats.withIndex()) SmallButton("${mm.getString("name")} · 내구 ${mm.getInt("hull")}", prominent = mat == k) { mat = k }
                }
                val cap = c.getInt("capacity")
                IntPicker("선원", crew, c.getInt("minCrew")..maxOf(c.getInt("minCrew") + 1, c.getInt("maxCrew")), "명") { crew = minOf(it, cap - guns) }
                IntPicker("대포", guns, 0..maxOf(1, c.getInt("maxGuns")), "문") { guns = minOf(it, cap - crew) }
                val price = m.getInt("price")
                val most = minOf(price, yard.gold())
                Text("적재 ${cap - crew - guns} · 금화 ${price}닢 · ${c.getInt("days")}일", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                IntPicker("제시액", minOf(offer, most), 0..most, "닢", 10) { offer = it }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    NameField(name, "배 이름") { name = it }
                    SmallButton("주문", enabled = most > 0 && !s.optBoolean("banned") && !yard.busy, prominent = true) {
                        yard.post("yard_order", "class" to c.getInt("class"), "material" to m.getInt("k"), "crew" to crew, "guns" to guns, "offer" to minOf(offer, most), "name" to name)
                    }
                }
            }
        }
    }
}

@Composable
private fun ShipChips(ships: List<JSONObject>, sel: Int, onPick: (Int) -> Unit) {
    if (ships.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((i, sh) in ships.withIndex()) SmallButton(sh.getString("name"), prominent = sel == i) { onPick(i) }
    }
}

@Composable
private fun Refit(yard: Yard, s: JSONObject) {
    val ships = s.optJSONArray("ships").objs()
    var ship by remember { mutableIntStateOf(0) }
    var crew by remember { mutableIntStateOf(0) }
    var guns by remember { mutableIntStateOf(0) }
    var name by remember { mutableStateOf("") }
    val sh = ships.getOrNull(ship) ?: return
    val lim = sh.getJSONObject("limits")
    LaunchedEffect(ship, ships.size) { crew = sh.getInt("crewCap"); guns = sh.getInt("gunCap") }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ShipChips(ships, ship) { ship = it }
        Text("선수상 · 지금 ${figureName(sh.getInt("figurehead"))}", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        s.optString("figureheadRare").takeIf { it.isNotEmpty() }?.let { Text(it, color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp) }
        for (f in s.optJSONArray("figureheads").objs()) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(f.getString("name"), color = Color.White, fontSize = 16.sp, modifier = Modifier.width(120.dp))
            SmallButton("금화 ${f.getInt("price")}닢", enabled = sh.getInt("figurehead") != f.getInt("k") && yard.gold() >= f.getInt("price") && !yard.busy) {
                yard.post("yard_figurehead", "k" to f.getInt("k"), "ship" to ship)
            }
        }
        Text("적재비율 변경", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        val cap = lim.getInt("capacity")
        IntPicker("선원", crew, lim.getInt("minCrew")..maxOf(lim.getInt("minCrew") + 1, lim.getInt("maxCrew")), "명") { crew = minOf(it, cap - guns) }
        IntPicker("대포", guns, 0..maxOf(1, lim.getInt("maxGuns")), "문") { guns = minOf(it, cap - crew) }
        Text("적재 ${cap - crew - guns} (지금 ${sh.getInt("cargoLoad")} 싣는 중)", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
        SmallButton("변경 · 금화 ${sh.getInt("refit")}닢", enabled = !yard.busy) { yard.post("yard_refit", "ship" to ship, "crew" to crew, "guns" to guns) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            NameField(name, "새 이름") { name = it }
            SmallButton("이름 변경", enabled = name.isNotBlank() && !yard.busy) { yard.post("yard_rename", "ship" to ship, "name" to name); name = "" }
        }
    }
}

private val FIGURES = listOf("없음", "바다표범", "제독", "유니콘", "사자", "독수리", "위인", "포세이돈", "용", "천사", "여신")
private fun figureName(k: Int) = FIGURES.getOrElse(k) { "없음" }

@Composable
private fun FleetRepair(yard: Yard, s: JSONObject) {
    val ships = s.optJSONArray("ships").objs()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (sh in ships) Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Navy.copy(alpha = 0.6f)).padding(14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.weight(1f)) {
                Text(sh.getString("name"), color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Text("${sh.getString("className")} · ${sh.getString("material")}", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
            }
            Text("내구 ${sh.getInt("hull")}/${sh.getInt("maxHull")} · 선회 ${sh.getInt("rudder")} · 추진 ${sh.getInt("sail")}", color = Color.White.copy(alpha = 0.75f), fontSize = 16.sp)
            val cost = sh.getInt("repair")
            SmallButton(if (cost == 0) "수리 불필요" else "수리 · ${cost}닢", enabled = cost > 0 && !yard.busy) { yard.post("yard_repair", "ship" to sh.getInt("index")) }
            SmallButton("매각 · ${sh.getInt("value") / 2}닢", enabled = ships.size > 1 && sh.getInt("index") != 0 && !yard.busy) { yard.post("yard_sell", "ship" to sh.getInt("index")) }
        }
    }
}

@Composable
private fun Cannons(yard: Yard, s: JSONObject) {
    val ships = s.optJSONArray("ships").objs()
    val types = s.optJSONArray("cannons").objs()
    var ship by remember { mutableIntStateOf(0) }
    var t by remember { mutableIntStateOf(0) }
    var count by remember { mutableIntStateOf(0) }
    val sh = ships.getOrNull(ship) ?: return
    val ty = types.getOrNull(t) ?: return
    val price = ty.getInt("price")
    val most = minOf(sh.optJSONArray("cannonMax").ints().getOrElse(t) { 0 }, yard.gold() / maxOf(price, 1))
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ShipChips(ships, ship) { ship = it; count = 0 }
        Text("지금 ${if (sh.getInt("gunType") == 0) "없음" else types.firstOrNull { it.getInt("type") == sh.getInt("gunType") }?.getString("name") ?: "대포"} ${sh.getInt("guns")}/${sh.getInt("gunCap")}문",
            color = Color.White.copy(alpha = 0.75f), fontSize = 16.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for ((i, c) in types.withIndex()) SmallButton("${c.getString("name")} ${c.getInt("price")}닢", prominent = t == i) { t = i; count = 0 }
        }
        IntPicker("수량", minOf(count, most), 0..most, "문") { count = it }
        SmallButton("장착 · 금화 ${minOf(count, most) * price}닢", enabled = minOf(count, most) > 0 && !yard.busy, prominent = true) {
            yard.post("yard_cannons", "type" to ty.getInt("type"), "count" to minOf(count, most), "ship" to ship); count = 0
        }
    }
}
