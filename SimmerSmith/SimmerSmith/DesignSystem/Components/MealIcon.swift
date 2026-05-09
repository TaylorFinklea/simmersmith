import SwiftUI
import SimmerSmithKit

/// Build 83 — hand-drawn meal icon library.
///
/// Replaces the SF Symbol path used by RecipeHeaderImage with a set of
/// brand-voice'd ink-stroke glyphs that read as "drawn into the smith's
/// notebook." Every icon is composed from SwiftUI Path primitives and
/// stroked in the foreground color; sizing is fully driven by the
/// container, so the same icon works at the 44pt list thumbnail and
/// the 200pt detail hero.
///
/// `auto` resolves to the best match from the recipe's mealType /
/// cuisine / name / tags via `MealIcon.autoDetect(for:)`. Per-recipe
/// overrides live in `RecipeIconOverrides.shared`.
public enum MealIcon: String, CaseIterable, Codable, Hashable, Sendable {
    case auto
    case forkKnife
    case pancakes
    case muffin
    case toast
    case bowl
    case pasta
    case pizza
    case sandwich
    case taco
    case burger
    case salad
    case soup
    case cake
    case cookie
    case coffee
    case egg
    case fish
    case meat
    case chicken
    case fruit
    case leaf
    case bread
    case popcorn
    case fries
    case sun
    case flame
    case carrot

    /// Short label shown beneath the icon in the picker.
    public var label: String {
        switch self {
        case .auto:      return "auto"
        case .forkKnife: return "meal"
        case .pancakes:  return "pancakes"
        case .muffin:    return "muffin"
        case .toast:     return "toast"
        case .bowl:      return "bowl"
        case .pasta:     return "pasta"
        case .pizza:     return "pizza"
        case .sandwich:  return "sandwich"
        case .taco:      return "taco"
        case .burger:    return "burger"
        case .salad:     return "salad"
        case .soup:      return "soup"
        case .cake:      return "cake"
        case .cookie:    return "cookie"
        case .coffee:    return "coffee"
        case .egg:       return "egg"
        case .fish:      return "fish"
        case .meat:      return "meat"
        case .chicken:   return "chicken"
        case .fruit:     return "fruit"
        case .leaf:      return "leaf"
        case .bread:     return "bread"
        case .popcorn:   return "popcorn"
        case .fries:     return "fries"
        case .sun:       return "sun"
        case .flame:     return "spicy"
        case .carrot:    return "veg"
        }
    }

    /// Used by the editor picker so the auto entry doesn't appear in
    /// the explicit-override grid (it's surfaced separately).
    public static var pickable: [MealIcon] {
        allCases.filter { $0 != .auto }
    }

    public static func autoDetect(for recipe: RecipeSummary) -> MealIcon {
        autoDetect(name: recipe.name, mealType: recipe.mealType, cuisine: recipe.cuisine, tags: recipe.tags)
    }

    public static func autoDetect(name rawName: String, mealType rawMeal: String, cuisine rawCuisine: String, tags rawTags: [String]) -> MealIcon {
        let name = rawName.lowercased()
        let mealType = rawMeal.lowercased()
        let cuisine = rawCuisine.lowercased()
        let tags = rawTags.map { $0.lowercased() }

        // Strong name keywords win over mealType — a "Banana Pancakes"
        // dinner should still get pancakes.
        if name.contains("pancake") || name.contains("waffle") || name.contains("crepe") {
            return .pancakes
        }
        if name.contains("muffin") || name.contains("cupcake") || name.contains("scone") {
            return .muffin
        }
        if name.contains("toast") || name.contains("french toast") {
            return .toast
        }
        if name.contains("pasta") || name.contains("noodle") || name.contains("spaghetti")
            || name.contains("lasagna") || name.contains("ramen") || name.contains("linguine")
            || name.contains("fettuccine") || name.contains("rigatoni") {
            return .pasta
        }
        if name.contains("pizza") || name.contains("calzone") || name.contains("flatbread") {
            return .pizza
        }
        if name.contains("sandwich") || name.contains("wrap") || name.contains("panini")
            || name.contains("grilled cheese") || name.contains("blt") {
            return .sandwich
        }
        if name.contains("taco") || name.contains("burrito") || name.contains("quesadilla")
            || name.contains("enchilada") || name.contains("fajita") {
            return .taco
        }
        if name.contains("burger") || name.contains("slider") || name.contains("cheeseburger") {
            return .burger
        }
        if name.contains("salad") || name.contains("slaw") {
            return .salad
        }
        if name.contains("soup") || name.contains("chili") || name.contains("stew")
            || name.contains("broth") || name.contains("chowder") || name.contains("bisque") {
            return .soup
        }
        if name.contains("cake") || name.contains("cheesecake") || name.contains("torte") {
            return .cake
        }
        if name.contains("cookie") || name.contains("brownie") || name.contains("biscotti") {
            return .cookie
        }
        if name.contains("coffee") || name.contains("latte") || name.contains("cappuccino")
            || name.contains("tea") {
            return .coffee
        }
        if name.contains("egg") || name.contains("omelet") || name.contains("frittata")
            || name.contains("quiche") || name.contains("scramble") {
            return .egg
        }
        if name.contains("fish") || name.contains("salmon") || name.contains("tuna")
            || name.contains("shrimp") || name.contains("seafood") || name.contains("cod")
            || name.contains("tilapia") || name.contains("halibut") {
            return .fish
        }
        if name.contains("steak") || name.contains("beef") || name.contains("brisket")
            || name.contains("ribs") || name.contains("pork") || name.contains("lamb") {
            return .meat
        }
        if name.contains("chicken") || name.contains("turkey") || name.contains("drumstick")
            || name.contains("wing") {
            return .chicken
        }
        if name.contains("apple") || name.contains("pear") || name.contains("smoothie")
            || name.contains("berry") || name.contains("fruit") {
            return .fruit
        }
        if name.contains("bread") || name.contains("loaf") || name.contains("focaccia")
            || name.contains("sourdough") {
            return .bread
        }
        if name.contains("popcorn") {
            return .popcorn
        }
        if name.contains("fries") || name.contains("chips") || name.contains("wedges") {
            return .fries
        }
        if name.contains("rice") || name.contains("oat") || name.contains("porridge")
            || name.contains("oatmeal") || name.contains("congee") || name.contains("grain") {
            return .bowl
        }

        // Fall back on mealType / tags / cuisine.
        if mealType == "dessert" { return .cake }
        if mealType == "breakfast" { return .sun }
        if mealType == "snack" { return .popcorn }
        if tags.contains("vegetarian") || tags.contains("vegan") { return .carrot }
        if cuisine.contains("mexican") || cuisine.contains("indian") || tags.contains("spicy") {
            return .flame
        }

        return .forkKnife
    }
}

