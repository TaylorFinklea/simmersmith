import SwiftUI

/// A minimal placeholder view for features not yet migrated to CloudKit.
/// Displays a centered icon, feature name, and "Coming to CloudKit soon" subtitle.
struct ComingSoonView: View {
    let feature: String

    var body: some View {
        VStack(spacing: SMSpacing.lg) {
            Image(systemName: "hourglass")
                .font(.system(size: 56))
                .foregroundStyle(SMColor.ember)
                .padding(.bottom, SMSpacing.sm)

            Text(feature)
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)

            Text("Coming to CloudKit soon")
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SMColor.paper)
        .paperBackground()
    }
}

#Preview {
    ComingSoonView(feature: "Grocery")
}
