import SwiftUI

enum SettingTypography {
    // The native macOS callout style is 12 pt; settings help must remain readable.
    static let supporting: Font = .callout
}

private enum SettingMetrics {
    static let rowInset: CGFloat = 16
    static let rowSpacing: CGFloat = 16
    static let controlColumn: CGFloat = 260
    static let choiceWidth: CGFloat = 220
    static let numericWidth: CGFloat = 72
}

private struct SettingRowInsetKey: EnvironmentKey {
    static let defaultValue = SettingMetrics.rowInset
}

private struct SettingResetGenerationKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var settingResetGeneration: Int {
        get { self[SettingResetGenerationKey.self] }
        set { self[SettingResetGenerationKey.self] = newValue }
    }
}

extension Binding where Value == Double {
    static func settingInteger(_ value: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
    }
}

private extension EnvironmentValues {
    var settingRowInset: CGFloat {
        get { self[SettingRowInsetKey.self] }
        set { self[SettingRowInsetKey.self] = newValue }
    }
}

struct SettingSectionLabel: View {
    let title: String
    var body: some View {
        Text(L10n.text(title)).font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GroupBox { VStack(alignment: .leading, spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading) }
            .toggleStyle(.switch)
            .controlSize(.regular)
    }
}

/// Page controls align with card outer edges; row controls keep their inner inset.
struct SettingPageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: SettingMetrics.rowSpacing) {
            Text(title).font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings-page-title")
            trailing
        }
        .controlSize(.regular)
    }
}

extension SettingPageHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        trailing = EmptyView()
    }
}

struct SettingSupportingText: View {
    private let text: Text
    init(_ text: String) { self.text = Text(L10n.text(text)) }
    init(_ text: Text) { self.text = text }
    init(verbatim text: String) { self.text = Text(verbatim: text) }

    var body: some View {
        text.font(SettingTypography.supporting).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingRow<Content: View>: View {
    @Environment(\.settingRowInset) private var inset
    let title: String
    var description: String? = nil
    // User and provider names must not be interpreted as localization keys.
    var localizesTitle = true
    @ViewBuilder var content: Content
    var body: some View {
        SettingRowLayout {
            label
            controls
        }
        .font(.body)
        .controlSize(.regular)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset).padding(.vertical, 11)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(localizesTitle ? L10n.text(title) : title).accessibilityIdentifier("settings-label-" + title)
            if let description {
                SettingSupportingText(description)
                    .accessibilityIdentifier("settings-description-" + title)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 8) { content }
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// One set of controls survives a width change, including an in-progress edit.
private struct SettingRowLayout: Layout {
    private func measurements(width: CGFloat, subviews: Subviews) -> (CGSize, CGSize, Bool) {
        let controls = subviews[1].sizeThatFits(.unspecified)
        let column = controls.width == 0 ? 0 : max(SettingMetrics.controlColumn, controls.width)
        let gap = controls.width == 0 ? 0 : SettingMetrics.rowSpacing
        let horizontal = width >= 140 + gap + column
        let labelWidth = horizontal ? width - gap - column : width
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, labelWidth), height: nil))
        return (label, controls, horizontal)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 140 + SettingMetrics.rowSpacing + SettingMetrics.controlColumn
        let (label, controls, horizontal) = measurements(width: width, subviews: subviews)
        return CGSize(width: width, height: horizontal ? max(label.height, controls.height) : label.height + 8 + controls.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (label, controls, horizontal) = measurements(width: bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: horizontal ? bounds.midY - label.height / 2 : bounds.minY),
                          proposal: ProposedViewSize(label))
        subviews[1].place(at: CGPoint(x: bounds.maxX - controls.width,
                                     y: horizontal ? bounds.midY - controls.height / 2 : bounds.maxY - controls.height),
                          proposal: ProposedViewSize(controls))
    }
}

struct SettingNote: View {
    @Environment(\.settingRowInset) private var inset
    let text: String
    var localizesText = true
    init(_ text: String, localizesText: Bool = true) {
        self.text = text
        self.localizesText = localizesText
    }
    var body: some View {
        SettingSupportingText(verbatim: localizesText ? L10n.text(text) : text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset).padding(.vertical, 10)
    }
}

