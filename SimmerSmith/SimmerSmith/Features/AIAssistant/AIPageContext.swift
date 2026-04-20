import Foundation

/// Describes whatever the user is currently looking at. The assistant
/// coordinator carries one of these and ships it to the backend with every
/// message so the AI has immediate context into the current screen.
struct AIPageContext: Codable, Equatable, Hashable, Sendable {
    var pageType: String
    var pageLabel: String
    var weekId: String?
    var weekStart: String?
    var weekStatus: String?
    var focusDate: String?
    var focusDayName: String?
    var recipeId: String?
    var recipeName: String?
    var groceryItemCount: Int?
    var briefSummary: String

    init(
        pageType: String,
        pageLabel: String = "",
        weekId: String? = nil,
        weekStart: String? = nil,
        weekStatus: String? = nil,
        focusDate: String? = nil,
        focusDayName: String? = nil,
        recipeId: String? = nil,
        recipeName: String? = nil,
        groceryItemCount: Int? = nil,
        briefSummary: String = ""
    ) {
        self.pageType = pageType
        self.pageLabel = pageLabel
        self.weekId = weekId
        self.weekStart = weekStart
        self.weekStatus = weekStatus
        self.focusDate = focusDate
        self.focusDayName = focusDayName
        self.recipeId = recipeId
        self.recipeName = recipeName
        self.groceryItemCount = groceryItemCount
        self.briefSummary = briefSummary
    }
}
