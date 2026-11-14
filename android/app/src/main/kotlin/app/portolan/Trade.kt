package app.portolan

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.horizontalScroll
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

/** The trading post as the engine reports it, and the deals made with it. */
class TradeSession(private val host: EngineHost, private val game: GameState, private val scope: CoroutineScope) {
    var state by mutableStateOf<JSONObject?>(null)
    var note by mutableStateOf("")
    /** The unit price the trader agreed to for one good. */
    var deal by mutableStateOf<Pair<Int, Int>?>(null)
    var prices by mutableStateOf<JSONObject?>(null)
    var busy by mutableStateOf(false)

    fun post(cmd: String, vararg args: Pair<String, Any?>, then: (JSONObject) -> Unit = {}) {
        if (busy) return
        busy = true
        scope.launch {
            val j = host.call(cmd, *args)
            j.optJSONObject("trade")?.let { state = it }
            j.optJSONObject("prices")?.let { prices = it }
            applyWallet(j.optJSONObject("wallet"), game)
            if (cmd == "trade_haggle") { note = j.optString("note"); if (j.has("deal")) { deal = deal?.copy(second = j.getInt("deal")) } }
            then(j)
            busy = false
        }
    }
}

@Composable
private fun Plate(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.clip(RoundedCornerShape(14.dp)).background(Navy.copy(alpha = 0.6f)).padding(16.dp), content = content)
}

