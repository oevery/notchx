import SwiftUI

/// Presentation only: all reading, recovery and preference changes remain
/// with the existing manager. The main row never competes with inline settings.
struct TeleprompterToolbar: View {
    @ObservedObject var manager: TeleprompterManager
    @ObservedObject private var speech: TeleprompterSpeechRecognizer
    let editScript: @MainActor () -> Void

    init(manager: TeleprompterManager, editScript: @escaping @MainActor () -> Void) {
        self.manager = manager
        self.speech = manager.speechRecognizer
        self.editScript = editScript
    }

    var body: some View {
        if manager.hasScript {
            VStack(spacing: 6) {
                primaryActions
                ViewThatFits(in: .horizontal) {
                    statusRow(showsParagraphTitle: true)
                    statusRow(showsParagraphTitle: false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("teleprompter-toolbar")
        }
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            if manager.pendingResumePosition != nil {
                Button(L10n.text("Continue Reading")) { manager.resumeSavedPosition() }
                    .dataAnnotationID("teleprompter-resume-control")
                Button(L10n.text("Start Over")) { manager.reset() }
                    .dataAnnotationID("teleprompter-start-over-control")
            } else {
                Button { manager.reset() } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Reset")
                .accessibilityLabel(L10n.text("Reset"))
                .dataAnnotationID("teleprompter-reset-control")

                Button { manager.togglePlayPause() } label: {
                    Image(systemName: manager.isPlaying || manager.isCountingDown ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(manager.isPlaying || manager.isCountingDown ? L10n.text("Pause") : L10n.text("Play"))
                .dataAnnotationID("teleprompter-play-control")
            }

            Spacer(minLength: 8)

            Button(action: editScript) {
                Label(L10n.text("Edit"), systemImage: "pencil")
                    .frame(minWidth: 48)
            }
            .dataAnnotationID("teleprompter-edit-script-button")

            TeleprompterReadingOptionsButton(manager: manager) {
                Image(systemName: "ellipsis").frame(width: 20)
            }
            .accessibilityLabel(L10n.text("More"))
            .help("Reading settings")
            .dataAnnotationID("teleprompter-more-control")
        }
        .font(.callout)
        .controlSize(.small)
        .buttonStyle(.bordered)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statusRow(showsParagraphTitle: Bool) -> some View {
        HStack(spacing: 8) {
            let progress = manager.pendingResumePosition?.progress ?? manager.readingProgress
            Text(L10n.format("Progress %d%%", Int(progress * 100))).monospacedDigit()
                .fixedSize()
                .accessibilityIdentifier("teleprompter-progress")
            Text(manager.speedDescription).fixedSize()
            Spacer(minLength: 8)
            Menu {
                ForEach(manager.paragraphs) { paragraph in
                    Button(paragraph.title) { manager.jumpToParagraph(paragraph.id) }
                }
            } label: {
                if showsParagraphTitle {
                    Label(L10n.text("Go to paragraph"), systemImage: "list.bullet")
                } else {
                    Image(systemName: "list.bullet").frame(width: 24, height: 20)
                }
            }
            .id(showsParagraphTitle)
            .fixedSize()
            .disabled(manager.paragraphs.isEmpty || manager.pendingResumePosition != nil)
            .help("Go to paragraph")
            .accessibilityLabel(L10n.text("Go to paragraph"))
            .dataAnnotationID("teleprompter-paragraph-control")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Both empty and reading states use the same native presentation lifecycle.
struct TeleprompterReadingOptionsButton<LabelContent: View>: View {
    @Environment(\.islandContentActive) private var contentActive
    @ObservedObject var manager: TeleprompterManager
    @ViewBuilder let label: () -> LabelContent
    @State private var showsOptions = false

    var body: some View {
        Button {
            guard contentActive else { return }
            manager.pause()
            showsOptions.toggle()
        } label: { label() }
        .popover(isPresented: $showsOptions) {
            TeleprompterReadingOptions(manager: manager) { showsOptions = false }
                .preferredColorScheme(.dark)
        }
        .islandPopoverInteraction(isPresented: $showsOptions, module: .teleprompter)
    }
}

struct TeleprompterReadingOptions: View {
    @ObservedObject var manager: TeleprompterManager
    let dismiss: () -> Void
    @State private var alignmentSelection: Int

    init(manager: TeleprompterManager, dismiss: @escaping () -> Void) {
        self.manager = manager
        self.dismiss = dismiss
        _alignmentSelection = State(initialValue: manager.textAlignmentIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Reading settings")).font(.headline)
                .accessibilityIdentifier("teleprompter-reading-options-title")
            Stepper(value: $manager.fontSize, in: 12...40, step: 2) {
                HStack {
                    Text(L10n.text("Font size"))
                    Spacer()
                    Text(L10n.format("%d pt", Int(manager.fontSize))).monospacedDigit()
                }
            }
            .accessibilityIdentifier("teleprompter-font-size-control")
            Picker(L10n.text("Alignment"), selection: $alignmentSelection) {
                Label(L10n.text("Left"), systemImage: "text.alignleft").tag(0)
                Label(L10n.text("Center"), systemImage: "text.aligncenter").tag(1)
                Label(L10n.text("Right"), systemImage: "text.alignright").tag(2)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("teleprompter-alignment-control")
            // The native segmented picker can update its binding while
            // reconciling views. Commit through the selection event instead
            // of publishing manager changes inside that reconciliation.
            .onChange(of: alignmentSelection) { _, value in
                if manager.textAlignmentIndex != value { manager.textAlignmentIndex = value }
            }
            .onChange(of: manager.textAlignmentIndex) { _, value in alignmentSelection = value }
            if manager.listeningMode == .classic {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.text("Scroll speed"))
                        Spacer()
                        Text(manager.speedDescription).monospacedDigit()
                    }
                    Slider(value: $manager.scrollSpeed, in: 1...30, step: 0.5)
                        .accessibilityLabel(L10n.text("Scroll speed"))
                        .accessibilityIdentifier("teleprompter-scroll-speed-control")
                }
            }
            if manager.hasScript, manager.listeningMode == .wordTracking, manager.pendingResumePosition == nil {
                Divider()
                Text(L10n.text("Reading recovery")).font(.headline)
                Button(L10n.text("Restart Current Paragraph")) { manager.restartCurrentParagraph(); dismiss() }
                    .accessibilityIdentifier("teleprompter-restart-paragraph-control")
                Button(L10n.text("Switch to Constant Speed")) { manager.switchToClassicAtCurrentPosition(); dismiss() }
                    .accessibilityIdentifier("teleprompter-classic-recovery-control")
            }
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .foregroundStyle(.primary)
        .padding(16)
        .frame(width: 312)
    }
}
