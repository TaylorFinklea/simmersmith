import SwiftUI
import UIKit

// MARK: - Color Tokens (Fusion · The Smith's Notebook)
//
// Light = linen paper analog. Dark = lamp-lit forge. Both share the
// ember accent. Colors resolve dynamically via UITraitCollection so a
// system theme change re-renders without manual plumbing.

enum SMColor {
    // ── New Fusion-native tokens ────────────────────────────────────
    static let paper       = Color(light: 0xEDE5D2, dark: 0x15110D)
    static let paperAlt    = Color(light: 0xF4ECDA, dark: 0x1F1A14)
    static let plate       = Color(light: 0x3A3833, dark: 0x2A241D)
    static let ink         = Color(light: 0x1B1813, dark: 0xEAE0CB)
    static let inkSoft     = Color(light: 0x5E5347, dark: 0x8F8576)
    static let inkFaint    = Color(light: 0x8C8270, dark: 0x6B6356)
    static let rule        = Color(light: 0xC7BCA4, dark: 0x33302A)

    static let ember       = Color(light: 0xE8541C, dark: 0xE8541C)
    static let emberHot    = Color(light: 0xC9851C, dark: 0xFFB347)
    static let bronze      = Color(light: 0x7B4A1F, dark: 0x7B4A1F)

    // Riso punctuation — used on store/category pills
    static let risoBlue    = Color(light: 0x2F4F7A, dark: 0x7E9DC8)
    static let risoGreen   = Color(light: 0x506B3A, dark: 0x9BB67D)
    static let risoYellow  = Color(light: 0xE5B432, dark: 0xF1C952)

    // ── Stable public names (existing 59 callsites) ─────────────────
    // Surfaces
    static let surface         = paper
    static let surfaceElevated = paperAlt
    static let surfaceCard     = paperAlt

    // Brand
    static let primary      = ember
    static let primaryMuted = bronze
    static let accent       = emberHot

    // Text
    static let textPrimary   = ink
    static let textSecondary = inkSoft
    static let textTertiary  = inkFaint

    // Semantic
    static let success       = risoGreen
    static let aiPurple      = ember        // the "Smith" speaks in ember
    static let favoritePink  = Color(light: 0xC95C77, dark: 0xE8758A)
    static let destructive   = Color(light: 0xB1422B, dark: 0xD45F5F)
    static let divider       = rule

    // Gradients — kept for API compatibility. Restated in paper tones
    // so the few callsites that use them don't ship dark slabs onto a
    // light background.
    static let cardGradient = LinearGradient(
        colors: [paperAlt, paper],
        startPoint: .top,
        endPoint: .bottom
    )
    static let headerGradient = LinearGradient(
        colors: [ember.opacity(0.18), paper.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Per-recipe placeholder gradients. Kept as 5 entries to match
    /// current callsites that index into the array. Updated to riso
    /// + ember + bronze tones over paperAlt so they sit on the new
    /// linen-paper surface.
    static let recipeGradients: [LinearGradient] = [
        LinearGradient(
            colors: [Color(light: 0xE8541C, dark: 0xE8541C).opacity(0.35), Color(light: 0xF4ECDA, dark: 0x1F1A14)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ),
        LinearGradient(
            colors: [Color(light: 0x506B3A, dark: 0x9BB67D).opacity(0.35), Color(light: 0xF4ECDA, dark: 0x1F1A14)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ),
        LinearGradient(
            colors: [Color(light: 0x2F4F7A, dark: 0x7E9DC8).opacity(0.35), Color(light: 0xF4ECDA, dark: 0x1F1A14)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ),
        LinearGradient(
            colors: [Color(light: 0xE5B432, dark: 0xF1C952).opacity(0.35), Color(light: 0xF4ECDA, dark: 0x1F1A14)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ),
        LinearGradient(
            colors: [Color(light: 0x7B4A1F, dark: 0x7B4A1F).opacity(0.35), Color(light: 0xF4ECDA, dark: 0x1F1A14)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ),
    ]
}

// MARK: - Typography (Fusion · serif + handwritten + stencil)
//
// Bundled OFL fonts: Instrument Serif (italic display), Spectral
// (body), Caveat (handwritten micro), Oswald (stencil numerics).
// Font.custom returns a system fallback if a font isn't registered,
// so views render even before the .ttf files land in the bundle.

enum SMFont {
    // ── Public semantic tokens (existing 404 callsites stay stable) ─
    static let display     = serifDisplay(28)
    static let headline    = serifDisplay(20)
    static let subheadline = bodySerif(16)
    static let body        = bodySerif(15)
    static let caption     = bodySerifItalic(13)
    static let label       = monoLabel(11)

    // ── New Fusion-native helpers (call directly from views) ────────

    /// Italic Instrument Serif for display / hero headers.
    /// Use 28–46pt for full hero titles, 20–24pt for section headers.
    static func serifDisplay(_ size: CGFloat) -> Font {
        Font.custom("InstrumentSerif-Italic", size: size)
    }

    /// Upright Instrument Serif for less-hero serif moments. Kept
    /// as a separate helper so call sites can opt into upright vs
    /// italic explicitly.
    static func serifTitle(_ size: CGFloat) -> Font {
        Font.custom("InstrumentSerif-Regular", size: size)
    }

    /// Spectral upright body copy. The default reading face.
    static func bodySerif(_ size: CGFloat) -> Font {
        Font.custom("Spectral-Regular", size: size)
    }

    /// Spectral italic body — used for inline emphasis and quoted
    /// notes ("Cooked Feb 3 — used dark miso, doubled the glaze").
    static func bodySerifItalic(_ size: CGFloat) -> Font {
        Font.custom("Spectral-Italic", size: size)
    }

    /// Caveat handwritten — sub-lines, micro labels, hand-drawn CTAs
    /// ("fire up →", "send →", "fennel · blood orange · olives").
    /// The variable Caveat font ships two named instances; bold uses
    /// the `CaveatRoman-Bold` PostScript name (Caveat ships the bold
    /// instance under the `Roman` style group, not as `Caveat-Bold`).
    static func handwritten(_ size: CGFloat, bold: Bool = false) -> Font {
        Font.custom(bold ? "CaveatRoman-Bold" : "Caveat-Regular", size: size)
    }

    /// Oswald stencil numerics — cooking step number and timer plate.
    /// Use sparingly; this is a marquee moment, not a body face.
    static func stencil(_ size: CGFloat, bold: Bool = false) -> Font {
        Font.custom(bold ? "Oswald-SemiBold" : "Oswald-Medium", size: size)
    }

    /// Mono uppercase eyebrow — "WEEK 10 · MARCH 4", "RECIPE № 047".
    /// System monospaced is fine; we don't bundle a custom mono.
    static func monoLabel(_ size: CGFloat) -> Font {
        Font.system(size: size, weight: .semibold, design: .monospaced)
    }
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
//
// Fusion is paper-on-paper; cards have minimal radius (0.5pt rule
// border, 0–2pt corner). Radii kept for API compatibility but flattened.

enum SMRadius {
    static let sm: CGFloat = 2
    static let md: CGFloat = 4
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
}

// MARK: - Color helpers

extension Color {
    /// Single-mode hex initializer used by old call sites.
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Dynamic color that resolves against the system color scheme.
    /// `light` is shown in Light Mode, `dark` in Dark Mode. iOS handles
    /// the live re-render when the user toggles appearance.
    init(light: UInt, dark: UInt) {
        self = Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red:   CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8)  & 0xFF) / 255,
                blue:  CGFloat( hex        & 0xFF) / 255,
                alpha: 1.0
            )
        })
    }
}
