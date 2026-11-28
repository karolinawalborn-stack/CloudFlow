import SwiftUI
import UIKit

// MARK: - Design tokens
//
// 0.4.0 visual language: deep-space navy canvas, aurora gradient accent
// (cyan → electric blue → violet), hairline gradient borders, monospaced
// "system" labels. Every looping animation is a pure transform/opacity
// animation on a small layer (no per-frame blur, no per-frame body
// evaluation) and is switched off by Reduce Motion or the in-app
// "流畅优先" toggle.

enum FlowStyle {
    static let lowMotionKey = "cloudflow.lowMotion"

    static let background = Color(red: 0.020, green: 0.027, blue: 0.055)
    static let backgroundDeep = Color(red: 0.008, green: 0.012, blue: 0.030)
    static let surface = Color(red: 0.060, green: 0.075, blue: 0.120)
    static let surfaceHigh = Color(red: 0.085, green: 0.104, blue: 0.165)
    static let field = Color(red: 0.030, green: 0.040, blue: 0.075)
    static let border = Color.white.opacity(0.08)
    static let text = Color(red: 0.94, green: 0.96, blue: 1.0)
    static let muted = Color(red: 0.55, green: 0.61, blue: 0.73)
    static let accent = Color(red: 0.24, green: 0.93, blue: 1.0)
    static let accent2 = Color(red: 0.32, green: 0.50, blue: 1.0)
    static let accent3 = Color(red: 0.66, green: 0.44, blue: 1.0)
    static let ink = Color(red: 0.012, green: 0.035, blue: 0.075)
    static let success = Color(red: 0.32, green: 0.94, blue: 0.68)
    static let warning = Color(red: 1.0, green: 0.74, blue: 0.38)
    static let danger = Color(red: 1.0, green: 0.43, blue: 0.50)

    static let mono = Font.system(size: 10, weight: .semibold, design: .monospaced)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent2, accent3], startPoint: .leading, endPoint: .trailing)
    }
    static var hairline: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.04), accent.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var cardFill: LinearGradient {
        LinearGradient(colors: [surfaceHigh.opacity(0.94), surface.opacity(0.90)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func diskColor(_ disk: Disk) -> Color {
        switch disk {
        case .quark: return Color(red: 0.50, green: 0.56, blue: 1.0)
        case .xunlei: return accent
        case .baidu: return Color(red: 1.0, green: 0.48, blue: 0.66)
        }
    }

    static func diskIcon(_ disk: Disk) -> String {
        switch disk {
        case .quark: return "cloud.fill"
        case .xunlei: return "bolt.fill"
        case .baidu: return "externaldrive.fill"
        }
    }

    static func statusColor(_ status: ShareJob.Status) -> Color {
        switch status {
        case .ready: return accent2
        case .running: return accent
        case .done: return success
        case .failed: return danger
        case .uncertain: return warning
        }
    }

    static func statusText(_ status: ShareJob.Status) -> String {
        switch status {
        case .ready: return "待转存"
        case .running: return "执行中"
        case .done: return "已完成"
        case .failed: return "需重试"
        case .uncertain: return "待核对"
        }
    }
}

@MainActor enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Backdrop

struct FlowBackdrop: View {
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [FlowStyle.backgroundDeep, FlowStyle.background, Color(red: 0.025, green: 0.035, blue: 0.08)], startPoint: .top, endPoint: .bottom)
            if animated && !reduceMotion && !lowMotion { AuroraField(drifting: true) } else { AuroraField(drifting: false) }
            GridPattern(spacing: 28)
                .stroke(Color.white.opacity(0.035), lineWidth: 0.5)
                .mask { LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .center) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AuroraField: View {
    let drifting: Bool
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let p = drifting && phase
            ZStack {
                blob(FlowStyle.accent2, diameter: w * 1.25, opacity: 0.30)
                    .offset(x: p ? -w * 0.18 : w * 0.10, y: p ? -h * 0.26 : -h * 0.36)
                blob(FlowStyle.accent3, diameter: w * 1.0, opacity: 0.22)
                    .offset(x: p ? w * 0.32 : w * 0.12, y: p ? -h * 0.02 : -h * 0.16)
                blob(FlowStyle.accent, diameter: w * 0.9, opacity: 0.13)
                    .offset(x: p ? -w * 0.10 : -w * 0.34, y: p ? h * 0.36 : h * 0.22)
            }
            .frame(width: w, height: h)
            .animation(drifting ? .easeInOut(duration: 16).repeatForever(autoreverses: true) : nil, value: phase)
        }
        .onAppear {
            guard drifting else { return }
            DispatchQueue.main.async { phase = true }
        }
    }

    // Radial gradients give a soft glow without any blur filter.
    private func blob(_ color: Color, diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.35), .clear], center: .center, startRadius: 0, endRadius: max(1, diameter / 2)))
            .frame(width: max(1, diameter), height: max(1, diameter))
    }
}

