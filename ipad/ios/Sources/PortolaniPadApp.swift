import SwiftUI
import PortolanCore

@main
struct PortolanPadApp: App {
    private let game: Game? = Game.findAssets().flatMap { try? Game(assets: $0) }

    var body: some Scene {
        WindowGroup {
            if let game {
                RootView(game: game).ignoresSafeArea().statusBarHidden()
            } else {
                Text("자료(assets)를 찾을 수 없습니다.")
            }
        }
    }
}
