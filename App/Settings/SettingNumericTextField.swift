import AppKit
import SwiftUI

/// Native numeric editing keeps linguistic checks out of the input/blur path.
/// Parsing, bounds and stale-draft protection remain in SettingNumberField.
struct SettingNumericTextField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.basicControlSize) private var size
    let title: String
    @Binding var text: String
    let identifier: String
    let onCommit: () -> Void
    var focusOnMount = false
    var onSubmit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var usesIslandChrome = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.cell = NumericCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.bezelStyle = .roundedBezel
        field.isBezeled = !usesIslandChrome
        field.drawsBackground = !usesIslandChrome
        field.alignment = .right
        field.isAutomaticTextCompletionEnabled = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        if field.controlSize != size.appKitSize { field.controlSize = size.appKitSize }
        let pointSize = usesIslandChrome ? size.islandPointSize : NSFont.systemFontSize(for: size.appKitSize)
        let font = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
        if field.font != font { field.font = font }
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.setAccessibilityIdentifier(identifier)
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor(), editor.string != text { editor.string = text }
        }
        if focusOnMount, !context.coordinator.requestedInitialFocus {
            context.coordinator.requestedInitialFocus = true
            Task { @MainActor [weak field] in
                guard let field, field.isEnabled, let window = field.window, window.isKeyWindow else { return }
                if window.makeFirstResponder(field) { field.selectText(nil) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingNumericTextField
        var requestedInitialFocus = false
        init(_ parent: SettingNumericTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) { parent.onCommit() }
        @objc func commit(_ sender: NSTextField) { parent.onCommit() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                guard let submit = parent.onSubmit else { return false }
                parent.text = textView.string
                submit()
            case #selector(NSResponder.cancelOperation(_:)):
                guard let cancel = parent.onCancel else { return false }
                cancel()
            default:
                return false
            }
            return true
        }
    }

    private final class NumericCell: NSTextFieldCell {
        // A cell-owned editor does not change the window's shared prose editor.
        private lazy var numericEditor: NSTextView = {
            let editor = NSTextView()
            editor.isFieldEditor = true
            editor.isAutomaticTextCompletionEnabled = false
            editor.enabledTextCheckingTypes = 0
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? { numericEditor }

        override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
            let editor = super.setUpFieldEditorAttributes(textObj)
            if let editor = editor as? NSTextView {
                editor.isAutomaticTextCompletionEnabled = false
                editor.enabledTextCheckingTypes = 0
            }
            return editor
        }
    }
}
