package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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

private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }

/** The bank (menu 0): deposit, withdraw, borrow, repay. */
@Composable
fun BankPanel(clerk: Clerk, game: GameState) {
    val bal = clerk.panel?.optInt("balance", game.bank) ?: game.bank
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            SmallButton("예금", enabled = !clerk.waiting) { clerk.act("bank.deposit") }
            SmallButton("출금", enabled = !clerk.waiting) { clerk.act("bank.withdraw") }
            SmallButton("대출", enabled = !clerk.waiting) { clerk.act("bank.borrow") }
            SmallButton("상환", enabled = !clerk.waiting) { clerk.act("bank.repay") }
            Spacer(Modifier.weight(1f))
            Text(if (bal >= 0) "예금잔고 ${bal}닢 · 월 3%" else "차입금 ${-bal}닢 · 월 10%", color = if (bal >= 0) Color.White else Color(0xFFFFA64D), fontSize = 18.sp)
        }
        TalkBox(clerk)
    }
}

/** The church (menu 7): pray and donate; the clerk's farewell comes when you leave. */
@Composable
fun ChurchPanel(clerk: Clerk, game: GameState) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            SmallButton("예배", enabled = !clerk.waiting) { clerk.act("church.pray") }
            SmallButton("기부", enabled = !clerk.waiting) { clerk.act("church.donate") }
            Spacer(Modifier.weight(1f))
            Text("운 ${game.luck}", color = Color.White.copy(alpha = 0.7f), fontSize = 18.sp)
        }
        TalkBox(clerk)
    }
}

/** The fortune teller (menu 17): four readings at 50 each. */
@Composable
fun FortunePanel(clerk: Clerk) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            for (f in clerk.panel?.optJSONArray("fortunes").objects())
                SmallButton(f.getString("name"), enabled = f.getBoolean("ok") && !clerk.waiting) { clerk.act("fortune.read", "fortune" to f.getInt("id")) }
        }
        TalkBox(clerk)
    }
}

/** The item shop: what is on sale, and the bag with equip and sell. */
@Composable
fun ItemShopPanel(clerk: Clerk) {
    val panel = clerk.panel
    val stock = panel?.optJSONArray("stock").objects()
    val items = panel?.optJSONArray("items").objects()
    fun stats(o: JSONObject) = when (o.getInt("slot")) { 0 -> "공격력 ${o.getInt("power")}"; 1, 2 -> "방어력 ${o.getInt("power")}"; else -> "" }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.weight(1f, fill = false)) {
            Card(Modifier.weight(1f)) {
                Text("구입", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                if (stock.isEmpty()) Text(panel?.optString("noStock") ?: "", color = Color.White.copy(alpha = 0.6f), fontSize = 16.sp)
                for (o in stock) Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable(enabled = !clerk.waiting) { clerk.act("item.buy", "id" to o.getInt("id")) }
                    .padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(o.getString("name"), color = Color.White, fontSize = 18.sp)
                        if (stats(o).isNotEmpty()) Text(stats(o), color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                    }
                    Text("${o.getInt("price")}닢", color = Gold, fontSize = 18.sp)
                }
            }
            Card(Modifier.weight(1f)) {
                Text("소지품 ${items.size} / ${panel?.optInt("maxItems") ?: 20}", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                if (items.isEmpty()) Text(panel?.optString("noItems") ?: "", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                Column(Modifier.heightIn(max = 260.dp).verticalScroll(rememberScrollState())) {
                    for (o in items) Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text((if (o.getBoolean("equipped")) "◆ " else "") + o.getString("name"), color = Color.White, fontSize = 16.sp)
                            if (stats(o).isNotEmpty()) Text(stats(o), color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        if (o.getInt("slot") >= 0) SmallButton(if (o.getBoolean("equipped")) "해제" else "장비", enabled = !clerk.waiting) { clerk.act("item.equip", "id" to o.getInt("id")) }
                        SmallButton("매각", enabled = !clerk.waiting) { clerk.act("item.sell", "id" to o.getInt("id")) }
                    }
                }
            }
        }
        TalkBox(clerk)
    }
}

