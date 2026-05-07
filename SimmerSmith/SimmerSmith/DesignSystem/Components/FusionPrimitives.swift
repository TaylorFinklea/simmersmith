import SwiftUI

// MARK: - Fusion drawing primitives
//
// Hand-drawn rules, riveted corners, paper grain, anvil-ember mark.
// These compose into the Smith's Notebook screens. Translated from
// the JSX mockup in /tmp/simmersmith-mockups/src/fusion.jsx (the
// FuHandRule / FuHandUnderline / FuRivet / FuMark / FuEmberGlow
// drawing helpers).

/// A wavy hand-drawn rule used as a section divider on paper.
/// Approximates the JSX `<path d="M2 4 C 30 2 …">` shape with a
/// SwiftUI Path so it scales without rasterizing.
struct HandRule: View {
    var color: Color = SMColor.rule
    var height: CGFloat = 8
    var lineWidth: CGFloat = 1.2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let mid = height / 2
            Path { p in
                p.move(to: CGPoint(x: 2, y: mid))
                p.addCurve(
                    to: CGPoint(x: w * 0.5, y: mid),
                    control1: CGPoint(x: w * 0.15, y: mid - 1.8),
                    control2: CGPoint(x: w * 0.30, y: mid + 1.8)
                )
                p.addCurve(
                    to: CGPoint(x: w - 2, y: mid),
                    control1: CGPoint(x: w * 0.70, y: mid - 1.8),
                    control2: CGPoint(x: w * 0.85, y: mid + 1.4)
                )
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .frame(height: height)
    }
}

/// A thin dashed hairline. Used on RecipeDetail's stat row top +
/// bottom edges (the `25 minutes / 4 plates / 1 pan` strip in the
/// mockup) and any other place a clean dashed rule reads better than
/// the slightly-wobbly HandRule.
struct DashedRule: View {
    var color: Color = SMColor.rule
    var dash: [CGFloat] = [3, 2]
    var lineWidth: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: lineWidth / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: lineWidth / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: dash))
        }
        .frame(height: lineWidth)
    }
}

/// A short hand-drawn underline used to mark hero titles.
struct HandUnderline: View {
    var color: Color = SMColor.ember
    var width: CGFloat = 80
    var height: CGFloat = 6
    var lineWidth: CGFloat = 2

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 2, y: height / 2))
            p.addQuadCurve(
                to: CGPoint(x: width * 0.5, y: height / 2),
                control: CGPoint(x: width * 0.25, y: 1)
            )
            p.addQuadCurve(
                to: CGPoint(x: width - 2, y: height / 2 - 0.5),
                control: CGPoint(x: width * 0.75, y: height / 2 + 1.5)
            )
        }
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .frame(width: width, height: height)
    }
}

/// A hand-drawn checkmark in an irregular box. Used for ingredient
/// "in pantry" ticks and grocery checkoff. When `checked`, the box
/// fills with ember and a white check is drawn over it.
struct HandCheck: View {
    var checked: Bool
    var color: Color = SMColor.ink
    var ember: Color = SMColor.ember
    var size: CGFloat = 18

