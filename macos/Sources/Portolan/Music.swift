import AVFoundation
import Foundation
import PortolanCore

/// The original songs (D2.MML rendered by tools/mml.py), addressed by the game's music index
/// as MAIN.EXE plays them through 0x94C6. Songs loop between their loop marks.
final class MusicPlayer {
    private struct Song: Decodable {
        let file: String
        let loopStart: Double?
        let loopEnd: Double?
        let gameIndex: Int
    }
    private struct Index: Decodable { let songs: [Song] }

    private var songs: [Int: Song] = [:]
    private let dir: URL
    private var player: AVAudioPlayer?
    private var playing: Int?
    private var timer: Timer?
    var enabled = ProcessInfo.processInfo.environment["PORTOLAN_SNAPSHOT"] == nil
    var volume: Float = 0.6 { didSet { player?.volume = volume } }
    /// Index 0x15, the victory fanfare, plays once (0x1040D turns looping off).
    static let fanfare = 21
    /// Called when a song that does not loop has played to its end.
    var finished: ((Int) -> Void)?

    init(assets: URL) {
        dir = assets.appendingPathComponent("music")
        if let d = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let i = try? JSONDecoder().decode(Index.self, from: d) {
            for s in i.songs { songs[s.gameIndex] = s }
        }
    }

    /// Plays game music `index` unless it is already playing.
    func play(_ index: Int?) {
        if !enabled {
            timer?.invalidate()
            player?.stop()
            player = nil
            playing = nil
            return
        }
        guard index != playing else { return }
        playing = index
        timer?.invalidate()
        player?.stop()
        player = nil
        guard let index, let s = songs[index],
              let p = try? AVAudioPlayer(contentsOf: dir.appendingPathComponent(s.file)) else { return }
        p.volume = volume
        p.prepareToPlay()
        p.play()
        player = p
        if index == MusicPlayer.fanfare {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak p] t in
                guard let p, !p.isPlaying else { return }
                t.invalidate()
                self?.finished?(index)
            }
        } else if let start = s.loopStart, let end = s.loopEnd {
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak p] _ in
                guard let p, p.currentTime >= end else { return }
                p.currentTime = start + (p.currentTime - end)
            }
        }
    }

    /// Port music by trade region (0x1B6EE): Europe, Africa and the New World, the Middle
    /// East, India, the Far East; supply ports have their own.
    static func portSong(zone: Int, port: Int) -> Int {
        if port >= 100 { return 15 }
        switch zone {
        case 0...2: return 10
        case 4, 9: return 12
        case 10: return 13
        case 11, 12: return 14
        default: return 11
        }
    }
}

extension Game {
    /// What should be playing now: a script's music, the battle, the building, the port or the
    /// hero's theme at sea.
    var sceneMusic: Int? {
        if opening { return 0 }                                     // OPEN.EXE: song 21
        if endingCode != nil { return cinemaSong }                  // END.EXE picks its own songs
        if title { return 3 }                                       // start menu: song 18
        if status.gameOver != nil { return 20 }
        if let s = session?.run?.music { return s }
        if let r = battleResult {
            // 0x1040D / 0x10471: the fanfare once, then the victory song; 0x1062C: a lost battle.
            if [0, 4, 6].contains(r.code) { return fanfareDone ? 17 : MusicPlayer.fanfare }
            if [5, 7].contains(r.code) { return 20 }
            return 16
        }
        if battle != nil || encounter != nil { return 16 }
        if let h = harbor {
            if buildingScene == .tavern { return 19 }
            if buildingScene == .palace { return 18 }
            return MusicPlayer.portSong(zone: h.id < 100 ? market.zone : 0, port: h.id)
        }
        return 4 + min(5, status.memory[DS.heroID])
    }
}
