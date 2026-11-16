import SwiftUI

@main
struct UABEApp: App {
    @StateObject private var vm = BundleViewModel()
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
                .onOpenURL { url in
                    Task { await vm.openExternal(url) }
                }
        }
    }
}
