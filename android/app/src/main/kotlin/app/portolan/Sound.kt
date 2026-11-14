package app.portolan

import android.content.Context
import android.content.res.AssetManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import org.json.JSONObject

/**
 * The original songs (assets/music, addressed by the game's own music index) and the eight sound
 * effects (assets/sfx). Songs loop between their loop marks. There is one effect channel: a new
 * effect cuts the one sounding. Music has three layers: the screen's (base), the building's and a
 * running scene's; the topmost one plays.
 */
object Sound {
    private class Song(val file: String, val loopStart: Double?, val loopEnd: Double?)

    private var assets: AssetManager? = null
    private var songs = mapOf<Int, Song>()
    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var playing: Int? = null
    private var loopTick: Runnable? = null
    private var sfxPlayer: MediaPlayer? = null
    private var sfxName: String? = null
    private var sfxCut: Runnable? = null
    private var stormLoop: Runnable? = null
    private val queued = mutableListOf<Runnable>()

    private var prefs: android.content.SharedPreferences? = null
    private var on = true
    private var vol = 0.6f

    /** Sound on or off, and the volume (0–1): both are kept between sessions. */
    var enabled: Boolean
        get() = on
        set(v) { on = v; save(); if (!v) { stopMusic(); stopEffects() } else apply() }
    var volume: Float
        get() = vol
        set(v) { vol = v.coerceIn(0f, 1f); save(); player?.setVolume(vol, vol); sfxPlayer?.setVolume(vol, vol) }

    private fun save() { prefs?.edit()?.putBoolean("enabled", on)?.putFloat("volume", vol)?.apply() }

    private var base: Int? = null
    private var building: Int? = null
    private var scene: Int? = null
    /** The victory fanfare plays once, then the victory song (0x1040D). */
    const val FANFARE = 21
    var onFinished: ((Int) -> Unit)? = null

    fun init(context: Context) {
        if (assets != null) return
        assets = context.applicationContext.assets
        prefs = context.applicationContext.getSharedPreferences("sound", Context.MODE_PRIVATE)
        on = prefs!!.getBoolean("enabled", true)
        vol = prefs!!.getFloat("volume", 0.6f)
        try {
            val text = assets!!.open("music/index.json").bufferedReader().use { it.readText() }
            val arr = JSONObject(text).getJSONArray("songs")
            songs = (0 until arr.length()).map { arr.getJSONObject(it) }.associate { s ->
                s.getInt("gameIndex") to Song(s.getString("file"), if (s.isNull("loopStart")) null else s.getDouble("loopStart"),
                    if (s.isNull("loopEnd")) null else s.getDouble("loopEnd"))
            }
        } catch (_: Exception) { songs = emptyMap() }
    }

    // ---- music layers ----

    fun base(index: Int?) { base = index; apply() }
    fun building(index: Int?) { building = index; apply() }
    fun scene(index: Int?) { scene = index?.takeIf { it >= 0 }; apply() }

    private fun apply() = play(scene ?: building ?: base)

    /** Plays game music [index] unless it is already playing. */
    fun play(index: Int?) {
        if (!enabled) { stopMusic(); return }
        if (index == playing && player != null) return
        stopMusic()
        playing = index
        val s = index?.let { songs[it] } ?: return
        val a = assets ?: return
        try {
            val fd = a.openFd("music/${s.file}")
            val p = MediaPlayer()
            p.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
            fd.close()
            p.setVolume(volume, volume)
            p.prepare()
            p.start()
            player = p
            if (index == FANFARE) {
                p.setOnCompletionListener { onFinished?.invoke(FANFARE) }
            } else if (s.loopStart != null && s.loopEnd != null) {
                val start = (s.loopStart * 1000).toInt(); val end = (s.loopEnd * 1000).toInt()
                val r = object : Runnable {
                    override fun run() {
                        val q = player ?: return
                        try {
                            val at = q.currentPosition
                            if (at >= end) q.seekTo((start + (at - end)).toLong(), MediaPlayer.SEEK_CLOSEST)
                        } catch (_: Exception) {}
                        handler.postDelayed(this, 30)
                    }
                }
                loopTick = r
                handler.postDelayed(r, 30)
            } else p.isLooping = true
        } catch (_: Exception) { player = null }
    }

