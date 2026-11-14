package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import org.json.JSONArray
import org.json.JSONObject

private fun JSONArray?.ints(): List<Int> = if (this == null) emptyList() else List(length()) { getInt(it) }
private fun JSONArray?.strs(): List<String> = if (this == null) emptyList() else List(length()) { getString(it) }
private fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }

private val gameNames = listOf("Black Jack", "Dice")

/** The tavern's gambling tables. Every move is the engine's; this only shows the table it reports. */
@Composable
fun GamblingPanel(st: EngineState, assets: Assets, onClose: () -> Unit) {
    LaunchedEffect(Unit) { st.post("gamble_enter") }
    val g = st.state
    val refusal = st.last?.optJSONObject("refusal")
    // The tavern panel around this one scrolls; a scroll of its own here would be nested in it.
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(g?.optString("purse").orEmpty(), color = Gold, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            val game = g?.optInt("game", -1) ?: -1
            if (game < 0) SmallButton("돌아가기") { st.post("gamble_close") { onClose() } }
        }
        when {
            refusal != null -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Face(assets, refusal.optInt("face"), refusal.optInt("nation"), 44)
                Text(refusal.optString("line"), color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            g == null -> Text("도박판을 차리는 중…", color = Color.White, fontSize = 18.sp)
            g.optInt("game", -1) < 0 -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                for ((k, name) in gameNames.withIndex()) SmallButton(name, prominent = true, enabled = g.optBoolean("canPlay") && !st.busy) { st.post("gamble_open", "game" to k) }
            }
            else -> {
                if (g.optInt("game") == 0) BlackJackTable(st, g, assets) else DiceTable(st, g, assets)
                if (g.optString("stage") == "over") SmallButton("자리를 뜬다", prominent = true) { st.post("gamble_close") }
            }
        }
    }
}

@Composable
private fun Face(assets: Assets, face: Int, nation: Int, height: Int) {
    val img = assets.portrait(face, nation)
    Canvas(Modifier.size((height * 0.8f).dp, height.dp).clip(RoundedCornerShape(5.dp)).background(Color.Black.copy(alpha = 0.3f))) {
        if (img != null) pixels(img, 0f, 0f, size.width, size.height)
    }
}

/** What was said at the table, the last few lines, each beside the face of who said it. */
@Composable
private fun TableTalk(g: JSONObject, assets: Assets) {
    val faces = g.optJSONArray("faces").ints()
    val nation = g.optInt("nation")
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Navy.copy(alpha = 0.6f)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (l in g.optJSONArray("lines").objs()) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val sp = l.optInt("speaker")
            if (sp in 1..faces.size) Face(assets, faces[sp - 1], nation, 28) else Spacer(Modifier.width(22.dp))
            Text(l.optString("text"), color = Color.White, fontSize = 16.sp, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun YesNo(st: EngineState, yes: String, no: String, yesArgs: Array<Pair<String, Any?>> = emptyArray(), noArgs: Array<Pair<String, Any?>> = emptyArray()) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        SmallButton("예", prominent = true, enabled = !st.busy) { st.post(yes, *yesArgs) }
        SmallButton("아니오", enabled = !st.busy) { st.post(no, *noArgs) }
    }
}

/** The stake (995): ten up to the limit. */
@Composable
private fun BetBox(st: EngineState, text: String, limit: Int, minBet: Int, onBet: (Int) -> Unit) {
    var amount by remember { mutableIntStateOf(minBet) }
    val n = amount.coerceIn(minBet, maxOf(minBet, limit))
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(text, color = Color.White.copy(alpha = 0.8f), fontSize = 16.sp)
        IntPicker("도박금", n, minBet..maxOf(minBet, limit), "닢", step = 10) { amount = it }
        SmallButton("건다", prominent = true, enabled = !st.busy) { onBet(n) }
    }
}

// ---- Black Jack -------------------------------------------------------------------------------------

private val suitNames = listOf("spade", "heart", "club", "diamond")

/** A card (0x2DB08): the suit picture or the back, with the rank printed over its corner. */
@Composable
private fun CardView(assets: Assets, card: Int, name: String) {
    val img = assets.image("sprites/gambling/card_${if (card < 0) "back" else suitNames[card / 13 % 4]}.png")
    Box(Modifier.size(48.dp, 72.dp)) {
        Canvas(Modifier.fillMaxSize()) { if (img != null) pixels(img, 0f, 0f, size.width, size.height) }
        if (card >= 0) Text(name.drop(1), color = Color.Black, fontSize = 16.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(start = 3.dp, top = 2.dp).background(Color(0xFFEDEDED)).padding(horizontal = 2.dp))
    }
}

