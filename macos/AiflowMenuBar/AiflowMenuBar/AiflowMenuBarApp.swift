import SwiftUI

@main
struct AiflowMenuBarApp: App {
    /// The single app-lifetime source of truth for the current run. The menu bar view and the
    /// VS Code companion bridge both observe and control this one instance.
    @StateObject private var appModel = WidgetViewModel.shared

    /// The companion bridge must be listening from launch, not from the first time the user
    /// opens the popover, or VS Code could never connect to an idle app.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Aiflow", systemImage: appModel.menuBarSymbolName) {
            MenuBarView(viewModel: appModel)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            WidgetViewModel.shared.startCompanionBridgeIfNeeded()
            WidgetViewModel.shared.startHandoffTransportIfNeeded()
        }
    }
}
