package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

val Navy = Color(0xFF0A1220)
val NavyLight = Color(0xFF1B2942)
val Gold = Color(0xFFE8B557)

fun DrawScope.pixels(img: ImageBitmap, x: Float, y: Float, w: Float, h: Float) {
    drawImage(img, srcOffset = IntOffset.Zero, srcSize = IntSize(img.width, img.height),
        dstOffset = IntOffset(x.toInt(), y.toInt()), dstSize = IntSize(w.toInt(), h.toInt()), filterQuality = FilterQuality.None)
}

enum class Screen { Title, Heroes, Town, Sea }

@Composable
fun GameApp(assets: Assets) {
    var screen by remember { mutableStateOf(Screen.Title) }
    var hero by remember { mutableIntStateOf(0) }
    var ending by remember { mutableStateOf<Int?>(null) }
    var port by remember { mutableIntStateOf(0) }
    val world = remember { SeaWorld(assets) }
    val nav = remember { NavData(assets) }
    val voyage = remember { VoyageState(nav) }
    val game = remember { GameState(nav, voyage) }
    val store = remember { SaveStore(assets.context, game) }
    val host = remember { EngineHost(Engine(assets.context)) }
    val scope = rememberCoroutineScope()
    val enginePath = remember { java.io.File(assets.context.filesDir, "engine-save.json").absolutePath }
    remember {
        store.onWrite = { if (host.ready) scope.launch { host.call("save", "path" to enginePath) } }
        store.onRead = { if (host.ready) kotlinx.coroutines.runBlocking { host.call("load", "path" to enginePath) } }
    }
    remember { Sound.init(assets.context) }
    LaunchedEffect(screen, hero) {
        Sound.building(null); Sound.scene(null)
        when (screen) {
            Screen.Title, Screen.Heroes -> Sound.base(3)
            Screen.Sea -> Sound.base(Sound.seaSong(hero))
            Screen.Town -> {}                                   // the port's song comes with the docking
        }
    }
    var engineLine by remember { mutableStateOf("엔진 시작 중…") }
    var heroInfo by remember { mutableStateOf<org.json.JSONObject?>(null) }
    LaunchedEffect(screen, engineLine) {
        if (screen == Screen.Heroes && host.ready && heroInfo == null) heroInfo = host.call("hero_info")
    }
    LaunchedEffect(Unit) {
        engineLine = host.start().fold(
            onSuccess = { g -> host.call("new", "seed" to 1).let { r -> "엔진 연결됨 · 항구 ${g.optInt("ports")}곳 · ${r.optString("captain")} ${r.optInt("year")}년 ${r.optInt("month") + 1}월" } },
            onFailure = { "엔진 오류: ${it.message}" }
        )
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (screen) {
            Screen.Title -> TitleScreen(assets, engineLine, canContinue = store.hasSave, newGame = { store.clear(); game.reset(); if (host.ready) scope.launch { host.call("new", "seed" to (System.nanoTime() and 0x7FFFFFFF).toInt()) }; screen = Screen.Heroes }) {
                store.read()?.let { (h, p, sea) -> hero = h; port = p; screen = if (sea) Screen.Sea else Screen.Town }
            }
            Screen.Heroes -> HeroScreen(assets, heroInfo, back = { screen = Screen.Title }) { h, given, family ->
                scope.launch {
                    var start = 0
                    if (host.ready) {
                        val j = host.call("new", "hero" to h, "given" to given, "family" to family, "seed" to (System.nanoTime() and 0x7FFFFFFF).toInt())
                        applyWallet(j.optJSONObject("wallet"), game)
                        start = j.optInt("port")
                    }
                    hero = h; port = start; screen = Screen.Town
                }
            }
            Screen.Town -> key(port) {
                TownScreen(assets, game, host, hero, port, title = { store.write(hero, port, false); screen = Screen.Title }, onEnding = { ending = it }) {
                    // 출항: out of the harbour onto the sea at that port.
                    world.ports.firstOrNull { it.id == port }?.let { p -> world.berth(p).let { (x, y) -> voyage.x = x; voyage.y = y } }
                    screen = Screen.Sea
                    store.write(hero, port, true)
                }
            }
            Screen.Sea -> SeaScreen(assets, world, game, host, hero, dock = { p -> port = p.id; store.write(hero, p.id, false); screen = Screen.Town }, title = { store.write(hero, port, true); screen = Screen.Title }, over = { store.clear(); screen = Screen.Title })
        }
        ending?.let { code -> EndingScreen(assets, host, code) { store.write(hero, port, false); ending = null; screen = Screen.Title } }
    }
}

