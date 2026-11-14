import SwiftUI
import PortolanCore

/// What the slot window is for: 저장, 로드, or the save after an ending (0x1680C modes 0–3).
enum SlotMode {
    case save, load, ending
}

/// The ten-slot window (0x16328): date, port or 해상, a red '*' on ending saves, and
/// "Slot nn" for an empty slot.
struct SaveSlotsView: View {
    @ObservedObject var game: Game
    let mode: SlotMode
    @State private var note = ""
    /// An original KOUKAI2.DAT picked with 원작 세이브 (newgame.md §8.1).
    @State private var dos: DOSSave?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 10) {
                    Text(mode == .load ? "Ｌｏａｄ Ｄａｔａ" : "Ｓａｖｅ Ｄａｔａ").font(.system(size: 28, weight: .bold, design: .serif))
                    if mode == .ending { Text(game.message(746)).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true) }
                    if let error = game.saveError {
                        ScrollView {
                            Text(error).font(GameFont.callout).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }.frame(maxHeight: 110)
                            .accessibilityIdentifier("portolan.slots.error")
                    } else {
                        Text(note.isEmpty ? game.message(951) : note).font(GameFont.callout)
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView {
                        VStack(spacing: 8) {
                            if let d = dos { dosSlots(d) } else { slots }
                        }
                    }.frame(maxHeight: 420)
                    HStack {
                        if mode == .load {
                            Button(dos == nil ? "원작 세이브 파일 열기…" : "Portolan 슬롯") { pickDOS() }
                        }
                        Spacer()
                        Button(mode == .ending ? "저장하지 않음" : "취소") { close() }.keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("portolan.slots.close")
                    }
                }
                .padding(24)
                .frame(width: min(640, geometry.size.width - 48))
                .frame(maxHeight: geometry.size.height - 40)
                .font(GameFont.body)
                .gamePanel(radius: 18)
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

    }

    /// The slots of an original KOUKAI2.DAT: date, port or 해상, a red '*' on ending saves.
    private func dosSlots(_ d: DOSSave) -> some View {
        ForEach(0..<DOSSave.slots, id: \.self) { s in
            let h = d.header(s)
            Button {
                guard h != nil else { return }
                game.question = Question(text: game.message(952)) {
                    game.loadDOS(d, slot: s)
                }
            } label: {
                HStack(spacing: 14) {
                    Text(String(format: "%02d", s + 1)).monospacedDigit().foregroundStyle(.secondary)
                    if let h {
                        Text(h.date).monospacedDigit().frame(width: 170, alignment: .leading)
                        Text(h.port.map { game.portName($0) } ?? game.message(1072)).frame(maxWidth: .infinity, alignment: .leading)
                        if h.type != 0 { Text("*").foregroundStyle(.red).fontWeight(.bold) }
                    } else {
                        Text(String(format: "      Slot %02d", s + 1)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8).padding(.horizontal, 10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
                .accessibilityIdentifier("portolan.slots.dos.\(s)")
        }
    }

    private func pickDOS() {
        game.saveError = nil
        if dos != nil {
            dos = nil
            return
        }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.message = "원작의 KOUKAI2.DAT를 고르십시오."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let d = DOSSave(url: url) {
            dos = d
            note = ""
        } else {
            note = "KOUKAI2.DAT 형식이 아닙니다."
        }
        #endif
    }

    private var slots: some View {
        ForEach(0..<SaveGame.slots, id: \.self) { s in
            let state = SaveGame.inspect(s)
            VStack(alignment: .leading, spacing: 8) {
                Button { pick(s) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Text(String(format: "%02d", s + 1)).monospacedDigit().foregroundStyle(.secondary)
                        if let h = state.header {
                            Text(h.date).monospacedDigit().frame(width: 170, alignment: .leading)
                            Text(h.port ?? game.message(1072)).frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if h.type != 0 { Text("*").foregroundStyle(.red).fontWeight(.bold) }
                        } else {
                            Text(state.hasCurrent ? "현재 저장을 읽을 수 없습니다" : String(format: "Slot %02d", s + 1))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(mode == .load && !state.canLoad)
                .accessibilityIdentifier("portolan.slots.slot.\(s)")
                if let problem = state.problem {
                    Text(problem).font(GameFont.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if mode == .load, let backup = state.backupHeader {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("이전 정상 저장 · \(backup.date) · \(backup.port ?? game.message(1072))")
                            .font(GameFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("이전 정상 저장 불러오기") { pick(s, recovery: true) }
                            .accessibilityIdentifier("portolan.slots.recovery.\(s)")
                    }
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func pick(_ s: Int, recovery: Bool = false) {
        game.saveError = nil
        switch mode {
        case .load:
            let state = SaveGame.inspect(s)
            guard (recovery ? state.backupHeader != nil : state.canLoad) else {
                game.saveError = state.problem ?? "불러올 저장이 없습니다."
                return
            }
            let prompt = recovery
                ? "이전 정상 저장을 불러오시겠습니까? 현재 저장 파일은 덮어쓰지 않습니다."
                : game.message(952)
            game.question = Question(text: prompt) {
                game.load(slot: s, recovery: recovery)
            }
        case .save, .ending:
            game.question = Question(text: game.message(954)) {
                if game.save(slot: s, ending: mode == .ending) { close() }
            }
        }
    }

    private func close() {
        game.saveError = nil
        game.slotMode = nil
        if mode == .ending { game.endingSaved() }
    }
}
