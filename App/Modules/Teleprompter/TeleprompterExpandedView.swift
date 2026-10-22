import SwiftUI
import AppKit

// MARK: - Preference key for measuring text height

private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Scroll-wheel catcher
//
// Transparent NSView that claims hits ONLY for scroll-wheel events.
// Clicks and hovers pass straight through to the buttons layered above it.

struct TeleprompterScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, Bool) -> Void   // (deltaY, hasPreciseScrollingDeltas)

    func makeNSView(context: Context) -> NSView {
        let view = _ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? _ScrollWheelNSView)?.onScroll = onScroll
    }
}

private final class _ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat, Bool) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
    }

    /// Consume swipe gestures so Mission Control / Space switching never fires.
    override func swipe(with event: NSEvent) { /* swallow */ }
    override func beginGesture(with event: NSEvent) { /* swallow */ }
    override func endGesture(with event: NSEvent) { /* swallow */ }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        return true
    }

    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        return true
    }

    /// Claim hits for the whole gesture family — not just `.scrollWheel`.
    /// When the user's scroll reaches a boundary, AppKit starts emitting
    /// `.swipe` / `.beginGesture` / `.endGesture` events as separate types.
    /// If we only claim `.scrollWheel`, those events slip through to the
    /// system gesture recognizer and switch Spaces.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent else { return nil }
        switch event.type {
        case .scrollWheel, .swipe, .beginGesture, .endGesture,
             .magnify, .rotate, .smartMagnify, .pressure, .gesture:
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        default:
            return nil
        }
    }
}

// MARK: - Scrolling text engine

struct TeleprompterScrollingTextView: View {
    @Environment(\.islandContentActive) private var contentActive
    let containerHeight: CGFloat

    @EnvironmentObject var appState: AppState
    @ObservedObject private var manager: TeleprompterManager
    @State private var offset: CGFloat = 0
    @State private var textHeight: CGFloat = 0
    @State private var scrollTimer: Timer?
    @State private var scrollGeneration = UUID()
    @State private var appliedNudge: CGFloat = 0
    @State private var appliedSeekID: UUID?
    @State private var paragraphTops: [Int: CGFloat] = [:]

    init(containerHeight: CGFloat, manager: TeleprompterManager? = nil) {
        self.containerHeight = containerHeight
        self.manager = manager ?? .shared
    }

