import SwiftUI

/// Design tokens. One source for colour, radius, spacing and motion — nothing
/// in the app hard-codes a value these cover.
enum Tokens {
    static let accent = Color(nsColor: .controlAccentColor)          // follows System Settings
    static let brand = Color(red: 0.039, green: 0.518, blue: 1.0)    // #0A84FF
    static let success = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let warning = Color(red: 1.0,   green: 0.624, blue: 0.039) // #FF9F0A
    static let danger  = Color(red: 1.0,   green: 0.271, blue: 0.227) // #FF453A

    // Radii — macOS uses tighter corners on controls than on containers.
    static let control: CGFloat = 8
    static let card: CGFloat = 12
    static let sheet: CGFloat = 16
    static let tile: CGFloat = 11

    // Spacing scale.
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12
    static let s4: CGFloat = 16, s5: CGFloat = 24, s6: CGFloat = 32

    // Motion. One curve family, four speeds — the whole app animates with these.
    static let quick  = Animation.smooth(duration: 0.22)
    static let normal = Animation.smooth(duration: 0.34)
    static let sheetIn = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let bouncy = Animation.spring(response: 0.32, dampingFraction: 0.62)
}

extension Font {
    static let sectionLabel = Font.system(size: 11, weight: .semibold).width(.standard)
    static let rowTitle = Font.system(size: 13)
    static let barTitle = Font.system(size: 13.5, weight: .semibold)
    static let caption2Mono = Font.system(size: 10.5, design: .monospaced)
    static let captionMono = Font.system(size: 11.5, design: .monospaced)
}

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Translucent card used for every grouped surface.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Tokens.card
    func body(content: Content) -> some View {
        content
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
            }
    }
}

extension View {
    func card(radius: CGFloat = Tokens.card) -> some View {
        modifier(CardBackground(radius: radius))
    }

    /// Hairline used between rows inside a card.
    func rowDivider(_ show: Bool) -> some View {
        overlay(alignment: .top) {
            if show { Divider().opacity(0.6) }
        }
    }
}

/// Pill label — download status, purity, counts.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.18), in: .capsule)
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
