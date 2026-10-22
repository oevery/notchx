import AppKit
import Speech
import SwiftUI
import Combine

@MainActor
final class TeleprompterScriptEditorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TeleprompterScriptEditorWindowController(manager: .shared, appState: .shared)
    private let manager: TeleprompterManager
    private let appState: AppState
    private let preferences: UserDefaults
    private let frameKey = "teleprompter.editor.frame"
    private var editingSession: IslandPresentationHandoff?
    private var returnToReadingOnClose = false
    private var sessionObservation: AnyCancellable?

    init(manager: TeleprompterManager, appState: AppState, preferences: UserDefaults = .standard) {
        self.manager = manager
        self.appState = appState
        self.preferences = preferences
        super.init(window: nil)
        sessionObservation = appState.$presentationHandoffs.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let session = self.editingSession,
                      !self.appState.isPresentationHandoffActive(session) else { return }
                self.close()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func show() { shared.showEditor(sourceWindow: NSApp.currentEvent?.window) }

    func showEditor(sourceWindow: NSWindow? = nil, activateApplication: Bool = true) {
        guard appState.teleprompterEnabled else { return }
        manager.pause()
        // Capture the source before every activation, including window reuse.
        guard let context = IslandWindowContext(sourceWindow: sourceWindow, appState: appState),
              let session = appState.beginPresentationHandoff(.window, for: .teleprompter,
                  returnsToSource: true, replacing: editingSession) else { return }
        editingSession = session
        returnToReadingOnClose = false
        let savedFrame = window?.frame ?? preferences.string(forKey: frameKey).map(NSRectFromString)
        if window == nil {
            let rootView = TeleprompterScriptEditorView(manager: manager) { [weak self] text in
                self?.applyScriptAndClose(text)
            }.notchXLocalized()
            let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 460))
            window.minSize = NSSize(width: 400, height: 340)
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(white: 0.07, alpha: 1)
            window.delegate = self
            self.window = window
        }
        guard let window else { return }
        window.title = L10n.text("Teleprompter Script")
        let minimum = IslandWindowPlacement.minimumFrameSize(for: window)
        let frame = IslandWindowPlacement.frame(size: window.frame.size, savedFrame: savedFrame,
            visibleFrame: context.screen.visibleFrame, islandFrame: context.islandFrame, minimumSize: minimum)
        window.minSize = minimum
        window.setFrame(frame, display: false)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if activateApplication { NSApp.activate(ignoringOtherApps: true) }
    }

    private func applyScriptAndClose(_ text: String) {
        guard let session = editingSession, appState.isPresentationHandoffActive(session),
              appState.teleprompterEnabled else { close(); return }
        manager.pause()
        manager.setScript(text)
        manager.sessionStore.discardDraft()
        returnToReadingOnClose = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { preferences.set(NSStringFromRect(window.frame), forKey: frameKey) }
        let session = editingSession
        editingSession = nil
        if let session { appState.finishPresentationHandoff(session, outcome: returnToReadingOnClose ? .completed : .cancelled) }
        returnToReadingOnClose = false
        window = nil
    }
}

// MARK: - Editor view

struct TeleprompterScriptEditorView: View {
    @ObservedObject private var manager: TeleprompterManager
    private let applyScript: (String) -> Void
    @State private var draftText: String = ""
    @State private var draftLoaded = false
    @State private var confirmDiscard = false
    @FocusState private var focused: Bool

    init(manager: TeleprompterManager, applyScript: @escaping (String) -> Void) {
        self.manager = manager
        self.applyScript = applyScript
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            controlsBar
            editor
            bottomBar
        }
        .background(Color(white: 0.07))
        .preferredColorScheme(.dark)
        .onAppear {
            draftText = manager.sessionStore.draft ?? manager.scriptText
            draftLoaded = true
            focused = true
        }
        .onChange(of: draftText) { _, text in
            guard draftLoaded else { return }
            if text == manager.scriptText { manager.sessionStore.discardDraft() }
            else { manager.sessionStore.saveDraft(text) }
        }
        .confirmationDialog(L10n.text("Discard saved draft?"), isPresented: $confirmDiscard) {
            Button(L10n.text("Discard Draft"), role: .destructive) {
                draftText = manager.scriptText
                manager.sessionStore.discardDraft()
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            // Title + word count
            VStack(alignment: .leading, spacing: 2) {
                Text("Script")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.82))
                Text(wordCountLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.white.opacity(0.28))
            }

