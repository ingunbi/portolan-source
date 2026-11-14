package app.portolan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONArray
import org.json.JSONObject

// The information screens that need pictures: 적하일람, 발견물정보, 항해도, 항해일지, 항구지도, the treasure map,
// and the residence of a story character (building 7). The engine reports the figures and the grids.

private val ChartSea = Color(0xFFFFCCAA)
private val ChartLand = Color(0xFFAA8866)
private val ChartFog = Color(0xFFDDAA88)

private fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else List(length()) { getJSONObject(it) }
private fun JSONArray?.ints(): List<Int> = if (this == null) emptyList() else List(length()) { getInt(it) }
private fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else List(length()) { getString(it) }

@Composable
private fun InfoLine(text: String, size: Int = 16, color: Color = Color.White, weight: FontWeight = FontWeight.Normal) =
    Text(text, color = color, fontSize = size.sp, fontWeight = weight)

/** 적하일람: every good aboard; touching one asks the bookkeeper where it sells best (the answer is the sheet's note). */
@Composable
fun CargoListInfo(info: JSONObject?, st: EngineState) {
    val c = info?.optJSONArray("cargo").objs()
    if (c.isEmpty()) { InfoLine(info?.optString("noCargo").orEmpty()); return }
    InfoLine("교역품을 누르면 가장 비싸게 팔리는 항구를 알려 줍니다.", 14, Color.White.copy(alpha = 0.6f))
    Column(Modifier.clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        for (x in c) Row(Modifier.fillMaxWidth().clickable(enabled = !st.busy) { st.post("info_advise", "good" to x.getInt("good")) }.padding(vertical = 6.dp)) {
            Text(x.optString("name"), color = Color.White, fontSize = 18.sp, modifier = Modifier.width(180.dp))
            Text("${x.optInt("amount")}", color = Gold, fontSize = 18.sp)
        }
    }
}

/** 발견물정보: the sites found, with the picture and the description of the one picked. */
@Composable
fun DiscoveryInfo(info: JSONObject?, assets: Assets) {
    val sites = info?.optJSONArray("sites").objs()
    if (sites.isEmpty()) { InfoLine("아직 발견한 것이 없습니다."); return }
    var pick by remember { mutableIntStateOf(-1) }
    Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        Column(Modifier.width(230.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            for ((i, s) in sites.withIndex())
                Text(s.optString("name"), color = if (pick == i) Gold else Color.White, fontSize = 18.sp,
                    modifier = Modifier.fillMaxWidth().clickable { pick = i }.padding(vertical = 7.dp))
        }
        sites.getOrNull(pick)?.let { d ->
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val pic = assets.image("pictures/%03d.png".format(d.optInt("picture")))
                if (pic != null) Canvas(Modifier.size(144.dp).clip(RoundedCornerShape(4.dp))) { pixels(pic, 0f, 0f, size.width, size.height) }
                InfoLine(d.optString("name"), 22, weight = FontWeight.Bold)
                InfoLine("（${d.optString("category")}）  중요도${d.optString("grade")}", 15, Color.White.copy(alpha = 0.7f))
                InfoLine(d.optString("text"), 16)
            }
        }
    }
}

private fun explored(chart: List<String>, col: Int, row: Int): Boolean {
    if (row !in 0 until 45 || row >= chart.size) return false
    return chart[row].getOrNull(((col % 90) + 90) % 90) == '1'
}

/** 항해도: the chart picture with the unexplored cells veiled and the fleet marked; an explored cell opens the zoom. */
@Composable
fun ChartInfo(info: JSONObject?, assets: Assets, onZoom: (col: Int, row: Int) -> Unit) {
    val chart = info?.optJSONArray("chart").strings()
    if (info == null || (info.optInt("charted") <= 0)) { InfoLine("아직 탐험한 해역이 없습니다."); return }
    val img = assets.image("images/chart.png")
    val cell = info.optJSONArray("fleetCell").ints()
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val w = minOf(maxWidth, 900.dp)
        Canvas(Modifier.size(w, w * 400f / 640f).pointerInput(chart) {
            detectTapGestures { p ->
                val scale = size.width / 640f
                val dc = ((p.x / scale - 50) / 6).toInt()
                val row = ((p.y / scale - 50) / 6).toInt()
                if (dc in 0 until 90 && row in 0 until 45) {
                    val col = (dc - 30 + 90) % 90
                    var any = false
                    for (dx in 0..1) for (dy in 0..1) if (explored(chart, col + dx, row + dy)) any = true
                    if (any) onZoom(col, row)
                }
            }
        }) {
            val scale = size.width / 640f
            if (img != null) pixels(img, 0f, 0f, size.width, size.height)
            for (row in 0 until 45) for (col in 0 until 90) if (!explored(chart, col, row)) {
                val dc = (col + 30) % 90
                drawRect(ChartFog, Offset((50 + 6f * dc) * scale, (50 + 6f * row) * scale), Size(6f * scale + 0.5f, 6f * scale + 0.5f))
            }
            if (cell.size == 2) drawRect(Color.Red, Offset(cell[0] * scale, cell[1] * scale), Size(6f * scale, 6f * scale))
        }
    }
    InfoLine("탐험한 해역을 누르면 확대합니다.", 14, Color.White.copy(alpha = 0.6f))
}

