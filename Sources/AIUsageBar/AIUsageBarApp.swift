import SwiftUI
import AppKit
import AIUsageBarUI

@main
struct AIUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Menu-bar-only agent; the UI lives in an NSPopover managed by the delegate.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon

        // The panel — an NSPopover sizes to its SwiftUI content every time,
        // which MenuBarExtra's window does not (it won't shrink back).
        let host = NSHostingController(rootView: MenuContentView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        // The menu-bar item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        updateButtonImage()
        observeLabel()
        model.startPolling()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateButtonImage() {
        guard let button = statusItem.button else { return }
        if let image = model.labelImage {
            image.isTemplate = false
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "AI"
        }
    }

    /// Re-render the menu-bar button whenever the model's label image changes.
    private func observeLabel() {
        withObservationTracking {
            _ = model.labelImage
        } onChange: {
            Task { @MainActor in
                self.updateButtonImage()
                self.observeLabel()   // re-arm
            }
        }
    }
}
