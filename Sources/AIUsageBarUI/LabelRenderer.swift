import SwiftUI
import AppKit
import AIUsageBarCore

/// Renders the menu-bar label SwiftUI view into an `NSImage`.
///
/// A plain `MenuBarExtra` text/label gets monochrome-tinted by the system, which
/// drops our threshold colors — so we render our own non-template image instead.
/// Because a non-template image doesn't auto-adapt to the menu-bar's light/dark
/// appearance, we pick the text color from the current appearance at render time.
public enum LabelRenderer {
    @MainActor
    public static func render(chips: [LabelChip], isDark: Bool? = nil) -> NSImage {
        let dark = isDark ?? currentIsDark()
        return image(MenuBarLabelView(chips: chips, textColor: dark ? .white : .black))
    }

    @MainActor
    public static func renderMeters(items: [MenuBarMeterItem], isDark: Bool? = nil) -> NSImage {
        let dark = isDark ?? currentIsDark()
        return image(MenuBarMetersView(items: items, textColor: dark ? .white : .black))
    }

    @MainActor
    public static func renderNumber(percent: Double?) -> NSImage {
        image(MenuBarNumberView(percent: percent))
    }

    @MainActor
    public static func renderDot(percent: Double?) -> NSImage {
        image(MenuBarDotView(percent: percent))
    }

    @MainActor
    private static func image(_ view: some View) -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = false
        return image
    }

    @MainActor
    public static func currentIsDark() -> Bool {
        let appearance = NSApplication.shared.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
