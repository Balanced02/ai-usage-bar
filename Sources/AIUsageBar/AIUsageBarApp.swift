import AppKit
import SwiftUI
import AIUsageBarUI

@main
struct AIUsageBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let host = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Usage Bar Settings"
        window.contentViewController = host
        window.isRestorable = false
        window.disableSnapshotRestoration()
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon

        // The panel — an NSPopover sizes to its SwiftUI content every time,
        // which MenuBarExtra's window does not (it won't shrink back).
        let host = NSHostingController(rootView: MenuContentView(
            model: model,
            openSettings: { [weak self] in self?.showSettings() }
        ))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        // The menu-bar item. Left-click opens the popover; right-click shows a
        // quick menu without opening it.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateButtonImage()
        observeLabel()
        model.startPolling()
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Right-click quick menu

    private func showQuickMenu() {
        let menu = NSMenu()

        item(menu, "Refresh now", #selector(refreshNow), key: "r")
        menu.addItem(.separator())

        for kind in model.kinds {
            for card in model.cards(for: kind) {
                let peek = NSMenuItem(title: model.peek(card), action: nil, keyEquivalent: "")
                peek.isEnabled = false
                menu.addItem(peek)
            }
        }
        menu.addItem(.separator())

        item(menu, "Copy snapshot", #selector(copySnapshotAction), key: "c")

        let dashboards = NSMenu()
        for kind in model.kinds where Theme.dashboardURL(for: kind) != nil {
            let d = NSMenuItem(title: Theme.kindName(kind), action: #selector(openDashboard(_:)), keyEquivalent: "")
            d.representedObject = Theme.dashboardURL(for: kind)
            d.target = self
            dashboards.addItem(d)
        }
        let dashParent = NSMenuItem(title: "Open dashboard", action: nil, keyEquivalent: "")
        menu.addItem(dashParent)
        menu.setSubmenu(dashboards, for: dashParent)

        menu.addItem(.separator())
        item(menu, "Settings…", #selector(showSettings), key: ",")
        item(menu, "Quit", #selector(quit), key: "q")

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        }
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, key: String) {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    @objc private func refreshNow() { Task { await model.refresh() } }
    @objc private func copySnapshotAction() { model.copySnapshot() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc func showSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(model: model)
            controller.window?.delegate = self
            settingsWindowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window else { return }
        settingsWindowController = nil
    }

    @objc private func openDashboard(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
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
