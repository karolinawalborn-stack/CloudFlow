import SwiftUI

enum FlowStyle {
    static let background = Color(red: 0.055, green: 0.061, blue: 0.073)
    static let surface = Color(red: 0.091, green: 0.103, blue: 0.125)
    static let border = Color(red: 0.18, green: 0.20, blue: 0.24)
    static let text = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let muted = Color(red: 0.65, green: 0.69, blue: 0.76)
    static let accent = Color(red: 0.37, green: 0.91, blue: 0.80)
    static let ink = Color(red: 0.025, green: 0.14, blue: 0.14)
    static let success = Color(red: 0.59, green: 0.86, blue: 0.73)
    static let warning = Color(red: 1.0, green: 0.78, blue: 0.48)

    static func diskColor(_ disk: Disk) -> Color {
        switch disk {
        case .quark: return accent
        case .xunlei: return warning
        case .baidu: return Color(red: 1.0, green: 0.69, blue: 0.73)
        }
    }

    static func diskIcon(_ disk: Disk) -> String {
        switch disk {
        case .quark: return "cloud"
        case .xunlei: return "bolt.fill"
        case .baidu: return "externaldrive"
        }
    }
}

struct FlowGlyph: View {
    let symbol: String
    var color: Color = FlowStyle.accent
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityHidden(true)
    }
}

struct FlowButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(primary ? FlowStyle.ink : FlowStyle.text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(primary ? FlowStyle.accent : FlowStyle.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(FlowStyle.border, lineWidth: primary ? 0 : 1) }
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct FlowCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(FlowStyle.border) }
    }
}

struct FlowBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.035, green: 0.075, blue: 0.095), FlowStyle.background, FlowStyle.background], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
