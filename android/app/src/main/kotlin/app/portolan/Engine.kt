package app.portolan

import android.content.Context
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter

/**
 * The game's own rules (PortolanCore, Swift) running as a child process: it reads one JSON command
 * per line and answers with one JSON line. The app ships it as a native library and gives it
 * a copy of the game data on disk.
 */
class Engine(private val context: Context) {
    private var process: Process? = null
    private var input: BufferedReader? = null
    private var output: OutputStreamWriter? = null

    /** The game data as plain files (the engine cannot read APK assets). */
    private fun dataDir(): File {
        val dir = File(context.filesDir, "assets-data")
        val stamp = File(dir, ".version")
        val version = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        if (!(stamp.exists() && stamp.readText() == version)) {
            dir.deleteRecursively()
            copyAssets("", dir)
            stamp.writeText(version)
        }
        return dir
    }

    private fun copyAssets(path: String, to: File) {
        val names = context.assets.list(path) ?: return
        if (names.isEmpty()) {
            to.parentFile?.mkdirs()
            context.assets.open(path).use { i -> to.outputStream().use { o -> i.copyTo(o) } }
            return
        }
        to.mkdirs()
        for (n in names) copyAssets(if (path.isEmpty()) n else "$path/$n", File(to, n))
    }

    /** Starts the process and waits for its greeting. Returns it, or an error text. */
    fun start(): Result<JSONObject> = runCatching {
        val exe = File(context.applicationInfo.nativeLibraryDir, "libportolanengine.so")
        val pb = ProcessBuilder(exe.absolutePath, dataDir().absolutePath)
        pb.environment()["LD_LIBRARY_PATH"] = context.applicationInfo.nativeLibraryDir
        val p = pb.start()
        process = p
        input = BufferedReader(InputStreamReader(p.inputStream, Charsets.UTF_8))
        output = OutputStreamWriter(p.outputStream, Charsets.UTF_8)
        JSONObject(input!!.readLine() ?: error("엔진이 응답하지 않습니다"))
    }

    /** One command and its answer. */
    @Synchronized
    fun call(command: JSONObject): JSONObject {
        val o = output ?: error("엔진이 시작되지 않았습니다")
        o.write(command.toString() + "\n"); o.flush()
        return JSONObject(input!!.readLine() ?: error("엔진이 끝났습니다"))
    }

    fun stop() { process?.destroy(); process = null }
}
