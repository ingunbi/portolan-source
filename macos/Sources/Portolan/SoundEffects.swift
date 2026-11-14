import AVFoundation
import Foundation

/// The eight sound effects of MAIN.EXE (docs/re/sfx.md), rendered by tools/sfx.py. The game has
/// one effect channel: a new effect cuts the one sounding. The storm is held, looping, for as
/// long as the storm lasts at sea.
final class SoundEffects {
    private let dir: URL
    private var players: [String: AVAudioPlayer] = [:]
    private var current: AVAudioPlayer?
    private var currentName: String?
    private var stopTimer: Timer?
    private var loopTimer: Timer?
    private var pending: [DispatchWorkItem] = []
    var enabled = ProcessInfo.processInfo.environment["PORTOLAN_SNAPSHOT"] == nil
    var volume: Float = 0.6

    init(assets: URL) { dir = assets.appendingPathComponent("sfx") }

    private func player(_ name: String) -> AVAudioPlayer? {
        if let p = players[name] { return p }
        let p = try? AVAudioPlayer(contentsOf: dir.appendingPathComponent(name + ".wav"))
        p?.prepareToPlay()
        players[name] = p
        return p
    }

    /// Plays `name` after `delay` seconds, muted after `cut` seconds when given (0x96DE).
    func play(_ name: String, after delay: Double = 0, cut: Double? = nil) {
        guard enabled else { return }
        let work = DispatchWorkItem { [weak self] in self?.start(name, cut: cut) }
        pending.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func start(_ name: String, cut: Double?) {
        guard enabled, let p = player(name) else { return }
        halt()
        p.currentTime = 0
        p.volume = volume
        p.play()
        current = p
        currentName = name
        if let cut {
            stopTimer = Timer.scheduledTimer(withTimeInterval: cut, repeats: false) { [weak self, weak p] _ in
                p?.stop()
                if self?.current === p { self?.current = nil; self?.currentName = nil }
            }
        }
        if name == "storm" {
            // storm.wav is an intro and a seamless loop (index.json loopStart / loopEnd).
            loopTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak p] _ in
                guard let p, p.currentTime >= 16.467 else { return }
                p.currentTime = 1.2015 + (p.currentTime - 16.467)
            }
        }
    }

    private func halt() {
        stopTimer?.invalidate()
        loopTimer?.invalidate()
        current?.stop()
        current = nil
        currentName = nil
    }

    /// Stops everything, queued effects too.
    func stopAll() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
        halt()
    }

    /// The storm voice is held while `on` (started at 0x1941B, muted at 0x1980E and 0x1B70E);
    /// after another effect has finished it comes back, as the sea screen restarts it.
    func storm(_ on: Bool) {
        if on {
            guard enabled, currentName != "storm", current?.isPlaying != true else { return }
            start("storm", cut: nil)
        } else if currentName == "storm" {
            halt()
        }
    }
}
