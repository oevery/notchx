import AppKit

/// One physical-input snapshot shared by hover and drag-approach consumers.
struct IslandPointerSnapshot {
    let location: NSPoint
    var pressedButtons: Int = 0

    static var live: Self { Self(location: NSEvent.mouseLocation, pressedButtons: NSEvent.pressedMouseButtons) }
    var leftButtonDown: Bool { pressedButtons & 1 != 0 }
}

/// Logical regions are independent of the larger animation viewport. Expanded
/// frames include their existing shadow margin; compact frames gain a small
/// approach band without making transparent pixels intercept clicks.
struct IslandPointerRegion {
    let frame: NSRect
    let screenFrame: NSRect

    func contains(_ point: NSPoint, keepingHover: Bool) -> Bool {
        let tolerance: CGFloat = keepingHover ? 8 : 4
        let region = frame.insetBy(dx: -tolerance, dy: -tolerance).intersection(screenFrame)
        // AppKit's contains excludes the top edge where the pointer is clamped.
        return !region.isNull && point.x >= region.minX && point.x <= region.maxX
            && point.y >= region.minY && point.y <= region.maxY
    }

    static func isHovering(at point: NSPoint, regions: [Self], keepingHover: Bool) -> Bool {
        regions.contains { $0.contains(point, keepingHover: keepingHover) }
    }
}
