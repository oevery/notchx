import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
private struct CompactContentProbe: NSViewRepresentable {
    let name: String
    var visible = true
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        view.wantsLayer = true
        view.layer?.backgroundColor = (visible ? NSColor.orange : .clear).cgColor
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class CompactSlotLayoutTests: XCTestCase {
    func testSharedSlotsCenterDifferentContentSizesAndAllCountWidths() async throws {
        let cover = NSImage(size: CGSize(width: 26, height: 26), flipped: false) { rect in
            NSColor.orange.setFill(); rect.fill(); return true
        }
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = makeWindow(host: host, height: 32)
        defer { window.contentView = nil; window.close() }
        for height in [32, 37] as [CGFloat] {
            window.setContentSize(CGSize(width: 279, height: height))
            for count in [1, 12, 100] {
                for kind in [CompactSlot<AnyView>.Kind.brand, .artwork] {
                    host.rootView = AnyView(CompactSideSlots(centerGapWidth: 179,
                        leading: AnyView(CompactSlot(kind: kind) { size in
                            AnyView(ZStack {
                                if kind == .brand {
                                    AgentBrandIcon(provider: count == 12 ? "claude" : "codex", size: size)
                                } else {
                                    PlaybackArtworkImage(image: cover, size: size, cornerRadius: Constants.compactArtworkCornerRadius)
                                }
                                CompactContentProbe(name: "left-content", visible: false).frame(width: size, height: size)
                            })
                        }), trailing: AnyView(CompactSlotCount(count: count).accessibilityIdentifier("count")))
                        .padding(.horizontal, 6).background(Color.black))
                    try await NativeUI.waitFor("centered native content", in: host) {
                        guard let probe = NativeUI.nativeViews(in: host).first(where: { $0.identifier?.rawValue == "left-content" }) else { return false }
                        let frame = probe.convert(probe.bounds, to: host)
                        return abs(frame.midX - 28) < 0.5 && abs(frame.midY - height / 2) < 0.5
                            && abs(frame.width - (kind == .brand ? 18 : 26)) < 0.5
                    }
                    let countFrame = try NativeUI.frame(in: host, id: "count")
                    XCTAssertEqual(countFrame.midX, window.frame.minX + 251, accuracy: 0.5)
                    XCTAssertEqual(countFrame.midY, window.frame.minY + height / 2, accuracy: 0.5)
                    XCTAssertEqual(countFrame.width, 44, accuracy: 0.5)
                    try capture(host, name: "slots-" + String(count) + "-" + String(Int(height)) + (kind == .brand ? "-brand" : "-artwork"))
                }
            }
        }
    }

    func testSpectrumDrawingStaysCenteredAcrossResizeAndAnimationChanges() throws {
        let view = CompactAudioSpectrumView(frame: CGRect(x: 0, y: 0, width: 20, height: 16))
        defer { view.setPlaying(false) }
        for size in [CGSize(width: 20, height: 16), CGSize(width: 26, height: 26), CGSize(width: 30, height: 20)] {
            view.setFrameSize(size)
            for playing in [false, true, false] {
                view.setPlaying(playing)
                view.layoutSubtreeIfNeeded()
                let bars = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer })
                XCTAssertEqual(bars.count, 4)
                let union = bars.reduce(CGRect.null) { $0.union($1.frame) }
                XCTAssertEqual(union.width, 16, accuracy: 0.01)
                XCTAssertEqual(union.midX, view.bounds.midX, accuracy: 0.01)
                XCTAssertEqual(union.midY, view.bounds.midY, accuracy: 0.01)
                XCTAssertEqual(bars.allSatisfy { $0.animation(forKey: "scaleY") != nil }, playing)
            }
        }
    }

    func testPlaybackIndicatorsKeepTheirCenterAndSlotAcrossRepeatedStateSwitches() async throws {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = makeWindow(host: host, height: 32)
        defer { window.contentView = nil; window.close() }
        for (index, state) in [(false, false), (true, false), (true, true), (false, true), (true, false)].enumerated() {
            host.rootView = AnyView(CompactSideSlots(centerGapWidth: 179,
                leading: AnyView(CompactSlot(kind: .artwork) { size in
                    CompactContentProbe(name: "cover").frame(width: size, height: size)
                }), trailing: AnyView(Button {} label: {
                    CompactSlot(kind: .indicator) { _ in
                        CompactPlaybackIndicator(isPlaying: state.0, isHovering: state.1, animatesSpectrum: false)
                            .background(CompactContentProbe(name: "indicator", visible: false))
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("playback-button")))
                .padding(.horizontal, 6).background(Color.black))
            _ = try await NativeUI.waitForElement(in: host, id: "playback-button")
            try await NativeUI.waitFor("playback state replacement", in: host) {
                NativeUI.nativeViews(in: host).contains { $0 is CompactAudioSpectrumView } == (state.0 && !state.1)
            }
            let button = try NativeUI.frame(in: host, id: "playback-button")
            let indicatorView = try XCTUnwrap(NativeUI.nativeViews(in: host).first { $0.identifier?.rawValue == "indicator" })
            let indicator = indicatorView.convert(indicatorView.bounds, to: nil)
            XCTAssertEqual(button.width, 44, accuracy: 0.5)
            XCTAssertEqual(button.height, 32, accuracy: 0.5)
            XCTAssertEqual(button.midX, window.frame.minX + 251, accuracy: 0.5)
            XCTAssertEqual(button.midY, window.frame.minY + 16, accuracy: 0.5)
            XCTAssertEqual(indicator.midX, button.midX - window.frame.minX, accuracy: 0.5)
            XCTAssertEqual(indicator.midY, button.midY - window.frame.minY, accuracy: 0.5)
            if let spectrum = NativeUI.nativeViews(in: host).first(where: { $0 is CompactAudioSpectrumView }) {
                let frame = spectrum.convert(spectrum.bounds, to: host)
                XCTAssertEqual(frame.midX, 251, accuracy: 0.5)
                XCTAssertEqual(frame.midY, 16, accuracy: 0.5)
            }
            try capture(host, name: "playback-" + String(index))
        }
    }

    func testDecorativeCurvesAreOutsideCompactInteractionShape() {
        let rect = CGRect(x: 0, y: 0, width: 279, height: 32)
        let surface = PillShape(topLeadingRadius: 6, topTrailingRadius: 6,
            bottomLeadingRadius: 12, bottomTrailingRadius: 12, outwardTopCorners: true)
        let hit = IslandInteractionShape(surface: surface, horizontalInset: 6).path(in: rect)
        for x in [1, 3, 5, 274, 276, 278] as [CGFloat] {
            XCTAssertFalse(hit.contains(CGPoint(x: x, y: 1)))
        }
        for x in [7, 28, 50, 229, 251, 272] as [CGFloat] {
            XCTAssertTrue(hit.contains(CGPoint(x: x, y: 16)))
        }
        XCTAssertEqual(IslandInteractionShape(surface: surface, horizontalInset: 0).path(in: rect), surface.path(in: rect))
    }

    private func makeWindow(host: NSView, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 279, height: height),
            styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/verification/compact-polish")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }
}