/** The inn: a night or two hours, and the six nations' support in this port. */
@Composable
fun InnPanel(clerk: Clerk, assets: Assets) {
    val support = clerk.panel?.optJSONArray("support").objects()
    var patron by remember { mutableIntStateOf(-1) }
    DisposableEffect(Unit) {
        clerk.onFlag = { j -> if (j.has("patronMenu")) patron = j.getInt("patronMenu") }
        onDispose { clerk.onFlag = null }
    }
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SmallButton("숙박 · 다음날 아침까지", enabled = !clerk.waiting) { clerk.act("inn.sleep") }
            SmallButton("두 시간 보내기", enabled = !clerk.waiting) { clerk.act("inn.wait") }
        }
        TalkBox(clerk)
        clerk.panel?.let { PatronBox(clerk, assets, it, patron, { n -> patron = n }, "inn", false) }
        if (support.isNotEmpty()) Card(Modifier.widthIn(max = 560.dp)) {
            Text(clerk.panel?.optString("supportTitle") ?: "", color = Gold, fontSize = 16.sp)
            Spacer(Modifier.height(6.dp))
            for (s in support) Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 3.dp)) {
                Text(s.getString("nation"), color = Color.White, fontSize = 16.sp, modifier = Modifier.width(100.dp))
                Box(Modifier.weight(1f).height(8.dp).clip(RoundedCornerShape(4.dp)).background(Color.White.copy(alpha = 0.12f))) {
                    Box(Modifier.fillMaxWidth(s.getInt("pct").coerceIn(0, 100) / 100f).fillMaxHeight()
                        .background(if (s.getBoolean("owner")) Color(0xFFFFE066) else Color.White.copy(alpha = 0.45f)))
                }
                Text("${s.getInt("pct")}%", color = Color.White, fontSize = 16.sp, modifier = Modifier.width(60.dp).padding(start = 8.dp))
                Text(if (s.getBoolean("owner")) clerk.panel?.optString("ownerMark") ?: "" else "", color = Gold, fontSize = 14.sp, modifier = Modifier.width(70.dp))
            }
        }
    }
}

/** The palace: an audience first (its scenes), then the king's help and papers. */
@Composable
fun PalacePanel(clerk: Clerk, assets: Assets) {
    val p = clerk.panel?.optJSONObject("palace")
    var audience by remember { mutableStateOf(false) }
    DisposableEffect(clerk) {
        clerk.onFlag = { j -> if (j.optBoolean("audience")) audience = true }
        onDispose { clerk.onFlag = null }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.fillMaxWidth()) {
        val face = p?.let { assets.image("portraits/%03d.png".format(it.optInt("face"))) }
        if (face != null) androidx.compose.foundation.Canvas(Modifier.size(80.dp, 100.dp)) { pixels(face, 0f, 0f, size.width, size.height) }
        Column(verticalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.weight(1f)) {
            if (p != null) Text(if (p.getBoolean("foreign")) "${p.getString("nation")} · 공헌도 ${p.getInt("standing")}" else "", color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SmallButton("알현", enabled = !clerk.waiting, prominent = true) { audience = false; clerk.act("palace.audience") }
                SmallButton("망명", enabled = !clerk.waiting && p?.optBoolean("defect") == true) { clerk.act("palace.defect") }
                SmallButton("자금원조", enabled = !clerk.waiting && p?.optBoolean("aid") == true) { clerk.act("palace.gold_aid") }
                SmallButton("선박원조", enabled = !clerk.waiting && p?.optBoolean("aid") == true) { clerk.act("palace.ship_aid") }
            }
            if (audience) Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SmallButton("세력상황", enabled = !clerk.waiting) { clerk.act("palace.power") }
                SmallButton("사략허가서", enabled = !clerk.waiting && p?.optBoolean("ownNation") == true) { clerk.act("palace.privateer") }
                SmallButton("면세증", enabled = !clerk.waiting && p?.optBoolean("foreign") == true) { clerk.act("palace.certificate") }
                SmallButton("물러나기", enabled = !clerk.waiting) { audience = false }
            }
            TalkBox(clerk)
        }
    }
}

/** 투자 at the trading post (economy) or 공업투자 at the shipyard (industry). */
@Composable
fun InvestBox(clerk: Clerk) {
    val inv = clerk.panel?.optJSONObject("invest") ?: return
    Card(Modifier.fillMaxWidth()) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            SmallButton(if (inv.getString("field") == "economy") "투자" else "공업투자", enabled = !clerk.waiting) { clerk.act("invest.do") }
            Text("${inv.getString("label")} ${inv.getInt("value")} · 이번 달 투자 ${inv.getInt("done")} / ${inv.getInt("cap")}닢", color = Color.White.copy(alpha = 0.75f), fontSize = 16.sp)
        }
        if (clerk.lines.isNotEmpty() || clerk.ask != null) { Spacer(Modifier.height(8.dp)); TalkBox(clerk) }
    }
}

/** The guild: the job desk and news of the nations. */
@Composable
fun GuildPanel(clerk: Clerk) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            SmallButton("업무알선", enabled = !clerk.waiting, prominent = true) { clerk.act("guild.desk") }
            SmallButton("나라정보", enabled = !clerk.waiting) { clerk.act("guild.news") }
        }
        TalkBox(clerk)
    }
}
