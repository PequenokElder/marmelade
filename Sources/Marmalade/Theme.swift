import SwiftUI

/// Orange + teal palette with frosted-glass panels over a soft gradient backdrop.
enum Theme {
    static let orange = Color(red: 1.00, green: 0.56, blue: 0.20)
    static let coral = Color(red: 1.00, green: 0.38, blue: 0.30)
    static let teal = Color(red: 0.13, green: 0.76, blue: 0.72)
    static let deepTeal = Color(red: 0.04, green: 0.20, blue: 0.24)
    static let midnight = Color(red: 0.03, green: 0.09, blue: 0.12)

    static let gradient = LinearGradient(colors: [orange, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warmGradient = LinearGradient(colors: [orange, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Soft blurred orange and teal blobs on deep teal, behind everything. The glass panels frost this.
struct FrostedBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Theme.deepTeal, Theme.midnight], startPoint: .top, endPoint: .bottom)
                Circle().fill(Theme.orange.opacity(0.85))
                    .frame(width: geo.size.width * 0.42)
                    .position(x: geo.size.width * 0.06, y: geo.size.height * 0.16)
                Circle().fill(Theme.teal.opacity(0.75))
                    .frame(width: geo.size.width * 0.46)
                    .position(x: geo.size.width * 0.96, y: geo.size.height * 0.86)
                Circle().fill(Theme.coral.opacity(0.55))
                    .frame(width: geo.size.width * 0.24)
                    .position(x: geo.size.width * 0.92, y: geo.size.height * 0.08)
                Circle().fill(Theme.teal.opacity(0.5))
                    .frame(width: geo.size.width * 0.28)
                    .position(x: geo.size.width * 0.08, y: geo.size.height * 0.95)
            }
            .blur(radius: 70)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

/// Fine static speckle that gives the glass a frosted, sandblasted feel.
struct FrostGrain: View {
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    var body: some View {
        Canvas { ctx, size in
            var rng = SplitMix(state: 42)
            let count = Int(size.width * size.height / 70)
            for _ in 0..<count {
                let x = Double.random(in: 0..<size.width, using: &rng)
                let y = Double.random(in: 0..<size.height, using: &rng)
                let a = Double.random(in: 0.03...0.11, using: &rng)
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(a)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A big frosted-glass pane: blurred material, faint teal tint, grain, and a bright rim.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(shape.fill(Theme.teal.opacity(0.07)))
            .overlay(FrostGrain().clipShape(shape))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.04), .white.opacity(0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1))
            .shadow(color: .black.opacity(0.30), radius: 18, y: 10)
    }
}

/// A lighter glass tile for each control group inside a panel.
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(12)
            .background(shape.fill(Color.white.opacity(0.07)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

/// Section heading with an orange-to-teal tab.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Theme.gradient).frame(width: 4, height: 15)
            Text(text).font(.headline)
        }
    }
}

/// The big call-to-action button.
struct GlowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration)
    }

    private struct Inner: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.vertical, 11)
                .background(Capsule().fill(Theme.warmGradient))
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: Theme.orange.opacity(isEnabled ? 0.55 : 0), radius: configuration.isPressed ? 4 : 14, y: 4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() } else { content }
    }
}

/// Small text-style button in teal (the system link style ignores tint).
struct TealLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration)
    }

    private struct Inner: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.teal)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
        }
    }
}
