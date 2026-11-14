import SwiftUI
import PortolanCore

extension Game {
    func openVoyagePlan() {
        held.removeAll()
        townAim = nil
        tabMenu = nil
        showVoyagePlan = true
    }

    @discardableResult
    func beginPlannedRoute(to port: Harbor) -> Bool {
        guard harbor == nil, voyage.canAutoSail, !voyage.ashore,
              knownPorts(voyage).contains(where: { $0.id == port.id }) else { return false }
        guard act({ $0.autoSail(to: port, in: world) }) else {
            say("알려진 해역에서 항로를 찾지 못했습니다. 주변 해역을 더 탐사해 보세요.")
            return false
        }
        plannedPortID = port.id
        paused = false
        showVoyagePlan = false
        say("\(portName(port.id)) 항로를 설정했습니다. 입항은 도착 후 선택하세요.")
        return true
    }

    func cancelCourse() {
        act { v in v.route = []; v.waypoint = nil; v.sail = 0 }
        plannedPortID = nil
        say("항로를 취소하고 돛을 접었습니다.")
    }
}

/// A chart table: planning pauses the world, and committing a course uses the original rules.
struct VoyagePlanView: View {
    @ObservedObject var game: Game
    @State private var query = ""
    @State private var selection: Int?
    @State private var preview: [[Double]] = []
    @State private var routeAvailable = false