struct GridPattern: Shape {
    var spacing: CGFloat = 28
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard spacing > 1 else { return path }
        var x: CGFloat = 0
        while x <= rect.width {
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height)); x += spacing
        }
        var y: CGFloat = 0
        while y <= rect.height {
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y)); y += spacing
        }
        return path
    }
}

// MARK: - Surfaces

struct FlowCard<Content: View>: View {
    var padding: CGFloat = 18
    let content: Content
    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) { self.padding = padding; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(FlowStyle.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(FlowStyle.hairline, lineWidth: 1))
    }
}

struct FlowGlyph: View {
    let symbol: String
    var color: Color = FlowStyle.accent
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous).fill(LinearGradient(colors: [color.opacity(0.24), color.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous).strokeBorder(color.opacity(0.28), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct SectionTitle: View {
    let index: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(index + " //").font(FlowStyle.mono).tracking(1.5).foregroundStyle(FlowStyle.accent.opacity(0.9))
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TechLabel: View {
    let index: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Text(index).foregroundStyle(FlowStyle.accent)
            Rectangle().fill(FlowStyle.accent.opacity(0.5)).frame(width: 14, height: 1)
            Text(title).foregroundStyle(FlowStyle.muted)
        }
        .font(FlowStyle.mono)
        .tracking(1.6)
        .accessibilityHidden(true)
    }
}

struct NoticeBanner: View {
    let text: String
    var body: some View {
        Group {
            if !text.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(FlowStyle.accent)
                    Text(text).font(.caption).foregroundStyle(FlowStyle.text.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FlowStyle.accent.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(FlowStyle.accent.opacity(0.2), lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: text)
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false

    var body: some View {
        FlowCard {
            VStack(spacing: 12) {
                if reduceMotion || lowMotion { EmptyEmblem(symbol: symbol, floating: false) } else { EmptyEmblem(symbol: symbol, floating: true) }
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(FlowStyle.muted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }
}

private struct EmptyEmblem: View {
    let symbol: String
    let floating: Bool
    @State private var lift = false
    var body: some View {
        ZStack {
            Circle().fill(FlowStyle.accent.opacity(0.08))
            Circle().strokeBorder(FlowStyle.accent.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            Image(systemName: symbol).font(.title2).foregroundStyle(FlowStyle.accentGradient)
        }
        .frame(width: 64, height: 64)
        .offset(y: floating && lift ? -4 : 2)
        .animation(floating ? .easeInOut(duration: 2.4).repeatForever(autoreverses: true) : nil, value: lift)
        .onAppear { if floating { DispatchQueue.main.async { lift = true } } }
        .accessibilityHidden(true)
    }
}

// MARK: - Inputs

struct FlowEditor: View {
    let title: String
    @Binding var text: String
    let height: CGFloat
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(prompt).font(.body).foregroundStyle(FlowStyle.muted.opacity(0.85))
                    .padding(.horizontal, 14).padding(.top, 17).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .focused($focused)
                .font(.body)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: height)
                .accessibilityLabel(title)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if focused {
                            Spacer()
                            Button("完成") { focused = false }
                        }
                    }
                }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FlowStyle.field.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? AnyShapeStyle(FlowStyle.accentGradient) : AnyShapeStyle(FlowStyle.border), lineWidth: focused ? 1.3 : 1))
        .animation(.easeOut(duration: 0.2), value: focused)
    }
}

struct FlowField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var secure = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(FlowStyle.muted)
            Group {
                if secure {
                    SecureField(text: $text, prompt: Text(prompt).foregroundColor(FlowStyle.muted.opacity(0.7))) { Text(title) }
                } else {
                    TextField(text: $text, prompt: Text(prompt).foregroundColor(FlowStyle.muted.opacity(0.7))) { Text(title) }
                }
            }
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FlowStyle.field.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? AnyShapeStyle(FlowStyle.accentGradient) : AnyShapeStyle(FlowStyle.border), lineWidth: focused ? 1.3 : 1))
            .animation(.easeOut(duration: 0.2), value: focused)
        }
    }
}

