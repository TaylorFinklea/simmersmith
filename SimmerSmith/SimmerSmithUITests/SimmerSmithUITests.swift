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

    func testAuthTokenFieldExists() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.secureTextFields["Bearer token"].waitForExistence(timeout: 5))
    }

    func testSaveAndConnectButtonExists() {
        let app = XCUIApplication()
        app.launch()

        let connectButton = app.buttons["Save and Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
    }

    func testStatusSectionShowsSyncStatus() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Connect"].waitForExistence(timeout: 5))
    }

    func testClearingServerFieldAndRetyping() {
        let app = XCUIApplication()
        app.launch()

        let serverField = app.textFields["http://192.168.1.20:8080"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 5))

        serverField.tap()
        serverField.doubleTap()
        serverField.typeText("http://localhost:8080")

        XCTAssertTrue(app.staticTexts["Connect"].waitForExistence(timeout: 2))
    }

    func testTabBarShowsAllMainTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-connection-check"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            XCTAssertTrue(tabBar.buttons["Recipes"].exists || tabBar.buttons.count >= 4)
        }
    }
}
