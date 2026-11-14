package app.portolan

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
import org.json.JSONObject

/** The engine owns the purse, the stores and the hold now; nothing is pushed from the app any more. */
fun walletArgs(@Suppress("UNUSED_PARAMETER") game: GameState): Array<Pair<String, Any?>> = emptyArray()

/** What the engine reports of the purse, the stores and the clock goes back into the app. */
fun applyWallet(w: JSONObject?, game: GameState) {
    if (w == null) return
    val v = game.voyage
    if (w.has("gold")) game.wallet.gold = w.getInt("gold")
    if (w.has("crew")) v.ships[0].crew = w.getInt("crew")
    if (w.has("water")) v.water = w.getInt("water")
    if (w.has("food")) v.food = w.getInt("food")
    if (w.has("hasShip")) game.hasShip = w.getBoolean("hasShip")
    if (w.has("class")) {
        v.ships[0].cls = game.nav.classes[w.getInt("class").coerceIn(0, game.nav.classes.size - 1)]
        v.ships[0].rudder = w.optInt("rudder", v.ships[0].rudder); v.ships[0].sail = w.optInt("sail", v.ships[0].sail)
        if (w.has("cargoCap")) game.wallet.cargoSpace = w.getInt("cargoCap")
        game.refreshLoad()
    }
    if (w.has("shot")) game.wallet.shot = w.getInt("shot")
    if (w.has("guns")) game.wallet.guns = w.getInt("guns")
    if (w.has("lumber")) game.wallet.lumber = w.getInt("lumber")
    if (w.has("year")) { v.year = w.getInt("year"); v.month = w.getInt("month"); v.dayOfMonth = w.getInt("day"); v.tick = w.getInt("tick") }
    if (w.has("bank")) game.bank = w.getInt("bank")
    if (w.has("luck")) game.luck = w.getInt("luck")
}

class AskUi(val kind: String, val max: Int, val options: List<String>, val suggested: String, val yes: String = "예", val no: String = "아니오")

/** One conversation with a clerk: what was said, the question waiting, and the building's own figures. */
class Clerk(private val host: EngineHost, private val game: GameState, private val scope: CoroutineScope) {
    var lines by mutableStateOf<List<String>>(emptyList())
    var ask by mutableStateOf<AskUi?>(null)
    var panel by mutableStateOf<JSONObject?>(null)
    var busy by mutableStateOf(false)
    val waiting get() = busy || ask != null
    /** Where a reply that starts a story scene goes. */
    var scenes: SceneRun? = null
    /** Set by a building that wants to know when an audience-like scene says "open the next menu". */
    var onFlag: ((JSONObject) -> Unit)? = null

    fun take(j: JSONObject, fromScene: Boolean = false) {
        if (!fromScene && j.has("scene")) {
            applyWallet(j.optJSONObject("wallet"), game)
            scenes?.take(j)
            return
        }
        onFlag?.invoke(j)
        lines = j.optJSONArray("lines")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
        ask = j.optJSONObject("ask")?.let { a ->
            AskUi(a.getString("kind"), a.optInt("max"), a.optJSONArray("options")?.let { o -> List(o.length()) { o.getString(it) } } ?: emptyList(),
                a.optString("suggested"), a.optString("yes", "예"), a.optString("no", "아니오"))
        }
        j.optJSONObject("panel")?.let { panel = it }
        applyWallet(j.optJSONObject("wallet"), game)
    }

    private fun post(cmd: String, vararg args: Pair<String, Any?>) {
        if (busy) return
        busy = true
        scope.launch {
            take(host.call(cmd, *args))
            busy = false
        }
    }

    fun act(action: String, vararg args: Pair<String, Any?>) = post("town_do", "action" to action, *args)
    fun answer(vararg args: Pair<String, Any?>) = post("town_answer", *args)
}

/** What the clerk says, and the question below it. */
@Composable
fun TalkBox(clerk: Clerk, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
            for (l in clerk.lines) Text(l, color = Color.White, fontSize = 18.sp, modifier = Modifier.padding(bottom = 4.dp))
        }
        clerk.ask?.let { AskView(it, clerk) }
    }
}

@Composable
private fun AskView(a: AskUi, clerk: Clerk) {
    when (a.kind) {
        "yesNo" -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SmallButton(a.yes, prominent = true) { clerk.answer("yes" to true) }
            SmallButton(a.no) { clerk.answer("yes" to false) }
        }
        "amount" -> {
            var n by remember(a) { mutableIntStateOf(0) }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("$n", color = Gold, fontSize = 28.sp, fontWeight = FontWeight.Bold)
                QtySlider(n.toFloat(), { n = it.toInt().coerceIn(0, a.max) }, 0f..maxOf(1, a.max).toFloat(), Modifier.widthIn(max = 520.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (d in listOf(-100, -10, -1, 1, 10, 100)) SmallButton(if (d > 0) "+$d" else "$d", Modifier.width(88.dp)) { n = (n + d).coerceIn(0, a.max) }
                    SmallButton("최대", Modifier.width(88.dp)) { n = a.max }
                    SmallButton("0", Modifier.width(88.dp)) { n = 0 }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    SmallButton("확인", enabled = n > 0, prominent = true) { clerk.answer("value" to n) }
                    SmallButton("취소") { clerk.answer("value" to 0) }
                }
            }
        }
        "choice" -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.heightIn(max = 260.dp).verticalScroll(rememberScrollState())) {
                for ((i, o) in a.options.withIndex()) SmallButton(o) { clerk.answer("choice" to i) }
            }
            SmallButton("취소") { clerk.answer("choice" to -1) }
        }
        "name" -> {
            var text by remember(a) { mutableStateOf(a.suggested) }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                BasicTextField(text, { text = it.take(12) }, textStyle = TextStyle(color = Color.White, fontSize = 20.sp), cursorBrush = SolidColor(Gold),
                    modifier = Modifier.width(260.dp).clip(RoundedCornerShape(10.dp)).border(1.dp, Gold.copy(alpha = 0.6f), RoundedCornerShape(10.dp)).padding(12.dp))
                SmallButton("확인", enabled = text.isNotBlank(), prominent = true) { clerk.answer("name" to text) }
            }
        }
    }
}

private fun Modifier.horizontalScrollRow(): Modifier = this
