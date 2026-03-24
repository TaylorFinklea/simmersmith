import Testing
import SimmerSmithKit

struct SimmerSmithTests {
    @Test
    func feedbackRequestDefaultsToIOSSource() {
        let request = FeedbackEntryRequest(targetType: "meal", targetName: "Pasta", sentiment: 1)
        #expect(request.source == "ios")
        #expect(request.active == true)
    }
}