    private fun stopMusic() {
        loopTick?.let { handler.removeCallbacks(it) }
        loopTick = null
        try { player?.stop() } catch (_: Exception) {}
        player?.release()
        player = null
        playing = null
    }

    /** Called when the app goes to the background and comes back. */
    fun pause() { try { player?.pause() } catch (_: Exception) {}; try { sfxPlayer?.pause() } catch (_: Exception) {} }
    fun resume() { if (enabled) { try { player?.start() } catch (_: Exception) {} } }

    // ---- effects ----

    /** Plays [name] after [delayMs], cut after [cutMs] when given (0x96DE). */
    fun sfx(name: String, delayMs: Long = 0, cutMs: Long? = null) {
        if (!enabled) return
        val r = Runnable { startEffect(name, cutMs) }
        queued += r
        handler.postDelayed(r, delayMs)
    }

    private fun startEffect(name: String, cutMs: Long?) {
        if (!enabled) return
        val a = assets ?: return
        haltEffect()
        try {
            val fd = a.openFd("sfx/$name.wav")
            val p = MediaPlayer()
            p.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
            fd.close()
            p.setVolume(volume, volume)
            p.prepare()
            p.start()
            sfxPlayer = p; sfxName = name
            if (cutMs != null) { val c = Runnable { haltEffect() }; sfxCut = c; handler.postDelayed(c, cutMs) }
            if (name == "storm") {
                // storm.wav is an intro and a seamless loop (index.json loopStart / loopEnd).
                val l = object : Runnable {
                    override fun run() {
                        val q = sfxPlayer ?: return
                        try { val at = q.currentPosition; if (at >= 16467) q.seekTo((1201 + (at - 16467)).toLong(), MediaPlayer.SEEK_CLOSEST) } catch (_: Exception) {}
                        handler.postDelayed(this, 30)
                    }
                }
                stormLoop = l
                handler.postDelayed(l, 30)
            }
        } catch (_: Exception) { sfxPlayer = null; sfxName = null }
    }

    private fun haltEffect() {
        sfxCut?.let { handler.removeCallbacks(it) }; sfxCut = null
        stormLoop?.let { handler.removeCallbacks(it) }; stormLoop = null
        try { sfxPlayer?.stop() } catch (_: Exception) {}
        sfxPlayer?.release()
        sfxPlayer = null; sfxName = null
    }

    fun stopEffects() {
        queued.forEach { handler.removeCallbacks(it) }
        queued.clear()
        haltEffect()
    }

    /** The storm voice is held while [on]; it comes back after another effect has finished. */
    fun storm(on: Boolean) {
        if (on) {
            if (!enabled || sfxName == "storm" || sfxPlayer?.isPlaying == true) return
            startEffect("storm", null)
        } else if (sfxName == "storm") haltEffect()
    }

    fun cue(name: String) = sfx(name, 0, if (name == "level_up") 331 else null)

    /** One volley: the shot leaves and lands (0xC636, 0xCB72); boarding is muted after 48 ticks (0xD0D9). */
    fun strike(boarding: Boolean) {
        if (boarding) sfx("boarding", 0, 796) else { sfx("cannon"); sfx("cannon", 350) }
    }

    fun release() { stopMusic(); stopEffects(); base = null; building = null; scene = null }

    /** What plays on the sea by hero: his own theme (0x94C6, songs 4–9). */
    fun seaSong(hero: Int) = 4 + minOf(5, hero)

    /** Port music by trade region (0x1B6EE). */
    fun portSong(zone: Int, port: Int): Int {
        if (port >= 100) return 15
        return when (zone) { in 0..2 -> 10; 4, 9 -> 12; 10 -> 13; 11, 12 -> 14; else -> 11 }
    }
}
