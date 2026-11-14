import Foundation
import PortolanCore
import Darwin

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--manifest"),
      !arguments[0].hasPrefix("--") else {
    writeError("사용법: PortolanValidate <assets 경로> [--manifest <출력 JSON 경로>]")
    exit(2)
}
let assets = URL(fileURLWithPath: arguments[0], isDirectory: true)
let report = ContentValidation.validate(assets: assets, scope: .full)
for issue in report.issues { writeError(issue.description) }
guard report.isValid else {
    writeError("게임 자료 검증 실패: 오류 \(report.errors.count)개, 경고 \(report.warnings.count)개")
    exit(1)
}
if arguments.count == 3 {
    let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    let registered = Set(report.manifest.entries.map {
        assets.appendingPathComponent($0.path).standardizedFileURL.path
    })
    guard !registered.contains(output.path) else {
        writeError("manifest 출력이 게임 자료 파일을 덮어쓸 수 없습니다: \(output.path)")
        exit(2)
    }
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report.manifest).write(to: output, options: .atomic)
    } catch {
        writeError("manifest를 저장하지 못했습니다: \(error.localizedDescription)")
        exit(1)
    }
}
print("게임 자료 검증 통과: \(report.manifest.entries.count)개 파일, 경고 \(report.warnings.count)개")
print("contentRevision: \(report.contentRevision)")
for limit in report.manifest.limitations { print("검사 범위: " + limit) }