// MARK: - Rendering

/// Stroked vector renderer for `MealIcon`. Container-driven sizing
/// (works at any frame), brand color defaults to white-on-gradient.
public struct MealIconView: View {
    let icon: MealIcon
    var color: Color = .white

    public init(icon: MealIcon, color: Color = .white) {
        self.icon = icon
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let stroke = max(1.4, geo.size.width * 0.07)
            ZStack {
                ForEach(Array(MealIconPaths.paths(for: icon, in: rect).enumerated()), id: \.offset) { _, layer in
                    if layer.fill {
                        layer.path.fill(color)
                    } else {
                        layer.path.stroke(
                            color,
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Path catalog

/// Each case returns a list of layered paths (fill or stroke) drawn
/// inside the supplied rect. Coordinates are computed from rect so
/// every icon scales linearly with the container.
private enum MealIconPaths {
    struct Layer { let path: Path; let fill: Bool }

    static func paths(for icon: MealIcon, in rect: CGRect) -> [Layer] {
        switch icon {
        case .auto, .forkKnife: return forkKnife(rect)
        case .pancakes:         return pancakes(rect)
        case .muffin:           return muffin(rect)
        case .toast:            return toast(rect)
        case .bowl:             return bowl(rect)
        case .pasta:            return pasta(rect)
        case .pizza:            return pizza(rect)
        case .sandwich:         return sandwich(rect)
        case .taco:             return taco(rect)
        case .burger:           return burger(rect)
        case .salad:            return salad(rect)
        case .soup:             return soup(rect)
        case .cake:             return cake(rect)
        case .cookie:           return cookie(rect)
        case .coffee:           return coffee(rect)
        case .egg:              return egg(rect)
        case .fish:             return fish(rect)
        case .meat:             return meat(rect)
        case .chicken:          return chicken(rect)
        case .fruit:            return fruit(rect)
        case .leaf:             return leaf(rect)
        case .bread:            return bread(rect)
        case .popcorn:          return popcorn(rect)
        case .fries:            return fries(rect)
        case .sun:              return sun(rect)
        case .flame:            return flame(rect)
        case .carrot:           return carrot(rect)
        }
    }

    // Convenience: convert (0...1, 0...1) coords into rect space.
    private static func pt(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }

    // MARK: pancakes — 3 stacked ovals + butter pat + drip
    static func pancakes(_ rect: CGRect) -> [Layer] {
        var stack = Path()
        let w = rect.width, h = rect.height
        // 3 ovals decreasing slightly upward
        for (i, dy) in [0.7, 0.55, 0.4].enumerated() {
            _ = i
            let oval = CGRect(
                x: rect.minX + w * 0.18,
                y: rect.minY + h * dy,
                width: w * 0.64,
                height: h * 0.14
            )
            stack.addEllipse(in: oval)
        }
        // Butter pat on top
        var butter = Path()
        butter.addRoundedRect(
            in: CGRect(
                x: rect.minX + w * 0.42,
                y: rect.minY + h * 0.31,
                width: w * 0.16,
                height: h * 0.08
            ),
            cornerSize: CGSize(width: w * 0.02, height: w * 0.02)
        )
        // Syrup drip down right side
        var drip = Path()
        drip.move(to: pt(rect, 0.74, 0.40))
        drip.addCurve(
            to: pt(rect, 0.78, 0.78),
            control1: pt(rect, 0.82, 0.55),
            control2: pt(rect, 0.70, 0.65)
        )
        return [
            Layer(path: stack, fill: false),
            Layer(path: butter, fill: false),
            Layer(path: drip, fill: false),
        ]
    }

    // MARK: muffin — dome top + fluted wrapper trapezoid
    static func muffin(_ rect: CGRect) -> [Layer] {
        let w = rect.width, h = rect.height
        var dome = Path()
        // Dome (rounded blob top)
        dome.move(to: pt(rect, 0.18, 0.5))
        dome.addCurve(
            to: pt(rect, 0.82, 0.5),
            control1: pt(rect, 0.22, 0.10),
            control2: pt(rect, 0.78, 0.10)
        )
        // Wrapper trapezoid
        var wrapper = Path()
        wrapper.move(to: pt(rect, 0.16, 0.5))
        wrapper.addLine(to: pt(rect, 0.84, 0.5))
        wrapper.addLine(to: pt(rect, 0.78, 0.85))
        wrapper.addLine(to: pt(rect, 0.22, 0.85))
        wrapper.closeSubpath()
        // Wrapper flutes — 3 verticals
        var flutes = Path()
        for x in [0.36, 0.5, 0.64] {
            flutes.move(to: pt(rect, x, 0.55))
            flutes.addLine(to: pt(rect, x - 0.02, 0.83))
        }
        // Two chocolate-chip dots on dome
        var chips = Path()
        chips.addEllipse(in: CGRect(
            x: rect.minX + w * 0.36, y: rect.minY + h * 0.25,
            width: w * 0.06, height: h * 0.06
        ))
        chips.addEllipse(in: CGRect(
            x: rect.minX + w * 0.56, y: rect.minY + h * 0.32,
            width: w * 0.06, height: h * 0.06
        ))
        return [
            Layer(path: dome, fill: false),
            Layer(path: wrapper, fill: false),
            Layer(path: flutes, fill: false),
            Layer(path: chips, fill: true),
        ]
    }

    // MARK: toast — slice with rounded top and crust line
    static func toast(_ rect: CGRect) -> [Layer] {
        let w = rect.width, h = rect.height
        var slice = Path()
        slice.move(to: pt(rect, 0.20, 0.85))
        slice.addLine(to: pt(rect, 0.20, 0.40))
        slice.addCurve(
            to: pt(rect, 0.80, 0.40),
            control1: pt(rect, 0.20, 0.10),
            control2: pt(rect, 0.80, 0.10)
        )
        slice.addLine(to: pt(rect, 0.80, 0.85))
        slice.closeSubpath()
        // Inner crust line
        var crust = Path()
        crust.move(to: pt(rect, 0.28, 0.78))
        crust.addLine(to: pt(rect, 0.28, 0.45))
        crust.addCurve(
            to: pt(rect, 0.72, 0.45),
            control1: pt(rect, 0.28, 0.22),
            control2: pt(rect, 0.72, 0.22)
        )
        crust.addLine(to: pt(rect, 0.72, 0.78))
        // Bite/butter spread — small ellipse middle
        var spread = Path()
        spread.addEllipse(in: CGRect(
            x: rect.minX + w * 0.40, y: rect.minY + h * 0.50,
            width: w * 0.20, height: h * 0.10
        ))
        return [
            Layer(path: slice, fill: false),
            Layer(path: crust, fill: false),
            Layer(path: spread, fill: false),
        ]
    }

    // MARK: bowl — oval rim + half-bowl + 3 steam wisps
    static func bowl(_ rect: CGRect) -> [Layer] {
        var bowl = Path()
        // Rim (top ellipse)
        bowl.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.14,
            y: rect.minY + rect.height * 0.45,
            width: rect.width * 0.72,
            height: rect.height * 0.16
        ))
        // Bowl base — half ellipse
        bowl.move(to: pt(rect, 0.14, 0.53))
        bowl.addCurve(
            to: pt(rect, 0.86, 0.53),
            control1: pt(rect, 0.18, 0.92),
            control2: pt(rect, 0.82, 0.92)
        )
        // Steam wisps
        var steam = Path()
        for x in [0.32, 0.50, 0.68] {
            steam.move(to: pt(rect, x, 0.36))
            steam.addCurve(
                to: pt(rect, x, 0.10),
                control1: pt(rect, x + 0.06, 0.28),
                control2: pt(rect, x - 0.06, 0.18)
            )
        }
        return [
            Layer(path: bowl, fill: false),
            Layer(path: steam, fill: false),
        ]
    }

    // MARK: pasta — bowl + swirl
    static func pasta(_ rect: CGRect) -> [Layer] {
        var bowlShape = Path()
        bowlShape.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.10,
            y: rect.minY + rect.height * 0.50,
            width: rect.width * 0.80,
            height: rect.height * 0.18
        ))
        bowlShape.move(to: pt(rect, 0.10, 0.59))
        bowlShape.addCurve(
            to: pt(rect, 0.90, 0.59),
            control1: pt(rect, 0.14, 0.95),
            control2: pt(rect, 0.86, 0.95)
        )
        // Swirl noodles — 3 concentric spirals above the bowl rim
        var noodles = Path()
        for r in [0.22, 0.16, 0.10] {
            let center = pt(rect, 0.50, 0.42)
            let radius = rect.width * r
            noodles.addEllipse(in: CGRect(
                x: center.x - radius, y: center.y - radius * 0.55,
                width: radius * 2, height: radius * 1.1
            ))
        }
        return [
            Layer(path: bowlShape, fill: false),
            Layer(path: noodles, fill: false),
        ]
    }

    // MARK: pizza — wedge slice + crust arc + pepperoni dots
    static func pizza(_ rect: CGRect) -> [Layer] {
        var wedge = Path()
        wedge.move(to: pt(rect, 0.50, 0.18))
        wedge.addLine(to: pt(rect, 0.18, 0.78))
        wedge.addLine(to: pt(rect, 0.82, 0.78))
        wedge.closeSubpath()
        // Crust line near base
        var crust = Path()
        crust.move(to: pt(rect, 0.18, 0.78))
        crust.addQuadCurve(
            to: pt(rect, 0.82, 0.78),
            control: pt(rect, 0.50, 0.92)
        )
        // Pepperoni dots
        var dots = Path()
        for (cx, cy, r) in [(0.42, 0.50, 0.05), (0.58, 0.60, 0.05), (0.50, 0.38, 0.04)] {
            dots.addEllipse(in: CGRect(
                x: rect.minX + rect.width * (cx - r),
                y: rect.minY + rect.height * (cy - r),
                width: rect.width * 2 * r,
                height: rect.height * 2 * r
            ))
        }
        return [
            Layer(path: wedge, fill: false),
            Layer(path: crust, fill: false),
            Layer(path: dots, fill: true),
        ]
    }

    // MARK: sandwich — triangle stack with horizontal layers
    static func sandwich(_ rect: CGRect) -> [Layer] {
        var triangle = Path()
        triangle.move(to: pt(rect, 0.18, 0.78))
        triangle.addLine(to: pt(rect, 0.50, 0.20))
        triangle.addLine(to: pt(rect, 0.82, 0.78))
        triangle.closeSubpath()
        // Two horizontal layer lines
        var layers = Path()
        layers.move(to: pt(rect, 0.30, 0.55))
        layers.addLine(to: pt(rect, 0.70, 0.55))
        layers.move(to: pt(rect, 0.24, 0.66))
        layers.addLine(to: pt(rect, 0.76, 0.66))
        return [
            Layer(path: triangle, fill: false),
            Layer(path: layers, fill: false),
        ]
    }

    // MARK: taco — half-circle shell + zigzag fill
    static func taco(_ rect: CGRect) -> [Layer] {
        var shell = Path()
        shell.move(to: pt(rect, 0.10, 0.50))
        shell.addCurve(
            to: pt(rect, 0.90, 0.50),
            control1: pt(rect, 0.20, 0.95),
            control2: pt(rect, 0.80, 0.95)
        )
        shell.addLine(to: pt(rect, 0.10, 0.50))
        // Zigzag lettuce poking out top
        var lettuce = Path()
        lettuce.move(to: pt(rect, 0.18, 0.50))
        for i in 1...10 {
            let x = 0.18 + Double(i) * 0.064
            let y = i % 2 == 0 ? 0.50 : 0.36
            lettuce.addLine(to: pt(rect, x, y))
        }
        return [
            Layer(path: shell, fill: false),
            Layer(path: lettuce, fill: false),
        ]
    }

    // MARK: burger — top bun curve, patty rect, bottom bun
    static func burger(_ rect: CGRect) -> [Layer] {
        var bun = Path()
        bun.move(to: pt(rect, 0.16, 0.40))
        bun.addCurve(
            to: pt(rect, 0.84, 0.40),
            control1: pt(rect, 0.20, 0.10),
            control2: pt(rect, 0.80, 0.10)
        )
        bun.addLine(to: pt(rect, 0.16, 0.40))
        // Lettuce wavy line
        var lettuce = Path()
        lettuce.move(to: pt(rect, 0.16, 0.50))
        lettuce.addCurve(
            to: pt(rect, 0.84, 0.50),
            control1: pt(rect, 0.36, 0.42),
            control2: pt(rect, 0.64, 0.58)
        )
        // Patty rectangle
        var patty = Path()
        patty.addRoundedRect(
            in: CGRect(
                x: rect.minX + rect.width * 0.16,
                y: rect.minY + rect.height * 0.55,
                width: rect.width * 0.68,
                height: rect.height * 0.14
            ),
            cornerSize: CGSize(width: rect.width * 0.04, height: rect.width * 0.04)
        )
        // Bottom bun
        var bottom = Path()
        bottom.move(to: pt(rect, 0.16, 0.74))
        bottom.addLine(to: pt(rect, 0.84, 0.74))
        bottom.addCurve(
            to: pt(rect, 0.16, 0.74),
            control1: pt(rect, 0.78, 0.92),
            control2: pt(rect, 0.22, 0.92)
        )
        // Sesame seeds on top bun
        var seeds = Path()
        for (cx, cy) in [(0.36, 0.26), (0.50, 0.20), (0.64, 0.26)] {
            seeds.addEllipse(in: CGRect(
                x: rect.minX + rect.width * cx - 1.5,
                y: rect.minY + rect.height * cy - 1,
                width: 3, height: 2
            ))
        }
        return [
            Layer(path: bun, fill: false),
            Layer(path: lettuce, fill: false),
            Layer(path: patty, fill: false),
            Layer(path: bottom, fill: false),
            Layer(path: seeds, fill: true),
        ]
    }

    // MARK: salad — bowl + leaf shapes poking out
    static func salad(_ rect: CGRect) -> [Layer] {
        var bowl = Path()
        bowl.move(to: pt(rect, 0.14, 0.55))
        bowl.addLine(to: pt(rect, 0.86, 0.55))
        bowl.addCurve(
            to: pt(rect, 0.14, 0.55),
            control1: pt(rect, 0.82, 0.92),
            control2: pt(rect, 0.18, 0.92)
        )
        // Leaves poking up out of bowl
        var leaves = Path()
        for (x, top) in [(0.30, 0.20), (0.45, 0.10), (0.60, 0.18), (0.75, 0.30)] {
            leaves.move(to: pt(rect, x, 0.55))
            leaves.addCurve(
                to: pt(rect, x + 0.05, 0.55),
                control1: pt(rect, x - 0.06, top),
                control2: pt(rect, x + 0.10, top + 0.02)
            )
        }
        // Cherry tomato dot
        var tomato = Path()
        tomato.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.42,
            y: rect.minY + rect.height * 0.42,
            width: rect.width * 0.10,
            height: rect.height * 0.10
        ))
        return [
            Layer(path: bowl, fill: false),
            Layer(path: leaves, fill: false),
            Layer(path: tomato, fill: true),
        ]
    }

