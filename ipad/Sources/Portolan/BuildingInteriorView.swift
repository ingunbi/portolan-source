import SwiftUI
import PortolanCore

/// The original GRAPH interior, shown as soon as the door opens, before its scenario.
/// Service controls remain separate so a refusal cannot accidentally unlock a shop.
struct BuildingInteriorView: View {
    @ObservedObject var game: Game
    let building: HarborPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(game.harbor.map { game.portName($0.id) } ?? "")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.wind)
                Spacer(minLength: 4)
                Text(building == .harbor ? "부두" : "실내")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(0.07), in: Capsule())
            }
            Text(building == .harbor ? "항구 사무소" : building.title)
                .font(.system(size: 28, weight: .semibold))
            Spacer(minLength: 0)
            if let image = game.buildingPicture(building) {
                Image(nsImage: image).pixelated().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(building.title + " 내부")
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(LinearGradient(colors: [Theme.navyLight, Theme.navy], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.gold.opacity(0.23)))
        .accessibilityIdentifier("portolan.building.scene.\(building.rawValue)")
    }
}
