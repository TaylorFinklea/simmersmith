import SwiftUI

/// 5th-tab root for the M22 grocery experience. A thin wrapper around
/// `GroceryView` that opts out of the modal "Done" button — the tab
/// bar handles navigation here.
struct GroceryTabView: View {
    var body: some View {
        GroceryView(dismissable: false)
    }
}
