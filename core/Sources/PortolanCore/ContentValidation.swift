import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum ContentValidationScope: String, Codable { case runtime, full }

public struct ContentValidationIssue: Codable, Equatable {
    public enum Severity: String, Codable { case error, warning }
    public let severity: Severity
    public let code: String
    public let path: String
    public let logicalID: String
    public let expected: String
    public let actual: String

    public var description: String {
        "\(severity == .error ? "오류" : "경고") [\(code)] \(path) · \(logicalID)\n기대: \(expected)\n확인: \(actual)"
    }
}

public struct ContentManifest: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public let path: String
        public let logicalID: String
        public let kind: String
        public let required: Bool
        public let formatVersion: Int
        public let byteCount: Int?
        public let sha256: String?
        public let source: String
    }
    public let schemaVersion: Int
    public let contentRevision: String
    public let entries: [Entry]
    public let limitations: [String]
}

public struct ContentValidationReport: Codable {
    public let scope: ContentValidationScope
    public let manifest: ContentManifest
    public let issues: [ContentValidationIssue]
    public var contentRevision: String { manifest.contentRevision }
    public var errors: [ContentValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ContentValidationIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }

    public func requireValid() throws {
        if !isValid { throw ContentValidationError(issues: errors) }
    }
}

public struct ContentValidationError: Error, LocalizedError {
    public let issues: [ContentValidationIssue]
    public init(issues: [ContentValidationIssue]) { self.issues = issues }
    public var errorDescription: String? {
        let detail = issues.prefix(8).map(\.description).joined(separator: "\n\n")
        let more = issues.count > 8 ? "\n\n외 \(issues.count - 8)개 오류" : ""
        return "게임 자료를 사용할 수 없습니다.\n\n" + detail + more
    }
    public var recoverySuggestion: String? {
        "표시된 파일을 포함해 같은 버전의 게임 자료를 다시 준비해 주세요. 저장 파일은 변경하지 않았습니다."
    }
}

/// Read-only validation of the assets actually consumed by this port. Runtime checks include
/// structure, static references and image headers; full adds pixel/audio decoding.
/// No modification-time, absolute path or directory enumeration order enters the revision.
public enum ContentValidation {
    public static func validate(assets: URL, scope: ContentValidationScope = .full) -> ContentValidationReport {
        ContentValidator(assets: assets, scope: scope).run()
    }
}

private final class ContentValidator {
    let assets: URL
    let scope: ContentValidationScope
    var issues: [ContentValidationIssue] = []
    var files: [String: ContentManifest.Entry] = [:]
    var contents: [String: Data] = [:]
    var images = Set<String>()

    init(assets: URL, scope: ContentValidationScope) {
        self.assets = assets.standardizedFileURL
        self.scope = scope
    }

    func issue(_ code: String, _ path: String, _ id: String, _ expected: String, _ actual: String, required: Bool = true) {
        issues.append(.init(severity: required ? .error : .warning, code: code, path: path,
                            logicalID: id, expected: expected, actual: actual))
    }

    func check(_ valid: Bool, _ path: String, _ id: String, _ expected: String, _ actual: String, required: Bool = true) {
        if !valid { issue("invalid_structure", path, id, expected, actual, required: required) }
    }