@Composable
private fun TradeRow(selected: Boolean, name: String, detail: String, price: Int, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(if (selected) Gold.copy(alpha = 0.2f) else Color.Transparent)
        .clickable(onClick = onClick).padding(horizontal = 8.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(name, color = Color.White, fontSize = 18.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
            Text(detail, color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
        }
        Text("${price}닢", color = Gold, fontSize = 18.sp)
    }
}

/** The trading post: buy what the zone sells, sell what the hold carries, haggle, and read the price list. */
@Composable
fun TradePanel(trade: TradeSession, game: GameState) {
    LaunchedEffect(Unit) { trade.post("trade_state") }
    val s = trade.state ?: run { Text("교역소 장부를 펴는 중…", color = Color.White, fontSize = 18.sp); return }
    val ships = s.optJSONArray("ships").objs()
    val offers = s.optJSONArray("offers").objs()
    val holdsMax = s.optInt("holdsMax", 5)
    var ship by remember { mutableIntStateOf(0) }
    var pick by remember { mutableIntStateOf(0) }
    var buyCount by remember { mutableIntStateOf(0) }
    var hold by remember { mutableIntStateOf(0) }
    var sellCount by remember { mutableIntStateOf(0) }
    var ask by remember { mutableIntStateOf(0) }
    var showPrices by remember { mutableStateOf(false) }
    var priceCategory by remember { mutableIntStateOf(0) }
    val sh = ships.getOrNull(ship) ?: run { Text("아직 배가 없습니다.", color = Color.White, fontSize = 18.sp); return }
    val holds = sh.optJSONArray("holds").objs()
    val free = sh.getInt("freeCargo")
    val offer = offers.getOrNull(pick)
    val list = offer?.getInt("price") ?: 0
    val unit = trade.deal?.let { d -> if (d.first == offer?.getInt("good")) d.second else null } ?: list
    val most = if (offer == null || unit <= 0 || holds.size >= holdsMax) 0 else minOf(game.wallet.gold / unit, free)
    val n = minOf(buyCount, most)
    LaunchedEffect(pick, offers.size) { ask = list; buyCount = 0; trade.deal = null }

    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (ships.size > 1) for ((i, x) in ships.withIndex()) SmallButton(x.getString("name"), prominent = i == ship) { ship = i; hold = 0; buyCount = 0; sellCount = 0 }
            else Text(sh.getString("name"), color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            SmallButton("시세·물가") { showPrices = true; trade.post("trade_prices", "category" to priceCategory) }
            Spacer(Modifier.weight(1f))
            Text("적재 여유 ${free}통 · 짐칸 ${holds.size} / $holdsMax", color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp)
        }
        Text(if (s.optBoolean("licensed")) "무역면허 적용 · 구입 가산금 면제" else "무역면허 없음 · 구입 단가에 20% 가산금 포함", color = Color.White.copy(alpha = 0.55f), fontSize = 14.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Plate(Modifier.weight(1f)) {
                Text("사기", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                if (offer != null) {
                    Text("${offer.getString("name")} · ${unit}닢/개", color = Gold, fontSize = 16.sp)
                    IntPicker("수량", n, 0..most, "개") { buyCount = it }
                    if (most == 0) Text(if (holds.size >= holdsMax) "짐칸이 모두 사용 중입니다. 적하를 먼저 판매하세요." else if (free == 0) "적재 공간이 없습니다. 적하나 보급품을 줄이세요." else "구입할 금화가 부족합니다.",
                        color = Gold, fontSize = 14.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        SmallButton("구입 · ${n * unit}닢", enabled = n > 0 && !trade.busy, prominent = true) {
                            trade.post("trade_buy", "good" to offer.getInt("good"), "amount" to n, "ship" to ship, "unit" to unit) { j -> if (j.optBoolean("done")) { buyCount = 0; trade.deal = null; trade.note = "" } }
                        }
                        SmallButton("취소") { buyCount = 0; trade.deal = null; ask = list; trade.note = "" }
                    }
                    Text(trade.note.ifEmpty { offer.optString("remark") }, color = Color.White.copy(alpha = 0.65f), fontSize = 14.sp)
                    Text("흥정", color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        IntPicker("1개", (if (ask == 0) list else minOf(ask, list)), 1..maxOf(1, list), "닢", modifier = Modifier.weight(1f)) { ask = it }
                        SmallButton("제안", enabled = unit >= list && !trade.busy) {
                            trade.deal = offer.getInt("good") to unit
                            trade.post("trade_haggle", "good" to offer.getInt("good"), "offer" to (if (ask == 0) list else minOf(ask, list)))
                        }
                    }
                }
                Spacer(Modifier.height(6.dp))
                for ((i, o) in offers.withIndex()) TradeRow(i == pick, o.getString("name"), o.getString("category"), o.getInt("price")) { pick = i }
            }
            Plate(Modifier.weight(1f)) {
                Text("팔기", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                val lot = holds.getOrNull(hold)
                if (lot != null) {
                    val m = minOf(sellCount, lot.getInt("amount"))
                    Text("${lot.getString("name")} · ${lot.getInt("price")}닢/개", color = Gold, fontSize = 16.sp)
                    IntPicker("수량", m, 0..lot.getInt("amount"), "개") { sellCount = it }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        SmallButton("판매 · ${m * lot.getInt("price")}닢", enabled = m > 0 && !trade.busy, prominent = true) {
                            trade.post("trade_sell", "hold" to hold, "amount" to m, "ship" to ship) { j -> if (j.optBoolean("done")) { sellCount = 0; hold = 0 } }
                        }
                        SmallButton("취소") { sellCount = 0 }
                    }
                }
                Spacer(Modifier.height(6.dp))
                if (holds.isEmpty()) Text("적하가 없습니다.", color = Color.White.copy(alpha = 0.6f), fontSize = 16.sp)
                for ((i, l) in holds.withIndex()) TradeRow(i == hold, l.getString("name"), "${l.getInt("amount")}개", l.getInt("price")) { hold = i; sellCount = 0 }
            }
        }
    }
    if (showPrices) Overlay {
        Text("시세 · 물가", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        val cats = s.optJSONArray("categories")
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
            for (c in 0 until (cats?.length() ?: 0)) SmallButton(cats!!.getString(c), prominent = c == priceCategory) { priceCategory = c; trade.post("trade_prices", "category" to c) }
        }
        val p = trade.prices
        if (p != null) {
            Spacer(Modifier.height(8.dp))
            Text(p.optString("title"), color = Color(0xFFFFE066), fontSize = 16.sp)
            Row { Text("상품명", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.width(150.dp)); Text("매각", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.width(90.dp)); Text("매입", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp) }
            Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                for (r in p.optJSONArray("rows").objs()) Row {
                    Text(r.getString("name"), color = Color.White, fontSize = 16.sp, modifier = Modifier.width(150.dp))
                    Text(if (r.getInt("buy") < 0) "----" else "${r.getInt("buy")}", color = Color.White, fontSize = 16.sp, modifier = Modifier.width(90.dp))
                    Text("${r.getInt("sell")}", color = Color.White, fontSize = 16.sp)
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        SmallButton("닫기", prominent = true) { showPrices = false }
    }
    }
}
