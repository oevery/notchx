import AppKit

enum ScreenDetector {
    struct CompactIslandMetrics {
        let size: CGSize
        let bottomCornerRadius: CGFloat
    }

    /// Check if the given screen has a notch (MacBook Pro 14"/16" etc.)
    static func hasNotch(screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    /// Get the notch rectangle area for positioning
    static func notchRect(screen: NSScreen) -> NSRect? {
        guard let topLeft = screen.auxiliaryTopLeftArea,
              let topRight = screen.auxiliaryTopRightArea else { return nil }

        let screenFrame = screen.frame
        // The notch is between the two auxiliary areas
        let notchX = screenFrame.origin.x + topLeft.width
        let notchWidth = screenFrame.width - topLeft.width - topRight.width
        let notchY = screenFrame.maxY - max(topLeft.height, topRight.height)
        let notchHeight = max(topLeft.height, topRight.height)

        return NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
    }

    static func compactIslandMetrics(screen: NSScreen) -> CompactIslandMetrics? {
        guard let notch = notchRect(screen: screen) else {
            return nil
        }

        return compactIslandMetrics(notch: notch, requestedSize: CGSize(
            width: notch.width, height: notch.height - Constants.compactNotchHeightInset))
    }

    static func compactIslandMetrics(notch: NSRect, requestedSize: CGSize) -> CompactIslandMetrics {
        // The real camera area is the lower bound, even for a smaller saved size.
        let width = max(Constants.compactNotchMinimumWidth, notch.width,
                        requestedSize.width.isFinite ? requestedSize.width : 0)
        let height = max(Constants.compactNotchMinimumHeight, notch.height,
                         requestedSize.height.isFinite ? requestedSize.height : 0)
        let bottomCornerRadius = min(Constants.compactNotchBottomCornerRadius, height / 2)

        return CompactIslandMetrics(
            size: CGSize(width: width, height: height),
            bottomCornerRadius: bottomCornerRadius
        )
    }

    /// Get the screen that the mouse cursor is currently on
    static var activeScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        }
    }

    /// Get the primary screen
    static var primaryScreen: NSScreen? {
        NSScreen.main
    }

    /// Stable, per-display identifier string (`CGDirectDisplayID` as text).
    /// Persisted in settings so the user's chosen display survives relaunches.
    static func displayIDString(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return String(number.uint32Value)
    }

    /// Find a screen by the identifier produced by `displayIDString`.
    static func screen(withIDString id: String) -> NSScreen? {
        guard !id.isEmpty else { return nil }
        return NSScreen.screens.first { displayIDString(for: $0) == id }
    }

    /// Sentinel id for the "show on every connected display" mode.
    static let allDisplaysIdentifier = "all"

    /// Human-readable list of the connected screens for the display picker.
    /// First entry is always "Automatic" (empty id == follow default rules).
    struct ScreenOption: Identifiable, Hashable {
        let id: String           // "" for Automatic, "all" for every display, otherwise CGDirectDisplayID string
        let name: String
    }

    static func availableScreenOptions() -> [ScreenOption] {
        var options: [ScreenOption] = [ScreenOption(id: "", name: "Automatic")]
        if NSScreen.screens.count > 1 {
            options.append(ScreenOption(id: allDisplaysIdentifier, name: "All Displays"))
        }
        for screen in NSScreen.screens {
            guard let id = displayIDString(for: screen) else { continue }
            let name: String
            if !screen.localizedName.isEmpty {
                name = screen.localizedName
            } else {
                let size = screen.frame.size
                name = L10n.format("Display (%d×%d)", Int(size.width), Int(size.height))
            }
            let suffix = hasNotch(screen: screen) ? L10n.text(" — notch") : ""
            options.append(ScreenOption(id: id, name: name + suffix))
        }
        return options
    }
}