    private var ports: [Harbor] { game.knownPorts(game.status).filter { $0.id != game.harbor?.id } }
    private var filtered: [Harbor] { ports.filter { query.isEmpty || game.portName($0.id).localizedCaseInsensitiveContains(query) } }
    private var destination: Harbor? { ports.first { $0.id == selection } }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.66).ignoresSafeArea().onTapGesture { game.showVoyagePlan = false }
                VStack(spacing: 16) {
                    header
                    HStack(alignment: .top, spacing: 16) {
                        portList.frame(width: geometry.size.width < 1100 ? 250 : 290)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                chart
                                destinationCard
                                readiness
                            }
                        }
                    }
                    footer
                }
                .padding(24)
                .frame(width: min(1040, geometry.size.width - 48), height: min(720, geometry.size.height - 40))
                .gamePanel(radius: 24)
                .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            selection = game.plannedPortID ?? ports.first?.id
            refreshPreview()
        }
        .onChange(of: selection) { _, _ in refreshPreview() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "map.fill").font(.system(size: 24)).foregroundStyle(Theme.current)
                .frame(width: 50, height: 50).background(Theme.current.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("다음 항해를 준비하세요").font(.system(size: 24, weight: .bold))
                Text("목적지 · 보급 · 진행 중인 임무").font(GameFont.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Label("계획 중 · 시간 정지", systemImage: "pause.circle.fill").font(GameFont.caption).foregroundStyle(Theme.current)
            Button { game.showVoyagePlan = false } label: { Image(systemName: "xmark").frame(width: 18, height: 20) }
                .help("항해 계획 닫기").keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("portolan.plan.close")
        }
    }

    private var portList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("알려진 항구").font(GameFont.headline)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("항구 검색", text: $query).textFieldStyle(.plain)
            }.padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                LazyVStack(spacing: 5) {
                    if filtered.isEmpty {
                        Text(query.isEmpty ? "주변 해역을 탐사하면\n새로운 항구를 발견합니다." : "검색 결과가 없습니다.")
                            .font(GameFont.callout).foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(filtered, id: \.id) { port in
                        Button { selection = port.id; game.plannedPortID = port.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: port.id < 100 ? "building.2.crop.circle" : "drop.circle")
                                    .font(GameFont.title3).foregroundStyle(selection == port.id ? Theme.current : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(game.portName(port.id)).font(.system(size: 18, weight: .semibold))
                                    Text(port.id < 100 ? "교역항" : "보급항").font(GameFont.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == port.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.current) }
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == port.id ? Theme.current.opacity(0.12) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selection == port.id ? Theme.current.opacity(0.35) : .clear))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("현재 위치에서 가까운 순서").font(GameFont.caption2).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            ZStack {
                Theme.navy
                if let map = game.image("minimap.png") { Image(nsImage: map).resizable().opacity(0.82) }
                Canvas { ctx, size in
                    func point(_ x: Double, _ y: Double) -> CGPoint {
                        CGPoint(x: x / Double(World.width) * size.width, y: y / Double(World.height) * size.height)
                    }
                    var line = Path()
                    var last = point(game.status.x, game.status.y)
                    line.move(to: last)
                    for step in preview {
                        let next = point(step[0], step[1])
                        if abs(next.x - last.x) > size.width / 2 { line.move(to: next) } else { line.addLine(to: next) }
                        last = next
                    }
                    ctx.stroke(line, with: .color(Theme.current), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    for port in ports {
                        let p = point(Double(port.x), Double(port.y)), selected = port.id == selection
                        let r = selected ? 5.0 : 2.0
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2)), with: .color(selected ? Theme.gold : .white.opacity(0.5)))
                    }
                    let p = point(game.status.x, game.status.y)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x-5, y: p.y-5, width: 10, height: 10)), with: .color(Theme.current))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x-9, y: p.y-9, width: 18, height: 18)), with: .color(Theme.current.opacity(0.5)), lineWidth: 1.5)
                }
                VStack {
                    HStack { Text("항해도").font(GameFont.caption.bold()); Spacer(); Label("현재 위치", systemImage: "circle.fill").font(GameFont.caption2).foregroundStyle(Theme.current) }
                    Spacer()
                }.padding(12)
            }
        }
        .frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("목적지").font(GameFont.caption).foregroundStyle(Theme.current)
                    Text(destination.map { game.portName($0.id) } ?? "항구를 선택하세요").font(.system(size: 25, weight: .bold))
                }
                Spacer()
                Image(systemName: "location.north.line.fill").font(GameFont.title).foregroundStyle(Theme.current)
            }
            Text(routeNote).font(GameFont.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).gameSection()
    }

    private var routeNote: String {
        if destination == nil { return "발견한 항구 중 다음 목적지를 골라 보세요." }
        if !routeAvailable { return "현재 해도에서는 연결되는 항로를 찾지 못했습니다. 직접 항해하며 주변 해역을 밝혀 보세요." }
        if game.harbor != nil { return "항로를 확인했습니다. 보급을 마치고 항구에서 출항한 뒤 이곳에서 항로를 지정하세요." }
        if !game.status.canAutoSail { return "자동 항해를 쓰려면 측량 능력이 있는 부선장이 필요합니다. 함대 편성의 직책을 확인하세요." }
        if game.status.ashore { return "상륙을 마치고 배로 돌아오면 항로를 지정할 수 있습니다." }
        return "알려진 해역을 따라 항해합니다. 바람과 해류, 물자를 살피고 도착하면 입항을 선택하세요."
    }

    private var readiness: some View {
        let advice = game.status.advice(in: game.world)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                supply("식수", advice.waterDays, "drop.fill", Theme.wind)
                supply("식량", advice.foodDays, "takeoutbag.and.cup.and.straw.fill", Theme.gold)
                supply("함대", game.status.ships.count, "sailboat.fill", Theme.current, suffix: "척")
            }
            if let goal = advice.objective {
                VStack(alignment: .leading, spacing: 5) {
                    Label(goal.title, systemImage: "flag.fill").font(GameFont.headline).foregroundStyle(Theme.gold)
                    Text(goal.detail).font(GameFont.callout).foregroundStyle(.secondary)
                    if let days = goal.daysRemaining { Text(days >= 0 ? "기한까지 \(days)일" : "기한 경과").font(GameFont.caption).foregroundStyle(days < 5 ? Color.orange : .secondary) }
                    if let id = goal.destinationID, ports.contains(where: { $0.id == id }) {
                        Button("임무 목적지 선택") { selection = id; game.plannedPortID = id }
                    }
                }.padding(14).gameSection()
            }
            ForEach(advice.warnings, id: \.id) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(warning.severity == .critical ? Color.orange : Theme.gold)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(warning.title).font(GameFont.subheadline.bold())
                        Text(warning.detail).font(GameFont.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("보급 일수는 현재 선원과 배급량 기준 추정치이며, 항해 중 사건에 따라 달라집니다.")
                .font(GameFont.caption2).foregroundStyle(.secondary)
        }
    }

    private func supply(_ title: String, _ value: Int?, _ symbol: String, _ tint: Color, suffix: String = "일분") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(GameFont.caption).foregroundStyle(tint)
            Text(value.map { "\($0)\(suffix)" } ?? "—").font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).gameSection()
    }

    private var footer: some View {
        HStack {
            Button { game.showVoyagePlan = false; game.showFleet(tab: 1) } label: { Label("함대 편성", systemImage: "person.3") }
            Spacer()
            Button { if let port = destination { _ = game.beginPlannedRoute(to: port) } } label: {
                Label("항로 지정", systemImage: "location.north.fill").padding(.horizontal, 12)
            }.buttonStyle(GameButtonStyle(prominent: true))
                .disabled(destination == nil || !routeAvailable || game.harbor != nil || !game.status.canAutoSail || game.status.ashore)
        }
    }

    private func refreshPreview() {
        preview = []
        routeAvailable = false
        guard let destination else { return }
        var copy = game.status
        guard copy.autoSail(to: destination, in: game.world), let first = copy.waypoint else { return }
        preview = [[first.x, first.y]] + copy.route
        routeAvailable = true
    }
}