    private var maxOffset: CGFloat {
        max(0, textHeight - containerHeight)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * min(1, max(0.5, manager.columnWidth))
            textBlock(width: width)
                .offset(y: -offset)
                .frame(width: geo.size.width, alignment: .top)
                .onChange(of: manager.seekRequest) { _, _ in applySeek(width: width) }
                .onChange(of: textHeight) { _, _ in applySeek(width: width) }
                .onAppear { updateParagraphLayout(width: width); applySeek(width: width) }
                .onChange(of: width) { _, _ in updateParagraphLayout(width: width) }
                .onChange(of: manager.fontSize) { _, _ in updateParagraphLayout(width: width) }
                .onChange(of: manager.scriptText) { _, _ in updateParagraphLayout(width: width) }
        }
        .clipped()
        .mask(bottomFade)
        // Constrain hit-testing to the GeometryReader's rect and make the
        // text itself non-interactive. Without this, the scrolled text's
        // layout bounds (huge due to fixedSize + padding) can swallow clicks
        // destined for sibling chrome like the island's lock/settings buttons.
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }
        .onChange(of: manager.isPlaying) { _, playing in
            playing ? startScrolling() : stopScrolling()
        }
        .onChange(of: appState.shouldReduceAnimations) { _, _ in
            guard manager.isPlaying else { return }
            startScrolling()
        }
        .onChange(of: manager.resetToken) { _, _ in
            stopScrolling()
            appliedNudge = manager.scrollNudge
            withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
        }
        .onChange(of: manager.scriptText) { _, _ in
            offset = 0; textHeight = 0
            appliedNudge = manager.scrollNudge
        }
        .onChange(of: manager.scrollNudge) { _, total in
            let delta = total - appliedNudge
            appliedNudge = total
            offset = max(0, min(maxOffset, offset + delta))
            reportScrollPosition()
        }
        .onChange(of: contentActive) { _, active in
            if active && manager.isPlaying { startScrolling() } else { stopScrolling() }
        }
        .onAppear { if manager.isPlaying { startScrolling() } }
        .onDisappear { stopScrolling(); manager.captureClassicViewPosition() }
    }

    private func textBlock(width: CGFloat) -> some View {
        let frameAlign: Alignment = {
            switch manager.textAlignment {
            case .leading:  return .topLeading
            case .trailing: return .topTrailing
            default:        return .top
            }
        }()

        return Text(manager.wordTrackingDisplayText)
            .font(.system(size: manager.fontSize, weight: .regular))
            .foregroundColor(.white.opacity(0.92))
            .lineSpacing(manager.fontSize * 0.35)
            .multilineTextAlignment(manager.textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: frameAlign)
            .padding(.top, containerHeight * manager.readingGuidePosition)
            .padding(.bottom, containerHeight * (1 - manager.readingGuidePosition))
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TextHeightKey.self, value: g.size.height)
                }
            )
    }

    private var bottomFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .black, location: 0.20),
                .init(color: .black, location: 0.74),
                .init(color: .clear, location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func startScrolling() {
        stopScrolling()
        guard contentActive else { return }
        let generation = scrollGeneration
        let framesPerSecond: Double = appState.shouldReduceAnimations ? 24 : 30
        scrollTimer = Timer(timeInterval: 1.0 / framesPerSecond, repeats: true) { _ in
            Task { @MainActor in
                guard manager.isPlaying, contentActive, scrollGeneration == generation else { return }
                let delta = CGFloat(manager.scrollSpeed / framesPerSecond)
                let next = min(offset + delta, maxOffset)
                offset = next
                reportScrollPosition()
                if maxOffset > 0, next >= maxOffset { manager.pause() }
            }
        }
        scrollTimer?.tolerance = 0.01
        if let scrollTimer { RunLoop.main.add(scrollTimer, forMode: .common) }
    }

    private func stopScrolling() {
        scrollGeneration = UUID()
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func applySeek(width: CGFloat) {
        let request = manager.seekRequest
        guard appliedSeekID != request.id, width > 1, maxOffset > 0 else { return }
        let position = TeleprompterLineLayout.position(forCharacterOffset: request.displayOffset, in: manager.wordTrackingDisplayText,
                                                     width: width, fontSize: manager.fontSize, lineSpacing: manager.fontSize * 0.35, alignment: manager.textAlignment)
        offset = request.progress.map { min(maxOffset, max(0, CGFloat($0) * maxOffset)) }
            ?? min(maxOffset, max(0, position.top))
        appliedSeekID = request.id
        reportScrollPosition()
    }

    private func updateParagraphLayout(width: CGFloat) {
        guard width > 1 else { return }
        let text = manager.wordTrackingDisplayText
        let offsets = manager.paragraphs.map(\.id)
        let positions = TeleprompterLineLayout.positions(forCharacterOffsets: offsets, in: text,
                                                       width: width, fontSize: manager.fontSize,
                                                       lineSpacing: manager.fontSize * 0.35, alignment: manager.textAlignment)
        paragraphTops = Dictionary(uniqueKeysWithValues: zip(offsets, positions).map { ($0.0, $0.1.top) })
        reportScrollPosition()
    }

    private func reportScrollPosition() {
        let paragraph = manager.paragraphs.last { paragraph in
            guard let top = paragraphTops[paragraph.id] else { return false }
            return top <= offset + 0.5
        }
        manager.reportProgress(maxOffset > 0 ? Double(offset / maxOffset) : 0, paragraphOffset: paragraph?.id)
    }
}

// MARK: - Compact expanded (408 × 88)

private struct TeleprompterExpandedInner: View {
    @ObservedObject var manager: TeleprompterManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "scroll")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(manager.isPlaying ? 0.85 : 0.28))
                .symbolEffect(.pulse, isActive: manager.isPlaying)
                .frame(width: 26)

            GeometryReader { geo in
                if manager.hasScript {
                    TeleprompterTextSurface(containerHeight: geo.size.height, manager: manager)
                } else {
                    TeleprompterEmptyState(manager: manager, compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if manager.hasScript {
                VStack(spacing: 8) {
                    iconButton("arrow.counterclockwise", size: 12) { manager.reset() }
                    if manager.pendingResumePosition != nil {
                        iconButton("arrow.up.left.and.arrow.down.right", size: 14, bold: true,
                                   annotationID: "teleprompter-show-recovery-control") { manager.play() }
                            .help("Continue Reading")
                            .accessibilityLabel(L10n.text("Continue Reading"))
                    } else {
                        iconButton(
                            manager.isPlaying || manager.isCountingDown ? "pause.fill" : "play.fill",
                            size: 14, bold: true,
                            annotationID: "teleprompter-play-control"
                        ) { manager.togglePlayPause() }
                    }
                }
            }
        }
    }
}