@Composable
fun GoldButton(text: String, modifier: Modifier = Modifier, prominent: Boolean = false, onClick: () -> Unit) {
    Box(
        modifier.clip(RoundedCornerShape(12.dp))
            .background(if (prominent) Gold else NavyLight.copy(alpha = 0.92f))
            .clickable(onClick = onClick).defaultMinSize(minHeight = 56.dp).padding(horizontal = 22.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, color = if (prominent) Color.Black.copy(alpha = 0.85f) else Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun TitleScreen(assets: Assets, engineLine: String, canContinue: Boolean, newGame: () -> Unit, resume: () -> Unit) {
    val pan = assets.image("opening/pan_ships_0.png")
    val logo = assets.image("opening/op00_10.png")
    Box(Modifier.fillMaxSize().background(Navy)) {
        Canvas(Modifier.fillMaxSize()) {
            if (pan != null) {
                val h = size.height * 0.46f
                val w = h * pan.width / pan.height
                val top = size.height * 0.2f
                pixels(pan, (size.width - w) / 2f, top, w, h)
            }
        }
        Column(Modifier.fillMaxSize().padding(top = 24.dp, bottom = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Canvas(Modifier.width(420.dp).height(84.dp)) {
                if (logo != null) pixels(logo, 0f, 0f, size.width, size.height)
            }
            Spacer(Modifier.weight(1f))
            if (canContinue) {
                GoldButton("이어하기", Modifier.width(280.dp), prominent = true, onClick = resume)
                Spacer(Modifier.height(12.dp))
                GoldButton("새 게임", Modifier.width(280.dp), onClick = newGame)
            } else {
                GoldButton("새 게임", Modifier.width(280.dp), prominent = true, onClick = newGame)
            }
            Spacer(Modifier.height(16.dp))
            Text("Portolan · 오픈소스 엔진 (Android 시험판)", color = Color.White.copy(alpha = 0.5f), fontSize = 14.sp)
            Text(engineLine, color = Gold.copy(alpha = 0.8f), fontSize = 14.sp)
        }
        SoundSettings(Modifier.align(Alignment.TopEnd).padding(20.dp))
    }
}

/** Sound on or off and the volume in tens, kept by [Sound]. */
@Composable
fun SoundSettings(modifier: Modifier = Modifier) {
    var on by remember { mutableStateOf(Sound.enabled) }
    var vol by remember { mutableIntStateOf(Math.round(Sound.volume * 10)) }
    Row(modifier.clip(RoundedCornerShape(12.dp)).background(NavyLight.copy(alpha = 0.85f)).padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("소리", color = Color.White, fontSize = 16.sp)
        SmallButton(if (on) "켬" else "끔", prominent = on) { on = !on; Sound.enabled = on }
        SmallButton("−", enabled = on && vol > 0) { vol -= 1; Sound.volume = vol / 10f }
        Text("${vol * 10}%", color = Color.White, fontSize = 16.sp, modifier = Modifier.width(48.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        SmallButton("+", enabled = on && vol < 10) { vol += 1; Sound.volume = vol / 10f }
    }
}

val heroNames = listOf("조안 페레로", "카탈리나 에란초", "옷토 스피노라", "에르네스트 로페스", "피에트로 콘티", "알 베자스")

@Composable
fun HeroScreen(assets: Assets, info: org.json.JSONObject?, back: () -> Unit, pick: (Int, String?, String?) -> Unit) {
    val heroes = info?.optJSONArray("heroes")?.let { a -> List(a.length()) { a.getJSONObject(it) } } ?: emptyList()
    var hero by remember { mutableStateOf<Int?>(null) }
    var naming by remember { mutableStateOf(false) }
    var given by remember { mutableStateOf("") }
    var family by remember { mutableStateOf("") }
    fun choose(h: Int) {
        hero = h; naming = false
        heroes.getOrNull(h)?.let { given = it.optString("given"); family = it.optString("family") }
    }
    Column(Modifier.fillMaxSize().background(Navy).padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("주인공을 선택해 주세요", color = Gold, fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(18.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            for (h in 0 until 6) {
                val img = assets.image("portraits/%03d.png".format(h))
                val on = hero == h
                Column(Modifier.clip(RoundedCornerShape(12.dp)).background(if (on) Gold.copy(alpha = 0.25f) else NavyLight).clickable {
                    if (heroes.isEmpty()) pick(h, null, null) else choose(h)
                }.padding(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Canvas(Modifier.size(84.dp, 105.dp)) { if (img != null) pixels(img, 0f, 0f, size.width, size.height) }
                    Spacer(Modifier.height(6.dp))
                    Text(heroes.getOrNull(h)?.optString("name") ?: heroNames[h], color = if (on) Gold else Color.White, fontSize = 14.sp,
                        fontWeight = if (on) FontWeight.Bold else FontWeight.Normal)
                }
            }
        }
        Spacer(Modifier.height(14.dp))
        Column(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Color.White.copy(alpha = 0.06f)).padding(18.dp)
            .verticalScroll(androidx.compose.foundation.rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            val h = hero?.let { heroes.getOrNull(it) }
            if (h == null) {
                Text("초상화를 선택하면 인물의 이야기와 능력치를 볼 수 있습니다.", color = Color.White.copy(alpha = 0.85f), fontSize = 18.sp)
            } else {
                if (naming) {
                    Text(info?.optString("rename").orEmpty(), color = Color.White.copy(alpha = 0.85f), fontSize = 18.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("이름", color = Color.White, fontSize = 18.sp)
                        NameField(given, 160) { given = it }
                        Text("성", color = Color.White, fontSize = 18.sp)
                        NameField(family, 160) { family = it }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(32.dp)) {
                    Column(Modifier.width(300.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(h.optString("name"), color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                        Text("${h.optInt("age")}세 · 기술 ${h.optString("skill")}", color = Color.White.copy(alpha = 0.8f), fontSize = 18.sp)
                        val stats = h.optJSONArray("stats")
                        val names = info?.optJSONArray("statNames")
                        for (r in 0 until 4) Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                            for (k in listOf(r, r + 4)) if (k < 7) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(names?.optString(k).orEmpty(), color = Color.White.copy(alpha = 0.8f), fontSize = 18.sp, modifier = Modifier.width(58.dp))
                                Text("${stats?.optInt(k) ?: 0}", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                    Text(h.optString("story"), color = Color.White.copy(alpha = 0.95f), fontSize = 18.sp, lineHeight = 26.sp, modifier = Modifier.weight(1f))
                }
            }
        }
        Spacer(Modifier.height(14.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            GoldButton("돌아가기", onClick = back)
            Spacer(Modifier.weight(1f))
            val h = hero
            if (h != null) {
                Text(if (naming) info?.optString("allGood").orEmpty() else info?.optString("ask").orEmpty(), color = Color.White, fontSize = 18.sp)
                GoldButton("예", prominent = true) {
                    if (naming) pick(h, given.take(6), family.take(6)) else naming = true
                }
                GoldButton("아니오") { if (naming) choose(h) else hero = null }
            }
        }
    }
}

@Composable
private fun NameField(value: String, width: Int, set: (String) -> Unit) {
    androidx.compose.foundation.text.BasicTextField(value, { set(it.take(6)) },
        textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 20.sp),
        cursorBrush = androidx.compose.ui.graphics.SolidColor(Gold), singleLine = true,
        modifier = Modifier.width(width.dp).clip(RoundedCornerShape(10.dp))
            .border(1.dp, Gold.copy(alpha = 0.6f), RoundedCornerShape(10.dp)).padding(12.dp))
}
