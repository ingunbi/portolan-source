package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
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
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

// The party ashore: a sighted village to search (menu 35) or open coast (menu 36), the list of ports to sail
// to (항구이동) and the menu of a fleet in reach (교섭, 전투). The engine does the rules; these only show them.

private fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }

@Composable
private fun Sheet(content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
        Column(Modifier.heightIn(max = maxHeight * 0.9f).widthIn(max = 760.dp).fillMaxWidth(0.9f).clip(RoundedCornerShape(20.dp)).background(NavyLight).padding(22.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp), content = content)
    }
}

@Composable
private fun Count(value: Int, max: Int, unit: String, set: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("$value$unit", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        QtySlider(value.toFloat(), { set(it.toInt().coerceIn(0, max)) }, 0f..maxOf(1, max).toFloat(), Modifier.widthIn(max = 420.dp))
    }
}

/**
 * Ashore. [start] is the engine's first report (kind "village" with the site, or "coast" with the tile and whether
 * the water roll found any); every action reports the sea again through [take].
 */
@Composable
fun ShoreScreen(host: EngineHost, assets: Assets, scope: CoroutineScope, start: JSONObject, take: (JSONObject) -> Unit, close: () -> Unit) {
    val village = start.optString("kind") == "village"
    var last by remember { mutableStateOf(start) }
    var lines by remember { mutableStateOf<List<String>>(emptyList()) }
    var picture by remember { mutableStateOf<String?>(null) }
    var bonus by remember { mutableIntStateOf(0) }
    var mode by remember { mutableIntStateOf(0) }                         // 0 nothing, 1 repair, 2 water
    var water by remember { mutableStateOf(start.optBoolean("hasWater")) }
    var leaving by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var ship by remember { mutableIntStateOf(0) }
    var part by remember { mutableIntStateOf(0) }
    var amount by remember { mutableIntStateOf(0) }
    val ships = last.optJSONObject("fleet")?.optJSONArray("ships").objs()
    val x = start.optInt("x"); val y = start.optInt("y")

    fun go(cmd: String, vararg args: Pair<String, Any?>, then: (JSONObject) -> Unit = {}) {
        if (busy) return
        busy = true
        scope.launch {
            val r = host.call(cmd, *args)
            if (r.has("fleet")) last = r
            take(r)
            r.optJSONArray("lines")?.let { a -> lines = List(a.length()) { a.getString(it) } }
            then(r)
            busy = false
        }
    }

    Box(Modifier.fillMaxSize()) {
        Sheet {
            Text(if (village) "상륙 · 부락" else "상륙", color = Gold, fontSize = 28.sp, fontWeight = FontWeight.Bold)
            Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                picture?.let { p ->
                    val img = assets.image(p)
                    if (img != null) Canvas(Modifier.size(144.dp).clip(RoundedCornerShape(4.dp))) { pixels(img, 0f, 0f, size.width, size.height) }
                }
                for (l in lines) Text(l, color = Color.White, fontSize = 18.sp)
                if (!village && mode == 1 && ships.isNotEmpty()) {
                    val s = ships[ship.coerceIn(0, ships.size - 1)]
                    val total = ships.sumOf { it.optInt("lumber") }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { for ((i, o) in ships.withIndex()) SmallButton(o.optString("name"), prominent = i == ship) { ship = i; amount = 0 } }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { for ((i, n) in listOf("내구", "선회", "추진").withIndex()) SmallButton(n, prominent = i == part) { part = i } }
                    Text("내구 ${s.optInt("hull")}/${s.optInt("maxHull")} · 선회 ${s.optInt("rudder")}/${s.optInt("maxRudder")} · 추진 ${s.optInt("sail")}/${s.optInt("maxSail")} · 자재 ${total}통",
                        color = Color.White.copy(alpha = 0.8f), fontSize = 16.sp)
                    Count(amount, total, "통") { amount = it }
                    SmallButton("수리", enabled = amount > 0 && !busy, prominent = true) { go("coast_repair", "ship" to ship, "part" to part, "lumber" to amount) { amount = 0 } }
                }
                if (!village && mode == 2 && ships.isNotEmpty()) {
                    val s = ships[ship.coerceIn(0, ships.size - 1)]
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { for ((i, o) in ships.withIndex()) SmallButton(o.optString("name"), prominent = i == ship) { ship = i; amount = 0 } }
                    Count(amount, s.optInt("free"), "통") { amount = it }
                    SmallButton("싣기", enabled = amount > 0 && !busy, prominent = true) { go("coast_water", "ship" to ship, "barrels" to amount) { amount = 0 } }
                }
            }
            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (village) {
                    SmallButton("보물탐색", prominent = true, enabled = !busy) {
                        go("land_search", "site" to start.optInt("site"), "bonus" to bonus) { r -> picture = r.optString("picture").ifEmpty { null }; bonus = r.optInt("bonus") }
                    }
                    SmallButton("환대", enabled = !busy) { go("land_host", "bonus" to bonus) { r -> bonus = r.optInt("bonus") } }
                    SmallButton("식량약탈", enabled = !busy) { go("land_plunder") { bonus = 0 } }
                    SmallButton("출항", enabled = !busy, onClick = close)
                } else {
                    SmallButton("출항", prominent = true, enabled = !busy) { leaving = true }
                    SmallButton("응급수리", enabled = !busy) { mode = if (mode == 1) 0 else 1; amount = 0 }
                    SmallButton("탐색", enabled = !busy) {
                        go("coast_search", "x" to x, "y" to y, "water" to water) { r -> water = r.optBoolean("hasWater"); mode = if (water) 2 else 0; amount = 0; picture = null }
                    }
                    SmallButton("대기", enabled = !busy) { go("coast_wait") { close() } }
                }
            }
        }
        if (leaving) Overlay {
            Text(start.optString("leaveAsk"), color = Color.White, fontSize = 20.sp)
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallButton("예", prominent = true) { leaving = false; go("coast_leave") { close() } }
                SmallButton("아니오") { leaving = false }
            }
        }
    }
}

/** 항구이동: the ports known, nearest first; the first mate must know surveying (the engine says why not). */
@Composable
fun PortList(host: EngineHost, scope: CoroutineScope, list: JSONObject, take: (JSONObject) -> Unit, close: () -> Unit) {
    if (!list.optBoolean("can")) {
        Overlay {
            Text("항구이동", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            Text(list.optString("why"), color = Color.White, fontSize = 18.sp)
            Spacer(Modifier.height(16.dp))
            SmallButton("닫기", prominent = true, onClick = close)
        }
        return
    }
    Sheet {
        Text("항구이동", color = Gold, fontSize = 28.sp, fontWeight = FontWeight.Bold)
        if (!list.optBoolean("can")) Text(list.optString("why"), color = Color.White, fontSize = 18.sp)
        Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState())) {
            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (list.optBoolean("can")) for (p in list.optJSONArray("ports").objs())
                    SmallButton(p.optString("name")) { scope.launch { take(host.call("auto_sail", "port" to p.getInt("id"))); close() } }
            }
        }
        SmallButton("닫기", onClick = close)
    }
}

/** A fleet within reach: talk to it (교섭) or attack (전투). */
@Composable
fun FleetMenu(fleet: Fleet, talk: () -> Unit, attack: () -> Unit, close: () -> Unit) {
    Overlay {
        Text(fleet.admiral, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SmallButton("교섭", prominent = true, onClick = talk)
            SmallButton("전투", onClick = attack)
            SmallButton("취소", onClick = close)
        }
    }
}
