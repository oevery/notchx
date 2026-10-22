import AppKit
import SwiftUI

/// Native numeric editing keeps linguistic checks out of the input/blur path.
/// Parsing, bounds and stale-draft protection remain in SettingNumberField.
struct SettingNumericTextField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    @Binding var text: String
    let identifier: String
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.cell = NumericCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.controlSize = .regular
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.setAccessibilityIdentifier(identifier)
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor(), editor.string != text { editor.string = text }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingNumericTextField
        init(_ parent: SettingNumericTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) { parent.onCommit() }
        @objc func commit(_ sender: NSTextField) { parent.onCommit() }
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
