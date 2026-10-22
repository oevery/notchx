import AppKit
import SwiftUI

/// Keep SwiftUI's scrolling, focus and ScrollViewReader behavior. Only the
/// native scroller layout changes: overlay where preferred, a stable gutter
/// for legacy scrollers, and no gutter for intentionally hidden indicators.
struct StableScrollView<Content: View>: View {
    @State private var viewportWidth: CGFloat?
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    @ViewBuilder var content: Content

    init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content
                // AppKit can reserve a gutter before SwiftUI invalidates its
                // cached document proposal. Use the real viewport immediately,
                // without rebuilding the content or resetting editor state.
                .frame(width: axes == .vertical ? viewportWidth : nil)
                // Keep the scroll container flexible instead of letting its
                // document width shrink the container by another gutter.
                .frame(maxWidth: axes == .vertical ? .infinity : nil, alignment: .leading)
                .background(ScrollLayoutAttachment(axes: axes, showsIndicators: showsIndicators, onViewportWidthChange: { width in
                    if axes == .vertical && viewportWidth != width { viewportWidth = width }
                }))
        }
        .scrollIndicators(showsIndicators ? .automatic : .never, axes: axes)
    }
}

extension View {
    /// List and TextEditor own their native scroll view rather than exposing
    /// its document content. Match only the scroll view in this control's frame.
    func stableNativeScrollLayout() -> some View {
        background(ScrollLayoutAttachment(matchesContainer: true))
    }
}

private struct ScrollLayoutAttachment: NSViewRepresentable {
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    var matchesContainer = false
    var onViewportWidthChange: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> ScrollLayoutAttachmentView { ScrollLayoutAttachmentView() }
    func updateNSView(_ view: ScrollLayoutAttachmentView, context: Context) {
        view.axes = axes
        view.showsIndicators = showsIndicators
        view.matchesContainer = matchesContainer
        view.onViewportWidthChange = onViewportWidthChange
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: ScrollLayoutAttachmentView, coordinator: ()) { view.stop() }
}

private final class ScrollLayoutAttachmentView: NSView {
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    var matchesContainer = false
    var onViewportWidthChange: ((CGFloat) -> Void)?
    private var reportedWidth: CGFloat?
    private weak var scrollView: NSScrollView?
    private weak var clipView: NSClipView?
    private var previousPostsFrameChanges = false
    private var resizeObserver: NSObjectProtocol?
    private var observations: [NSKeyValueObservation] = []
    private var pendingUpdate: DispatchWorkItem?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { scheduleUpdate() }
    }
    override func layout() {
        super.layout()
        if scrollView == nil || (!matchesContainer && scrollView !== enclosingScrollView)
            || scrollView?.contentView.bounds.width != reportedWidth { scheduleUpdate() }
    }

    func scheduleUpdate() {
        guard pendingUpdate == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingUpdate = nil
            guard self.window != nil, let target = self.findScrollView() else { return }
            if self.scrollView !== target {
                self.disconnect()
                self.scrollView = target
                // AppKit continues to handle subsequent input-device and
                // system preference changes, including legacy-only controls.
                target.scrollerStyle = NSScroller.preferredScrollerStyle
                self.observations = [
                    target.observe(\.autohidesScrollers) { [weak self] _, _ in self?.scheduleUpdate() },
                    target.observe(\.hasVerticalScroller) { [weak self] _, _ in self?.scheduleUpdate() },
                    target.observe(\.hasHorizontalScroller) { [weak self] _, _ in self?.scheduleUpdate() }
                ]
                let clip = target.contentView
                self.clipView = clip
                self.previousPostsFrameChanges = clip.postsFrameChangedNotifications
                clip.postsFrameChangedNotifications = true
                self.resizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                    object: clip, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleUpdate() }
                    }
            }
            // Overlay scrollers ignore autohidesScrollers. For legacy, false
            // reserves the same space whether the document fits or overflows.
            var changed = false
            if target.autohidesScrollers { target.autohidesScrollers = false; changed = true }
            let vertical = self.showsIndicators && self.axes.contains(.vertical)
            let horizontal = self.showsIndicators && self.axes.contains(.horizontal)
            if target.hasVerticalScroller != vertical { target.hasVerticalScroller = vertical; changed = true }
            if target.hasHorizontalScroller != horizontal { target.hasHorizontalScroller = horizontal; changed = true }
            if changed { target.tile() }
            let width = target.contentView.bounds.width
            if width > 0, self.reportedWidth != width {
                self.reportedWidth = width
                self.onViewportWidthChange?(width)
            }
        }
        pendingUpdate = work
        DispatchQueue.main.async(execute: work)
    }

    func stop() {
        pendingUpdate?.cancel(); pendingUpdate = nil
        disconnect()
    }

    private func disconnect() {
        observations.forEach { $0.invalidate() }; observations = []
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        clipView?.postsFrameChangedNotifications = previousPostsFrameChanges
        clipView = nil
        scrollView = nil
        reportedWidth = nil
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    private func findScrollView() -> NSScrollView? {
        guard matchesContainer else { return enclosingScrollView }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var ancestor = superview
        while let container = ancestor {
            if let match = matchingScrollView(in: container) { return match }
            ancestor = container.superview
        }
        return nil
    }

    private func matchingScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView {
            let rect = convert(bounds, to: scroll)
            if abs(rect.minX - scroll.bounds.minX) < 2, abs(rect.minY - scroll.bounds.minY) < 2,
               abs(rect.width - scroll.bounds.width) < 2, abs(rect.height - scroll.bounds.height) < 2 { return scroll }
        }
        return view.subviews.lazy.compactMap { self.matchingScrollView(in: $0) }.first
    }
}