            Spacer()

            // Speed
            speedControl

            Divider()
                .frame(height: 20)
                .opacity(0.2)

            // Trash
            toolbarButton(icon: "trash", color: .white.opacity(0.45)) {
                draftText = ""
            }
            .help("Clear")

            if draftText != manager.scriptText {
                Button(L10n.text("Discard Draft")) { confirmDiscard = true }.font(.caption)
            }
            // Done (filled circle checkmark — stands out against the dark bg)
            Button { applyAndClose() } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 30, height: 30)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                }
            }
            .buttonStyle(.plain)
            .hoverPointer()
            .keyboardShortcut(.return, modifiers: .command)
            .help("Done (⌘↩)")
            .accessibilityLabel(L10n.text("Done"))
            .dataAnnotationID("teleprompter-editor-done-control")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color(white: 0.095))
    }

    private var modeControl: some View {
        Picker("", selection: $manager.listeningMode) {
            ForEach(TeleprompterListeningMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 176)
        .dataAnnotationID("teleprompter-listening-mode-control")
    }

    private var speedControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "tortoise.fill")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.28))
            Slider(value: $manager.scrollSpeed, in: 1...30, step: 0.5)
                .frame(width: 96)
                .tint(.white.opacity(0.4))
            Image(systemName: "hare.fill")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.28))
            Text(String(format: "%.1f", manager.scrollSpeed))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.white.opacity(0.28))
                .frame(width: 28, alignment: .leading)
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            labeledControl("Size") {
                HStack(spacing: 6) {
                    styleButton("textformat.size.smaller") {
                        manager.fontSize = max(12, manager.fontSize - 2)
                    }
                    Text("\(Int(manager.fontSize))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.white.opacity(0.42))
                        .frame(width: 24)
                    styleButton("textformat.size.larger") {
                        manager.fontSize = min(40, manager.fontSize + 2)
                    }
                }
            }

            Divider()
                .frame(height: 22)
                .opacity(0.2)

            labeledControl("Align") {
                Picker("", selection: $manager.textAlignmentIndex) {
                    Image(systemName: "text.alignleft").tag(0)
                    Image(systemName: "text.aligncenter").tag(1)
                    Image(systemName: "text.alignright").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 108)
            }

            Divider()
                .frame(height: 22)
                .opacity(0.2)

            labeledControl("Speed") {
                speedControl
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(white: 0.082))
        .dataAnnotationID("teleprompter-style-controls")
    }

    private func labeledControl<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.30))
            content()
        }
    }

    private func styleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.48))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }

    // MARK: Text area

    private var editor: some View {
        TextEditor(text: $draftText)
            .stableNativeScrollLayout()
            .focused($focused)
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.065))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Draft saved automatically. Done applies it.")).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.18))
            Text(bottomHelpText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.22))
            Spacer()
            if manager.listeningMode == .wordTracking {
                speechLocaleControl
            }
            modeControl
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(white: 0.095))
    }

    private var speechLocaleControl: some View {
        Picker("", selection: $manager.speechLocale) {
            ForEach(speechLocaleOptions, id: \.identifier) { locale in
                Text(speechLocaleLabel(locale))
                    .tag(locale.identifier)
            }
        }
        .labelsHidden()
        .frame(width: 136)
        .dataAnnotationID("teleprompter-speech-locale-control")
    }

    private var speechLocaleOptions: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted {
            speechLocaleLabel($0) < speechLocaleLabel($1)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func toolbarButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }

    private var wordCountLabel: String {
        let words = draftText.split(whereSeparator: \.isWhitespace).count
        return draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("Empty")
            : (words == 1 ? L10n.text("1 word") : L10n.format("%d words", words))
    }

    private var bottomHelpText: String {
        switch manager.listeningMode {
        case .classic:
            return L10n.text("Classic scrolls upward at a steady speed.")
        case .wordTracking:
            return L10n.text("Word Tracking follows your speech after Teleprompter permissions are granted.")
        }
    }

    private func applyAndClose() {
        applyScript(draftText)
    }

    private func speechLocaleLabel(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
