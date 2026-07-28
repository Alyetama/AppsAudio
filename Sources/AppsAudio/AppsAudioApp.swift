import AppKit
import SwiftUI

@main
struct AppsAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        // No windows — this is a pure menu-bar (status item) app.
        Settings { EmptyView() }
    }
}

/// Uses a plain NSStatusItem + NSPopover rather than SwiftUI's MenuBarExtra:
/// MenuBarExtra's window popover flickers / fails to anchor when the item lives
/// in Bartender's hidden section. A real status item behaves correctly there.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: MixerView(model: model))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "slider.vertical.3",
                                   accessibilityDescription: "AppsAudio")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        model.refresh()                        // ensure the list is current on open
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
