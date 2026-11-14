package app.portolan

import androidx.compose.foundation.background
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
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

private fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }

/** A building's state as the engine reports it under one key, and the deals made with it. */
class EngineState(private val host: EngineHost, private val game: GameState, private val scope: CoroutineScope, private val key: String) {
    var state by mutableStateOf<JSONObject?>(null)
    var note by mutableStateOf("")
    var last by mutableStateOf<JSONObject?>(null)
    var busy by mutableStateOf(false)

    fun post(cmd: String, vararg args: Pair<String, Any?>, then: (JSONObject) -> Unit = {}) {
        if (busy) return
        busy = true
        scope.launch {
            val j = host.call(cmd, *args)
            j.optJSONObject(key)?.let { state = it }
            note = j.optString("note")
            last = j
            applyWallet(j.optJSONObject("wallet"), game)
            then(j)
            busy = false
        }
    }
}

/** The harbour office: departure, supplies, the dock of a capital and the naming of a supply port. */
@Composable
fun HarborPanel(st: EngineState, clerk: Clerk, game: GameState, setSail: () -> Unit) {
    LaunchedEffect(Unit) { st.post("harbor_state") }
    val s = st.state ?: run { Text("항구 사무소 장부를 펴는 중…", color = Color.White, fontSize = 18.sp); return }
    var tab by remember { mutableIntStateOf(0) }
    var confirm by remember { mutableStateOf<String?>(null) }
    var storeAsk by remember { mutableStateOf<Pair<String, Int>?>(null) }
    var name by remember { mutableStateOf("") }
    val dock = s.optJSONObject("dock")
    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SmallButton("출항", prominent = true, enabled = !st.busy && clerk.ask == null) {
                st.post("harbor_depart") { j -> if (j.optBoolean("canDepart")) confirm = j.optString("note") }
            }
            SmallButton("보급", prominent = tab == 0) { tab = 0 }
            if (dock != null) SmallButton("도크", prominent = tab == 1) { tab = 1 }
            if (s.optBoolean("supplyPort")) SmallButton("명명", prominent = tab == 2) { tab = 2 }
            Spacer(Modifier.weight(1f))
            Text("운항 ${s.optInt("operating")}명 · 약 ${s.optInt("days")}일분", color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp)
        }
        if (clerk.lines.isNotEmpty()) TalkBox(clerk)
        if (st.note.isNotEmpty() && confirm == null) Text(st.note, color = Color(0xFFFFE066), fontSize = 18.sp)
        when (tab) {
            1 -> if (dock != null) {
                val stored = dock.optJSONArray("stored").objs()
                val ships = s.optJSONArray("ships").objs()
                Text(if (stored.isEmpty()) dock.optString("empty") else dock.optString("some"), color = Color.White, fontSize = 16.sp)
                for (d in stored) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(d.getString("name") + "호", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(170.dp))
                    Text(d.getString("className"), color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.width(150.dp))
                    SmallButton("배비", enabled = !st.busy) { st.post("harbor_dock_out", "index" to d.getInt("index")) }
                    for (x in ships) SmallButton("교환:${x.getString("name")}", enabled = !st.busy) { st.post("harbor_dock_exchange", "ship" to x.getInt("index"), "index" to d.getInt("index")) }
                }
                for (x in ships.drop(1)) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(x.getString("name") + "호", color = Color.White, fontSize = 18.sp, modifier = Modifier.width(170.dp))
                    Text("선원 ${x.getInt("crew")}명", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.width(150.dp))
                    SmallButton("보관", enabled = !st.busy) { st.post("harbor_dock_store", "ship" to x.getInt("index")) { j -> if (j.has("ask")) storeAsk = j.getString("ask") to j.getInt("askShip") } }
                }
            }
            2 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(s.optString("namingAsk"), color = Color.White, fontSize = 16.sp)
                androidx.compose.foundation.text.BasicTextField(name, { name = it.take(7) },
                    textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 18.sp),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(Gold),
                    modifier = Modifier.width(180.dp).clip(RoundedCornerShape(10.dp)).background(Color.White.copy(alpha = 0.08f)).padding(12.dp))
                SmallButton("명명", enabled = name.isNotBlank() && !st.busy) { st.post("harbor_rename", "name" to name); name = "" }
            }
            else -> Supplies(st, s, game)
        }
    }
    confirm?.let { text ->
        Overlay {
            Text(text, color = Color.White, fontSize = 20.sp)
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallButton("출항", prominent = true) { confirm = null; setSail() }
                SmallButton("취소") { confirm = null }
            }
        }
    }
    storeAsk?.let { (text, ship) ->
        Overlay {
            Text(text, color = Color.White, fontSize = 20.sp)
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallButton("예", prominent = true) { storeAsk = null; st.post("harbor_dock_store", "ship" to ship, "confirm" to 1) }
                SmallButton("아니오") { storeAsk = null }
            }
        }
    }
    }
}

@Composable
private fun Supplies(st: EngineState, s: JSONObject, game: GameState) {
    val ships = s.optJSONArray("ships").objs()
    val supplies = s.optJSONArray("supplies").objs()
    var ship by remember { mutableIntStateOf(0) }
    var unloading by remember { mutableStateOf(false) }
    val amounts = remember { mutableStateListOf(0, 0, 0, 0) }
    val sh = ships.getOrNull(ship) ?: run { Text("아직 배가 없습니다.", color = Color.White, fontSize = 18.sp); return }
    val held = sh.getJSONArray("held")
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (ships.size > 1) for ((i, x) in ships.withIndex()) SmallButton(x.getString("name"), prominent = i == ship) { ship = i; amounts.fill(0) }
            else Text(sh.getString("name"), color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            Text("적재 여유 ${sh.getInt("freeCargo")} / ${sh.getInt("cargoCap")}통", color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SmallButton("싣기", prominent = !unloading) { unloading = false; amounts.fill(0) }
            SmallButton("내리기", prominent = unloading) { unloading = true; amounts.fill(0) }
        }
        for ((k, sp) in supplies.withIndex()) {
            val price = sp.getInt("price")
            val have = held.getInt(k)
            val most = if (unloading) have else if (price == 0) sh.getInt("freeCargo") else minOf(sh.getInt("freeCargo"), game.wallet.gold / price)
            val n = minOf(amounts[k], most)
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Navy.copy(alpha = 0.6f)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(sp.getString("name"), color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Text(if (price == 0) "무료" else "1통 ${price}닢", color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp)
                    Text("보유 ${have}통", color = Color.White, fontSize = 16.sp)
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    IntPicker("수량", n, 0..most, "통", modifier = Modifier.weight(1f)) { amounts[k] = it }
                    if (unloading) SmallButton("내리기", Modifier.width(150.dp), enabled = n > 0 && !st.busy) {
                        st.post("harbor_unload", "kind" to k, "barrels" to n, "ship" to ship) { j -> if (j.optBoolean("done")) amounts[k] = 0 }
                    } else SmallButton(if (price == 0) "싣기" else "구입 · ${n * price}닢", Modifier.width(150.dp), enabled = n > 0 && !st.busy, prominent = true) {
                        st.post("harbor_buy", "kind" to k, "barrels" to n, "ship" to ship) { j -> if (j.optBoolean("done")) amounts[k] = 0 }
                    }
                }
            }
        }
    }
}
