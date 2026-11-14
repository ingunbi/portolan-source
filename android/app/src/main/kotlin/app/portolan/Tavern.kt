package app.portolan

import androidx.compose.foundation.Canvas
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
import org.json.JSONArray
import org.json.JSONObject

private fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }

/** The tavern: a round of drinks, sailors to sign and to let go, patrons to talk to, and the officers aboard. */
@Composable
fun TavernPanel(clerk: Clerk, assets: Assets, gamble: EngineState) {
    val t = clerk.panel?.optJSONObject("tavern")
    var mode by remember { mutableIntStateOf(0) }
    var bottles by remember { mutableIntStateOf(4) }
    var sailors by remember { mutableIntStateOf(0) }
    var patron by remember { mutableIntStateOf(-1) }
    DisposableEffect(clerk) {
        clerk.onFlag = { j -> if (j.has("patronMenu")) patron = j.getInt("patronMenu") }
        onDispose { clerk.onFlag = null }
    }
    if (t == null) { Text("주점 장부를 펴는 중…", color = Color.White, fontSize = 18.sp); return }
    val hireable = t.optInt("hireable")
    LaunchedEffect(hireable) { sailors = hireable }
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SmallButton("선원 · 한턱내기 · 항해자", prominent = mode == 0) { mode = 0 }
            SmallButton("선원해고", prominent = mode == 1, enabled = (t.optJSONArray("ships")?.length() ?: 0) > 0) { mode = 1 }
            SmallButton("여급과대화", prominent = mode == 2, enabled = t.optBoolean("hasBarmaid") && !clerk.waiting) {
                mode = 2
                if (t.optJSONObject("barmaid")?.optBoolean("seated") != true) clerk.act("tavern.barmaid")
            }
            SmallButton("도박", prominent = mode == 3, enabled = !clerk.waiting) { mode = 3 }
        }
        if (mode != 3 && (clerk.lines.isNotEmpty() || clerk.ask != null)) Card(Modifier.fillMaxWidth()) { TalkBox(clerk) }
        if (mode == 3) GamblingPanel(gamble, assets) { mode = 0 }
        else if (mode == 2) Barmaid(clerk, t.optJSONObject("barmaid"), assets) { mode = 0 }
        else if (mode == 1) Dismiss(clerk, t) else Main(clerk, t, assets, bottles, { bottles = it }, sailors, { sailors = it }, patron) { patron = it }
    }
}

/** The navigators waiting at the tavern or the inn ([place] is the command prefix): talk, treat (tavern only), news, hire. */
@Composable
fun PatronBox(clerk: Clerk, assets: Assets, t: JSONObject, patron: Int, setPatron: (Int) -> Unit, place: String, treat: Boolean) {
    val patrons = t.optJSONArray("patrons").objs()
    Card(Modifier.fillMaxWidth()) {
        Text("항해자와 대화", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        if (patrons.isEmpty()) Text(t.optString("nobody"), color = Color.White.copy(alpha = 0.6f), fontSize = 16.sp)
        for (p in patrons) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(vertical = 4.dp)) {
            val face = assets.portrait(p.getInt("face"), p.getInt("nation"))
            if (face != null) Canvas(Modifier.size(40.dp, 50.dp).clip(RoundedCornerShape(5.dp))) { pixels(face, 0f, 0f, size.width, size.height) }
            Column(Modifier.weight(1f)) {
                Text(p.getString("name"), color = Color.White, fontSize = 18.sp, fontWeight = if (patron == p.getInt("p")) FontWeight.Bold else FontWeight.Normal)
                Text("항해 ${p.getInt("navLevel")} · 전투 ${p.getInt("battleLevel")} · ${p.getString("ability")}", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
            }
            SmallButton("말을 건다", enabled = !clerk.waiting) { clerk.act("$place.greet", "p" to p.getInt("p")) }
        }
        if (patron >= 0 && patrons.any { it.getInt("p") == patron }) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
            if (treat) SmallButton("한턱내기", enabled = !clerk.waiting) { clerk.act("$place.patron_treat", "p" to patron) }
            SmallButton("항해자정보", enabled = !clerk.waiting) { clerk.act("$place.patron_rumour", "p" to patron) }
            SmallButton("고용", enabled = !clerk.waiting, prominent = true) { clerk.act("$place.patron_join", "p" to patron) }
            SmallButton("그만두기") { setPatron(-1) }
        }
    }
}

