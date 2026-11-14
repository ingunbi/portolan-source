import SwiftUI
import PortolanCore

/// A rules profile is saved with the campaign. Layout settings never change this profile.
struct RulesView: View {
    @ObservedObject var game: Game
    @State private var destination: Int?
    private var profile: RulesProfile { game.title ? game.newGameRules : game.voyage.saveContext.rules }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    Text(game.title ? "새 게임 규칙" : "현재 항해 규칙").font(GameFont.title2.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("\(profile.mode.title) · 규칙 버전 \(profile.rulesRevision)")
                                .font(GameFont.title3.bold()).accessibilityIdentifier("portolan.rules.current")
                            Text("고전·현대 화면 선택은 표시 방식만 바꿉니다. 규칙과 저장 진행은 그대로 유지됩니다.")
                                .fixedSize(horizontal: false, vertical: true)
                            if game.title { selection } else { copySection }
                            Divider()
                            Text("확장 기능 준비 상황").font(GameFont.headline)
                            Text("현재 제공되는 추가 기능은 없습니다. 확장 프로필을 골라도 원작과 같은 게임 규칙으로 진행하며 아래 기능은 켜지지 않습니다.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(RulesRegistry.features, id: \.id) { feature in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(feature.title)
                                        Text("구현 대기 · 선택할 수 없습니다").font(GameFont.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("portolan.rules.feature.\(feature.id)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = game.rulesError {
                        ScrollView {
                            Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100).accessibilityIdentifier("portolan.rules.error")
                    }
                    HStack {
                        Spacer()
                        Button("닫기") { game.showRules = false; game.rulesError = nil }
                            .keyboardShortcut(.cancelAction).accessibilityIdentifier("portolan.rules.close")
                    }
                }
                .font(GameFont.body).padding(24)
                .frame(width: min(740, geometry.size.width - 40))
                .frame(maxHeight: geometry.size.height - 40)
                .gamePanel(radius: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.colorScheme, .dark)

    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(RulesMode.allCases, id: \.self) { mode in
                Button {
                    _ = game.selectNewGameRules(RulesProfile(mode: mode))
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: profile.mode == mode ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode == .original ? "원작 규칙으로 시작" : "확장 프로필로 시작").fontWeight(.semibold)
                            Text(mode == .original ? "원작의 이야기와 수치를 유지합니다." : "추가 기능은 아직 없습니다. 향후 확장을 위한 별도 프로필로 저장합니다.")
                                .font(GameFont.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("portolan.rules.select.\(mode.rawValue)")
            }
            Text("이 선택은 다음에 시작할 새 게임에 적용됩니다.").font(GameFont.callout).foregroundStyle(.secondary)
        }
    }

    private var copySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if profile.mode == .original {
                Text("확장 프로필 사본 만들기").font(GameFont.headline)
                Text("빈 슬롯에 새 사본을 만든 뒤 그 사본으로 계속합니다. 기존 원작 슬롯은 유지됩니다. 추가 기능은 활성화되지 않습니다.")
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = game.interaction.saveBlockReason {
                    Text(reason).foregroundStyle(Theme.gold).fixedSize(horizontal: false, vertical: true)
                }
                let empty = (0..<SaveGame.slots).filter { slot in
                    let info = SaveGame.inspect(slot)
                    return !info.hasCurrent && info.backupHeader == nil
                }
                if empty.isEmpty {
                    Text("사용 가능한 빈 슬롯이 없습니다.").foregroundStyle(Theme.gold)
                } else {
                    GamePicker("새 사본 슬롯", selection: $destination,
                               options: [(Int?.none, "슬롯 선택")] + empty.map { (Int?.some($0), String(format: "%02d · 빈 슬롯", $0 + 1)) },
                               accessibilityIdentifier: "portolan.rules.destination")
                    Button("선택한 빈 슬롯에 사본 만들기") {
                        guard let destination else { return }
                        game.question = Question(text: "원작 저장은 유지하고 선택한 빈 슬롯에 확장 프로필 사본을 만드시겠습니까? 추가 기능은 아직 제공되지 않습니다.") {
                            _ = game.createExpandedCopy(slot: destination)
                        }
                    }
                    .disabled(destination == nil || !game.interaction.canStoreVoyage)
                    .accessibilityIdentifier("portolan.rules.copy")
                }
            } else {
                Text("이 항해는 확장 프로필 사본입니다. 원작으로 돌아가려면 보존된 원작 슬롯을 불러오세요.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("활성화한 추가 기능: \(profile.enabledFeatures.isEmpty ? "없음" : profile.enabledFeatures.joined(separator: ", "))")
                .font(GameFont.callout).accessibilityIdentifier("portolan.rules.enabled")
        }
    }
}
