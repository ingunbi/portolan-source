package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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

private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }

/** A running story scene (the scenario scripts): what the engine reports and what the player answered. */
class SceneRun(private val host: EngineHost, private val game: GameState, private val scope: CoroutineScope) {
    var scene by mutableStateOf<JSONObject?>(null)
    var duel by mutableStateOf<JSONObject?>(null)
    var busy by mutableStateOf(false)
    /** The building whose door started the scene (its interior is the backdrop), or -1. */
    var building by mutableIntStateOf(-1)
    var onEntry: ((JSONObject) -> Unit)? = null
    var onDone: (() -> Unit)? = null
    var onEnding: ((Int) -> Unit)? = null
    /** The building's own follow-up (what the clerk says next) once a scene it started is over. */
    var onAfter: ((JSONObject) -> Unit)? = null

    fun take(j: JSONObject) {
        applyWallet(j.optJSONObject("wallet"), game)
        duel = j.optJSONObject("duel")
        val sc = j.optJSONObject("scene")
        if (sc != null && !sc.optBoolean("done")) { scene = sc; Sound.scene(sc.optInt("music", -1)); return }
        scene = null; duel = null
        Sound.scene(null)
        if (sc != null && sc.has("ending")) onEnding?.invoke(sc.getInt("ending"))
        j.optJSONObject("entry")?.let { onEntry?.invoke(it) }
        onAfter?.invoke(j)
        onDone?.invoke()
    }

    private fun post(cmd: String, vararg args: Pair<String, Any?>) {
        if (busy) return
        busy = true
        scope.launch { take(host.call(cmd, *args)); busy = false }
    }

    fun answer(value: Int) = post("scene_answer", "value" to value)
    fun duelStart() = post("sduel_start")
    fun duelMove(move: Int) = post("sduel_move", "move" to move)
}

/** Speech windows, the picture and the prompt of a running scene. */
@Composable
fun SceneOverlay(run: SceneRun, assets: Assets, mosque: Boolean = false) {
    val sc = run.scene ?: return
    val prompt = sc.optJSONObject("prompt")
    val kind = prompt?.optString("kind") ?: ""
    val windows = sc.optJSONArray("windows").objects()
    val current = sc.optInt("current")
    val hero = sc.optInt("hero")
    val picture = sc.optInt("picture", -1)
    val interior = run.building.takeIf { it >= 0 }?.let { assets.image("images/graph_%02d.png".format(if (it == 10 && mosque) 20 else it + 6)) }
    val event = if (picture >= 0) assets.image("images/event${hero + 1}_$picture.png") else null
    val scroll = rememberScrollState()
    LaunchedEffect(windows.map { it.optString("text") }.hashCode()) { scroll.animateScrollTo(scroll.maxValue) }

    Box(Modifier.fillMaxSize().background(if (interior != null) Navy else Color.Black.copy(alpha = 0.55f))
        .clickable(enabled = kind == "next") { run.answer(0) }) {
        // The backdrop: the building's inside, or the scene's picture.
        Row(Modifier.fillMaxSize().padding(24.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            if (interior != null) Canvas(Modifier.width(380.dp).fillMaxHeight(0.62f).clip(RoundedCornerShape(14.dp))) {
                val h = size.height; val w = h * interior.width / interior.height
                pixels(interior, (size.width - minOf(w, size.width)) / 2f, 0f, minOf(w, size.width), minOf(h, size.width * interior.height / interior.width))
            }
            if (event != null) Canvas(Modifier.weight(1f).fillMaxHeight(0.62f).clip(RoundedCornerShape(14.dp))) {
                val w = minOf(size.width, size.height * event.width / event.height); val h = w * event.height / event.width
                pixels(event, (size.width - w) / 2f, 0f, w, h)
            }
        }
        Column(Modifier.align(Alignment.BottomCenter).widthIn(max = 1100.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.heightIn(max = 360.dp).verticalScroll(scroll), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for (w in windows) SpeechWindow(w, assets, w.optInt("id") == current, kind == "next")
            }
            Controls(run, prompt, assets)
        }
    }
}

@Composable
private fun SpeechWindow(w: JSONObject, assets: Assets, current: Boolean, waits: Boolean) {
    val hero = w.optInt("id") == 2
    val face = w.optInt("face", -1).takeIf { it >= 0 }?.let { assets.portrait(it) }
    val portrait: @Composable () -> Unit = {
        if (face != null) Canvas(Modifier.size(84.dp, 105.dp).clip(RoundedCornerShape(8.dp)).border(1.5.dp, Gold.copy(alpha = 0.6f), RoundedCornerShape(8.dp))) {
            pixels(face, 0f, 0f, size.width, size.height)
        }
    }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(NavyLight.copy(alpha = 0.97f))
        .border(if (current) 1.5.dp else 1.dp, Gold.copy(alpha = if (current) 0.7f else 0.3f), RoundedCornerShape(16.dp)).padding(18.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        if (!hero) portrait()
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val speaker = w.optString("speaker")
            if (speaker.isNotEmpty()) Text(speaker, color = Color.Black.copy(alpha = 0.85f), fontSize = 18.sp, fontWeight = FontWeight.ExtraBold,
                modifier = Modifier.clip(RoundedCornerShape(50)).background(Gold).padding(horizontal = 12.dp, vertical = 3.dp))
            Text(w.optString("text"), color = Color.White.copy(alpha = 0.95f), fontSize = 24.sp, lineHeight = 31.sp)
            if (current && waits) Text("▼", color = Gold, fontSize = 14.sp, modifier = Modifier.align(Alignment.End))
        }
        if (hero) portrait()
    }
}

@Composable
private fun Controls(run: SceneRun, prompt: JSONObject?, assets: Assets) {
    when (prompt?.optString("kind")) {
        "next" -> Row(verticalAlignment = Alignment.CenterVertically) {
            Text("화면을 누르면 이어집니다", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.weight(1f))
            SmallButton("계속", prominent = true, enabled = !run.busy) { run.answer(0) }
        }
        "menu" -> {
            val choices = prompt.optJSONArray("choices")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
                for (i in 0 until (choices?.length() ?: 0)) SmallButton(choices!!.getString(i), prominent = i == 0, enabled = !run.busy) { run.answer(i) }
            }
        }
        "yesNo" -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SmallButton("예", prominent = true, enabled = !run.busy) { run.answer(1) }
            SmallButton("아니오", enabled = !run.busy) { run.answer(0) }
        }
        "duel" -> {
            val d = run.duel
            if (d == null) SmallButton("${prompt.optString("opponentName")}와(과) 결투", prominent = true, enabled = !run.busy) { run.duelStart() }
            else DuelPanel(assets, d) { m -> run.duelMove(m) }
        }
        "ending" -> SmallButton("끝", prominent = true, enabled = !run.busy) { run.answer(0) }
        else -> {}
    }
}
