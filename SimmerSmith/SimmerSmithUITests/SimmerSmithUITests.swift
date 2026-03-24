import XCTest

final class SimmerSmithUITests: XCTestCase {
    func testLaunchShowsConnectionForm() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["http://192.168.1.20:8080"].exists)
    }

    func testTypingServerAddressDoesNotLeaveConnectionScreen() {
        let app = XCUIApplication()
        app.launch()

        let serverField = app.textFields["http://192.168.1.20:8080"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 5))

        serverField.tap()
        serverField.typeText("h")

        XCTAssertTrue(app.staticTexts["Connect"].waitForExistence(timeout: 2))
        XCTAssertTrue(serverField.exists)
    }
}
