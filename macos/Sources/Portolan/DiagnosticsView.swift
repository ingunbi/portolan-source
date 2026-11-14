import SwiftUI
import PortolanCore

struct DiagnosticsView: View {
    @ObservedObject var game: Game
    @State private var recording = true
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    Text("문제 재현용 진단 기록").font(GameFont.title2.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("최근 행동과 게임 상태를 이 컴퓨터에 보관합니다. 문제가 생기면 아래 내용을 확인한 뒤 진단 묶음을 저장하세요.")
                            Text(DiagnosticExport.privacy).foregroundStyle(.secondary)
                            Text("포함 파일: diagnostic.json · content-manifest.json · manifest.json · README.txt")
                                .font(GameFont.caption).fixedSize(horizontal: false, vertical: true)
                            Text("주인공: \(game.status.captain.name) · 선박: \(game.status.ships.map(\.name).joined(separator: ", "))")
                            Text("항해·조타·교역·보급·수리: 지원 코어 구간 재현\n대화·해전·도시: 실행 위치와 행동 문맥만 제공")
                            if let recorder = game.diagnostics {
                                Text("명령 \(recorder.recordCount)개 · 진단 사건 \(recorder.bundle.diagnosticOnlyEvents.count)개 · 순환 체크포인트 \(recorder.bundle.safeCheckpointsDiscarded)개 정리")
                                if recorder.isStopped { Text("용량 한도로 기록이 중단되었습니다. 현재 기록을 저장하거나 새 기록을 시작하세요.").foregroundStyle(.orange) }
                                ForEach(recorder.bundle.incompleteReasons, id: \.self) { Text($0).foregroundStyle(.orange).font(GameFont.caption) }
                            }
                            Toggle("진단 기록 켜기", isOn: $recording)
                                .onChange(of: recording) { game.diagnostics?.enabled = recording }
                                .accessibilityIdentifier("portolan.diagnostics.enabled")
                            Button("새 기록 시작") { game.restartDiagnostics(); recording = true }
                                .accessibilityIdentifier("portolan.diagnostics.restart")
                            if let status = game.diagnosticExportStatus {
                                Text(status).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("portolan.diagnostics.status")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("닫기") { game.showDiagnostics = false }.keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("portolan.diagnostics.close")
                        Spacer()
                        Button("진단 묶음 저장…") { game.chooseDiagnosticDestination() }
                            .buttonStyle(GameButtonStyle(prominent: true))
                            .accessibilityIdentifier("portolan.diagnostics.export")
                    }
                }
                .font(GameFont.body).padding(24)
                .frame(width: min(800, geometry.size.width - 48), height: min(650, geometry.size.height - 48))
                .gamePanel(radius: 20).environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.onAppear { recording = game.diagnostics?.enabled ?? false }
    }
}