@Composable
private fun BlackJackTable(st: EngineState, g: JSONObject, assets: Assets) {
    val bj = g.optJSONObject("bj")
    val faces = g.optJSONArray("faces").ints()
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        if (faces.isNotEmpty()) Face(assets, faces[0], g.optInt("nation"), 70)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (bj != null) {
                val dealer = bj.optJSONArray("dealer").ints()
                val dNames = bj.optJSONArray("dealerNames").strs()
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    for ((i, c) in dealer.withIndex()) CardView(assets, c, dNames.getOrElse(i) { "" })
                    if (bj.optString("dealerRemark").isNotEmpty()) Text(bj.optString("dealerRemark"), color = Color.White, fontSize = 16.sp, modifier = Modifier.padding(start = 8.dp))
                }
                val player = bj.optJSONArray("player").ints()
                val pNames = bj.optJSONArray("names").strs()
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    for ((i, c) in player.withIndex()) CardView(assets, c, pNames.getOrElse(i) { "" })
                    if (bj.optBoolean("placed")) {
                        Text(bj.optString("remark"), color = Color.White, fontSize = 16.sp, modifier = Modifier.padding(start = 8.dp))
                        Text("도박금 ${bj.optInt("bet")}닢", color = Gold, fontSize = 14.sp, modifier = Modifier.padding(start = 8.dp))
                    }
                }
            }
            TableTalk(g, assets)
            when (g.optString("stage")) {
                "invite", "again" -> YesNo(st, "gamble_yes", "gamble_no")
                "betting" -> BetBox(st, g.optString("betText"), g.optInt("limit"), g.optInt("minBet", 10)) { n -> st.post("gamble_bet", "amount" to n) }
                "playing" -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    SmallButton("ＨＩＴ", prominent = true, enabled = !st.busy) { st.post("gamble_hit") }
                    SmallButton("ＳＴＡＮＤ", enabled = !st.busy) { st.post("gamble_stand") }
                }
            }
        }
    }
}

// ---- Dice -------------------------------------------------------------------------------------------

@Composable
private fun DiceTable(st: EngineState, g: JSONObject, assets: Assets) {
    val d = g.optJSONObject("dice")
    val faces = g.optJSONArray("faces").ints()
    val nation = g.optInt("nation")
    var choosing by remember { mutableStateOf(false) }
    val keep = remember { mutableStateListOf(false, false, false, false, false) }
    val phase = d?.optString("phase").orEmpty()
    LaunchedEffect(phase, g.optJSONArray("lines")?.length()) { if (phase != "rolling") { choosing = false; for (i in 0 until 5) keep[i] = false } }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (d != null && (phase == "rolling" || phase == "finished")) {
            val dice = d.optJSONArray("dice")
            val held = d.optJSONArray("held")
            val rolls = d.optJSONArray("rolls").ints()
            val hands = d.optJSONArray("hands").strs()
            val winners = d.optJSONArray("winners").ints()
            for (p in listOf(1, 2, 0)) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.width(130.dp)) {
                    if (p == 0) Text(g.optString("hero"), color = Color.White, fontSize = 14.sp)
                    else if (faces.size >= p) Face(assets, faces[p - 1], nation, 30)
                }
                if (rolls.getOrElse(p) { 0 } == 0) Text("—", color = Color.White.copy(alpha = 0.5f), fontSize = 16.sp)
                else {
                    val values = dice?.optJSONArray(p).ints()
                    val flags = held?.optJSONArray(p)
                    for ((i, v) in values.withIndex()) {
                        val isHeld = flags?.optBoolean(i) == true || (p == 0 && choosing && keep[i])
                        val canToggle = p == 0 && choosing && flags?.optBoolean(i) != true
                        val img = assets.image("sprites/gambling/die_$v.png")
                        Canvas(Modifier.size(38.dp).clip(RoundedCornerShape(3.dp))
                            .border(2.dp, if (isHeld) Color(0xFFFFD54F) else Color.Transparent, RoundedCornerShape(3.dp))
                            .clickable(enabled = canToggle) { keep[i] = !keep[i] }) { if (img != null) pixels(img, 0f, 0f, size.width, size.height) }
                    }
                    Text(hands.getOrElse(p) { "" }, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 6.dp))
                }
                if (winners.contains(p)) Text("♛", color = Gold, fontSize = 20.sp)
            }
            if (d.optInt("bet") > 0) Text("도박금 ${d.optInt("bet")}닢", color = Gold, fontSize = 14.sp)
        }
        TableTalk(g, assets)
        when (g.optString("stage")) {
            "invite", "again" -> YesNo(st, "gamble_yes", "gamble_no")
            "round" -> when (phase) {
                "betting" -> BetBox(st, g.optString("betText"), d?.optInt("limit") ?: 0, g.optInt("minBet", 10)) { n -> st.post("gamble_bet", "amount" to n) }
                "offer" -> YesNo(st, "gamble_answer", "gamble_answer", arrayOf("yes" to true), arrayOf("yes" to false))
                "rolling" -> if (choosing) Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("남길 주사위를 고르십시오.", color = Color.White, fontSize = 16.sp)
                    SmallButton("굴린다", prominent = true, enabled = !st.busy) {
                        val k = JSONArray().also { a -> for (b in keep) a.put(b) }
                        st.post("gamble_reroll", "keep" to k)
                    }
                } else Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(d?.optString("ask").orEmpty(), color = Color.White, fontSize = 16.sp)
                    SmallButton("예", prominent = true, enabled = !st.busy) { st.post("gamble_stay") }
                    SmallButton("아니오", enabled = !st.busy) { choosing = true }
                }
            }
        }
    }
}
