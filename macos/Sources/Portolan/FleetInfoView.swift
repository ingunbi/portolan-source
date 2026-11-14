import SwiftUI
import PortolanCore

/// Fleet information (메뉴 26 자함대정보: 함선정보, 인물정보, 적하정보) and rations (메뉴 28 식량할당).
struct FleetInfoView: View {
    @ObservedObject var game: Game

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { game.showFleet = false }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("자함대 정보").font(.system(size: 28, weight: .bold, design: .serif))
                        HStack(spacing: 6) {
                            ForEach(Array(["함선", "인물", "적하", "배급"].enumerated()), id: \.offset) { index, label in
                                Button(label) { game.fleetTab = index }
                                    .buttonStyle(GameButtonStyle(prominent: game.fleetTab == index))
                                    .accessibilityIdentifier("portolan.fleet.tab.\(index)")
                            }
                        }
                        Spacer()
                        Button { game.showFleet = false } label: { Image(systemName: "xmark.circle.fill").font(GameFont.title2) }
                            .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("portolan.fleet.close")
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Group {
                            switch game.fleetTab {
                            case 0: ships
                            case 1: people
                            case 2: cargo
                            default: rations
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: min(900, geometry.size.width - 40) - 48, alignment: .topLeading)
                    }.frame(maxHeight: .infinity)
                        .accessibilityIdentifier("portolan.fleet.table")
                    if game.fleetTab < 2 {
                        Text("가로로 스크롤하면 모든 항목을 확인할 수 있습니다.")
                            .font(GameFont.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(width: min(900, geometry.size.width - 40), height: min(660, geometry.size.height - 32))
                .gamePanel()
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var ships: some View {
        let v = game.status
        let d = game.world.navigation
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(["배", "선종", "선장", "내구", "선회 · 추진", "선원", "대포", "적재", "사기", "선수상"], id: \.self) {
                    Text($0).font(GameFont.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(v.ships.indices, id: \.self) { i in
                let s = v.ships[i]
                GridRow {
                    Text(s.name).fontWeight(.semibold)
                    Text("\(d.classes[s.classIndex].name) · \(Shipyard.materials[s.material])")
                    Text(i == 0 ? v.captain.name : v.officers.indices.contains(i - 1) ? v.officers[i - 1].name : "—")
                    Text("\(s.hull)/\(s.maxHull)").monospacedDigit()
                    Text("\(s.rudder) · \(s.sail)").monospacedDigit()
                    Text("\(s.crew)/\(s.crewCapacity)").monospacedDigit()
                    Text(s.gunType == 0 ? "—" : "\(d.cannons[s.gunType - 1].name) \(s.guns)/\(s.gunCapacity)")
                    Text("\(s.cargoLoad)/\(s.cargoCapacity)").monospacedDigit()
                    Text("\(s.morale)").monospacedDigit().foregroundStyle(s.morale < Navigation.mutinyMorale ? Color.red : .primary)
                    Text(Shipyard.figureheadNames[s.figurehead])
                }.font(GameFont.callout)
            }
        }
    }

    private var people: some View {
        let v = game.status
        let names = ["통솔", "항해", "지식", "직감", "용기", "검술", "매력", "운"]
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("이름").font(GameFont.caption).foregroundStyle(.secondary)
                Text("직책").font(GameFont.caption).foregroundStyle(.secondary)
                Text("레벨").font(GameFont.caption).foregroundStyle(.secondary)
                ForEach(names, id: \.self) { Text($0).font(GameFont.caption).foregroundStyle(.secondary) }
                Text("충성 · 월급").font(GameFont.caption).foregroundStyle(.secondary)
            }
            GridRow {
                Text(v.captain.name).fontWeight(.semibold)
                Text("제독")
                Text("\(v.captain.navLevel) · \(v.captain.battleLevel)").monospacedDigit()
                ForEach(v.captain.stats.indices, id: \.self) { Text("\(v.captain.stats[$0])").monospacedDigit() }
                Text("—")
            }.font(GameFont.callout)
            ForEach(v.officers.indices, id: \.self) { k in
                let o = v.officers[k]
                GridRow {
                    Text(o.name).fontWeight(.semibold)
                    if k < v.ships.count - 1 {
                        Text("선장")
                    } else {
                        let officerOptions: [(OfficerPost?, String)] = [(nil, "항해사")] + OfficerPost.allCases.map { post -> (OfficerPost?, String) in
                            (post, post.name)
                        }
                        GamePicker("직책", selection: Binding<OfficerPost?>(get: { o.post }, set: { p in _ = game.act { $0.appoint(k, to: p) } }),
                                   options: officerOptions)
                            .frame(width: 150)
                    }
                    Text("\(o.navLevel) · \(o.battleLevel)").monospacedDigit()
                    ForEach(o.stats.indices, id: \.self) { Text("\(o.stats[$0])").monospacedDigit() }
                    Text("\(o.loyalty) · \(o.salary)닢").monospacedDigit().foregroundStyle(o.unpaid ? Color.orange : .primary)
                }.font(GameFont.callout)
            }
        }
    }

    private var cargo: some View {
        let v = game.status
        let d = game.world.navigation
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(v.ships.indices, id: \.self) { i in
                let s = v.ships[i]
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(s.name).fontWeight(.semibold).frame(width: 140, alignment: .leading)
                    Text("식수 \(s.water / 10) · 식량 \(s.food / 10) · 자재 \(s.lumber) · 포탄 \(s.shot)").monospacedDigit()
                    Text(s.holds.isEmpty ? "교역품 없음" : s.holds.map { "\(d.goods[$0.good].name) \($0.amount)" }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }.font(GameFont.callout)
            }
        }
    }

    /// Daily ration in percent (DS:0x2D55 water, 0x2D56 food; 0...100). Less food and water
    /// lasts longer but lowers morale: `100 − leadership / 5 − ration` a day, fifths when positive.
    private var rations: some View {
        let v = game.status
        return VStack(alignment: .leading, spacing: 12) {
            ration("식수", value: v.waterRation, perDay: v.dailyWater, stock: v.water) { r in game.act { $0.waterRation = r } }
            ration("식량", value: v.foodRation, perDay: v.dailyFood, stock: v.food) { r in game.act { $0.foodRation = r } }
            Text("배급을 줄이면 물자는 오래 가지만 매일 사기가 떨어집니다.").font(GameFont.caption).foregroundStyle(.secondary)
        }.frame(width: 660)
    }

    private func ration(_ title: String, value: Int, perDay: Int, stock: Int, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title).font(GameFont.headline).frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(Int($0.rounded())) }), in: 0...100)
            Text("\(value)% · 하루 \(perDay / 10)통 · \(perDay > 0 ? stock / perDay : 0)일분").monospacedDigit()
                .frame(width: 290, alignment: .trailing)
        }
    }
}