struct SettingContent<Content: View>: View {
    @Environment(\.settingRowInset) private var inset
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .font(.body).controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset).padding(.vertical, 11)
    }
}

struct SettingSearchField: View {
    let title: String
    @Binding var query: String
    let isSearching: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            TextField(L10n.text(title), text: $query).onSubmit(action)
                .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.text(title))
            Button(L10n.text("Search"), action: action).disabled(isSearching)
        }.buttonStyle(.bordered)
    }
}

struct SettingRowDivider: View {
    var body: some View { Divider() }
}

struct SettingToggleRow: View {
    let title: String
    var description: String? = nil
    @Binding var isOn: Bool
    var identifier: String = ""
    var body: some View {
        SettingRow(title: title, description: description) {
            SettingSwitch(title: title, isOn: $isOn)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// Shared native switch traits for page headers, rows and compound controls.
struct SettingSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var localizesTitle = true

    private var displayTitle: String { localizesTitle ? L10n.text(title) : title }

    var body: some View {
        Toggle(displayTitle, isOn: $isOn)
            .labelsHidden().toggleStyle(.switch).controlSize(.regular)
            .accessibilityLabel(displayTitle)
    }
}

struct SettingActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) { content }
            .controlSize(.regular).buttonStyle(.bordered)
    }
}

/// Presentation only: permission checks and request/open actions belong to the caller.
struct SettingPermissionRow<Actions: View>: View {
    let title: String
    var description: String? = nil
    let isGranted: Bool
    var grantedTitle = "Granted"
    @ViewBuilder var actions: Actions

    var body: some View {
        SettingRow(title: title, description: description) {
            if isGranted {
                Label(L10n.text(grantedTitle), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(L10n.text(grantedTitle))
            } else {
                SettingActions { actions }
            }
        }
    }
}

struct SettingPickerRow<Value: Hashable, Options: View>: View {
    let title: String
    var description: String? = nil
    @Binding var selection: Value
    var segmented = false
    var identifier: String = ""
    @ViewBuilder var options: Options

    var body: some View {
        SettingRow(title: title, description: description) {
            SettingChoiceField {
                if segmented { picker.pickerStyle(.segmented) }
                else { picker.pickerStyle(.menu) }
            }
        }
    }

    private var picker: some View {
        Picker(L10n.text(title), selection: $selection) { options }
            .labelsHidden()
            .accessibilityLabel(L10n.text(title))
            .accessibilityIdentifier(identifier)
    }
}

struct SettingChoiceField<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.labelsHidden().frame(width: SettingMetrics.choiceWidth, alignment: .trailing)
    }
}

struct SettingSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formattedValue: (Double) -> String

    var body: some View {
        SettingRow(title: title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step).accessibilityLabel(L10n.text(title))
                Text(formattedValue(value)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
            }.frame(width: SettingMetrics.controlColumn)
        }
    }
}

/// Continuous controls suit perceived timing; exact values remain directly editable.
struct SettingSliderNumberRow: View {
    let title: String
    var description: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var commonRange: ClosedRange<Double>? = nil
    let unit: String
    var resetGeneration = 0
    var identifier: String = ""

    var body: some View {
        SettingRow(title: title, description: description) {
            SettingSliderNumberField(title: title, value: $value, range: range, commonRange: commonRange, unit: unit,
                                     resetGeneration: resetGeneration, identifier: identifier)
        }
    }
}

struct SettingNumberRow: View {
    let title: String
    var description: String? = nil
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    let unit: String
    var resetGeneration = 0
    var identifier: String = ""

    var body: some View {
        SettingRow(title: title, description: description) {
            SettingNumberField(title: title, value: $value, range: range, unit: unit,
                               step: step, resetGeneration: resetGeneration, identifier: identifier)
        }
    }
}

