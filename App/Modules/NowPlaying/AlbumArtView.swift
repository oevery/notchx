import SwiftUI
import AppKit
import CoreGraphics

struct AlbumArtView: View {
    let image: NSImage?
    var size: CGFloat = 56
    var cornerRadius: CGFloat? = nil
    var glowEnabled = true
    @State private var averageGlowColor: Color = .clear
    @State private var colorRequestID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandMotion) private var motion

    var body: some View {
        ZStack {
            if glowEnabled, image != nil {
                glowLayer(scale: 1.22, opacity: 0.34, blur: size * 0.32)
                glowLayer(scale: 1.75, opacity: 0.22, blur: size * 0.62)
                glowLayer(scale: 2.3, opacity: 0.12, blur: size * 0.95)
            }

            PlaybackArtworkImage(image: image, size: size, cornerRadius: resolvedCornerRadius)
        }
        .frame(width: size, height: size)
        .contentShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .onAppear {
            updateAverageGlowColor()
        }
        .onChange(of: glowEnabled) { _, _ in updateAverageGlowColor() }
        .onChange(of: image.map(ObjectIdentifier.init)) { _, _ in
            updateAverageGlowColor()
        }
        .onDisappear { colorRequestID = UUID() }
    }

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 0.15
    }

    private func updateAverageGlowColor() {
        let request = UUID()
        colorRequestID = request
        guard glowEnabled, let image else {
            averageGlowColor = .clear
            return
        }

        image.averageColor { color in
            guard colorRequestID == request else { return }
            let nextColor = color.map { nsColor in
                let boosted = boostedGlowColor(from: nsColor)
                return Color(nsColor: boosted)
            } ?? Color.clear
            withAnimation(reduceMotion ? .easeOut(duration: 0.1) : motion.artwork) {
                averageGlowColor = nextColor
            }
        }
    }

    @ViewBuilder
    private func glowLayer(scale: CGFloat, opacity: Double, blur: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
            .fill(averageGlowColor.opacity(opacity))
            .scaleEffect(scale)
            .blur(radius: blur)
            .blendMode(.screen)
            .shadow(color: averageGlowColor.opacity(opacity * 0.9), radius: blur * 0.6)
            // Glow may extend well outside the artwork, including over tabs.
            // It is decorative and must never enlarge the button's hit region.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func boostedGlowColor(from color: NSColor) -> NSColor {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            hue: hue,
            saturation: min(max(saturation * 1.15, 0.55), 1.0),
            brightness: min(max(brightness * 1.18, 0.72), 1.0),
            alpha: alpha
        )
    }
}

/// Animate the image itself, including late artwork, without replacing buttons
/// or restarting their glow/state whenever transport metadata changes.
struct PlaybackArtworkImage: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandMotion) private var motion

    var body: some View {
        ZStack {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: size, height: size)
            .id(image.map(ObjectIdentifier.init))
            .transition(.opacity)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(reduceMotion ? .easeOut(duration: 0.1) : motion.artwork,
                   value: image.map(ObjectIdentifier.init))
        .modifier(PlaybackArtworkGeometry())
    }
}

extension NSImage {
    func averageColor(completion: @escaping (NSColor?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            // A glow needs a palette sample, not a full-resolution pixel scan.
            // Bounded work also keeps simultaneous incoming/outgoing artwork cheap.
            let width = min(cgImage.width, 32)
            let height = min(cgImage.height, 32)
            let totalPixels = width * height

            guard totalPixels > 0,
                  let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            guard let data = context.data else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            let pointer = data.bindMemory(to: UInt32.self, capacity: totalPixels)
            var totalRed: UInt64 = 0
            var totalGreen: UInt64 = 0
            var totalBlue: UInt64 = 0

            for index in 0..<totalPixels {
                let color = pointer[index]
                totalRed += UInt64(color & 0xFF)
                totalGreen += UInt64((color >> 8) & 0xFF)
                totalBlue += UInt64((color >> 16) & 0xFF)
            }

            let averageRed = CGFloat(totalRed) / CGFloat(totalPixels) / 255.0
            let averageGreen = CGFloat(totalGreen) / CGFloat(totalPixels) / 255.0
            let averageBlue = CGFloat(totalBlue) / CGFloat(totalPixels) / 255.0

            let minimumBrightness: CGFloat = 0.5
            let isNearBlack = averageRed < 0.03 && averageGreen < 0.03 && averageBlue < 0.03

            let finalColor: NSColor
            if isNearBlack {
                finalColor = NSColor(white: minimumBrightness, alpha: 1.0)
            } else {
                var color = NSColor(red: averageRed, green: averageGreen, blue: averageBlue, alpha: 1.0)
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0

                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

                if brightness < minimumBrightness {
                    let saturationScale = brightness / minimumBrightness
                    color = NSColor(
                        hue: hue,
                        saturation: saturation * saturationScale,
                        brightness: minimumBrightness,
                        alpha: alpha
                    )
                }

                finalColor = color
            }

            DispatchQueue.main.async {
                completion(finalColor)
            }
        }
    }
}