/** The four chart cells around a point (the chart's zoom, the treasure map): 48×48 tiles, land and sea, and a red cross. */
@Composable
fun ZoomView(zoom: JSONObject) {
    val grid = zoom.optJSONArray("grid").strings()
    val mark = zoom.optJSONArray("mark").ints()
    Canvas(Modifier.size(384.dp).clip(RoundedCornerShape(4.dp))) {
        val c = size.width / 48f
        drawRect(ChartSea)
        for ((y, row) in grid.withIndex()) for ((x, ch) in row.withIndex()) if (ch == '1')
            drawRect(ChartLand, Offset(x * c, y * c), Size(c + 0.5f, c + 0.5f))
        if (mark.size == 2) {
            val a = Offset((mark[0] - 0.75f) * c, (mark[1] - 0.75f) * c)
            val b = Offset((mark[0] + 2.75f) * c, (mark[1] + 2.75f) * c)
            drawLine(Color.Red, a, b, strokeWidth = c * 0.5f)
            drawLine(Color.Red, Offset(b.x, a.y), Offset(a.x, b.y), strokeWidth = c * 0.5f)
        }
    }
}

/** 항해일지: six lines a page, opening on the last page. */
@Composable
fun LogbookInfo(info: JSONObject?) {
    val log = info?.optJSONArray("log").objs()
    if (log.isEmpty()) { InfoLine("항해일지에 아직 적힌 것이 없습니다."); return }
    val last = (log.size - 1) / 6
    var page by remember(log.size) { mutableIntStateOf(last) }
    val p = page.coerceIn(0, last)
    Column(Modifier.heightIn(min = 280.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        for (k in log.indices.filter { it / 6 == p }) Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            InfoLine(log[k].optString("date"), 16, Color.White.copy(alpha = 0.6f))
            InfoLine(log[k].optString("text"), 17)
        }
    }
    Row(Modifier.fillMaxWidth()) {
        if (p > 0) SmallButton(info?.optString("logPrev").orEmpty().ifEmpty { "이전" }) { page = p - 1 }
        Spacer(Modifier.weight(1f))
        if (p < last) SmallButton(info?.optString("logNext").orEmpty().ifEmpty { "다음" }) { page = p + 1 }
    }
}

private val buildingKeys = listOf("교역소", "주점", "조선소", "항구", "여관", "왕궁", "조합", "NPC", "은행", "아이템", "교회", "점술가")

/** 항구지도: the town map with the building names over their doors. */
@Composable
fun PortMapInfo(info: JSONObject?, assets: Assets) {
    val town = assets.towns[info?.optInt("port", -1) ?: -1]
    val img = town?.let { assets.image("portmaps/%03d.png".format(it.map)) }
    if (town == null || img == null) { InfoLine("이 항구의 지도는 없습니다."); return }
    val names = info?.optJSONArray("buildingNames").strings()
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val side = minOf(maxWidth, 640.dp)
        val sidePx = with(LocalDensity.current) { side.toPx() }
        val scale = sidePx / 1536f
        Box(Modifier.size(side).clipToBounds()) {
            Canvas(Modifier.fillMaxSize()) { pixels(img, 0f, 0f, size.width, size.height) }
            for ((k, key) in buildingKeys.withIndex()) {
                val d = town.doors[key] ?: continue
                if (k == 7) continue
                val label = names.getOrNull(k)?.takeIf { it.isNotEmpty() } ?: key
                val x = (d.first * 16 + 16) * scale
                val y = (d.second * 16 - 10) * scale
                Text(label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.layout { m, c ->
                        val p = m.measure(c)
                        layout(p.width, p.height) { p.place((x - p.width / 2f).toInt(), (y - p.height / 2f).toInt()) }
                    }.background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(3.dp)).padding(horizontal = 3.dp))
            }
        }
    }
}

/** The residence (building 7): a patron, a map maker or a scholar of a skill. */
@Composable
fun ResidencePanel(clerk: Clerk, assets: Assets) {
    val r = clerk.panel?.optJSONObject("residence")
    var picture by remember { mutableStateOf<String?>(null) }
    DisposableEffect(Unit) {
        clerk.onFlag = { j -> picture = if (j.has("picture")) j.getString("picture") else null }
        onDispose { clerk.onFlag = null }
    }
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (r == null) { InfoLine("…"); TalkBox(clerk); return@Column }
        if (r.has("none")) { InfoLine(r.optString("none"), 18); TalkBox(clerk); return@Column }
        val type = r.optInt("type")
        val contracted = r.optBoolean("contracted")
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            val face = assets.image("portraits/%03d.png".format(r.optInt("portrait")))
            if (face != null) Canvas(Modifier.size(64.dp, 80.dp).clip(RoundedCornerShape(6.dp))) { pixels(face, 0f, 0f, size.width, size.height) }
            InfoLine(r.optString("name"), 22, Gold, FontWeight.Bold)
        }
        @OptIn(ExperimentalLayoutApi::class)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (type <= 1) SmallButton(if (contracted) "계약 중" else "계약", enabled = !contracted && !clerk.waiting) { clerk.act("residence.contract") }
            if (type == 0) {
                SmallButton("발견물보고", enabled = contracted && !clerk.waiting) { clerk.act("residence.report") }
                SmallButton("모험이야기", enabled = !clerk.waiting) { clerk.act("residence.rumour") }
            }
            if (type == 1) {
                SmallButton("지리보고", enabled = contracted && !clerk.waiting) { clerk.act("residence.report") }
                SmallButton("지도확인", enabled = r.optBoolean("hasMap") && !clerk.waiting) { clerk.act("residence.map") }
            }
            r.optJSONObject("skill")?.let { s ->
                SmallButton("${s.optString("name")} 습득 · 금화 ${s.optInt("fee")}닢", enabled = !s.optBoolean("has") && !clerk.waiting) { clerk.act("residence.learn") }
            }
        }
        TalkBox(clerk)
        picture?.let { path ->
            val img = assets.image(path)
            if (img != null) Canvas(Modifier.widthIn(max = 480.dp).fillMaxWidth().aspectRatio(img.width.toFloat() / img.height)) { pixels(img, 0f, 0f, size.width, size.height) }
        }
    }
}