struct FlowSegmented: View {
    let options: [String]
    @Binding var selection: String
    var marks: [Bool] = []
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option == selection
                Button {
                    guard !selected else { return }
                    Haptics.select()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        Text(option).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        if index < marks.count && marks[index] {
                            Circle().fill(selected ? FlowStyle.accent : FlowStyle.success.opacity(0.8)).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(selected ? FlowStyle.text : FlowStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(FlowStyle.accent.opacity(0.15))
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(FlowStyle.accent.opacity(0.45), lineWidth: 1))
                                .matchedGeometryEffect(id: "segment", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FlowStyle.field.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(FlowStyle.border, lineWidth: 1))
    }
}

// MARK: - Buttons

struct FlowButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, hero }
    let kind: Kind
    init(primary: Bool) { kind = primary ? .primary : .secondary }
    init(_ kind: Kind) { self.kind = kind }
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let filled = kind != .secondary
        let radius: CGFloat = kind == .hero ? 18 : 14
        return configuration.label
            .font(kind == .hero ? Font.body.weight(.semibold) : Font.subheadline.weight(.semibold))
            .foregroundStyle(filled && enabled ? FlowStyle.ink : FlowStyle.text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, kind == .hero ? 20 : 15)
            .padding(.vertical, kind == .hero ? 14 : 9)
            .frame(minHeight: kind == .hero ? 56 : 46)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(enabled ? AnyShapeStyle(FlowStyle.accentGradient) : AnyShapeStyle(FlowStyle.surfaceHigh))
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(LinearGradient(colors: [Color.white.opacity(enabled ? 0.30 : 0.05), .clear], startPoint: .top, endPoint: .center))
                                .padding(1)
                        )
                        .shadow(color: FlowStyle.accent.opacity(enabled ? (pressed ? 0.12 : 0.30) : 0), radius: kind == .hero ? 16 : 9, y: 6)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(FlowStyle.surfaceHigh.opacity(pressed ? 1 : 0.85))
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(FlowStyle.hairline, lineWidth: 1))
                }
            }
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: pressed)
    }
}

struct ChipStyle: ButtonStyle {
    var tint: Color = FlowStyle.text
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.2), lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }
}

struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .brightness(configuration.isPressed ? 0.04 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Motion primitives

struct PulseDot: View {
    let color: Color
    var active = true
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false

    var body: some View {
        ZStack {
            if active && !reduceMotion && !lowMotion { PulseHalo(color: color) }
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct PulseHalo: View {
    let color: Color
    @State private var expand = false
    var body: some View {
        Circle()
            .fill(color.opacity(0.55))
            .scaleEffect(expand ? 2.8 : 1)
            .opacity(expand ? 0 : 0.8)
            .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: expand)
            .onAppear { DispatchQueue.main.async { expand = true } }
    }
}

struct ScanLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false
    var body: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.06))
            if reduceMotion || lowMotion { Capsule().fill(FlowStyle.accentGradient).opacity(0.5) } else { ScanSweep() }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct ScanSweep: View {
    @State private var move = false
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(colors: [.clear, FlowStyle.accent, FlowStyle.accent3, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * 0.42)
                .offset(x: move ? geo.size.width : -geo.size.width * 0.42)
                .animation(.easeInOut(duration: 1.25).repeatForever(autoreverses: false), value: move)
        }
        .onAppear { DispatchQueue.main.async { move = true } }
    }
}

struct ShimmerOverlay: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false
    var body: some View {
        if !(reduceMotion || lowMotion) {
            ShimmerSweep()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct ShimmerSweep: View {
    @State private var move = false
    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Color.white.opacity(0.38), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.35)
                .offset(x: move ? geo.size.width * 1.1 : -geo.size.width * 0.4)
                .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: move)
        }
        .onAppear { DispatchQueue.main.async { move = true } }
    }
}

