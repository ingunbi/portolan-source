package app.portolan

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Everything the harbour windows work on. */
class GameState(val nav: NavData, val voyage: VoyageState) {
    /** The fleet has a ship (a new game starts with none until the story hands one over). */
    var hasShip by androidx.compose.runtime.mutableStateOf(true)
    val wallet = Wallet()
    /** The bank balance (negative: a debt) and the captain's luck, as the engine keeps them. */
    var bank by androidx.compose.runtime.mutableIntStateOf(0)
    var luck by androidx.compose.runtime.mutableIntStateOf(0)
    /** A new game: the opening date, purse, stores and untouched markets. */
    fun reset() {
        val v = voyage
        v.year = 1522; v.month = 4; v.dayOfMonth = 16; v.tick = 24; v.daysAtSea = 0; v.summerWinds = false
        v.water = 260; v.food = 80; v.ships[0].crew = 15; v.heading8 = 2
        wallet.gold = 300; wallet.lumber = 0; wallet.shot = 0; wallet.guns = 0
        refreshLoad()
    }

    /** The hold's weight for the speed rule. */
    fun refreshLoad() { }
}

@Composable
fun BuildingPanel(game: GameState, host: EngineHost, assets: Assets, port: Int, portName: String, building: String, entry: org.json.JSONObject?, onEnding: (Int) -> Unit,
                  leave: () -> Unit, setSail: () -> Unit) {
    val scope = rememberCoroutineScope()
    DisposableEffect(building) {
        Sound.building(when (building) { "주점" -> 19; "왕궁" -> 18; else -> null })
        onDispose { Sound.building(null); Sound.scene(null) }
    }
    val sceneRun = remember(building) { SceneRun(host, game, scope).also { it.onEnding = onEnding } }
    val clerk = remember(building) {
        Clerk(host, game, scope).also { c ->
            c.scenes = sceneRun
            sceneRun.onAfter = { j -> c.take(j, fromScene = true) }
            entry?.let { c.take(it, fromScene = true) }
        }
    }
    // The windows full of lists and forms use the whole screen; the short ones (bank, church, inn ...) are as tall as their content.
    val tall = building in setOf("교역소", "주점", "항구", "조선소")
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.72f)).clickable(enabled = false) {}) {
        Column(
            Modifier.align(if (tall) Alignment.Center else Alignment.TopCenter)
                .then(if (tall) Modifier.fillMaxHeight(0.92f) else Modifier.padding(top = 32.dp).heightIn(min = 400.dp, max = maxHeight * 0.92f))
                .fillMaxWidth(0.9f).widthIn(max = 1240.dp)
                .clip(RoundedCornerShape(20.dp)).background(NavyLight).padding(24.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(building, color = Gold, fontSize = 28.sp, fontWeight = FontWeight.Bold)
                    Text("$portName · ${game.voyage.dateText}", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                }
                Text("금화 ${game.wallet.gold}", color = Gold, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(20.dp))
                GoldButton("나가기", onClick = leave)
            }
            Spacer(Modifier.height(16.dp))
            val engine = host.ready
            when {
                building == "교역소" && !game.hasShip -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("싣고 다닐 배가 아직 없습니다.", color = Color.White, fontSize = 20.sp)
                }
                building == "교역소" && engine -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(Modifier.weight(1f)) { TradePanel(remember { TradeSession(host, game, scope) }, game) }
                    InvestBox(clerk)
                }
                building == "주점" && engine -> TavernPanel(clerk, assets, remember { EngineState(host, game, scope, "gamble") })
                building == "항구" && engine -> HarborPanel(remember { EngineState(host, game, scope, "harbor") }, clerk, game, setSail)
                !engine -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("$building 안은 엔진이 있어야 열립니다.", color = Color.White, fontSize = 20.sp)
                }
                building == "조선소" -> ShipyardPanel(remember { Yard(host, game, scope) }, assets, clerk, game)
                building == "은행" -> BankPanel(clerk, game)
                building == "교회" -> ChurchPanel(clerk, game)
                building == "점술가" -> FortunePanel(clerk)
                building == "NPC" -> ResidencePanel(clerk, assets)
                building == "아이템" -> ItemShopPanel(clerk)
                building == "여관" -> InnPanel(clerk, assets)
                building == "조합" -> GuildPanel(clerk)
                building == "왕궁" -> PalacePanel(clerk, assets)
                else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("$building 안에는 볼일이 없습니다.", color = Color.White, fontSize = 20.sp)
                }
            }
        }
        SceneOverlay(sceneRun, assets)
    }
}

@Composable
private fun Chip(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    Box(Modifier.clip(RoundedCornerShape(12.dp)).background(if (enabled) Gold.copy(alpha = 0.9f) else Color.White.copy(alpha = 0.12f))
        .clickable(enabled = enabled, onClick = onClick).defaultMinSize(minWidth = UiSize.Touch, minHeight = UiSize.Touch).padding(horizontal = 18.dp, vertical = 10.dp), contentAlignment = Alignment.Center) {
        Text(text, color = if (enabled) Color.Black.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.35f), fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
    }
}