    func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            && !path.contains("\\") && !path.contains("\0")
    }

    @discardableResult
    func data(_ path: String, id: String? = nil, required: Bool = true, kind: String = "binary",
              source: String = "original-derived") -> Data? {
        guard safe(path) else {
            issue("invalid_path", path, id ?? path, "자료 폴더 안의 상대 경로", path, required: required)
            return nil
        }
        if let prior = files[path] {
            if required && !prior.required {
                files[path] = .init(path: path, logicalID: id ?? prior.logicalID, kind: prior.kind,
                                   required: true, formatVersion: 1, byteCount: prior.byteCount,
                                   sha256: prior.sha256, source: prior.source)
                if contents[path] == nil {
                    issue("missing_file", path, id ?? path, "필수 자료 파일", "읽을 수 없음")
                }
            }
            return contents[path]
        }
        let value: Data?
        do { value = try Data(contentsOf: assets.appendingPathComponent(path)) }
        catch {
            value = nil
            issue(FileManager.default.fileExists(atPath: assets.appendingPathComponent(path).path) ? "unreadable_file" : "missing_file",
                  path, id ?? path, required ? "필수 자료 파일" : "선택 자료; 없으면 무음/장식 생략",
                  error.localizedDescription, required: required)
        }
        files[path] = .init(path: path, logicalID: id ?? path, kind: kind, required: required, formatVersion: 1,
                           byteCount: value?.count, sha256: value.map(Self.hash), source: source)
        contents[path] = value
        return value
    }

    static func hash(_ data: Data) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        PortableHash.sha256Hex(data)
        #endif
    }

    func json(_ path: String, required: Bool = true) -> [String: Any]? {
        guard let d = data(path, required: required, kind: "json") else { return nil }
        do {
            guard let object = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                issue("invalid_json", path, path, "JSON 객체", "최상위 값이 객체가 아님", required: required)
                return nil
            }
            return object
        } catch {
            issue("invalid_json", path, path, "해독 가능한 JSON", error.localizedDescription, required: required)
            return nil
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
        guard let d = data(path, kind: "json") else { return nil }
        do { return try JSONDecoder().decode(type, from: d) }
        catch {
            let location: String
            switch error {
            case DecodingError.keyNotFound(let key, let context): location = (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
                 DecodingError.dataCorrupted(let context): location = context.codingPath.map(\.stringValue).joined(separator: ".")
            default: location = path
            }
            issue("invalid_json", path, location, "필수 필드와 자료형을 갖춘 JSON", String(describing: error))
            return nil
        }
    }

    func binary(_ path: String, count: Int) -> [UInt8]? {
        guard let d = data(path) else { return nil }
        guard d.count == count else {
            issue("invalid_size", path, path, "\(count)바이트", "\(d.count)바이트")
            return nil
        }
        return [UInt8](d)
    }

    func png(_ path: String, id: String? = nil, width: Int? = nil, height: Int? = nil, required: Bool = true) {
        guard let d = data(path, id: id, required: required, kind: "png") else { return }
        let bytes = [UInt8](d.prefix(24))
        guard bytes.count == 24, Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR" else {
            issue("invalid_image", path, id ?? path, "PNG IHDR 헤더", "잘못되거나 잘린 이미지", required: required)
            return
        }
        func u32(_ k: Int) -> Int { bytes[k..<k+4].reduce(0) { $0 << 8 | Int($1) } }
        let w = u32(16), h = u32(20)
        guard w > 0 && h > 0 && w <= 16384 && h <= 16384 else {
            issue("invalid_image", path, id ?? path, "1...16384 범위의 너비·높이", "\(w)×\(h)", required: required)
            return
        }
        check(w > 0 && h > 0 && w <= 16384 && h <= 16384 && (width.map { $0 == w } ?? true),
              path, id ?? path, width.map { "너비 \($0)" } ?? "유효한 이미지 크기", "\(w)×\(h)", required: required)
        if let height { check(h == height, path, id ?? path, "높이 \(height)", "\(h)", required: required) }
        guard images.insert(path).inserted, scope == .full else { return }
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(d as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            issue("invalid_image", path, id ?? path, "해독 가능한 PNG 픽셀", "이미지 디코딩 실패", required: required)
            return
        }
        #endif
    }

    func run() -> ContentValidationReport {
        if let mask = binary("world_mask.bin", count: World.width * World.height),
           let invalid = mask.firstIndex(where: { $0 > 2 }) {
            issue("invalid_terrain", "world_mask.bin", "tile[\(invalid)]", "지형 0...2", "\(mask[invalid])")
        }
        struct Ports: Decodable { let ports: [Harbor] }
        let ports = decode(Ports.self, "ports.json")?.ports
        if let ports {
            check(ports.count == 130, "ports.json", "ports", "항구 130개", "\(ports.count)개")
            for (i, p) in ports.enumerated() {
                check(p.id == i, "ports.json", "ports[\(i)].id", "중복 없이 순서대로 ID \(i)", "\(p.id)")
                check((0..<World.width).contains(p.x) && (0..<World.height).contains(p.y),
                      "ports.json", "ports[\(i)]", "세계 안의 항구 좌표", "\(p.x),\(p.y)")
                check(!p.name.isEmpty, "ports.json", "ports[\(i)].name", "항구 이름", "빈 이름")
            }
        }
        if let navigation = decode(NavigationData.self, "navigation.json") { validateNavigation(navigation) }
        let text = json("text.json")
        if let text { validateText(text) }
        let ds = binary("ds.bin", count: 0x10000)
        for n in 0..<7 {
            let path = "scenario/SNR\(n).DAT"
            if let d = data(path, id: "SNR\(n)", kind: "snr") {
                validateScript([UInt8](d), number: n, lines: text?["scenario\(n)"] as? [String])
            }
        }
        _ = binary("scenario/COLONY.DAT", count: 100 * 0xDA)
        if let names = binary("scenario/NAME.TBL", count: 6 * 32 * 13) {
            for i in 0..<192 {
                let name = Array(names[i*13..<(i+1)*13].prefix { $0 != 0 })
                check(DataSegment.decodeKorean(Array(name)) != nil,
                      "scenario/NAME.TBL", "name[\(i)]", "CP949 이름", "해독 실패")
            }
        }
        if let points = binary("scenario/MONSTER.DAT", count: 40 * 5) {
            for i in stride(from: 0, to: points.count, by: 5) {
                let x = Int(points[i]) | Int(points[i+1]) << 8, y = Int(points[i+2]) | Int(points[i+3]) << 8
                check(x < World.width && y < World.height && points[i+4] < 10,
                      "scenario/MONSTER.DAT", "point[\(i/5)]", "세계 안 좌표와 사건 0...9", "\(x),\(y),\(points[i+4])")
            }
        }
        validateRoutes()
        validateTowns()
        validateGraphics(ds: ds)
        validateAudio(directory: "music", key: "songs")
        validateAudio(directory: "sfx", key: "effects")
        let entries = files.values.sorted { $0.path < $1.path }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding this finite, string/integer-only schema cannot fail.
        let canonical = (try? encoder.encode(entries)) ?? Data()
        let manifest = ContentManifest(schemaVersion: 1, contentRevision: Self.hash(canonical), entries: entries,
            limitations: [
                "SNR 검사는 헤더·장/블록·명령 길이·정적 분기/대사 참조에 한정합니다. 동적 DS 접근과 이야기 도달 가능성은 증명하지 않습니다.",
                "원작 tools/snr.py all --check와 실제 여섯 주인공 플레이 검수는 별도입니다.",
                "runtime은 PNG 헤더와 참조를 검사하며 full만 픽셀·음향 디코딩을 추가합니다.",
                "ITEM.MES 103/106/107/110/115의 알려진 CP949 대체문자는 원본 추출 문자열과 정확히 일치할 때만 경고로 보존합니다.",
                "SHA-256은 검사한 파일의 동일성을 나타내며 원본의 진품 여부나 저작권을 인증하지 않습니다."
            ])
        return .init(scope: scope, manifest: manifest, issues: issues.sorted {
            ($0.path, $0.logicalID, $0.code, $0.actual) < ($1.path, $1.logicalID, $1.code, $1.actual)
        })
    }

    func validateNavigation(_ n: NavigationData) {
        let p = "navigation.json"
        for (id, count, expected) in [
            ("classes", n.classes.count, 25), ("newGame.heroes", n.newGame.heroes.count, 6),
            ("newGame.persons", n.newGame.persons.count, 120), ("markets", n.markets.count, 100),
            ("goods", n.goods.count, 46), ("categories", n.categories.count, 10),
            ("zones", n.zones.count, 13), ("drinks", n.drinks.count, 14),
            ("shipRegions", n.shipRegions.count, 11), ("cannons", n.cannons.count, 7)
        ] { check(count == expected, p, id, "\(expected)개", "\(count)개") }
        check(n.sailTable.count == 8 && n.sailTable.allSatisfy { $0.count == 8 }, p, "sailTable", "8×8 배열", "행 수 \(n.sailTable.count)")
        for (id, values) in [("windSummer", n.windSummer), ("windWinter", n.windWinter), ("current", n.current)] {
            check(values.count == 450 && values.allSatisfy { (0...255).contains($0) }, p, id, "450개 바이트", "\(values.count)개")
        }
        for (i, h) in n.newGame.heroes.enumerated() {
            check((0..<130).contains(h.port) && (0..<70).contains(h.fleet), p, "newGame.heroes[\(i)]", "유효한 항구/함대 ID", "\(h.port)/\(h.fleet)")
        }
        for (i, person) in n.newGame.persons.enumerated() {
            check(person.stats.count == 8, p, "newGame.persons[\(i)].stats", "능력 8개", "\(person.stats.count)개")
        }
        for (i, c) in n.classes.enumerated() {
            check((0..<8).contains(c.sailType) && c.hull > 0 && c.capacity > 0 && c.price >= 0,
                  p, "classes[\(i)]", "유효한 돛 종류·선체·적재량·가격", "\(c.sailType)/\(c.hull)/\(c.capacity)/\(c.price)")
        }
        for (i, m) in n.markets.enumerated() {
            check(m.support.count == 6 && m.prices.count == n.categories.count, p, "markets[\(i)]", "국가 6개·상품 분류별 가격", "\(m.support.count)/\(m.prices.count)")
            check(n.drinks.indices.contains(m.drink) && n.zones.indices.contains(m.zone) && n.shipRegions.indices.contains(m.shipRegion),
                  p, "markets[\(i)]", "존재하는 음료·교역권·조선권 ID", "\(m.drink)/\(m.zone)/\(m.shipRegion)")
            check(m.specialty == 255 || n.goods.indices.contains(m.specialty), p, "markets[\(i)].specialty", "상품 ID 또는 255", "\(m.specialty)")
        }
        for (i, g) in n.goods.enumerated() {
            check(n.categories.indices.contains(g.category), p, "goods[\(i)].category", "존재하는 분류 ID", "\(g.category)")
        }
        for (i, z) in n.zones.enumerated() {
            check(z.sellPrices.count == n.goods.count && z.goods.allSatisfy { n.goods.indices.contains($0.good) },
                  p, "zones[\(i)]", "모든 상품의 가격과 유효한 판매 상품 ID", "가격 \(z.sellPrices.count)개")
        }
        check((n.shipRegions.flatMap { $0 } + n.commonShips).allSatisfy { n.classes.indices.contains($0) },
              p, "shipRegions/commonShips", "존재하는 선종 ID", "선종 범위 밖 참조")
    }

    func validateText(_ text: [String: Any]) {
        // tools/extract.py:item_texts preserves these five undecodable records from the
        // original ITEM.MES with CP949 replacement. Match ID AND the SHA-256 of the exact extracted
        // text (the text itself is not kept here): a new replacement character, even at one of these
        // IDs, remains an error.
        let originalItemDecodeWarnings: [Int: String] = [
            103: "70aeac265fa9637b4499655efcf04d99f29f422f7eb7ae2e4d1126d0b2721fae",
            106: "73cc8b4b1adf03d39f9d992d8221a43ebcaa41152469b939580394be72579213",
            107: "d975daa95159c3837609b042c76bec75dc084d283951f174c7776c37cd33b5c3",
            110: "552ef32213dbc88c5a25ac4765a3d129ec889d6509cf5f61de3b914bf312dc9d",
            115: "8b4ac9a1ed495bf6b488d262480d0990f27af6ae344a58a59a1d134667597c80"
        ]
        for (key, minimum) in [("message", 1179), ("items", 116)] + (0..<7).map({ ("scenario\($0)", 1) }) {
            guard let lines = text[key] as? [String] else {
                issue("invalid_text", "text.json", key, "문자열 배열", "누락 또는 자료형 오류")
                continue
            }
            check(lines.count >= minimum, "text.json", key, "최소 \(minimum)개", "\(lines.count)개")
            for (i, line) in lines.enumerated() where line.contains("\u{FFFD}") || (key != "items" && line.isEmpty) {
                if key == "items", originalItemDecodeWarnings[i] == Self.hash(Data(line.utf8)) {
                    issue("legacy_text_decode", "text.json", "items[\(i)]",
                          "원본 ITEM.MES의 알려진 CP949 해독 결과 보존", line, required: false)
                    continue
                }
                issue("invalid_text", "text.json", "\(key)[\(i)]", "해독된 비어 있지 않은 문장", line.isEmpty ? "빈 문장" : "대체 문자 U+FFFD 포함")
            }
        }
        check((text["menus"] as? [[String]])?.count == 61, "text.json", "menus", "메뉴 61개의 문자열 배열", "누락·개수·자료형 확인 필요")
    }

    func validateRoutes() {
        guard let d = data("routes.bin") else { return }
        guard d.count >= 624 * 16 && d.count % 16 == 0 else {
            issue("invalid_size", "routes.bin", "routes", "최소 624개 16바이트 노드", "\(d.count)바이트")
            return
        }
        let bytes = [UInt8](d)
        func w(_ a: Int) -> Int { Int(bytes[a]) | Int(bytes[a+1]) << 8 }
        for i in 0..<624 {
            let a = i * 16, x = w(a) & 0x7FFF, y = w(a+2)
            check(x < World.width && y < World.height, "routes.bin", "node[\(i)]", "세계 안의 좌표", "\(x),\(y)")
            for k in 0..<4 {
                let next = w(a+4+2*k)
                check(next == 0xFFFF || next < 624, "routes.bin", "node[\(i)].next[\(k)]", "노드 0...623 또는 65535", "\(next)")
            }
        }
    }

    func validateTowns() {
        let path = "portmaps/portmaps.json"
        guard let j = json(path) else { return }
        guard let buildings = j["buildings"] as? [String], buildings.count == 12,
              let walk = j["walk"] as? [[Int]], walk.count == 7,
              walk.allSatisfy({ $0.count == 4 && $0.allSatisfy { (0...255).contains($0) } }),
              let ports = j["ports"] as? [[String: Any]] else {
            issue("invalid_structure", path, "towns", "시설 12개·걷기 표 7×4·항구 목록", "필수 표 누락/형식 오류")
            return
        }
        check(j["size"] as? Int == 96 && j["tile"] as? Int == 16, path, "size/tile", "96×96 지도·16픽셀 타일", "크기 메타데이터 불일치")
        check(ports.count == 130, path, "ports", "항구 130개", "\(ports.count)개")
        for (i, port) in ports.enumerated() {
            guard let id = port["port"] as? Int, let map = port["map"] as? Int,
                  let chip = port["chipSet"] as? Int, let doors = port["doors"] as? [String: [Int]] else {
                issue("invalid_structure", path, "ports[\(i)]", "항구/지도/타일셋/문", "필드 누락 또는 자료형 오류")
                continue
            }
            check(id == i && map >= 0 && map <= 999 && walk.indices.contains(chip), path, "ports[\(i)]", "순차 ID와 유효한 지도·타일셋", "\(id)/\(map)/\(chip)")
            guard map >= 0 && map <= 999 else { continue }
            _ = binary(String(format: "portmaps/%03d.tiles", map), count: 96*96)
            png(String(format: "portmaps/%03d.png", map), id: "town.\(id)", width: 1536, height: 1536)
            for (name, xy) in doors {
                check(buildings.contains(name) && xy.count == 2 && xy.allSatisfy { (0..<96).contains($0) },
                      path, "ports[\(i)].doors.\(name)", "알려진 시설과 지도 안 x,y", "\(xy)")
            }
        }
    }

    func validateGraphics(ds: [UInt8]?) {
        for i in 0..<128 {
            png(String(format: "portraits/%03d.png", i), id: "portrait.\(i)", width: 64, height: 80)
            png(String(format: "pictures/%03d.png", i), id: "picture.\(i)")
        }
        for i in 0..<65 { png(String(format: "images/graph_%02d.png", i), id: "graph.\(i)") }
        png("images/chart.png")
        png("minimap.png")
        for type in 1...2 {
            png("frame/frame_sea_type\(type).png", width: 640, height: 400)
            png("frame/frame_port_type\(type).png", width: 640, height: 400)
        }
        for font in ["ascii", "digits", "hangul"] { png("frame/font_\(font).png") }
        for hero in 0..<6 {
            for direction in ["up", "right", "down", "left"] {
                for frame in 0..<2 { png("townchars/hero\(hero)_\(direction)_\(frame).png") }
            }
        }
        png("opening/op00_10.png")
        if let ds {
            for i in 0..<120 {
                let a = DS.person(i) + 0x1A, face = Int(ds[a]) | Int(ds[a+1]) << 8
                check(face & 0xC000 != 0 || face < 128, "ds.bin", "person[\(i)].portrait", "초상화 0...127 또는 조합 얼굴", "\(face)")
            }
        }
        let indices = ["faces/faces.json", "townchars/townchars.json", "opening/opening.json",
                       "endings/endings.json", "frame/index.json"]
            + ["battle", "duel", "figureheads", "gambling", "ships", "ui"].map { "sprites/\($0)/index.json" }
        for path in indices {
            guard let j = json(path) else { continue }
            let directory = (path as NSString).deletingLastPathComponent
            imageReferences(j, directory: directory, location: path)
            if path == "faces/faces.json" { validateFaces(j, path: path) }
            if path == "endings/endings.json" { validateEndings(j, path: path) }
            if path == "opening/opening.json" {
                check((j["pictures"] as? [[String: Any]])?.isEmpty == false, path, "pictures", "오프닝 그림 목록", "목록 누락 또는 빈 목록")
            }
            if path == "townchars/townchars.json" {
                check((j["heroes"] as? [[String: Any]])?.count == 6, path, "heroes", "여섯 주인공 보행 그림", "목록 확인 필요")
            }
            if directory.hasPrefix("sprites/") {
                guard let specs = j["files"] as? [[String: Any]], !specs.isEmpty else {
                    issue("invalid_structure", path, "files", "스프라이트 파일 목록", "누락·빈 목록·형식 오류")
                    continue
                }
                for (i, spec) in specs.enumerated() {
                    guard let name = spec["name"] as? String else {
                        issue("invalid_structure", path, "files[\(i)]", "name", "파일 이름 누락 또는 형식 오류")
                        continue
                    }
                    if let w = spec["w"] as? Int, let h = spec["h"] as? Int {
                        png(directory + "/" + name, width: w, height: h)
                    } else if directory == "sprites/duel",
                              let cell = spec["cell"] as? [Int], cell == [192, 120],
                              let frames = spec["frames"] as? Int, (1...85).contains(frames),
                              let rects = spec["rects"] as? [[String: Int]], rects.count == frames {
                        // tools/sprites.py:ia_strip lays frames side by side, not into
                        // individual w/h files. Original rectangles may extend beyond
                        // the cell and the extractor intentionally clips those pixels.
                        for (r, rect) in rects.enumerated() {
                            check(["x", "y", "w", "h"].allSatisfy { rect[$0].map { $0 >= 0 } == true },
                                  path, "files[\(i)].rects[\(r)]", "원본 프레임의 음수가 아닌 x/y/w/h", "\(rect)")
                        }
                        png(directory + "/" + name, width: cell[0] * frames, height: cell[1])
                    } else {
                        issue("invalid_structure", path, "files[\(i)]", "name/w/h 또는 일기토 cell=[192,120]·frames·rects",
                              "필드 누락 또는 스트립 형식 오류")
                    }
                }
            }
        }
        validateSeaMap()
    }

    func validateEndings(_ j: [String: Any], path: String) {
        guard let endings = j["endings"] as? [[String: Any]], endings.count == 6,
              let windows = j["windows"] as? [String: [String: [Double]]], windows.count == 2 else {
            issue("invalid_structure", path, "endings/windows", "주인공 엔딩 6개와 대화 창 2개", "목록·창 형식 오류")
            return
        }
        for name in windows.keys.sorted() {
            let window = windows[name]!
            check(window["frame"]?.count == 4 && window["face"]?.count == 2 && window["text"]?.count == 2,
                  path, "windows.\(name)", "frame 4개·face/text 각 2개 좌표", "좌표 개수 확인 필요")
        }
        for (i, ending) in endings.enumerated() {
            check(ending["hero"] as? Int == i, path, "endings[\(i)].hero", "주인공 번호 \(i)", "\(ending["hero"] ?? "없음")")
            check(ending["homecoming"] is [[String: Any]] && ending["portrait"] is [String: Any],
                  path, "endings[\(i)]", "귀환 장면과 초상화 구성", "필수 구성 확인 필요")
        }
        func inspect(_ object: Any, location: String) {
            if let dictionary = object as? [String: Any] {
                for key in dictionary.keys.sorted() {
                    let value = dictionary[key]!
                    if ["drawAt", "slideTo", "finalAt", "at"].contains(key), let xy = value as? [Double] {
                        check(xy.count == 2 && xy.allSatisfy(\.isFinite), path, location + "." + key,
                              "유한한 x,y 좌표 2개", "\(xy)")
                    }
                    if key == "say", let say = value as? [String: Any] {
                        let window = say["window"] as? String ?? ""
                        check(windows[window] != nil && say["text"] is String, path, location + ".say",
                              "존재하는 창과 대사 문자열", window)
                    }
                    inspect(value, location: location + "." + key)
                }
            } else if let array = object as? [Any] {
                for (i, child) in array.enumerated() { inspect(child, location: location + "[\(i)]") }
            }
        }
        inspect(j, location: "endings")
    }

    /// Catalogues contain both live references and explicitly labelled check renders.
    /// Do not require sample/check pictures or wildcard documentation as game assets.
    func imageReferences(_ value: Any, directory: String, location: String, required: Bool = true) {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                imageReferences(dictionary[key]!, directory: directory, location: location + "." + key,
                                required: required && key != "checkRenders" && key != "samples")
            }
        } else if let array = value as? [Any] {
            for (i, child) in array.enumerated() {
                imageReferences(child, directory: directory, location: location + "[\(i)]", required: required)
            }
        } else if let name = value as? String, name.hasSuffix(".png"), !name.contains("*") {
            png(directory + "/" + name, id: location, required: required)
        }
    }

    func validateFaces(_ j: [String: Any], path: String) {
        guard let w = j["width"] as? Int, let h = j["height"] as? Int,
              let palette = j["palette"] as? [[Int]], let layers = j["layers"] as? [[String: Any]],
              let sets = j["sets"] as? [[String: Any]] else {
            issue("invalid_structure", path, "faces", "얼굴 크기·팔레트·레이어·국가별 조각", "필수 필드 누락")
            return
        }
        check(w == 64 && h == 80 && palette.count == 8 && palette.allSatisfy { $0.count == 3 && $0.allSatisfy { (0...255).contains($0) } },
              path, "palette/size", "64×80 얼굴·RGB 색상 8개", "\(w)×\(h), \(palette.count)색")
        check(sets.count == 7 && layers.count == 5, path, "sets/layers", "국가 7개·레이어 5개", "\(sets.count)/\(layers.count)")
        for (i, layer) in layers.enumerated() {
            guard let name = layer["name"] as? String, let mask = layer["mask"] as? Int,
                  let shift = layer["shift"] as? Int, let x = layer["x"] as? Int, let y = layer["y"] as? Int,
                  let lw = layer["width"] as? Int, let lh = layer["height"] as? Int, let blend = layer["blend"] as? String else {
                issue("invalid_structure", path, "layers[\(i)]", "완전한 얼굴 레이어", "필드 누락")
                continue
            }
            check((0...15).contains(mask) && (0..<16).contains(shift) && x >= 0 && y >= 0
                  && lw > 0 && lh > 0 && lw <= 64 && lh <= 80 && x <= 64-lw && y <= 80-lh
                  && ["copy", "or"].contains(blend), path, "layers[\(i)]", "얼굴 안의 레이어와 유효한 비트 범위", "\(name)")
            guard (0...15).contains(mask) else { continue }
            for (n, set) in sets.enumerated() {
                let names = (set["parts"] as? [String: [String]])?[name]
                check(names?.count == mask + 1, path, "sets[\(n)].parts.\(name)", "\(mask+1)개 조각", "\(names?.count ?? 0)개")
                for part in names ?? [] { png("faces/" + part, width: lw, height: lh) }
            }
        }
    }

    func validateSeaMap() {
        if let chips = binary("seamap/chips.bin", count: World.width * World.height) {
            check(chips.allSatisfy { $0 < 128 }, "seamap/chips.bin", "chips", "타일 0...127", "타일 범위 검사")
        }
        if let pixels = binary("seamap/chips_indexed.bin", count: 128 * 256) {
            check(pixels.allSatisfy { $0 < 16 }, "seamap/chips_indexed.bin", "paletteIndices", "색상 0...15", "색상 범위 검사")
        }
        let path = "seamap/index.json"
        guard let j = json(path) else { return }
        guard let phases = (j["palettes"] as? [String: Any])?["phases"] as? [[[Int]]],
              phases.count == 5 && phases.allSatisfy({ $0.count == 16 && $0.allSatisfy { $0.count == 3 && $0.allSatisfy { (0...255).contains($0) } } }) else {
            issue("invalid_structure", path, "palettes.phases", "5×16×3 RGB 팔레트", "누락·크기·자료형 오류")
            return
        }
        guard let markers = j["markers"] as? [[String: Any]] else {
            issue("invalid_structure", path, "markers", "항구·발견지 표식 배열", "누락 또는 형식 오류")
            return
        }
        for (i, marker) in markers.enumerated() {
            guard let kind = marker["kind"] as? String, let id = marker["id"] as? Int,
                  let x = marker["x"] as? Int, let y = marker["y"] as? Int,
                  let chips = marker["chips"] as? [Int], let hidden = marker["hidden"] as? Int else {
                issue("invalid_structure", path, "markers[\(i)]", "완전한 표식", "필드 누락")
                continue
            }
            check((kind == "site" ? (0..<100).contains(id) : (0..<130).contains(id))
                  && (0..<World.width).contains(x) && (0..<World.height-1).contains(y)
                  && chips.count == 4 && (chips + [hidden]).allSatisfy { (0..<128).contains($0) },
                  path, "markers[\(i)]", "존재하는 항구/발견지·2×2 표식·유효한 타일", "\(kind):\(id),\(x),\(y)")
        }
        if let windows = (j["windowOverrides"] as? [String: Any])?["windows"] as? [[String: Any]] {
            for (i, window) in windows.enumerated() {
                guard let third = window["third"] as? Int, let col = window["blockCol"] as? Int,
                      let row = window["blockRow"] as? Int, let tiles = window["tiles"] as? [[Int]] else {
                    issue("invalid_structure", path, "windows[\(i)]", "지도 덮어쓰기 위치·타일", "필드 누락")
                    continue
                }
                check((0..<3).contains(third) && (0..<28).contains(col) && (0..<43).contains(row)
                      && tiles.allSatisfy { $0.count == 3 && (0..<World.width).contains($0[0]) && (0..<World.height).contains($0[1]) && (0..<128).contains($0[2]) },
                      path, "windows[\(i)]", "유효한 창 위치와 x,y,chip", "덮어쓰기 범위 검사")
            }
        }
    }

    func validateAudio(directory: String, key: String) {
        let path = directory + "/index.json"
        guard let j = json(path, required: false) else { return }
        guard let tracks = j[key] as? [[String: Any]], !tracks.isEmpty else {
            issue("invalid_audio_index", path, key, "음향 파일 목록", "누락·빈 목록·형식 오류", required: false)
            return
        }
        for (i, track) in tracks.enumerated() {
            guard let name = track["file"] as? String else {
                issue("invalid_audio_index", path, "\(key)[\(i)]", "파일 이름", "누락", required: false)
                continue
            }
            let file = directory + "/" + name
            guard data(file, required: false, kind: "audio") != nil else { continue }
            let duration = track["duration"] as? Double
            let start = track["loopStart"] as? Double, end = track["loopEnd"] as? Double
            if start != nil || end != nil {
                // tools/sfx.py emits duration rounded to 3 decimals, loop marks to 6.
                check(start != nil && end != nil && start! >= 0 && end! > start! && end! <= (duration.map { $0 + 0.0005 } ?? .infinity),
                      path, "\(key)[\(i)].loop", "0 ≤ 루프 시작 < 끝 ≤ 재생 길이", "\(start ?? -1)...\(end ?? -1)", required: false)
            }
            #if canImport(AVFoundation)
            if scope == .full {
                do {
                    let player = try AVAudioPlayer(contentsOf: assets.appendingPathComponent(file))
                    check(player.duration > 0 && (end.map { $0 <= player.duration + 0.1 } ?? true),
                          file, name, "재생 가능한 음향과 유효한 루프", "\(player.duration)초", required: false)
                } catch {
                    issue("invalid_audio", file, name, "재생 가능한 음향; 실패 시 무음", error.localizedDescription, required: false)
                }
            }
            #endif
        }
    }

    /// Bounded structural sweep using the instruction widths documented by tools/snr.py.
    /// This does not execute the VM or try to prove dynamic DS addresses or story conditions.
    func validateScript(_ d: [UInt8], number: Int, lines: [String]?) {
        let path = "scenario/SNR\(number).DAT"
        func bad(_ location: String, _ expected: String, _ actual: String) { issue("invalid_scenario", path, location, expected, actual) }
        guard d.count >= 24, Array(d.prefix(4)) == Array("SNDT".utf8) else {
            bad("SNR\(number)", "SNDT 헤더와 장 목록", "헤더가 없거나 파일이 잘림"); return
        }
        check(d[4] == 0 && d[5] == (number == 0 ? 0x80 : UInt8(number-1)),
              path, "SNR\(number).identity", "파일 번호에 맞는 원작 시나리오 번호", "\(d[4]),\(d[5])")
        func u16(_ a: Int) -> Int { Int(d[a]) << 8 | Int(d[a+1]) }
        func u32(_ a: Int) -> Int { d[a..<a+4].reduce(0) { $0 << 8 | Int($1) } }
        var chapters: [Int] = [], cursor = 16, ended = false
        while cursor + 4 <= d.count {
            let offset = u32(cursor); cursor += 4
            if offset == 0xFFFFFFFF { ended = true; break }
            guard offset >= 20 && offset + 2 <= d.count else { bad("chapter", "파일 안의 장 주소", "\(offset)"); return }
            chapters.append(offset)
            if chapters.count > 256 { bad("chapter", "최대 256장", "장 목록 종료 없음"); return }
        }
        guard ended, !chapters.isEmpty, cursor <= chapters.min()! else { bad("chapter", "종료 표식이 있는 장 목록", "종료·범위 오류"); return }
        var blocks: [(id: String, start: Int)] = []
        for (c, base) in chapters.enumerated() {
            var at = base, count = 0, done = false, local: [Int] = []
            let end = chapters.filter { $0 > base }.min() ?? d.count
            while at + 2 <= end {
                let rel = u16(at); at += 2
                if rel == 0xFFFF { done = true; break }
                let target = base + rel
                guard target > base && target < end else { bad("\(c).\(count)", "장 안의 블록 주소", "\(target)"); return }
                local.append(target)
                blocks.append(("\(c).\(count)", target)); count += 1
                if count > 256 { break }
            }
            guard done, local.allSatisfy({ $0 >= at }) else { bad("chapter \(c)", "종료 표식이 있는 블록 목록", "종료·범위 오류"); return }
        }
        let boundaries = Set(chapters + blocks.map(\.start) + [d.count]).sorted()
        let widths: [Int: Int] = [
            0xC0:2, 0xC3:1, 0xC4:1, 0xC5:2, 0xC7:1, 0xC8:3, 0xC9:4, 0xCA:2, 0xCB:6, 0xCC:3, 0xCD:2,
            0xD0:5, 0xDC:5, 0xD1:2, 0xD4:3, 0xE2:3, 0xE3:3, 0xE4:2, 0xE6:2, 0xE7:2, 0xE8:2, 0xE9:2,
            0xEA:2, 0xEB:4, 0xEC:2, 0xED:2, 0xEE:2, 0xF0:1, 0xF1:1, 0xF2:1, 0xF4:2, 0xF8:1,
            0xF9:3, 0xFA:4, 0xFB:2, 0xFC:3, 0xFE:3, 0xFF:1
        ]
        for block in blocks {
            guard let end = boundaries.first(where: { $0 > block.start }) else { continue }
            var at = block.start, triggerEnded = false, targets: [Int] = []
            while at + 4 <= end {
                let key = d[at], target = u16(at+2); at += 4
                if key == 0xFF { triggerEnded = true; break }
                targets.append(target)
            }
            guard triggerEnded else { bad(block.id, "종료된 트리거 목록", "목록 잘림"); continue }
            var instructionStarts = Set<Int>(), lastOp = -1
            while at < end {
                let op = Int(d[at]), cls = op >> 6, relative = at - block.start
                let size: Int
                if cls == 0 {
                    let a = op & 3, source = op >> 2 & 3, dest = op >> 4 & 3
                    if a == 2 || dest == 3 || (dest < 2 && source == 2) || (dest == 2 && (source == 0 || a != 0)) {
                        bad(block.id + " @\(relative)", "지원되는 MOV 명령", "\(op)"); break
                    }
                    size = dest != 2 && a == 0 && source == 3 ? 4 : 3
                } else if cls == 1 { size = 3 }
                else if cls == 2 {
                    let condition = op & 3, right = op >> 2 & 3, left = op >> 4 & 3
                    if left == 3 || (left == 2 && (right < 2 || condition >= 2)) {
                        bad(block.id + " @\(relative)", "지원되는 조건 분기", "\(op)"); break
                    }
                    size = left == 2 && right != 2 ? 4 : 5
                } else if let width = widths[op] { size = width }
                else { bad(block.id + " @\(relative)", "알려진 명령", "\(op)"); break }
                guard at + size <= end else { bad(block.id + " @\(relative)", "\(size)바이트 명령", "잘린 명령"); break }
                instructionStarts.insert(relative)
                if cls == 2 { targets.append(u16(at+size-2)) }
                if op == 0xFE { targets.append(u16(at+1)) }
                if [0xC8, 0xD4, 0xC9, 0xFA].contains(op), let lines {
                    let line = u16(at + ([0xC9, 0xFA].contains(op) ? 2 : 1))
                    check(lines.indices.contains(line), "text.json", "scenario\(number)[\(line)] via \(block.id)@\(relative)",
                          "SNR이 참조하는 대사", "없는 대사 ID \(line)")
                }
                if op == 0xCC {
                    let face = u16(at+1)
                    if face < 128 { png(String(format: "portraits/%03d.png", face), id: "SNR\(number).portrait.\(face)", width: 64, height: 80) }
                }
                if op == 0xCB && number > 0 {
                    png("images/event\(number)_\(d[at+5]).png", id: "SNR\(number).picture.\(d[at+5])")
                }
                lastOp = op; at += size
            }
            if at == end {
                for target in targets where !instructionStarts.contains(target) {
                    bad(block.id, "명령 시작 위치를 가리키는 분기", "\(target)")
                }
                if ![0xF2, 0xF4, 0xFE].contains(lastOp) { bad(block.id, "종료 또는 goto로 끝나는 블록", "\(lastOp)") }
            }
        }
    }
}