struct SettingActionRow: View {
    let title: String
    var description: String? = nil
    let buttonTitle: String
    var identifier: String = ""
    let action: () -> Void

    var body: some View {
        SettingRow(title: title, description: description) {
            Button(L10n.text(buttonTitle), action: action)
                .accessibilityIdentifier(identifier)
        }
    }
}

struct SettingRestoreRow: View {
    var description = "Your content and macOS permissions are kept."
    let buttonTitle: String
    var identifier: String = ""
    var undo: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        SettingRow(title: "Restore settings", description: description) {
            if let undo { Button(L10n.text("Undo"), action: undo) }
            Button(L10n.text(buttonTitle), action: action)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// The disclosure owns its inset; child rows must not add the same inset again.
struct SettingDisclosureGroup<Content: View>: View {
    @Environment(\.islandMotion) private var motion
    @State private var isExpanded = false
    let title: String
    var identifier = ""
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup(L10n.text(title), isExpanded: $isExpanded.animation(motion.content)) {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.settingRowInset, 0)
        }
        .disclosureGroupStyle(SettingDisclosureStyle(identifier: identifier.isEmpty ? "settings-disclosure-" + title : identifier))
        .padding(.horizontal, SettingMetrics.rowInset).padding(.vertical, 11)
    }
}

/// Settings and the island share the same intrinsic arrow/title hit area.
/// Only expansion changes animate layout; live diagnostic updates do not.
private struct SettingDisclosureStyle: DisclosureGroupStyle {
    let identifier: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            IslandDisclosureButton(expanded: configuration.isExpanded, action: { configuration.isExpanded.toggle() }) {
                configuration.label
            }
            .accessibilityIdentifier(identifier)
            if configuration.isExpanded {
                configuration.content.padding(.top, 8).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingNumberField: View {
    @Environment(\.locale) private var locale
    @Environment(\.settingResetGeneration) private var parentResetGeneration
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var step: Double? = nil
    var resetGeneration = 0
    var identifier: String = ""
    @State private var draft = SettingNumericDraft()
    private var generation: Int { resetGeneration + parentResetGeneration }

    var body: some View {
        HStack(spacing: 8) {
            SettingNumericTextField(title: L10n.text(title), text: Binding(get: { draft.text }, set: { draft.edit($0) }),
                                    identifier: identifier, onCommit: commitDraft)
                .frame(width: SettingMetrics.numericWidth)
                .accessibilityLabel(L10n.text(title))
                .accessibilityIdentifier(identifier)
                .help(L10n.format("Enter a value from %@ to %@ %@.",
                    range.lowerBound.formatted(.number.locale(locale)),
                    range.upperBound.formatted(.number.locale(locale)), L10n.text(unit)))
            if !unit.isEmpty {
                Text(L10n.text(unit)).foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier.isEmpty ? "" : identifier + "-unit")
            }
            if let step {
                Stepper(L10n.text(title), value: stepperValue, in: range, step: step)
                    .labelsHidden()
                    .accessibilityLabel(L10n.text(title))
                    .accessibilityIdentifier(identifier.isEmpty ? "" : identifier + "-stepper")
            }
        }
        .fixedSize()
        .onAppear { refreshDraft() }
        .onChange(of: value) { _, _ in refreshDraft() }
        .onChange(of: generation) { _, _ in refreshDraft() }
        .onChange(of: locale) { _, _ in refreshDraft() }
        .onDisappear { commitDraft() }
    }

    private func refreshDraft() {
        draft.synchronize(with: value, locale: locale, resetGeneration: generation)
    }

    private func commitDraft() {
        guard let committed = draft.valueToCommit(currentValue: value, in: range, locale: locale,
                                                  resetGeneration: generation) else {
            refreshDraft()
            return
        }
        if value != committed { value = committed }
        refreshDraft()
    }

    private var stepperValue: Binding<Double> {
        Binding(get: {
            let proposed = draft.valueToCommit(currentValue: value, in: range, locale: locale, resetGeneration: generation) ?? value
            return SettingValueBounds.clamped(proposed, in: range)
        }, set: { proposed in
            value = SettingValueBounds.clamped(proposed, in: range)
            refreshDraft()
        })
    }
}

/// Keep both native controls on the same bounded value without quantizing a drag.
enum SettingValueBounds {
    static func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard !value.isNaN else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func binding(_ value: Binding<Double>, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { clamped(value.wrappedValue, in: range) },
            set: { value.wrappedValue = clamped($0, in: range) }
        )
    }