/// A light beam that orbits a rounded border.
struct OrbitBorder: ViewModifier {
    let cornerRadius: CGFloat
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(FlowStyle.hairline, lineWidth: 1))
            .overlay {
                if active {
                    if reduceMotion || lowMotion {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(FlowStyle.accent.opacity(0.35), lineWidth: 1.2)
                    } else {
                        OrbitRing(cornerRadius: cornerRadius)
                    }
                }
            }
    }
}

private struct OrbitRing: View {
    let cornerRadius: CGFloat
    @State private var spin = false
    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 1.6
            AngularGradient(colors: [.clear, FlowStyle.accent.opacity(0.95), FlowStyle.accent3, .clear, .clear, FlowStyle.accent2.opacity(0.7), .clear], center: .center)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 7).repeatForever(autoreverses: false), value: spin)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .mask { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(lineWidth: 1.3) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { DispatchQueue.main.async { spin = true } }
    }
}

/// Staggered entrance used for page sections.
struct RiseIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false

    func body(content: Content) -> some View {
        let still = reduceMotion || lowMotion
        return content
            .opacity(shown || still ? 1 : 0)
            .offset(y: shown || still ? 0 : 16)
            .onAppear {
                guard !shown else { return }
                if still { shown = true; return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(Double(index) * 0.06)) { shown = true }
            }
    }
}

extension View {
    func riseIn(_ index: Int) -> some View { modifier(RiseIn(index: index)) }
    func orbitBorder(cornerRadius: CGFloat, active: Bool = true) -> some View { modifier(OrbitBorder(cornerRadius: cornerRadius, active: active)) }
    /// Shared chrome for Form-based sheets.
    func flowFormChrome() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(FlowBackdrop(animated: false))
            .toolbarBackground(FlowStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(FlowStyle.accent)
    }
}

// MARK: - Data visuals

struct MetricTile: View {
    let title: String
    let value: Int
    var suffix = ""
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(value)")
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                if !suffix.isEmpty {
                    Text(suffix).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(FlowStyle.muted)
                }
            }
            HStack(spacing: 5) {
                Capsule().fill(tint).frame(width: 10, height: 3)
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(FlowStyle.muted).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: value)
        .accessibilityElement(children: .combine)
    }
}

struct ProgressRing: View {
    let progress: Double
    var body: some View {
        let clamped = max(0, min(1, progress))
        let percent = String(Int((clamped * 100).rounded())) + "%"
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.03, clamped))
                .stroke(AngularGradient(colors: [FlowStyle.accent, FlowStyle.accent2, FlowStyle.accent3, FlowStyle.accent], center: .center), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: percent)
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
        }
        .frame(width: 46, height: 46)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: clamped)
        .accessibilityLabel(Text(verbatim: "进度 " + percent))
    }
}

struct FlowCore: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FlowStyle.lowMotionKey) private var lowMotion = false
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [FlowStyle.accent.opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: 46))
            Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            if reduceMotion || lowMotion { CoreRings(spinning: false) } else { CoreRings(spinning: true) }
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(FlowStyle.accentGradient)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 88, height: 88)
        .accessibilityHidden(true)
    }
}

private struct CoreRings: View {
    let spinning: Bool
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(AngularGradient(colors: [FlowStyle.accent.opacity(0), FlowStyle.accent], center: .center, startAngle: .degrees(0), endAngle: .degrees(252)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(7)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(spinning ? .linear(duration: 3.6).repeatForever(autoreverses: false) : nil, value: spin)
            Circle()
                .trim(from: 0.05, to: 0.42)
                .stroke(FlowStyle.accent3.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
                .padding(18)
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(spinning ? .linear(duration: 6.5).repeatForever(autoreverses: false) : nil, value: spin)
        }
        .onAppear {
            guard spinning else { return }
            DispatchQueue.main.async { spin = true }
        }
    }
}

struct LoadBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(FlowStyle.accentGradient)
                .frame(width: geo.size.width * max(0, min(1, progress)))
        }
        .frame(height: 2)
        .opacity(progress > 0 && progress < 1 ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: progress)
        .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let status: ShareJob.Status
    var body: some View {
        let color = FlowStyle.statusColor(status)
        HStack(spacing: 5) {
            if status == .running {
                ProgressView().controlSize(.small).tint(color).scaleEffect(0.75).frame(width: 10, height: 10)
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(FlowStyle.statusText(status)).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1))
        .fixedSize()
    }
}
