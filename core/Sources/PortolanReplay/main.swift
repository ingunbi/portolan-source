import Foundation
import PortolanCore
import Darwin

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 || (args.count == 4 && args[2] == "--identity") else {
    fputs("사용법: PortolanReplay <assets> <진단 폴더> [--identity build-identity.json]\n", stderr)
    exit(2)
}
do {
    let world = try World(assets: URL(fileURLWithPath: args[0]))
    let bundle = try DiagnosticExport.read(from: URL(fileURLWithPath: args[1]))
    let identity = args.count == 4
        ? try JSONDecoder().decode(BuildIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        : BuildIdentity.current
    let result = try DiagnosticReplay.run(bundle, in: world, identity: identity)
    print(String(decoding: try DiagnosticCodec.encode(result), as: UTF8.self))
    print("재현 통과: 지원 코어 \(result.matchedSegments)구간·\(result.matchedCommands)명령. 진단 전용 사건 \(result.diagnosticOnlyEvents)개. 전체 세션 재생: \(result.entireSessionReplayed)")
} catch {
    fputs((error.localizedDescription + "\n").cString(using: .utf8)!, stderr)
    exit(1)
}
