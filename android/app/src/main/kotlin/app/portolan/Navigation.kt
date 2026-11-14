package app.portolan

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** The sea rules of PortolanCore/Navigation.swift, ported: zone winds, the daily weather roll, fleet speed. */
class ShipClass(val name: String, val oars: Boolean, val sailType: Int, val minCrew: Int, val capacity: Int, val rudder: Int, val sail: Int, val maxCrew: Int)

class NavData(assets: Assets) {
    val sailTable: List<List<Int>>
    val windSummer: List<Int>
    val windWinter: List<Int>
    val current: List<Int>
    val classes: List<ShipClass>

    init {
        val j = assets.json("navigation.json")
        fun ints(a: org.json.JSONArray) = List(a.length()) { a.getInt(it) }
        sailTable = j.getJSONArray("sailTable").let { t -> List(t.length()) { ints(t.getJSONArray(it)) } }
        windSummer = ints(j.getJSONArray("windSummer"))
        windWinter = ints(j.getJSONArray("windWinter"))
        current = ints(j.getJSONArray("current"))
        classes = j.getJSONArray("classes").let { c ->
            List(c.length()) { i ->
                c.getJSONObject(i).let { o ->
                    ShipClass(o.getString("name"), o.getBoolean("oars"), o.getInt("sailType"), o.getInt("minCrew"),
                        o.getInt("capacity"), o.getInt("rudder"), o.getInt("sail"), o.getInt("crewCapacity"))
                }
            }
        }
    }

    companion object {
        const val TICKS_PER_DAY = 72
        const val TILE_UNITS = 60
        const val WEATHER_INTERVAL = 12
        const val ZONE_SIZE = 72
        val DX = intArrayOf(0, 1, 1, 1, 0, -1, -1, -1)
        val DY = intArrayOf(-1, -1, 0, 1, 1, 1, 0, -1)
        /** The sea panel's seconds of play per game day (the remaster clock). */
        const val SECONDS_PER_DAY = 2.4

        /** 72×72-tile zone of WINDCUR.DAT (0x22A0D). */
        fun zone(x: Int, y: Int) = (y / ZONE_SIZE) * 30 + x / ZONE_SIZE
    }
}

class Weather(val windDir: Int, val windStrength: Int, val currentDir: Int, val currentStrength: Int)

/** The player's flagship as far as speed goes. */
class Flagship(var cls: ShipClass, var sail: Int, var rudder: Int, crew: Int, var sailorShare: Int = 100, var load: Int = 0) {
    var crew by androidx.compose.runtime.mutableIntStateOf(crew)
}

class Captain(val navLevel: Int, val seamanship: Int)

/** A small deterministic generator for the weather rolls (the original's own sequence is not copied). */
class Rng(var seed: Long = 1L) {
    fun next(n: Int): Int {
        seed = seed * 6364136223846793005L + 1442695040888963407L
        return (((seed ushr 33).toInt()) and 0x7FFFFFFF) % n
    }
}

object Rules {
    /** Daily roll of the zone wind (0x199EC): strength may rise by one, direction may veer. */
    fun roll(w: Int, c: Int, rng: Rng): Weather {
        val strength = min(7, (w and 7) + rng.next(2))
        val r3 = rng.next(3)
        val r5 = rng.next(5)
        val veer = ((r3 - 1) * (r5 shr 2)) shl 3
        val dir = ((veer + (w and 0xF8)) and 0x38) shr 3
        return Weather(dir, strength, (c shr 3) and 7, c and 7)
    }

    /** Fleet speed in half knots (0x30C2F). */
    fun fleetSpeed(ships: List<Flagship>, captain: Captain, heading: Int, windDir: Int, windStrength: Int, data: NavData): Int {
        val angle = abs(windDir - heading)
        val row = data.sailTable[angle]
        val headwind = angle in 3..5
        var slowest = 200
        var oared = 0
        for (ship in ships) {
            val c = ship.cls
            var wind = windStrength
            if (c.oars) { wind = max(windStrength, 3); oared++ }
            var a = (row[c.sailType] * ship.sail * wind / 150) and 0xFF
            val manned = min(100, ship.sailorShare * ship.crew / c.minCrew)
            a = (manned * a / 100) and 0xFF
            val trim = min(150, -100 * ship.load / c.capacity + 180)
            a = (max(0, trim) * a / 100) and 0xFF
            var s = min(30, captain.navLevel * a / 10 + a)
            s = min(40, captain.seamanship * s / 75)
            if (headwind) s = ship.rudder * s / 100
            slowest = min(slowest, s)
        }
        slowest = max(2, slowest)
        if (windStrength == 0 && oared == 0) return 0          // becalmed without oars
        return slowest
    }
}
