import SwiftUI

struct BrandToolbarBadge: View {
    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}
