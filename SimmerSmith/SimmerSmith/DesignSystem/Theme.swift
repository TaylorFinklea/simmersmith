import SwiftUI

// MARK: - Color Tokens

enum SMColor {
    // Surfaces
    static let surface = Color(hex: 0x1A1A1E)
    static let surfaceElevated = Color(hex: 0x252528)
    static let surfaceCard = Color(hex: 0x2A2A2F)

    // Brand
    static let primary = Color(hex: 0xD4A047)
    static let primaryMuted = Color(hex: 0xA07830)
    static let accent = Color(hex: 0xE07C5A)

    // Text
    static let textPrimary = Color(hex: 0xF5F0EB)
    static let textSecondary = Color(hex: 0x9A958E)
    static let textTertiary = Color(hex: 0x6B665F)

    // Semantic
    static let success = Color(hex: 0x7CB375)
    static let aiPurple = Color(hex: 0xB07CFF)
    static let favoritePink = Color(hex: 0xE8758A)
    static let destructive = Color(hex: 0xD45F5F)
    static let divider = Color(hex: 0x333338)

    // Gradients
    static let cardGradient = LinearGradient(
        colors: [Color(hex: 0x2A2A2F), Color(hex: 0x222225)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let headerGradient = LinearGradient(
        colors: [Color(hex: 0xD4A047).opacity(0.3), Color(hex: 0x1A1A1E)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let recipeGradients: [LinearGradient] = [
        LinearGradient(colors: [Color(hex: 0x8B4513).opacity(0.6), Color(hex: 0x2A2A2F)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0x556B2F).opacity(0.6), Color(hex: 0x2A2A2F)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0x8B0000).opacity(0.4), Color(hex: 0x2A2A2F)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0x4A708B).opacity(0.5), Color(hex: 0x2A2A2F)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0xCD853F).opacity(0.5), Color(hex: 0x2A2A2F)], startPoint: .topLeading, endPoint: .bottomTrailing),
    ]
}

// MARK: - Typography

enum SMFont {
    static let display = Font.system(size: 28, weight: .bold, design: .serif)
    static let headline = Font.system(size: 20, weight: .semibold)
    static let subheadline = Font.system(size: 16, weight: .medium)
    static let body = Font.system(size: 15, weight: .regular)
    static let caption = Font.system(size: 13, weight: .regular)
    static let label = Font.system(size: 12, weight: .semibold)
}

// MARK: - Spacing

enum SMSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Radius

enum SMRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

// MARK: - Color(hex:) extension

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