    /// A common slider range never narrows numeric input or rewrites an old value.
    /// Retain expanded bounds for this appearance so moving inward cannot rescale a drag.
    static func sliderRange(for value: Double, in inputRange: ClosedRange<Double>,
                            commonRange: ClosedRange<Double>?, retaining previous: ClosedRange<Double>? = nil) -> ClosedRange<Double> {
        guard let commonRange else { return inputRange }
        let current = clamped(value, in: inputRange)
        let lower = min(commonRange.lowerBound, previous?.lowerBound ?? commonRange.lowerBound, current)
        let upper = max(commonRange.upperBound, previous?.upperBound ?? commonRange.upperBound, current)
        return clamped(lower, in: inputRange)...clamped(upper, in: inputRange)
    }

    static func committedValue(
        from draft: String,
        currentValue: Double,
        in range: ClosedRange<Double>,
        locale: Locale
    ) -> Double {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = try? Double(text, format: .number.locale(locale), lenient: false),
              parsed.isFinite else { return clamped(currentValue, in: range) }
        return clamped(parsed, in: range)
    }
}

struct SettingNumericDraft {
    private(set) var text = ""
    private(set) var hasUncommittedEdit = false
    private var resetGeneration = 0
    private var synchronizedValue: Double = 0

    mutating func edit(_ text: String) {
        self.text = text
        hasUncommittedEdit = true
    }

    mutating func synchronize(with value: Double, locale: Locale, resetGeneration: Int = 0) {
        text = value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        hasUncommittedEdit = false
        self.resetGeneration = resetGeneration
        synchronizedValue = value
    }

    func valueToCommit(currentValue: Double, in range: ClosedRange<Double>, locale: Locale, resetGeneration: Int = 0) -> Double? {
        guard hasUncommittedEdit, self.resetGeneration == resetGeneration,
              synchronizedValue == currentValue || (synchronizedValue.isNaN && currentValue.isNaN) else { return nil }
        return SettingValueBounds.committedValue(from: text, currentValue: currentValue, in: range, locale: locale)
    }
}

struct SettingSliderNumberField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var commonRange: ClosedRange<Double>? = nil
    let unit: String
    var resetGeneration = 0
    var identifier: String = ""
    @State private var sliderEditGeneration = 0
    @State private var retainedSliderRange: ClosedRange<Double>?

    private var sliderRange: ClosedRange<Double> {
        SettingValueBounds.sliderRange(for: value, in: range, commonRange: commonRange, retaining: retainedSliderRange)
    }

    private var boundedValue: Binding<Double> {
        Binding(get: { SettingValueBounds.clamped(value, in: sliderRange) }, set: { proposed in
            let bounds = sliderRange
            retainedSliderRange = bounds
            // An explicit slider action wins even if it selects the current value.
            sliderEditGeneration += 1
            let clamped = SettingValueBounds.clamped(proposed, in: bounds)
            if value != clamped { value = clamped }
        })
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: boundedValue, in: sliderRange)
                .accessibilityLabel(Text(L10n.text(title)))
                .accessibilityIdentifier(identifier.isEmpty ? "" : identifier + "-slider")
            SettingNumberField(title: title, value: $value, range: range, unit: unit,
                               resetGeneration: resetGeneration + sliderEditGeneration, identifier: identifier)
        }
        .controlSize(.regular)
        .frame(width: SettingMetrics.controlColumn)
        .onAppear {
            retainedSliderRange = SettingValueBounds.sliderRange(for: value, in: range, commonRange: commonRange)
        }
        .onChange(of: value) { _, _ in retainedSliderRange = sliderRange }
    }
}
