import SwiftUI

@main
struct DarkroomBoothApp: App {
    @StateObject private var controller = BoothController()

    var body: some Scene {
        WindowGroup("Darkroom Booth", id: "operator") {
            OperatorView()
                .environmentObject(controller)
                .frame(minWidth: 720, minHeight: 560)
        }
        Window("Booth", id: "booth") {
            BoothView()
                .environmentObject(controller)
        }
    }
}
