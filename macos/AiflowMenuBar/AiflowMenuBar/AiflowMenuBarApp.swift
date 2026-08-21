import AppKit
import Combine
import SwiftUI

@main
struct AiflowMenuBarApp: App {
    @StateObject private var appModel = WidgetViewModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var widgetPresenter: AiflowWidgetPresenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let viewModel = WidgetViewModel.shared
        let presenter = AiflowWidgetPresenter(viewModel: viewModel)
        widgetPresenter = presenter
        viewModel.attachAttentionPresenter(presenter)
        AiflowWidgetPresentation.show = { [weak presenter] in
            presenter?.showWidgetIfNeeded()
        }
        viewModel.startCompanionBridgeIfNeeded()
        viewModel.startHandoffTransportIfNeeded()
    }
}

/// SwiftUI's MenuBarExtra has no public API for programmatic opening. This small AppKit host
/// keeps the same MenuBarView and shared WidgetViewModel while allowing attention events and
/// notification taps to show the existing widget without synthetic input.
@MainActor
final class AiflowWidgetPresenter: NSObject, AttentionWidgetPresenting, NSPopoverDelegate {
    private let viewModel: WidgetViewModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var stateObserver: AnyCancellable?

    init(viewModel: WidgetViewModel) {
        self.viewModel = viewModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarView(viewModel: viewModel))
        popover.contentSize = NSSize(width: 348, height: 560)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleWidget(_:))
        }
        refreshStatusItem()
        stateObserver = viewModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatusItem() }
        }
    }

    var isWidgetVisible: Bool { popover.isShown }

    func showWidgetIfNeeded() {
        guard !popover.isShown, let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func toggleWidget(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showWidgetIfNeeded()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        viewModel.popoverDidBecomeVisible()
    }

    func popoverDidClose(_ notification: Notification) {
        viewModel.popoverDidBecomeHidden()
    }

    private func refreshStatusItem() {
        statusItem.button?.image = NSImage(
            systemSymbolName: viewModel.menuBarSymbolName,
            accessibilityDescription: "Aiflow"
        )
    }
}