// MARK: - Full expanded (658 × 180)

struct TeleprompterFullExpandedInner: View {
    @Environment(\.islandContentActive) private var contentActive
    @ObservedObject private var manager: TeleprompterManager
    @State private var spaceMonitor: Any?
    private let editScript: @MainActor () -> Void

    init(manager: TeleprompterManager? = nil, editScript: @escaping @MainActor () -> Void = { TeleprompterScriptEditorWindowController.show() }) {
        self.manager = manager ?? .shared
        self.editScript = editScript
    }

    var body: some View {
        VStack(spacing: 6) {
            TeleprompterToolbar(manager: manager, editScript: editScript)
                .layoutPriority(1)
            GeometryReader { geo in
                ZStack {
                    if manager.hasScript {
                        TeleprompterTextSurface(containerHeight: geo.size.height, manager: manager)
                    } else {
                        TeleprompterEmptyState(manager: manager, editScript: editScript)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                    if let n = manager.countdownValue {
                        Text("\(n)")
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .transition(.asymmetric(insertion: .scale(scale: 1.3).combined(with: .opacity), removal: .scale(scale: 0.7).combined(with: .opacity)))
                            .animation(.spring(duration: 0.3), value: n)
                            .id(n)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("teleprompter-reading-viewport")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if contentActive { installSpaceMonitor() } }
        .onChange(of: contentActive) { _, active in
            if active { installSpaceMonitor() } else { removeSpaceMonitor() }
        }
        .onDisappear { removeSpaceMonitor() }
    }

    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window is IslandPanel else { return event }
            let hasModifiers = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            guard let action = TeleprompterKeyboardAction.resolve(keyCode: event.keyCode, hasModifiers: hasModifiers,
                                                                 isRepeat: event.isARepeat, isEditing: event.window?.firstResponder is NSTextView) else { return event }
            Task { @MainActor in manager.perform(action) }
            return nil
        }
    }

    private func removeSpaceMonitor() {
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        spaceMonitor = nil
    }
}

// MARK: - Shared helpers

struct TeleprompterEmptyState: View {
    @ObservedObject private var manager: TeleprompterManager
    @ObservedObject private var sessionStore: TeleprompterSessionStore
    private let compact: Bool
    private let editScript: @MainActor () -> Void

    init(manager: TeleprompterManager, compact: Bool = false,
         editScript: @escaping @MainActor () -> Void = { TeleprompterScriptEditorWindowController.show() }) {
        self.manager = manager
        self.sessionStore = manager.sessionStore
        self.compact = compact
        self.editScript = editScript
    }

    private var hasDraft: Bool {
        !(sessionStore.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if compact {
            scriptButton.buttonStyle(.plain).font(.caption).foregroundStyle(.primary)
        } else {
            VStack(spacing: 8) {
                Text(L10n.text(hasDraft ? "You have a saved draft" : "No script added yet"))
                    .font(.headline)
                    .accessibilityIdentifier("teleprompter-empty-title")
                Text(L10n.text(hasDraft
                               ? "Continue editing, then choose Done to start prompting."
                               : "Add or paste a script to start prompting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("teleprompter-empty-description")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { emptyActions }.fixedSize()
                    VStack(spacing: 6) { emptyActions }.fixedSize()
                }
                .controlSize(.regular)
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("teleprompter-empty-state")
        }
    }

    @ViewBuilder
    private var emptyActions: some View {
        scriptButton.buttonStyle(.borderedProminent)
        TeleprompterReadingOptionsButton(manager: manager) {
            Text(L10n.text("Reading settings"))
        }
        .buttonStyle(.bordered)
        .dataAnnotationID("teleprompter-empty-settings-control")
    }

    private var scriptButton: some View {
        Button(action: editScript) {
            Label(L10n.text(hasDraft ? "Continue editing draft" : "Add script"),
                  systemImage: hasDraft ? "pencil" : "plus.circle")
        }
        .dataAnnotationID("teleprompter-edit-script-button")
    }
}

@ViewBuilder
private func iconButton(
    _ icon: String,
    size: CGFloat,
    bold: Bool = false,
    annotationID: String? = nil,
    action: @escaping () -> Void
) -> some View {
    let button = Button(action: action) {
        Image(systemName: icon)
            .font(.system(size: size, weight: bold ? .bold : .regular))
            .foregroundColor(.white.opacity(bold ? 1.0 : 0.55))
    }
    .buttonStyle(.plain)
    .hoverPointer()

    if let annotationID {
        button.dataAnnotationID(annotationID)
    } else {
        button
    }
}

private struct TeleprompterTextSurface: View {
    let containerHeight: CGFloat

    @ObservedObject private var manager: TeleprompterManager

    init(containerHeight: CGFloat, manager: TeleprompterManager? = nil) {
        self.containerHeight = containerHeight
        self.manager = manager ?? .shared
    }

    var body: some View {
        Group {
            if manager.listeningMode == .wordTracking {
                TeleprompterWordTrackingTextView(containerHeight: containerHeight, manager: manager)
            } else {
                TeleprompterScrollingTextView(containerHeight: containerHeight, manager: manager)
            }
        }
        .overlay {
            TeleprompterScrollWheelCatcher { deltaY, isPrecise in
                manager.nudgeOffset(by: scrollNudge(deltaY: deltaY, isPrecise: isPrecise))
            }
        }
        .overlay(alignment: .top) {
            if manager.showsReadingGuide {
                Rectangle().fill(.orange.opacity(0.55)).frame(height: 1)
                    .offset(y: containerHeight * manager.readingGuidePosition)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomLeading) {
            TeleprompterSpeechStatus(manager: manager)
                .padding(.bottom, 2)
        }
    }

    private func scrollNudge(deltaY: CGFloat, isPrecise: Bool) -> CGFloat {
        let pxPerLine = manager.fontSize * 1.4
        // Direction: scroll UP = rewind, scroll DOWN = fast-forward.
        return isPrecise ? -deltaY * 1.2 : -deltaY * pxPerLine
    }
}

private struct TeleprompterSpeechStatus: View {
    @ObservedObject private var manager: TeleprompterManager
    @ObservedObject private var speech: TeleprompterSpeechRecognizer

    init(manager: TeleprompterManager) {
        self.manager = manager
        self.speech = manager.speechRecognizer
    }

    var body: some View {
        if manager.listeningMode == .wordTracking {
            HStack(spacing: 5) {
                Image(systemName: statusIcon)
                    .font(.system(size: 9, weight: .medium))
                if manager.isPlaying, speech.isListening {
                    levelMeter
                }
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(.black.opacity(0.28)))
            .dataAnnotationID("teleprompter-speech-status")
        }
    }

    private var statusText: String {
        if let error = speech.error, !error.isEmpty { return error }
        if manager.isCountingDown { return L10n.text("Starting soon") }
        if manager.isPlaying, speech.isListening {
            if !speech.lastSpokenText.isEmpty {
                let spoken = speech.lastSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                return L10n.format("Heard: %@ · %@", String(spoken.prefix(18)), diagnosticLabel)
            }
            return speech.inputLevel > 0.006
                ? L10n.format("Listening · %@", diagnosticLabel)
                : L10n.format("Waiting for voice · %@", diagnosticLabel)
        }
        return L10n.text("Word Tracking")
    }

    private var statusIcon: String {
        if speech.error != nil { return "exclamationmark.triangle.fill" }
        if manager.isPlaying, speech.isListening { return "waveform" }
        return "text.word.spacing"
    }

    private var statusColor: Color {
        if speech.error != nil { return .orange.opacity(0.9) }
        if speech.matchConfidenceLabel.hasPrefix("Weak") || speech.matchConfidenceLabel.hasPrefix("No") {
            return .orange.opacity(0.72)
        }
        if manager.isPlaying, speech.inputLevel > 0.006 { return .white.opacity(0.62) }
        return .white.opacity(0.42)
    }

    private var diagnosticLabel: String {
        speech.matchConfidenceLabel.isEmpty ? progressLabel : speech.matchConfidenceLabel
    }

    private var progressLabel: String {
        let total = max(manager.wordTrackingDisplayText.count, 1)
        let clamped = min(max(speech.recognizedCharCount, 0), total)
        return "\(Int((Double(clamped) / Double(total)) * 100))%"
    }

    private var levelMeter: some View {
        GeometryReader { geometry in
            Capsule(style: .continuous)
                .fill(.white.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.56))
                        .frame(width: max(2, geometry.size.width * min(max(speech.inputLevel, 0), 1)))
                }
        }
        .frame(width: 18, height: 3)
    }
}

// MARK: - Public entry point

struct TeleprompterExpandedView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.islandPresentationState) private var presentationState
    @ObservedObject private var manager: TeleprompterManager

    init(manager: TeleprompterManager? = nil) { self.manager = manager ?? .shared }

    var body: some View {
        if (presentationState ?? appState.currentState) == .fullExpanded {
            TeleprompterFullExpandedInner(manager: manager)
        } else {
            TeleprompterExpandedInner(manager: manager)
        }
    }
}
