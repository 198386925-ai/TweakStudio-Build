import SwiftUI

@main
struct TweakStudioApp: App {
    @StateObject private var store = TweakStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
