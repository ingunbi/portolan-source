package app.portolan

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** The one running engine, called from coroutines (one command at a time, in order). */
class EngineHost(private val engine: Engine) {
    var ready = false
        private set

    suspend fun start(): Result<JSONObject> = withContext(Dispatchers.IO) { engine.start().also { ready = it.isSuccess } }

    suspend fun call(cmd: String, vararg args: Pair<String, Any?>): JSONObject = withContext(Dispatchers.IO) {
        val o = JSONObject().put("cmd", cmd)
        for ((k, v) in args) if (v != null) o.put(k, if (v is List<*>) JSONArray(v) else v)
        try { engine.call(o) } catch (e: Exception) { JSONObject().put("ok", false).put("error", e.message ?: "엔진 오류") }
    }
}

/** What the sea screen needs of the engine's report. */
class Fleet(val id: Int, val x: Int, val y: Int, val heading: Int, val nation: Int, val admiral: String, val cls: Int, val near: Boolean)

class Encounter(val enemy: String, val nation: String, val ours: Int, val theirs: Int, val defending: Boolean,
                val merchantOffer: Boolean, val lines: List<String>, val face: Int)

class SeaSnap(val raw: JSONObject) {
    private val j = raw
    val ok = j.optBoolean("ok")
    val x = j.optDouble("x"); val y = j.optDouble("y")
    val heading8 = j.optInt("heading8")
    val speedUnits = j.optInt("speedUnits")
    val year = j.optInt("year"); val month = j.optInt("month"); val day = j.optInt("day"); val tick = j.optInt("tick")
    val gold = j.optInt("gold"); val crew = j.optInt("crew"); val water = j.optInt("water"); val food = j.optInt("food")
    val daysAtSea = j.optInt("daysAtSea")
    val windDir = j.optJSONObject("weather")?.optInt("windDir") ?: 0
    val windStrength = j.optJSONObject("weather")?.optInt("windStrength") ?: 0
    val currentDir = j.optJSONObject("weather")?.optInt("currentDir") ?: 0
    val currentStrength = j.optJSONObject("weather")?.optInt("currentStrength") ?: 0
    val shot = j.optJSONArray("ships")?.optJSONObject(0)?.optInt("shot") ?: 0
    val hull = j.optJSONArray("ships")?.optJSONObject(0)?.optInt("hull") ?: 0
    val guns = j.optJSONArray("ships")?.optJSONObject(0)?.optInt("guns") ?: 0
    val gameOver = j.optString("gameOver")
    val note = j.optString("note")
    /** A sea alarm's three text pages, the notice line, the incident in progress (1 storm, 2 calm, 3 fog) and a running scene. */
    val alarm: List<String> = j.optJSONArray("alarm")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
    val notice = j.optString("notice")
    val sounds: List<String> = j.optJSONArray("sounds")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
    val event = j.optInt("event", 0)
    /** A party is ashore, and a village or the coast can be landed on. */
    val ashore = j.optBoolean("ashore")
    val landable = j.optBoolean("landable")
    val scene: JSONObject? = j.optJSONObject("scene")?.takeIf { !it.optBoolean("done") }
    val fleets: List<Fleet> = j.optJSONArray("fleets")?.let { a ->
        List(a.length()) { i -> a.getJSONObject(i).let { Fleet(it.getInt("id"), it.getInt("x"), it.getInt("y"), it.getInt("heading"), it.getInt("nation"), it.getString("admiral"), it.getInt("class"), it.optBoolean("near")) } }
    } ?: emptyList()
    val encounter: Encounter? = j.optJSONObject("encounter")?.let { e ->
        Encounter(e.getString("enemy"), e.getString("nation"), e.getInt("ours"), e.getInt("theirs"), e.getBoolean("defending"),
            e.getBoolean("merchantOffer"), e.getJSONArray("lines").let { a -> List(a.length()) { a.getString(it) } }, e.optInt("face"))
    }
    val dateText get() = "${year}년 ${month + 1}월 ${day + 1}일"
}

class BUnit(j: JSONObject) {
    val k = j.getInt("k"); val x = j.getInt("x"); val y = j.getInt("y"); val heading = j.getInt("heading")
    val side = j.getInt("side"); val owner = j.getInt("owner"); val flags = j.getInt("flags")
    val hull = j.getInt("hull"); val maxHull = j.getInt("maxHull"); val crew = j.getInt("crew"); val maxCrew = j.getInt("maxCrew")
    val rudder = j.getInt("rudder"); val sails = j.getInt("sails"); val shot = j.getInt("shot")
    val name = j.getString("name"); val alive = j.getBoolean("alive"); val flagship = j.getBoolean("flagship")
    val sailOnly = j.getBoolean("sailOnly"); val player = j.getBoolean("player")
}

class Reach(val cell: Int, val heading: Int, val path: List<Int>)

class BattleSnap(private val j: JSONObject) {
    val ok = j.optBoolean("ok")
    val width = j.optInt("width", 52); val height = j.optInt("height", 48)
    val map: List<Int> = j.optJSONArray("map")?.let { a -> List(a.length()) { a.getInt(it) } } ?: emptyList()
    val units: List<BUnit> = j.optJSONArray("units")?.let { a -> List(a.length()) { BUnit(a.getJSONObject(it)) } } ?: emptyList()
    val active = j.optInt("active", -1)
    val moved = j.optBoolean("moved")
    val phase = j.optString("phase")
    val endCode = j.optInt("endCode")
    val windDir = j.optInt("windDir"); val windStrength = j.optInt("windStrength")
    val tick = j.optInt("tick")
    val log: List<String> = j.optJSONArray("log")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
    val canLeave = j.optBoolean("canLeave")
    val reach: Map<Int, Reach> = j.optJSONArray("reach")?.let { a ->
        (0 until a.length()).map { a.getJSONObject(it) }.associate { r -> r.getInt("cell") to Reach(r.getInt("cell"), r.getInt("heading"), r.getJSONArray("path").let { p -> List(p.length()) { p.getInt(it) } }) }
    } ?: emptyMap()
    private fun ints(k: String): List<Int> = j.optJSONArray(k)?.let { a -> List(a.length()) { a.getInt(it) } } ?: emptyList()
    val targets = ints("targets"); val duelOffered = ints("duelOffered"); val boardable = ints("boardable")
    val strikeSerial = j.optJSONObject("strike")?.optInt("serial") ?: -1
    val strikeTarget = j.optJSONObject("strike")?.optInt("target") ?: -1
    val strikeAttacker = j.optJSONObject("strike")?.optInt("attacker") ?: -1
    val strikeBoarding = j.optJSONObject("strike")?.optBoolean("boarding") ?: false
    val duel: JSONObject? = j.optJSONObject("duel")
    val result: JSONObject? = j.optJSONObject("result")
}