@Composable
private fun Main(clerk: Clerk, t: JSONObject, assets: Assets, bottles: Int, setBottles: (Int) -> Unit, sailors: Int, setSailors: (Int) -> Unit,
                 patron: Int, setPatron: (Int) -> Unit) {
    val affordable = t.optInt("bottlesMax")
    val hireable = t.optInt("hireable")
    val b = minOf(bottles, affordable)
    val s = minOf(sailors, hireable)
    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Card(Modifier.weight(1f)) {
            Text("${t.getString("drink")} 한 병에 금화 ${t.getInt("price")}닢", color = Color.White, fontSize = 18.sp)
            IntPicker("병", b, 0..affordable, "병") { setBottles(it) }
            SmallButton("한턱 내기 · 금화 ${b * t.getInt("price")}닢", enabled = b > 0 && !clerk.waiting, prominent = true) { clerk.act("tavern.treat", "bottles" to b) }
            Spacer(Modifier.height(10.dp))
            Text("분위기 ${t.getInt("mood")} / 100", color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)
            Box(Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)).background(Color.White.copy(alpha = 0.12f))) {
                Box(Modifier.fillMaxWidth(t.getInt("mood") / 100f).fillMaxHeight().background(if (t.getInt("mood") < t.getInt("willing")) Color(0xFFFFA64D) else Color(0xFF4CD964)))
            }
        }
        Card(Modifier.weight(1f)) {
            Text(t.getString("advice"), color = Color.White, fontSize = 18.sp)
            Text("지원자 ${t.getInt("volunteers")}명 · 선원 한 사람당 금화 ${t.getInt("wage")}닢 · 빈 자리 ${t.getInt("vacancies")}명", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
            IntPicker("고용", s, 0..hireable, "명") { setSailors(it) }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SmallButton("가능한 인원 모두", enabled = hireable > 0) { setSailors(hireable) }
                SmallButton("고용 · 금화 ${s * t.getInt("wage")}닢", enabled = s > 0 && !clerk.waiting, prominent = true) { clerk.act("tavern.hire", "n" to s) }
            }
            if (t.optBoolean("hiredToday")) Text("오늘은 이미 선원을 모았습니다.", color = Color.White.copy(alpha = 0.55f), fontSize = 14.sp)
        }
    }
    PatronBox(clerk, assets, t, patron, setPatron, "tavern", true)
    val officers = t.optJSONArray("officers").objs()
    val posts = t.optJSONArray("posts")
    Card(Modifier.fillMaxWidth()) {
        Text("동료 ${officers.size}명 · 남는 선장 ${t.optInt("spareCaptains")}", color = Gold, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        for (o in officers) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(vertical = 3.dp)) {
            Text(o.getString("name"), color = Color.White, fontSize = 16.sp, modifier = Modifier.width(150.dp))
            Text("항해 ${o.getInt("navLevel")} · 충성 ${o.getInt("loyalty")} · 월 ${o.getInt("salary")}닢", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.weight(1f))
            if (o.getString("captainOf").isNotEmpty()) Text("${o.getString("captainOf")} 선장", color = Color.White.copy(alpha = 0.75f), fontSize = 14.sp)
            else Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SmallButton("—", prominent = o.getInt("post") < 0) { clerk.act("tavern.appoint", "k" to o.getInt("k")) }
                for (i in 0 until (posts?.length() ?: 0)) SmallButton(posts!!.getString(i), prominent = o.getInt("post") == i) { clerk.act("tavern.appoint", "k" to o.getInt("k"), "post" to i) }
            }
            SmallButton("해고", enabled = t.optInt("spareCaptains") > 0 && !clerk.waiting) { clerk.act("tavern.dismiss_officer", "k" to o.getInt("k")) }
        }
    }
}

@Composable
private fun Dismiss(clerk: Clerk, t: JSONObject) {
    val ships = t.optJSONArray("ships").objs()
    val keep = remember { mutableStateMapOf<Int, Int>() }
    Card(Modifier.fillMaxWidth()) {
        for (s in ships) {
            val i = s.getInt("index")
            val most = s.getInt("keepMax")
            val k = minOf(keep[i] ?: s.getInt("crew"), most)
            Text(s.getString("prompt"), color = Color.White, fontSize = 16.sp)
            IntPicker("남길", k, 0..most, "명") { keep[i] = it }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("사기 ${s.getInt("morale")}", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                SmallButton("해고", enabled = !clerk.waiting && k < s.getInt("crew")) { clerk.act("tavern.dismiss", "ship" to i, "keep" to k); keep.remove(i) }
            }
            Spacer(Modifier.height(10.dp))
        }
    }
}

/** The barmaid's table: ten gold for her company, then boasting, presents, investigations and gossip. */
@Composable
private fun Barmaid(clerk: Clerk, b: JSONObject?, assets: Assets, leave: () -> Unit) {
    if (b == null) { Text("여급이 보이지 않습니다.", color = Color.White, fontSize = 18.sp); return }
    var gossip by remember { mutableStateOf(false) }
    val seated = b.optBoolean("seated")
    Card(Modifier.fillMaxWidth()) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            val face = assets.image("portraits/%03d.png".format(b.getInt("portrait")))
            Canvas(Modifier.size(64.dp, 80.dp).clip(RoundedCornerShape(6.dp)).background(Color.Black.copy(alpha = 0.3f))) {
                if (face != null) pixels(face, 0f, 0f, size.width, size.height)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(b.getString("name"), color = Gold, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                if (seated) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (t in b.optJSONArray("topics").objs()) {
                            val id = t.getInt("id")
                            SmallButton(t.getString("name"), prominent = id == 3 && gossip, enabled = !clerk.waiting) {
                                gossip = id == 3
                                clerk.act("tavern.barmaid_topic", "topic" to id)
                            }
                        }
                    }
                    if (gossip) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (t in b.optJSONArray("gossip").objs()) {
                            SmallButton(t.getString("name"), enabled = t.optBoolean("enabled") && !clerk.waiting) {
                                clerk.act("tavern.barmaid_gossip", "topic" to t.getInt("id"))
                            }
                        }
                    }
                }
                SmallButton("돌아가기", enabled = !clerk.waiting) { clerk.act("tavern.barmaid_leave"); leave() }
            }
        }
    }
}
