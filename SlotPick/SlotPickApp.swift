import Sparkle
import SwiftUI

@main
struct SlotPickApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 640, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
        }
    }
}

private struct CheckForUpdatesButton: View {
    private let updater: SPUUpdater
    @State private var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var body: some View {
        Button("アップデートを確認…") {
            updater.checkForUpdates()
        }
        .disabled(!canCheckForUpdates)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) {
            canCheckForUpdates = $0
        }
    }
}
