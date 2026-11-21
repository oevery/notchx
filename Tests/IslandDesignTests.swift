import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class IslandDesignTests: XCTestCase {
    func testFreshAndLegacyPreferencesUseSameLookAfterStateRecreation() {
        for legacyTheme in [nil, "frosted", "glass", "black", "unknown"] as [String?] {
            let domain = "app.notchx.tests.island-design." + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set(legacyTheme, forKey: "appearance.theme")
            defaults.set(1.3, forKey: "appearance.animationSpeed")
            defaults.set(230.0, forKey: SettingsDefaults.Appearance.compactWidth.key)
            defaults.set(37.0, forKey: SettingsDefaults.Tools.customMinutes.key)
            let saved = defaults.persistentDomain(forName: domain) ?? [:]

            func verifyAppearance(_ state: AppState) {
                XCTAssertEqual(state.islandAppearance(reduceTransparency: false, increasedContrast: false),
                               IslandAppearance(compact: true))
                state.presentFullExpandedModule(.tools)
                XCTAssertEqual(state.currentState, .fullExpanded)
                XCTAssertEqual(state.islandAppearance(reduceTransparency: false, increasedContrast: false),
                               IslandAppearance())
                XCTAssertEqual(state.animationSpeed, 1.3)
                XCTAssertEqual(state.compactIslandWidth, 230)
                XCTAssertEqual(state.keepAwakeCustomMinutes, 37)
            }
            verifyAppearance(AppState(preferenceStore: defaults))
            verifyAppearance(AppState(preferenceStore: defaults))
            XCTAssertEqual(defaults.persistentDomain(forName: domain) as NSDictionary?, saved as NSDictionary)
        }
    }

    func testCompactAndAccessibilityUseAnOpaqueBackdrop() {
        XCTAssertTrue(IslandAppearance().usesFrostedBackdrop)
        XCTAssertFalse(IslandAppearance(compact: true).usesFrostedBackdrop)
        XCTAssertFalse(IslandAppearance(reduceTransparency: true).usesFrostedBackdrop)
        let highContrast = IslandAppearance(increasedContrast: true)
        XCTAssertFalse(highContrast.usesFrostedBackdrop)
        XCTAssertTrue(highContrast.increasedContrast)
        XCTAssertGreaterThan(luminance(IslandPalette.secondary.color(for: highContrast)),
                             luminance(IslandPalette.secondary.color(for: IslandAppearance())))
    }

    func testCompactPlaybackActionMatchesPlaybackState() {
        let playing = CompactPlaybackAction(isPlaying: true)
        XCTAssertEqual(playing, .pause)
        XCTAssertEqual(playing.symbol, "pause.fill")
        XCTAssertEqual(playing.title, L10n.text("Pause"))

        let paused = CompactPlaybackAction(isPlaying: false)
        XCTAssertEqual(paused, .play)
        XCTAssertEqual(paused.symbol, "play.fill")
        XCTAssertEqual(paused.title, L10n.text("Play"))
    }

    func testBasicControlSizesMapToNativeAndSharedIslandMetrics() {
        XCTAssertEqual(BasicControlSize.allCases, [.regular, .small])
        var environment = EnvironmentValues()
        XCTAssertEqual(environment.basicControlSize, .regular)
        for size in BasicControlSize.allCases {
            environment.controlSize = size.swiftUISize
            XCTAssertEqual(environment.basicControlSize, size)
            XCTAssertEqual(size.appKitSize, size == .small ? .small : .regular)
            XCTAssertGreaterThan(size.islandHeight, size.islandPointSize + 2 * size.verticalInset)
        }
        XCTAssertGreaterThan(BasicControlSize.regular.islandHeight, BasicControlSize.small.islandHeight)
        XCTAssertGreaterThan(BasicControlSize.regular.horizontalInset, BasicControlSize.small.horizontalInset)
    }

    func testPalettePreservesRoleHierarchyAndReferenceContrast() {
        for appearance in [IslandAppearance(), IslandAppearance(reduceTransparency: true),
                           IslandAppearance(increasedContrast: true)] {
            var environment = EnvironmentValues()
            environment.islandAppearance = appearance
            let tones: [IslandPalette] = [.primary, .label, .secondary, .tertiary]
            let colors = tones.map { luminance($0.resolve(in: environment)) }
            for (stronger, quieter) in zip(colors, colors.dropFirst()) {
                XCTAssertGreaterThan(stronger, quieter)
            }
            let referenceSurface = Color(white: appearance.usesFrostedBackdrop ? 0.18 : 0)
            for tone in tones + [.icon] {
                XCTAssertGreaterThanOrEqual(contrast(tone.resolve(in: environment), referenceSurface), 4.5)
            }
        }
    }

    func testIslandNativeAppearanceMapsDarkAndHighContrastVariants() throws {
        for increasedContrast in [false, true] {
            let name = IslandNativeAppearance.name(increasedContrast: increasedContrast)
            XCTAssertEqual(name, increasedContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertEqual(appearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        }
    }

    func testSettingsDisclosureLabelsContrastWithTheirRenderedBackground() async throws {
        let (state, domain) = isolatedState()
        defer { state.modulePreferenceStore.removePersistentDomain(forName: domain) }
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            try await verifyDisclosureContrast(in: AdvancedSettingsView(), titles: ["Energy Diagnostics"],
                                               appearance: appearance, state: state)
            try await verifyDisclosureContrast(in: AppearanceSettingsView(appState: state),
                titles: ["Advanced animation settings", "Animation timing"], appearance: appearance, state: state)
        }
    }

    private func verifyDisclosureContrast(in page: some View, titles: [String],
                                          appearance: NSAppearance, state: AppState) async throws {
        let host = NSHostingView(rootView: page
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(state).basicControlSize(.regular))
        let window = offscreenWindow(host, appearance: appearance, size: CGSize(width: 680, height: 590))
        defer { window.close() }
        var frames: [CGRect] = []
        for title in titles {
            let id = "settings-disclosure-" + title
            _ = try await NativeUI.waitForElement(in: host, id: id)
            let screenFrame = try NativeUI.frame(in: host, id: id)
            let localFrame = host.convert(window.convertFromScreen(screenFrame), from: nil)
            frames.append(localFrame)
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        for (title, frame) in zip(titles, frames) {
            let pointsToPixels = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
            let labelPixels = CGRect(x: (frame.minX + 18) * pointsToPixels, y: top * pointsToPixels,
                width: (frame.width - 18) * pointsToPixels, height: frame.height * pointsToPixels).integral
            let backgroundX = Int(labelPixels.maxX + 8 * pointsToPixels)
            let background = try XCTUnwrap(pixelLuminance(in: bitmap, x: backgroundX, y: Int(labelPixels.midY)))
            let fragment = try XCTUnwrap(bitmap.cgImage?.cropping(to: labelPixels))
            let raster = NSBitmapImageRep(cgImage: fragment)
            let ratios = (0..<raster.pixelsHigh).flatMap { row in
                (0..<raster.pixelsWide).compactMap { column in
                    pixelLuminance(in: raster, x: column, y: row).map { contrast($0, background) }
                }
            }.sorted(by: >)
            let interiorRatio = try XCTUnwrap(ratios.dropFirst(11).first)
            XCTAssertGreaterThanOrEqual(interiorRatio, 4.5,
                "\(title) on \(appearance.name.rawValue) must contrast with the settings card")
            let attachment = XCTAttachment(image: NSImage(cgImage: fragment, size: .zero))
            attachment.name = "\(appearance.name.rawValue)-\(title)"
            attachment.lifetime = captureEvidence ? .keepAlways : .deleteOnSuccess
            add(attachment)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testSharedMenuInsetMovesNativeTitleAndArrowWithoutChangingControlBounds() async throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let (state, domain) = isolatedState()
        defer { state.modulePreferenceStore.removePersistentDomain(forName: domain) }
        for size in BasicControlSize.allCases {
            for isEnabled in [true, false] {
                func menu(_ id: String, shared: Bool) -> some View {
                    IslandMenuButton(label: "Duration", identifier: id, module: .tools,
                        items: [IslandMenuItem(title: "1 小时") {}], selectedIndex: 0, usesSharedBezel: shared)
                        .fixedSize()
                }
                let host = NSHostingView(rootView: HStack {
                    menu("reference", shared: false)
                    menu("shared", shared: true)
                }.environmentObject(state).basicControlSize(size).disabled(!isEnabled))
                let window = offscreenWindow(host, appearance: dark, size: CGSize(width: 300, height: 80))
                defer { window.close() }
                func nativeButton(_ id: String) -> NSPopUpButton? {
                    NativeUI.nativeViews(in: host).compactMap { $0 as? NSPopUpButton }
                        .first { $0.accessibilityIdentifier() == id && !$0.bounds.isEmpty }
                }
                try await NativeUI.waitFor("configured island menus", in: host) {
                    nativeButton("reference") != nil && nativeButton("shared") != nil
                }
                let reference = try XCTUnwrap(nativeButton("reference"))
                let shared = try XCTUnwrap(nativeButton("shared"))
                let bounds = shared.bounds
                let intrinsic = reference.intrinsicContentSize
                XCTAssertEqual(shared.intrinsicContentSize, intrinsic)
                XCTAssertEqual(bounds.width - reference.bounds.width, 2 * size.horizontalInset, accuracy: 1)
                XCTAssertEqual(bounds.height, max(intrinsic.height, size.islandHeight), accuracy: 1)
                let before = try menuTriggerBitmap(reference, bounds: bounds, appearance: dark)
                let after = try menuTriggerBitmap(shared, bounds: bounds, appearance: dark)
                let unpadded = try litColumns(in: before)
                let padded = try litColumns(in: after)
                XCTAssertGreaterThan(padded.lowerBound, unpadded.lowerBound)
                XCTAssertGreaterThanOrEqual(padded.lowerBound, size.horizontalInset)
                XCTAssertGreaterThanOrEqual(bounds.width - padded.upperBound, size.horizontalInset)
                XCTAssertEqual(unpadded.upperBound - padded.upperBound, size.horizontalInset, accuracy: 1)
                XCTAssertEqual(shared.selectedItem?.title, "1 小时")
                XCTAssertEqual(shared.isEnabled, isEnabled)
                XCTAssertFalse(window.isVisible)
                let beforeAndAfter = NSImage(size: CGSize(width: bounds.width, height: bounds.height * 2), flipped: false) { _ in
                    before.draw(in: bounds.offsetBy(dx: 0, dy: bounds.height))
                    after.draw(in: bounds)
                    return true
                }
                let attachment = XCTAttachment(image: beforeAndAfter)
                attachment.name = "menu-\(size)-\(isEnabled ? "enabled" : "disabled")-before-after"
                attachment.lifetime = captureEvidence ? .keepAlways : .deleteOnSuccess
                add(attachment)
            }
        }
    }

    private func menuTriggerBitmap(_ button: NSPopUpButton, bounds: CGRect, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let scale = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * CGFloat(scale)).rounded(.up)),
            pixelsHigh: Int((bounds.height * CGFloat(scale)).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let rasterContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let context = NSGraphicsContext(cgContext: rasterContext.cgContext, flipped: button.isFlipped)
        let cell = try XCTUnwrap(button.cell)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        if button.isFlipped {
            context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        }
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(button.isFlipped ? -scale : scale))
        appearance.performAsCurrentDrawingAppearance {
            NSColor.black.setFill()
            bounds.fill()
            cell.draw(withFrame: bounds, in: button)
        }
        bitmap.size = bounds.size
        return bitmap
    }

    private func isolatedState() -> (AppState, String) {
        let domain = "app.notchx.tests.island-render." + UUID().uuidString
        return (AppState(preferenceStore: UserDefaults(suiteName: domain)!, preferenceDomainName: domain), domain)
    }

    private func offscreenWindow(_ host: NSView, appearance: NSAppearance, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    private var captureEvidence: Bool { ProcessInfo.processInfo.environment["NOTCHX_CAPTURE_TEST_IMAGES"] == "1" }

    private func pixelLuminance(in bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double? {
        guard (0..<bitmap.pixelsWide).contains(x), (0..<bitmap.pixelsHigh).contains(y),
              let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func litColumns(in bitmap: NSBitmapImageRep) throws -> ClosedRange<CGFloat> {
        let columns = (0..<bitmap.pixelsWide).filter { column in
            (0..<bitmap.pixelsHigh).contains { row in
                (bitmap.colorAt(x: column, y: row)?.redComponent ?? 0) > 0.12
            }
        }
        let first = try XCTUnwrap(columns.first)
        let last = try XCTUnwrap(columns.last)
        let pointsPerPixel = bitmap.size.width / CGFloat(bitmap.pixelsWide)
        return CGFloat(first) * pointsPerPixel...CGFloat(last) * pointsPerPixel
    }

    func testActionPaintKeepsLabelsLegibleAndFeedbackDistinct() {
        let appearances = [IslandAppearance(), IslandAppearance(increasedContrast: true)]
        for appearance in appearances {
            for primary in [true, false] {
                func paint(enabled: Bool = true, hovered: Bool = false, pressed: Bool = false) -> IslandActionPaint {
                    IslandActionPaint(isPrimary: primary, isEnabled: enabled, isHovered: hovered,
                                      isPressed: pressed, appearance: appearance)
                }
                let idle = paint()
                let hovered = paint(hovered: true)
                let pressed = paint(hovered: true, pressed: true)
                let disabled = paint(enabled: false)
                XCTAssertNotEqual(luminance(idle.fill), luminance(hovered.fill))
                XCTAssertNotEqual(luminance(hovered.fill), luminance(pressed.fill))
                XCTAssertEqual(disabled.fill, paint(enabled: false, hovered: true, pressed: true).fill)
                XCTAssertNotEqual(disabled.foreground, idle.foreground)
                for state in [idle, hovered, pressed, disabled] {
                    XCTAssertGreaterThanOrEqual(contrast(state.foreground, state.fill), 4.5)
                }
            }
        }
    }

    private func luminance(_ color: Color) -> Double {
        let resolved = color.resolve(in: EnvironmentValues())
        return 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
    }

    private func contrast(_ foreground: Color, _ background: Color) -> Double {
        contrast(luminance(foreground), luminance(background))
    }

    private func contrast(_ foreground: Double, _ background: Double) -> Double {
        (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
    }
}