    // MARK: soup — bowl + steam + spoon handle
    static func soup(_ rect: CGRect) -> [Layer] {
        var bowl = Path()
        bowl.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.14,
            y: rect.minY + rect.height * 0.52,
            width: rect.width * 0.72,
            height: rect.height * 0.14
        ))
        bowl.move(to: pt(rect, 0.14, 0.59))
        bowl.addCurve(
            to: pt(rect, 0.86, 0.59),
            control1: pt(rect, 0.18, 0.94),
            control2: pt(rect, 0.82, 0.94)
        )
        // Steam wisps
        var steam = Path()
        for x in [0.36, 0.54] {
            steam.move(to: pt(rect, x, 0.46))
            steam.addCurve(
                to: pt(rect, x, 0.18),
                control1: pt(rect, x + 0.07, 0.36),
                control2: pt(rect, x - 0.07, 0.28)
            )
        }
        // Spoon handle in bowl
        var spoon = Path()
        spoon.move(to: pt(rect, 0.66, 0.46))
        spoon.addLine(to: pt(rect, 0.78, 0.30))
        spoon.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.74,
            y: rect.minY + rect.height * 0.55,
            width: rect.width * 0.10,
            height: rect.height * 0.06
        ))
        return [
            Layer(path: bowl, fill: false),
            Layer(path: steam, fill: false),
            Layer(path: spoon, fill: false),
        ]
    }

    // MARK: cake — 2-tier layered + candle
    static func cake(_ rect: CGRect) -> [Layer] {
        var bottom = Path()
        bottom.addRoundedRect(
            in: CGRect(
                x: rect.minX + rect.width * 0.16,
                y: rect.minY + rect.height * 0.55,
                width: rect.width * 0.68,
                height: rect.height * 0.28
            ),
            cornerSize: CGSize(width: rect.width * 0.04, height: rect.width * 0.04)
        )
        var top = Path()
        top.addRoundedRect(
            in: CGRect(
                x: rect.minX + rect.width * 0.28,
                y: rect.minY + rect.height * 0.36,
                width: rect.width * 0.44,
                height: rect.height * 0.20
            ),
            cornerSize: CGSize(width: rect.width * 0.04, height: rect.width * 0.04)
        )
        // Frosting drip line on top tier
        var frosting = Path()
        frosting.move(to: pt(rect, 0.30, 0.46))
        for (x, dy) in [(0.40, 0.50), (0.50, 0.46), (0.60, 0.51), (0.70, 0.46)] {
            frosting.addLine(to: pt(rect, x, dy))
        }
        // Candle
        var candle = Path()
        candle.move(to: pt(rect, 0.50, 0.36))
        candle.addLine(to: pt(rect, 0.50, 0.18))
        // Flame
        var flame = Path()
        flame.move(to: pt(rect, 0.50, 0.18))
        flame.addCurve(
            to: pt(rect, 0.50, 0.06),
            control1: pt(rect, 0.56, 0.14),
            control2: pt(rect, 0.46, 0.10)
        )
        return [
            Layer(path: bottom, fill: false),
            Layer(path: top, fill: false),
            Layer(path: frosting, fill: false),
            Layer(path: candle, fill: false),
            Layer(path: flame, fill: false),
        ]
    }

    // MARK: cookie — circle + 4 chip dots
    static func cookie(_ rect: CGRect) -> [Layer] {
        var disk = Path()
        disk.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.16,
            y: rect.minY + rect.height * 0.16,
            width: rect.width * 0.68,
            height: rect.height * 0.68
        ))
        var chips = Path()
        for (cx, cy) in [(0.35, 0.40), (0.60, 0.35), (0.45, 0.62), (0.65, 0.62)] {
            chips.addEllipse(in: CGRect(
                x: rect.minX + rect.width * (cx - 0.04),
                y: rect.minY + rect.height * (cy - 0.04),
                width: rect.width * 0.08,
                height: rect.height * 0.08
            ))
        }
        return [
            Layer(path: disk, fill: false),
            Layer(path: chips, fill: true),
        ]
    }

    // MARK: coffee — mug + handle arc + steam
    static func coffee(_ rect: CGRect) -> [Layer] {
        var mug = Path()
        mug.addRoundedRect(
            in: CGRect(
                x: rect.minX + rect.width * 0.22,
                y: rect.minY + rect.height * 0.40,
                width: rect.width * 0.42,
                height: rect.height * 0.42
            ),
            cornerSize: CGSize(width: rect.width * 0.04, height: rect.width * 0.04)
        )
        // Handle arc
        var handle = Path()
        handle.move(to: pt(rect, 0.64, 0.50))
        handle.addCurve(
            to: pt(rect, 0.64, 0.74),
            control1: pt(rect, 0.84, 0.52),
            control2: pt(rect, 0.84, 0.72)
        )
        // Steam
        var steam = Path()
        for x in [0.36, 0.50] {
            steam.move(to: pt(rect, x, 0.34))
            steam.addCurve(
                to: pt(rect, x, 0.10),
                control1: pt(rect, x + 0.06, 0.26),
                control2: pt(rect, x - 0.06, 0.18)
            )
        }
        return [
            Layer(path: mug, fill: false),
            Layer(path: handle, fill: false),
            Layer(path: steam, fill: false),
        ]
    }

    // MARK: egg — sunny-side oval + filled yolk dot
    static func egg(_ rect: CGRect) -> [Layer] {
        var white = Path()
        // Slightly irregular ellipse
        white.move(to: pt(rect, 0.18, 0.55))
        white.addCurve(
            to: pt(rect, 0.86, 0.50),
            control1: pt(rect, 0.10, 0.20),
            control2: pt(rect, 0.70, 0.18)
        )
        white.addCurve(
            to: pt(rect, 0.18, 0.55),
            control1: pt(rect, 0.94, 0.78),
            control2: pt(rect, 0.40, 0.92)
        )
        var yolk = Path()
        yolk.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.40,
            y: rect.minY + rect.height * 0.40,
            width: rect.width * 0.22,
            height: rect.height * 0.22
        ))
        return [
            Layer(path: white, fill: false),
            Layer(path: yolk, fill: true),
        ]
    }

    // MARK: fish — body oval + tail triangle + dot eye + fin
    static func fish(_ rect: CGRect) -> [Layer] {
        var body = Path()
        body.move(to: pt(rect, 0.22, 0.50))
        body.addCurve(
            to: pt(rect, 0.70, 0.50),
            control1: pt(rect, 0.30, 0.22),
            control2: pt(rect, 0.62, 0.22)
        )
        body.addCurve(
            to: pt(rect, 0.22, 0.50),
            control1: pt(rect, 0.62, 0.78),
            control2: pt(rect, 0.30, 0.78)
        )
        // Tail
        var tail = Path()
        tail.move(to: pt(rect, 0.70, 0.50))
        tail.addLine(to: pt(rect, 0.92, 0.32))
        tail.addLine(to: pt(rect, 0.92, 0.68))
        tail.closeSubpath()
        // Eye dot
        var eye = Path()
        eye.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.30,
            y: rect.minY + rect.height * 0.42,
            width: rect.width * 0.06,
            height: rect.height * 0.06
        ))
        // Fin
        var fin = Path()
        fin.move(to: pt(rect, 0.42, 0.40))
        fin.addLine(to: pt(rect, 0.55, 0.30))
        fin.addLine(to: pt(rect, 0.58, 0.42))
        return [
            Layer(path: body, fill: false),
            Layer(path: tail, fill: false),
            Layer(path: eye, fill: true),
            Layer(path: fin, fill: false),
        ]
    }

    // MARK: meat — irregular steak blob + bone notch
    static func meat(_ rect: CGRect) -> [Layer] {
        var blob = Path()
        blob.move(to: pt(rect, 0.22, 0.42))
        blob.addCurve(
            to: pt(rect, 0.78, 0.36),
            control1: pt(rect, 0.32, 0.18),
            control2: pt(rect, 0.62, 0.20)
        )
        blob.addCurve(
            to: pt(rect, 0.84, 0.66),
            control1: pt(rect, 0.92, 0.46),
            control2: pt(rect, 0.94, 0.56)
        )
        blob.addCurve(
            to: pt(rect, 0.30, 0.78),
            control1: pt(rect, 0.74, 0.86),
            control2: pt(rect, 0.46, 0.92)
        )
        blob.addCurve(
            to: pt(rect, 0.22, 0.42),
            control1: pt(rect, 0.14, 0.66),
            control2: pt(rect, 0.10, 0.54)
        )
        // Marbling stripe
        var marble = Path()
        marble.move(to: pt(rect, 0.34, 0.56))
        marble.addCurve(
            to: pt(rect, 0.70, 0.52),
            control1: pt(rect, 0.46, 0.48),
            control2: pt(rect, 0.58, 0.60)
        )
        return [
            Layer(path: blob, fill: false),
            Layer(path: marble, fill: false),
        ]
    }

    // MARK: chicken — drumstick: round meat + narrow handle + bone
    static func chicken(_ rect: CGRect) -> [Layer] {
        var drum = Path()
        // Round meaty top
        drum.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.20,
            y: rect.minY + rect.height * 0.16,
            width: rect.width * 0.50,
            height: rect.height * 0.50
        ))
        // Handle narrowing down
        var handle = Path()
        handle.move(to: pt(rect, 0.56, 0.58))
        handle.addLine(to: pt(rect, 0.84, 0.86))
        handle.move(to: pt(rect, 0.66, 0.50))
        handle.addLine(to: pt(rect, 0.92, 0.78))
        // Bone end (small circle at tip)
        var bone = Path()
        bone.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.78,
            y: rect.minY + rect.height * 0.74,
            width: rect.width * 0.16,
            height: rect.height * 0.16
        ))
        return [
            Layer(path: drum, fill: false),
            Layer(path: handle, fill: false),
            Layer(path: bone, fill: false),
        ]
    }

    // MARK: fruit — apple circle + stem + leaf
    static func fruit(_ rect: CGRect) -> [Layer] {
        var apple = Path()
        // Apple has a notch on top
        apple.move(to: pt(rect, 0.50, 0.30))
        apple.addCurve(
            to: pt(rect, 0.18, 0.55),
            control1: pt(rect, 0.32, 0.30),
            control2: pt(rect, 0.18, 0.40)
        )
        apple.addCurve(
            to: pt(rect, 0.50, 0.92),
            control1: pt(rect, 0.18, 0.78),
            control2: pt(rect, 0.30, 0.92)
        )
        apple.addCurve(
            to: pt(rect, 0.82, 0.55),
            control1: pt(rect, 0.70, 0.92),
            control2: pt(rect, 0.82, 0.78)
        )
        apple.addCurve(
            to: pt(rect, 0.50, 0.30),
            control1: pt(rect, 0.82, 0.40),
            control2: pt(rect, 0.68, 0.30)
        )
        // Stem
        var stem = Path()
        stem.move(to: pt(rect, 0.50, 0.30))
        stem.addLine(to: pt(rect, 0.50, 0.16))
        // Leaf
        var leaf = Path()
        leaf.move(to: pt(rect, 0.50, 0.20))
        leaf.addCurve(
            to: pt(rect, 0.72, 0.16),
            control1: pt(rect, 0.60, 0.10),
            control2: pt(rect, 0.70, 0.10)
        )
        leaf.addCurve(
            to: pt(rect, 0.50, 0.20),
            control1: pt(rect, 0.72, 0.22),
            control2: pt(rect, 0.62, 0.22)
        )
        return [
            Layer(path: apple, fill: false),
            Layer(path: stem, fill: false),
            Layer(path: leaf, fill: false),
        ]
    }

    // MARK: leaf — pointed teardrop with center vein
    static func leaf(_ rect: CGRect) -> [Layer] {
        var leaf = Path()
        leaf.move(to: pt(rect, 0.20, 0.80))
        leaf.addCurve(
            to: pt(rect, 0.80, 0.20),
            control1: pt(rect, 0.20, 0.40),
            control2: pt(rect, 0.50, 0.20)
        )
        leaf.addCurve(
            to: pt(rect, 0.20, 0.80),
            control1: pt(rect, 0.50, 0.50),
            control2: pt(rect, 0.30, 0.70)
        )
        // Vein
        var vein = Path()
        vein.move(to: pt(rect, 0.24, 0.76))
        vein.addLine(to: pt(rect, 0.76, 0.24))
        return [
            Layer(path: leaf, fill: false),
            Layer(path: vein, fill: false),
        ]
    }

    // MARK: bread — loaf with diagonal scoring
    static func bread(_ rect: CGRect) -> [Layer] {
        var loaf = Path()
        loaf.move(to: pt(rect, 0.16, 0.66))
        loaf.addCurve(
            to: pt(rect, 0.84, 0.66),
            control1: pt(rect, 0.18, 0.30),
            control2: pt(rect, 0.82, 0.30)
        )
        loaf.addLine(to: pt(rect, 0.84, 0.78))
        loaf.addCurve(
            to: pt(rect, 0.16, 0.78),
            control1: pt(rect, 0.78, 0.84),
            control2: pt(rect, 0.22, 0.84)
        )
        loaf.closeSubpath()
        // Scoring diagonals
        var scoring = Path()
        for x in [0.34, 0.50, 0.66] {
            scoring.move(to: pt(rect, x - 0.06, 0.45))
            scoring.addLine(to: pt(rect, x + 0.06, 0.55))
        }
        return [
            Layer(path: loaf, fill: false),
            Layer(path: scoring, fill: false),
        ]
    }

    // MARK: popcorn — cluster of bumps over striped tub
    static func popcorn(_ rect: CGRect) -> [Layer] {
        var tub = Path()
        // Tub: trapezoid
        tub.move(to: pt(rect, 0.22, 0.55))
        tub.addLine(to: pt(rect, 0.78, 0.55))
        tub.addLine(to: pt(rect, 0.72, 0.88))
        tub.addLine(to: pt(rect, 0.28, 0.88))
        tub.closeSubpath()
        // Stripes
        var stripes = Path()
        stripes.move(to: pt(rect, 0.36, 0.58))
        stripes.addLine(to: pt(rect, 0.34, 0.86))
        stripes.move(to: pt(rect, 0.64, 0.58))
        stripes.addLine(to: pt(rect, 0.66, 0.86))
        // Popcorn bumps
        var pops = Path()
        for (cx, cy, r) in [
            (0.30, 0.36, 0.10),
            (0.50, 0.26, 0.12),
            (0.70, 0.36, 0.10),
            (0.42, 0.46, 0.08),
            (0.60, 0.46, 0.08),
        ] {
            pops.addEllipse(in: CGRect(
                x: rect.minX + rect.width * (cx - r),
                y: rect.minY + rect.height * (cy - r),
                width: rect.width * 2 * r,
                height: rect.height * 2 * r
            ))
        }
        return [
            Layer(path: tub, fill: false),
            Layer(path: stripes, fill: false),
            Layer(path: pops, fill: false),
        ]
    }

    // MARK: fries — container + 5 sticks
    static func fries(_ rect: CGRect) -> [Layer] {
        var container = Path()
        container.move(to: pt(rect, 0.22, 0.50))
        container.addLine(to: pt(rect, 0.78, 0.50))
        container.addLine(to: pt(rect, 0.72, 0.88))
        container.addLine(to: pt(rect, 0.28, 0.88))
        container.closeSubpath()
        // Sticks rising
        var sticks = Path()
        for (x, top) in [(0.32, 0.16), (0.42, 0.10), (0.50, 0.20), (0.58, 0.10), (0.68, 0.18)] {
            sticks.move(to: pt(rect, x, 0.50))
            sticks.addLine(to: pt(rect, x, top))
        }
        return [
            Layer(path: container, fill: false),
            Layer(path: sticks, fill: false),
        ]
    }

    // MARK: sun — circle + 8 rays
    static func sun(_ rect: CGRect) -> [Layer] {
        var disk = Path()
        disk.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.32,
            y: rect.minY + rect.height * 0.32,
            width: rect.width * 0.36,
            height: rect.height * 0.36
        ))
        var rays = Path()
        let cx = 0.50, cy = 0.50
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4
            let inner = (cos(angle) * 0.26, sin(angle) * 0.26)
            let outer = (cos(angle) * 0.42, sin(angle) * 0.42)
            rays.move(to: pt(rect, cx + inner.0, cy + inner.1))
            rays.addLine(to: pt(rect, cx + outer.0, cy + outer.1))
        }
        return [
            Layer(path: disk, fill: false),
            Layer(path: rays, fill: false),
        ]
    }

    // MARK: flame — teardrop flame
    static func flame(_ rect: CGRect) -> [Layer] {
        var flame = Path()
        flame.move(to: pt(rect, 0.50, 0.10))
        flame.addCurve(
            to: pt(rect, 0.74, 0.62),
            control1: pt(rect, 0.62, 0.32),
            control2: pt(rect, 0.78, 0.46)
        )
        flame.addCurve(
            to: pt(rect, 0.50, 0.90),
            control1: pt(rect, 0.74, 0.80),
            control2: pt(rect, 0.62, 0.90)
        )
        flame.addCurve(
            to: pt(rect, 0.26, 0.62),
            control1: pt(rect, 0.38, 0.90),
            control2: pt(rect, 0.26, 0.80)
        )
        flame.addCurve(
            to: pt(rect, 0.50, 0.10),
            control1: pt(rect, 0.22, 0.46),
            control2: pt(rect, 0.38, 0.32)
        )
        // Inner flicker
        var flicker = Path()
        flicker.move(to: pt(rect, 0.50, 0.40))
        flicker.addCurve(
            to: pt(rect, 0.62, 0.66),
            control1: pt(rect, 0.56, 0.50),
            control2: pt(rect, 0.62, 0.58)
        )
        flicker.addCurve(
            to: pt(rect, 0.50, 0.78),
            control1: pt(rect, 0.62, 0.74),
            control2: pt(rect, 0.56, 0.78)
        )
        flicker.addCurve(
            to: pt(rect, 0.38, 0.66),
            control1: pt(rect, 0.44, 0.78),
            control2: pt(rect, 0.38, 0.74)
        )
        flicker.addCurve(
            to: pt(rect, 0.50, 0.40),
            control1: pt(rect, 0.38, 0.58),
            control2: pt(rect, 0.44, 0.50)
        )
        return [
            Layer(path: flame, fill: false),
            Layer(path: flicker, fill: false),
        ]
    }

    // MARK: carrot — triangular root + 3 frond fronds
    static func carrot(_ rect: CGRect) -> [Layer] {
        var root = Path()
        root.move(to: pt(rect, 0.30, 0.40))
        root.addLine(to: pt(rect, 0.70, 0.40))
        root.addLine(to: pt(rect, 0.50, 0.92))
        root.closeSubpath()
        // Ridge lines
        var ridges = Path()
        ridges.move(to: pt(rect, 0.40, 0.50))
        ridges.addLine(to: pt(rect, 0.46, 0.52))
        ridges.move(to: pt(rect, 0.54, 0.62))
        ridges.addLine(to: pt(rect, 0.60, 0.64))
        // Fronds — 3 leaf tufts
        var fronds = Path()
        for (cx, top) in [(0.36, 0.12), (0.50, 0.06), (0.64, 0.12)] {
            fronds.move(to: pt(rect, cx, 0.40))
            fronds.addCurve(
                to: pt(rect, cx + 0.04, 0.40),
                control1: pt(rect, cx - 0.06, top),
                control2: pt(rect, cx + 0.10, top + 0.04)
            )
        }
        return [
            Layer(path: root, fill: false),
            Layer(path: ridges, fill: false),
            Layer(path: fronds, fill: false),
        ]
    }

    // MARK: forkKnife — generic crossed utensils
    static func forkKnife(_ rect: CGRect) -> [Layer] {
        var fork = Path()
        // Fork handle
        fork.move(to: pt(rect, 0.34, 0.30))
        fork.addLine(to: pt(rect, 0.34, 0.84))
        // Tines
        for x in [0.28, 0.34, 0.40] {
            fork.move(to: pt(rect, x, 0.16))
            fork.addLine(to: pt(rect, x, 0.36))
        }
        // Knife
        var knife = Path()
        knife.move(to: pt(rect, 0.66, 0.16))
        knife.addLine(to: pt(rect, 0.66, 0.84))
        knife.move(to: pt(rect, 0.66, 0.16))
        knife.addCurve(
            to: pt(rect, 0.66, 0.50),
            control1: pt(rect, 0.78, 0.22),
            control2: pt(rect, 0.78, 0.44)
        )
        return [
            Layer(path: fork, fill: false),
            Layer(path: knife, fill: false),
        ]
    }
}
