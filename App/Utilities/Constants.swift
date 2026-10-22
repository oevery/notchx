import SwiftUI

enum Constants {
    // MARK: - Island Sizes
    static let compactSize = CGSize(width: 200, height: 36)
    static let nonNotchCompactSize = CGSize(width: 220, height: 28)
    static let expandedSize = CGSize(width: 408, height: 88)
    static let fullExpandedSize = CGSize(width: 658, height: 180)

    // MARK: - Window
    static let windowMaxWidth: CGFloat = 420
    static let windowMaxHeight: CGFloat = 260
    static let expandedShadowHorizontalPadding: CGFloat = 40
    static let expandedShadowBottomPadding: CGFloat = 40
    static let expandedNotchHeightBoost: CGFloat = 5
    static let compactNotchHorizontalInset: CGFloat = 1
    static let compactNotchHeightInset: CGFloat = -4
    static let compactNotchBottomCornerRadius: CGFloat = 12
    static let compactNotchMinimumWidth: CGFloat = 168
    static let compactNotchMinimumHeight: CGFloat = 32
    static let compactNotchVerticalOffset: CGFloat = 0
    static let compactSideWidth: CGFloat = 44
    static let compactSideCurve: CGFloat = 6
    static let compactSlotContentSize: CGFloat = 26
    static let compactSlotBrandSize: CGFloat = 18
    static let compactArtworkCornerRadius: CGFloat = 6
    static let compactMinimalHorizontalPadding: CGFloat = 14
    static let expandedTopInset: CGFloat = 0
    static let compactCornerRadius: CGFloat = 18
    static let expandedCornerRadius: CGFloat = 22
    static let fullExpandedCornerRadius: CGFloat = 40
    static let fullExpandedBottomCornerRadius: CGFloat = 28

    // Domain-specific HUD feedback; shell/page timing belongs to IslandMotion.
    static let progressBar: Animation = .easeInOut(duration: 0.15)
    static let overshootBounce: Animation = .spring(response: 0.36, dampingFraction: 0.68)

    // MARK: - Timing
    static let hudAutoDismissDelay: TimeInterval = 1.5
    static let hoverPeekDelay: TimeInterval = 0.3
    static let notificationDisplayDuration: TimeInterval = 2.0
    static let notificationHoverFullExpandWindow: TimeInterval = 10.0
    static let weatherRefreshInterval: TimeInterval = 1800 // 30 minutes

    // MARK: - Menu Bar
    static let menuBarIconName = "rectangle.on.rectangle.angled"
}

/// Content slots and decorative curves have independent dimensions.
/// totalWidth measures from the real camera edge to the outer shell edge.
struct CompactSideLayout: Equatable {
    let contentWidth = Constants.compactSideWidth
    let cornerInset = Constants.compactSideCurve
    var totalWidth: CGFloat { contentWidth + cornerInset }
    let canvasSize = Constants.compactSlotContentSize
    var brandSize: CGFloat { min(Constants.compactSlotBrandSize, canvasSize) }
}

/// Shared by host sizing, toolbar layout and offscreen presentation validation.
enum FullExpandedLayout {
    static let agentMaximumContentHeight: CGFloat = 420
    static let shelfHeight = ShelfGridLayout.contentHeight + shoulderTopPadding + bottomPadding + moduleBottomPadding
    static let shoulderTopPadding: CGFloat = 4
    static let inlineTopPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 14
    static let moduleBottomPadding: CGFloat = 4
    static let inlineToolbarHeight: CGFloat = 42
    static let toolbarSpacing: CGFloat = 8
    static var inlineHeightBoost: CGFloat {
        inlineToolbarHeight + toolbarSpacing + inlineTopPadding - shoulderTopPadding
    }
    static func shelfContentHeight(inlineToolbar: Bool, availableHeight: CGFloat?) -> CGFloat {
        let preferred = shelfHeight + (inlineToolbar ? inlineHeightBoost : 0)
        return min(preferred, max(0, availableHeight ?? preferred))
    }
    static func agentContentHeight(measuredHeight: CGFloat, inlineToolbar: Bool, availableHeight: CGFloat?) -> CGFloat {
        let preferred = measuredHeight + shoulderTopPadding + bottomPadding + moduleBottomPadding
            + (inlineToolbar ? inlineHeightBoost : 0)
        return min(preferred, agentMaximumContentHeight, max(0, availableHeight ?? preferred))
    }
    static func musicContentHeight(hasShoulderBar: Bool) -> CGFloat {
        let base = Constants.fullExpandedSize.height
        if hasShoulderBar { return base - shoulderTopPadding - bottomPadding }
        return base + inlineHeightBoost - inlineTopPadding - bottomPadding - inlineToolbarHeight - toolbarSpacing
    }
}
