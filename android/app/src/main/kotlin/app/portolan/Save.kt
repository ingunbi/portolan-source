package app.portolan

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** One save slot, kept in the app's private storage (the voyage, the purse and every market's prices). */
class SaveStore(private val context: Context, private val game: GameState) {
    private val prefs get() = context.getSharedPreferences("portolan", Context.MODE_PRIVATE)

    val hasSave get() = prefs.contains("save")

    /** The engine keeps its own half of the game (ships, items, bank, the world's fleets); these carry it to and from a file. */
    var onWrite: (() -> Unit)? = null
    var onRead: (() -> Unit)? = null

    fun write(hero: Int, port: Int, inSea: Boolean) {
        val v = game.voyage
        val w = game.wallet
        val o = JSONObject()
        o.put("hero", hero); o.put("port", port); o.put("inSea", inSea)
        o.put("x", v.x); o.put("y", v.y); o.put("heading", v.heading8)
        o.put("year", v.year); o.put("month", v.month); o.put("day", v.dayOfMonth); o.put("tick", v.tick)
        o.put("daysAtSea", v.daysAtSea); o.put("summer", v.summerWinds)
        o.put("water", v.water); o.put("food", v.food); o.put("crew", v.ships[0].crew)
        o.put("gold", w.gold); o.put("lumber", w.lumber); o.put("shot", w.shot); o.put("guns", w.guns)
        prefs.edit().putString("save", o.toString()).apply()
        onWrite?.invoke()
    }

    /** Restores the state and returns (hero, port, inSea), or null. */
    fun read(): Triple<Int, Int, Boolean>? {
        val s = prefs.getString("save", null) ?: return null
        onRead?.invoke()
        return try {
            val o = JSONObject(s)
            val v = game.voyage
            val w = game.wallet
            v.x = o.getDouble("x"); v.y = o.getDouble("y"); v.heading8 = o.getInt("heading")
            v.year = o.getInt("year"); v.month = o.getInt("month"); v.dayOfMonth = o.getInt("day"); v.tick = o.getInt("tick")
            v.daysAtSea = o.getInt("daysAtSea"); v.summerWinds = o.getBoolean("summer")
            v.water = o.getInt("water"); v.food = o.getInt("food"); v.ships[0].crew = o.getInt("crew")
            w.gold = o.getInt("gold"); w.lumber = o.getInt("lumber"); w.shot = o.getInt("shot"); w.guns = o.optInt("guns", 0)
            Triple(o.getInt("hero"), o.getInt("port"), o.getBoolean("inSea"))
        } catch (e: Exception) { null }
    }

    fun clear() = prefs.edit().remove("save").apply()
}
