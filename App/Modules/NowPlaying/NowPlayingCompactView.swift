import AppKit
import SwiftUI

struct NowPlayingCompactView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var manager = NowPlayingManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Button(action: appState.presentNowPlaying) { albumHint }
                .buttonStyle(.plain)
                .help(L10n.text("Open playback page"))

            if appState.usesWideCompactLayout && !manager.title.isEmpty {
                Button(action: appState.presentNowPlaying) {
                    Text(manager.title)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? .easeOut(duration: 0.1) : appState.contentSwapAnimation, value: manager.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Open playback page"))
            }

            Spacer(minLength: 0)
            playbackHint
        }
    }

    private var compactArtSize: CGFloat {
        appState.usesWideCompactLayout ? 22 : 24
    }

    private var albumHint: some View {
        PlaybackArtworkImage(image: manager.albumArt, size: compactArtSize, cornerRadius: compactArtSize / 2)
    }

    @ViewBuilder
    private var playbackHint: some View {
        NowPlayingPlaybackCompactButton()
    }
}

// MARK: - Equalizer Bars Animation

final class CompactAudioSpectrumView: NSView {
    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2
    private static let barCount = 4
    private static let barHeight: CGFloat = 14
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var animationTimer: Timer?
    private var barColor: NSColor = .white

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    deinit {
        animationTimer?.invalidate()
    }

    private func setupBars() {
        for _ in 0..<Self.barCount {
            let barLayer = CAShapeLayer()
            barLayer.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.fillColor = barColor.cgColor
            barLayer.backgroundColor = barColor.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            barLayer.path = NSBezierPath(
                roundedRect: barLayer.bounds,
                xRadius: Self.barWidth / 2,
                yRadius: Self.barWidth / 2
            ).cgPath

            barLayers.append(barLayer)
            barScales.append(0.35)
            layer?.addSublayer(barLayer)
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing
        let startX = bounds.midX - width / 2
        // Reposition without implicit motion or disturbing the scale animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            bar.position = CGPoint(x: startX + CGFloat(index) * (Self.barWidth + Self.barSpacing) + Self.barWidth / 2,
                                   y: bounds.midY)
        }
        CATransaction.commit()
    }

    func updateBarColor(_ color: NSColor) {
        guard color != barColor else { return }
        barColor = color
        for barLayer in barLayers {
            barLayer.fillColor = color.cgColor
            barLayer.backgroundColor = color.cgColor
        }
    }

    func setPlaying(_ isPlaying: Bool) {
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
        updateBars()
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }

    private func updateBars() {
        for (index, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[index]
            let targetScale = CGFloat.random(in: 0.35...1.0)
            barScales[index] = targetScale

            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false

            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)

            barLayer.add(animation, forKey: "scaleY")
        }
    }

    private func resetBars() {
        for (index, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barScales[index] = 0.35
        }
    }
}

struct EqualizerBarsView: NSViewRepresentable {
    let isPlaying: Bool
    var barColor: NSColor = .white

    func makeNSView(context: Context) -> CompactAudioSpectrumView {
        let spectrumView = CompactAudioSpectrumView()
        spectrumView.updateBarColor(barColor)
        spectrumView.setPlaying(isPlaying)
        return spectrumView
    }

    func updateNSView(_ nsView: CompactAudioSpectrumView, context: Context) {
        nsView.updateBarColor(barColor)
        nsView.setPlaying(isPlaying)
    }
}

struct NowPlayingPlaybackCompactButton: View {
    @Environment(\.islandContentActive) private var contentActive
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var manager = NowPlayingManager.shared
    @State private var isHovering = false

    var body: some View {
        Button {
            appState.beginCompactControlInteraction()
            manager.togglePlayPause()
        } label: {
            CompactSlot(kind: .indicator) { _ in
                CompactPlaybackIndicator(isPlaying: manager.isPlaying, isHovering: isHovering,
                    animatesSpectrum: contentActive && !reduceMotion && !appState.shouldReduceMotion,
                    barColor: manager.albumArtColor ?? .white)
                .animation(reduceMotion ? .easeOut(duration: 0.08) : appState.motion.feedback, value: manager.isPlaying)
                .animation(reduceMotion ? .easeOut(duration: 0.08) : appState.motion.feedback, value: isHovering)
            }
        }
        .buttonStyle(.plain)
        .disabled(!manager.hasControllableTrack)
        .allowsHitTesting(!manager.isControlPending)
        .hoverPointer()
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

/// All playback states occupy one centered footprint inside CompactSlot.
struct CompactPlaybackIndicator: View {
    let isPlaying: Bool
    let isHovering: Bool
    let animatesSpectrum: Bool
    var barColor: NSColor = .white

    private var stateID: String { isPlaying ? (isHovering ? "pause" : "spectrum") : "play" }

    var body: some View {
        ZStack {
            Group {
                if isPlaying && !isHovering {
                    EqualizerBarsView(isPlaying: animatesSpectrum, barColor: barColor)
                        .frame(width: 20, height: 16)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(isPlaying ? 0.95 : 0.9))
                        .frame(width: 18, height: 18, alignment: .center)
                }
            }
            .id(stateID)
            .transition(.opacity)
        }
        .frame(width: 20, height: 18, alignment: .center)
    }
}
