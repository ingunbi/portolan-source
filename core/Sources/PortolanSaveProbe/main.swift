import Foundation
import CryptoKit
import Darwin
@_spi(SaveProbe) import PortolanCore

// A deliberately separate executable: a test driver can SIGKILL it at a real IO boundary.
// It never defaults to the player's save directory and never starts the game UI.
struct ProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func category(_ error: Error) -> String {
    guard let error = error as? SaveFailure else {
        return error is RulesValidationError ? "rules" : "probe"
    }
    switch error {
    case .invalidSlot: return "invalidSlot"
    case .missing: return "missing"
    case .busy: return "busy"
    case .slotOccupied: return "slotOccupied"
    case .corrupt: return "corrupt"
    case .unsupportedVersion: return "unsupportedVersion"
    case .unsupportedExtension: return "unsupportedExtension"
    case .unsupportedRulesMode: return "unsupportedRulesMode"
    case .cannotRead: return "cannotRead"
    case .cannotWrite: return "cannotWrite"
    }
}

func snapshot(_ v: Voyage) -> [String: Any] {
    ["gold": v.gold, "date": SaveGame.dateText(v), "heroID": v.heroID,
     "ships": v.ships.count, "crew": v.crew, "officers": v.officers.count,
     "rng": v.rng.seed, "memorySHA256": digest(Data(v.memory.bytes)),
     "shipIDs": v.ships.map { $0.shipInstanceID.uuidString },
     "saveID": v.saveContext.saveID.uuidString, "generation": v.saveContext.generation,
     "mode": v.saveContext.rules.mode.rawValue]
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw ProbeError(message: "command required: init/read/write/inspect/migrate/import-dos") }
    var options: [String: String] = [:]
    var i = 1
    while i < args.count {
        guard args[i].hasPrefix("--"), i + 1 < args.count else { throw ProbeError(message: "options require --name value") }
        guard options[args[i]] == nil else { throw ProbeError(message: "duplicate option: \(args[i])") }
        options[args[i]] = args[i + 1]
        i += 2
    }
    let known = Set(["--directory", "--slot", "--gold", "--assets", "--hold-at", "--input", "--dos-slot", "--recovery", "--require-empty"])
    guard options.keys.allSatisfy(known.contains) else { throw ProbeError(message: "unknown option") }
    guard let path = options["--directory"], path.hasPrefix("/") else {
        throw ProbeError(message: "--directory must be an explicit absolute isolated path")
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let liveRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    guard directory.path != "/", directory.path != liveRoot.path,
          !directory.path.hasPrefix(liveRoot.path + "/") else {
        throw ProbeError(message: "Application Support and system root are prohibited probe destinations")
    }
    guard let slot = Int(options["--slot"] ?? "0"), (0..<SaveGame.slots).contains(slot) else { throw SaveFailure.invalidSlot }
    let file = directory.appendingPathComponent("slot\(slot).json")
    let emptyText = options["--require-empty"] ?? "false"
    guard ["true", "false"].contains(emptyText) else { throw ProbeError(message: "--require-empty expects true or false") }
    let requireEmpty = emptyText == "true"
    if command == "migrate" && requireEmpty { throw ProbeError(message: "migrate installs a raw fixture before conversion; --require-empty is not applicable") }
    SaveGame.override = directory
    defer { SaveGame.override = nil; SaveGame.checkpointObserver = nil }
    if let name = options["--hold-at"] {
        guard let stage = SaveCheckpoint(rawValue: name) else { throw ProbeError(message: "unknown checkpoint: \(name)") }
        SaveGame.checkpointObserver = { current in
            emit(["event": "checkpoint", "stage": current.rawValue, "pid": getpid()])
            if current == stage {
                // stdout is written synchronously before the process stops itself.
                raise(SIGSTOP)
            }
        }
    }
    func world() throws -> World {
        guard let assets = options["--assets"] else { throw ProbeError(message: "--assets required for this command") }
        return try World(assets: URL(fileURLWithPath: assets, isDirectory: true))
    }
    func save(_ v: Voyage) throws {
        try SaveGame.write(v, slot: slot, port: "검수 항구", requireEmpty: requireEmpty)
        let restored = try SaveGame.read(from: file)
        var result = snapshot(restored)
        result["event"] = "result"; result["ok"] = true; result["command"] = command
        result["sha256"] = digest(try Data(contentsOf: file))
        emit(result)
    }
    switch command {
    case "init":
        if !requireEmpty && FileManager.default.fileExists(atPath: file.path) { throw ProbeError(message: "init refuses an existing slot") }
        let w = try world()
        var v = Voyage.joanAfterPrologue(in: w)
        guard let gold = Int(options["--gold"] ?? "100") else { throw ProbeError(message: "invalid gold") }
        v.gold = gold; v.saveContext.contentRevision = w.contentRevision
        try save(v)
    case "write":
        var v = try SaveGame.read(from: file)
        guard let text = options["--gold"], let gold = Int(text) else { throw ProbeError(message: "--gold integer required") }
        v.gold = gold
        try save(v)
    case "read":
        let recovery = options["--recovery"] == "true"
        let v = try SaveGame.read(from: recovery ? file.appendingPathExtension("backup") : file)
        var result = snapshot(v)
        result["event"] = "result"; result["ok"] = true; result["command"] = command
        emit(result)
    case "inspect":
        let info = SaveGame.inspect(slot)
        emit(["event": "result", "ok": true, "command": command,
              "hasCurrent": info.hasCurrent, "canLoad": info.canLoad,
              "hasBackup": info.backupHeader != nil, "problem": info.problem ?? ""])
    case "migrate":
        guard let input = options["--input"] else { throw ProbeError(message: "--input required") }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw ProbeError(message: "migrate refuses an existing slot") }
        let source = URL(fileURLWithPath: input)
        let bytes = try Data(contentsOf: source)
        let v = try SaveGame.read(from: source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
        try save(v)
        guard try Data(contentsOf: source) == bytes else { throw ProbeError(message: "migration source changed") }
    case "import-dos":
        guard let input = options["--input"], let dosSlot = Int(options["--dos-slot"] ?? "0"), (0..<DOSSave.slots).contains(dosSlot) else {
            throw ProbeError(message: "--input and valid --dos-slot required")
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw ProbeError(message: "import refuses an existing slot") }
        let source = URL(fileURLWithPath: input)
        let bytes = try Data(contentsOf: source)
        guard let dos = DOSSave(url: source) else { throw ProbeError(message: "invalid DOS save length") }
        let w = try world()
        guard var v = dos.voyage(slot: dosSlot, in: w) else { throw ProbeError(message: "empty DOS slot") }
        v.saveContext.contentRevision = w.contentRevision
        try save(v)
        guard try Data(contentsOf: source) == bytes else { throw ProbeError(message: "DOS source changed") }
    default: throw ProbeError(message: "unknown command: \(command)")
    }
}

do { try run() }
catch {
    emit(["event": "error", "ok": false, "category": category(error), "message": error.localizedDescription])
    exit(2)
}