    var body: some View {
        let stroke = checked ? ember : color
        ZStack {
            Path { p in
                let s = size
                p.move(to: CGPoint(x: s * 0.125, y: s * 0.166))
                p.addQuadCurve(to: CGPoint(x: s * 0.5, y: s * 0.125), control: CGPoint(x: s * 0.166, y: s * 0.125))
                p.addQuadCurve(to: CGPoint(x: s * 0.875, y: s * 0.166), control: CGPoint(x: s * 0.834, y: s * 0.125))
                p.addQuadCurve(to: CGPoint(x: s * 0.875, y: s * 0.5), control: CGPoint(x: s * 0.916, y: s * 0.208))
                p.addQuadCurve(to: CGPoint(x: s * 0.875, y: s * 0.875), control: CGPoint(x: s * 0.875, y: s * 0.916))
                p.addQuadCurve(to: CGPoint(x: s * 0.5, y: s * 0.875), control: CGPoint(x: s * 0.834, y: s * 0.916))
                p.addQuadCurve(to: CGPoint(x: s * 0.125, y: s * 0.875), control: CGPoint(x: s * 0.166, y: s * 0.916))
                p.addQuadCurve(to: CGPoint(x: s * 0.125, y: s * 0.5), control: CGPoint(x: s * 0.083, y: s * 0.834))
                p.addQuadCurve(to: CGPoint(x: s * 0.125, y: s * 0.166), control: CGPoint(x: s * 0.083, y: s * 0.166))
                p.closeSubpath()
            }
            .stroke(stroke, style: StrokeStyle(lineWidth: max(1.2, size * 0.07)))
            .background(checked ? ember : .clear)

            if checked {
                Path { p in
                    p.move(to: CGPoint(x: size * 0.25, y: size * 0.5))
                    p.addLine(to: CGPoint(x: size * 0.46, y: size * 0.71))
                    p.addLine(to: CGPoint(x: size * 0.79, y: size * 0.29))
                }
                .stroke(SMColor.paper, style: StrokeStyle(lineWidth: max(1.6, size * 0.12), lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A small radial-gradient rivet used to dress riveted plates. Four
/// corner rivets express the "forged" treatment on hero cards.
struct Rivet: View {
    var size: CGFloat = 5
    var color: Color = Color(light: 0x9C7A2A, dark: 0x5A5046)
    var glow: Color? = nil

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.85), color.opacity(0.55)],
                    center: UnitPoint(x: 0.3, y: 0.3),
                    startRadius: 0,
                    endRadius: size * 0.6
                )
            )
            .frame(width: size, height: size)
            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 3)
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.3), lineWidth: 0.5)
                    .padding(0.5)
            )
    }
}

/// View modifier that drops 4 rivets in the corners of a card.
struct RivetCorners: ViewModifier {
    var color: Color = Color(light: 0x9C7A2A, dark: 0x5A5046)
    var ember: Color = SMColor.ember
    var inset: CGFloat = 6
    var glow: Bool = false

    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                VStack {
                    HStack {
                        Rivet(size: 4.5, color: color, glow: glow ? ember : nil)
                        Spacer()
                        Rivet(size: 4.5, color: color, glow: glow ? ember : nil)
                    }
                    Spacer()
                    HStack {
                        Rivet(size: 4.5, color: color, glow: glow ? ember : nil)
                        Spacer()
                        Rivet(size: 4.5, color: color, glow: glow ? ember : nil)
                    }
                }
                .padding(inset)
            }
        )
    }
}

extension View {
    /// Drops 4 corner rivets on a riveted plate card.
    func rivetCorners(
        color: Color = Color(light: 0x9C7A2A, dark: 0x5A5046),
        ember: Color = SMColor.ember,
        inset: CGFloat = 6,
        glow: Bool = false
    ) -> some View {
        modifier(RivetCorners(color: color, ember: ember, inset: inset, glow: glow))
    }
}

/// Paper grain — subtle dot noise overlaid on the page background.
/// Performance-cheap: a single CGImage drawn via Canvas, scaled by
/// system. The opacity is what makes it read as "linen" not "grid".
struct PaperGrain: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let dark = scheme == .dark
            let darkDot = Color(white: 0, opacity: dark ? 0.18 : 0.05)
            let lightDot = Color(white: 1, opacity: dark ? 0.04 : 0.5)
            // Two staggered dot grids — gives a slightly noisy linen.
            for x in stride(from: 0, to: size.width, by: 3) {
                for y in stride(from: 0, to: size.height, by: 3) {
                    let rect = CGRect(x: x, y: y, width: 0.7, height: 0.7)
                    ctx.fill(Path(ellipseIn: rect), with: .color(darkDot))
                }
            }
            for x in stride(from: 1.5, to: size.width, by: 5) {
                for y in stride(from: 1.5, to: size.height, by: 5) {
                    let rect = CGRect(x: x, y: y, width: 0.6, height: 0.6)
                    ctx.fill(Path(ellipseIn: rect), with: .color(lightDot))
                }
            }
        }
        .opacity(scheme == .dark ? 0.55 : 0.7)
        .allowsHitTesting(false)
    }
}

