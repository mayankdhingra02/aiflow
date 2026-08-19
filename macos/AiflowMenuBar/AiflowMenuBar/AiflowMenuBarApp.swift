import SwiftUI

@main
struct AiflowMenuBarApp: App {
    @StateObject private var appModel = WidgetViewModel()

    var body: some Scene {
        MenuBarExtra("Aiflow", systemImage: appModel.menuBarSymbolName) {
            MenuBarView(viewModel: appModel)
        }
        .menuBarExtraStyle(.window)
    }
}