/// View modifier that applies the paper page background with grain.
/// Use as the root background of any Fusion screen body.
struct PaperBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    SMColor.paper.ignoresSafeArea()
                    PaperGrain().ignoresSafeArea()
                }
            )
    }
}

extension View {
    /// Linen-paper page background with grain. Use on any scrolling
    /// Fusion screen body. iOS chrome (nav bar, tab bar) sits over
    /// this and inherits Liquid Glass blur from the system.
    func paperBackground() -> some View {
        modifier(PaperBackground())
    }
}

// MARK: - Brand mark (FuMark · anvil + ember)
//
// Smith's anvil silhouette inside a hand-drawn stamp circle, with an
// ember floating above. Drawn entirely in SwiftUI so it themes on
// the fly; no static asset.

struct FuMark: View {
    var size: CGFloat = 40
    var color: Color = SMColor.ink
    var ember: Color = SMColor.ember

    var body: some View {
        Canvas { ctx, dim in
            // Scale a 64x64 design space onto whatever frame we got.
            let s = min(dim.width, dim.height) / 64

            // hand-drawn stamp circle
            var circle = Path()
            circle.move(to: CGPoint(x: 32 * s, y: 4 * s))
            circle.addQuadCurve(to: CGPoint(x: 60 * s, y: 32 * s), control: CGPoint(x: 56 * s, y: 4 * s))
            circle.addQuadCurve(to: CGPoint(x: 32 * s, y: 60 * s), control: CGPoint(x: 60 * s, y: 60 * s))
            circle.addQuadCurve(to: CGPoint(x: 4  * s, y: 32 * s), control: CGPoint(x: 8  * s, y: 60 * s))
            circle.addQuadCurve(to: CGPoint(x: 32 * s, y: 4  * s), control: CGPoint(x: 4  * s, y: 4  * s))
            ctx.stroke(circle, with: .color(color), lineWidth: 1.2 * s)

            // anvil silhouette
            var anvil = Path()
            anvil.move(to: CGPoint(x: 16 * s, y: 38 * s))
            anvil.addLine(to: CGPoint(x: 20 * s, y: 34 * s))
            anvil.addLine(to: CGPoint(x: 42 * s, y: 34 * s))
            anvil.addLine(to: CGPoint(x: 46 * s, y: 38 * s))
            anvil.addLine(to: CGPoint(x: 43 * s, y: 41 * s))
            anvil.addLine(to: CGPoint(x: 37 * s, y: 41 * s))
            anvil.addLine(to: CGPoint(x: 37 * s, y: 45 * s))
            anvil.addLine(to: CGPoint(x: 41 * s, y: 47 * s))
            anvil.addLine(to: CGPoint(x: 41 * s, y: 49 * s))
            anvil.addLine(to: CGPoint(x: 21 * s, y: 49 * s))
            anvil.addLine(to: CGPoint(x: 21 * s, y: 47 * s))
            anvil.addLine(to: CGPoint(x: 25 * s, y: 45 * s))
            anvil.addLine(to: CGPoint(x: 25 * s, y: 41 * s))
            anvil.addLine(to: CGPoint(x: 19 * s, y: 41 * s))
            anvil.closeSubpath()
            ctx.stroke(anvil, with: .color(color), style: StrokeStyle(lineWidth: 1.3 * s, lineJoin: .round))

            // horn sketch
            var horn = Path()
            horn.move(to: CGPoint(x: 42 * s, y: 34 * s))
            horn.addQuadCurve(to: CGPoint(x: 53 * s, y: 28 * s), control: CGPoint(x: 50 * s, y: 32 * s))
            ctx.stroke(horn, with: .color(color), style: StrokeStyle(lineWidth: 1.3 * s, lineCap: .round))

            // ember above
            ctx.fill(Path(ellipseIn: CGRect(x: 28 * s, y: 16 * s, width: 8 * s, height: 8 * s)),
                     with: .color(ember.opacity(0.35)))
            ctx.fill(Path(ellipseIn: CGRect(x: 30 * s, y: 18 * s, width: 4 * s, height: 4 * s)),
                     with: .color(ember))

            // sparks
            for (start, end) in [
                (CGPoint(x: 32 * s, y: 14 * s), CGPoint(x: 31 * s, y: 11 * s)),
                (CGPoint(x: 32 * s, y: 14 * s), CGPoint(x: 33 * s, y: 11 * s)),
                (CGPoint(x: 28 * s, y: 17 * s), CGPoint(x: 25.5 * s, y: 16 * s)),
                (CGPoint(x: 36 * s, y: 17 * s), CGPoint(x: 38.5 * s, y: 16 * s)),
            ] {
                var spark = Path()
                spark.move(to: start)
                spark.addLine(to: end)
                ctx.stroke(spark, with: .color(ember), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Lowercase-italic wordmark with ember dot — `simmer·smith`.
struct FuWordmark: View {
    var size: CGFloat = 22
    var color: Color = SMColor.ink
    var ember: Color = SMColor.ember

    var body: some View {
        HStack(spacing: 0) {
            Text("simmer")
                .font(SMFont.serifDisplay(size))
                .foregroundStyle(color)
            Text("·")
                .font(SMFont.serifDisplay(size))
                .foregroundStyle(ember)
            Text("smith")
                .font(SMFont.serifDisplay(size))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Headers
//
// `FuNavBarSubtle` from the JSX mockup translated to an in-content
// hero header. The system NavigationStack toolbar stays on top of
// this — Liquid Glass + native back/toolbar items — and this header
// sits inside the scroll view as the visual anchor.

struct FuHero: View {
    var eyebrow: String
    var title: String
    var emberAccent: String? = nil   // single character pulled out in ember (e.g. "." after "Wednesday")
    var trailing: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(eyebrow.uppercased())
                    .font(SMFont.monoLabel(10))
                    .tracking(1.4)
                    .foregroundStyle(SMColor.inkSoft)
                Spacer()
                if let trailing { trailing }
            }
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(title)
                    .font(SMFont.serifDisplay(38))
                    .foregroundStyle(SMColor.ink)
                if let emberAccent {
                    Text(emberAccent)
                        .font(SMFont.serifDisplay(38))
                        .foregroundStyle(SMColor.ember)
                }
            }
            HandUnderline(color: SMColor.ember, width: 60)
                .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

// MARK: - Plate (riveted card)

struct FuPlate<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var glow: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let dark = scheme == .dark
        let plateGradient = LinearGradient(
            colors: dark
                ? [SMColor.plate, SMColor.paperAlt]
                : [Color(hex: 0x4A4A45), Color(hex: 0x2A2823)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return content()
            .padding(14)
            .background(plateGradient)
            .foregroundStyle(dark ? SMColor.ink : SMColor.paper)
            .overlay(
                Rectangle()
                    .stroke(dark ? SMColor.rule : Color(hex: 0x1B1916), lineWidth: 1)
            )
            .shadow(
                color: dark ? .black.opacity(0.5) : .black.opacity(0.18),
                radius: 8, x: 0, y: 4
            )
            .overlay(
                Rectangle()
                    .stroke(SMColor.ember.opacity(glow ? 0.8 : 0), lineWidth: glow ? 1.5 : 0)
            )
            .rivetCorners(
                color: dark ? Color(hex: 0x5A5046) : Color(hex: 0x888377),
                ember: SMColor.ember,
                glow: glow
            )
    }
}

// MARK: - Washi tape strip (used on index-card-style cards)

struct FuWashiTape: View {
    @Environment(\.colorScheme) private var scheme
    var color: Color = SMColor.risoYellow
    var width: CGFloat = 60
    var height: CGFloat = 18

    var body: some View {
        Rectangle()
            .fill(color.opacity(scheme == .dark ? 0.25 : 0.4))
            .frame(width: width, height: height)
            .overlay(
                Rectangle()
                    .stroke(SMColor.rule, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
            )
            .rotationEffect(.degrees(-3))
    }
}

// MARK: - Index card (paper note)
//
// The index-card pattern from `Fu1Week` — paperAlt fill, 0.5px rule
// border, slight rotation, optional washi-tape strip pinned on top.

struct FuIndexCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var rotation: Double = -0.5
    var washi: Color? = nil
    var rivets: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            content()
                .padding(16)
                .background(SMColor.paperAlt)
                .overlay(
                    Rectangle().stroke(SMColor.rule, lineWidth: 0.5)
                )
                .shadow(
                    color: scheme == .dark ? .clear : .black.opacity(0.06),
                    radius: 6, x: 0, y: 2
                )
                .modifier(WashiOverlayIfNeeded(washi: washi))
                .modifier(RivetsIfNeeded(rivets: rivets))
        }
        .rotationEffect(.degrees(rotation))
    }
}

private struct WashiOverlayIfNeeded: ViewModifier {
    var washi: Color?
    func body(content: Content) -> some View {
        if let washi {
            content.overlay(
                FuWashiTape(color: washi)
                    .offset(y: -10)
                    .padding(.leading, 30),
                alignment: .topLeading
            )
        } else {
            content
        }
    }
}

private struct RivetsIfNeeded: ViewModifier {
    var rivets: Bool
    func body(content: Content) -> some View {
        if rivets {
            content.rivetCorners()
        } else {
            content
        }
    }
}

// MARK: - Ember CTA
//
// The hand-drawn ember call-to-action used on "fire up →", "send →",
// "forge into library →". Caveat-typeset, slight rotation, ember
// background with glow on dark backgrounds.

struct FuEmberCTA: View {
    @Environment(\.colorScheme) private var scheme
    var label: String
    var rotation: Double = -0.6
    var size: CGFloat = 18

    var body: some View {
        Text(label)
            .font(SMFont.handwritten(size, bold: true))
            .foregroundStyle(Color(hex: 0x1A0E0A))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(SMColor.ember)
            .shadow(
                color: scheme == .dark
                    ? SMColor.ember.opacity(0.7)
                    : SMColor.ember.opacity(0.25),
                radius: 12, x: 0, y: 0
            )
            .rotationEffect(.degrees(rotation))
    }
}

// MARK: - Inline ember pill (chip)

struct FuOutlinedPill: View {
    var label: String
    var color: Color = SMColor.ember
    var filled: Bool = false
    var rotation: Double = 0

    var body: some View {
        Text(label.lowercased())
            .font(SMFont.handwritten(14))
            .foregroundStyle(filled ? SMColor.paper : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(filled ? color : .clear)
            .overlay(
                Capsule().stroke(color, lineWidth: 1.2)
            )
            .clipShape(Capsule())
            .rotationEffect(.degrees(rotation))
    }
}

// MARK: - Eyebrow labels (mono uppercase)

struct FuEyebrow: View {
    var text: String
    var color: Color = SMColor.inkSoft
    var ember: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(SMFont.monoLabel(10))
            .tracking(1.4)
            .foregroundStyle(ember ? SMColor.ember : color)
    }
}

// MARK: - Mono recipe number badge

struct FuRecipeNumber: View {
    var index: Int

    var body: some View {
        Text("№\(String(format: "%03d", index))")
            .font(SMFont.monoLabel(8))
            .foregroundStyle(SMColor.paper)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.55))
    }
}
