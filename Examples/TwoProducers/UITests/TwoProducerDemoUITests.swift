import XCTest

final class TwoProducerDemoUITests: XCTestCase {
    @MainActor
    func testPairCallRevokeAndResetFlow() throws {
        let app = launchApp()
        defer { app.terminate() }

        let greeterPair = app.buttons["pair-greeter"]
        XCTAssertTrue(greeterPair.isEnabled)
        greeterPair.click()
        waitForLabel(app.staticTexts["status-greeter"], "Paired")

        replaceText(in: app.textFields["greeting-name"], with: "Ada")
        app.buttons["call-greeter"].click()
        waitForLabel(app.staticTexts["result-greeter"], "Hello, Ada!")

        let calculatorPair = app.buttons["pair-calculator"]
        XCTAssertTrue(calculatorPair.isEnabled)
        calculatorPair.click()
        waitForLabel(app.staticTexts["status-calculator"], "Paired")

        replaceText(in: app.textFields["calculator-left"], with: "19")
        replaceText(in: app.textFields["calculator-right"], with: "23")
        app.buttons["call-calculator"].click()
        waitForLabel(app.staticTexts["result-calculator"], "19 + 23 = 42")

        app.buttons["revoke-greeter"].click()
        waitForLabel(app.staticTexts["status-greeter"], "Revoked")
        waitForLabel(app.staticTexts["status-calculator"], "Paired")
        XCTAssertTrue(app.buttons["call-calculator"].isEnabled)

        app.buttons["reset-demo"].click()
        waitForLabel(app.staticTexts["status-greeter"], "Discovered")
        waitForLabel(app.staticTexts["status-calculator"], "Discovered")
        XCTAssertFalse(app.buttons["call-greeter"].isEnabled)
        XCTAssertFalse(app.buttons["call-calculator"].isEnabled)

        app.buttons["pair-greeter"].click()
        waitForLabel(app.staticTexts["status-greeter"], "Paired")
        replaceText(in: app.textFields["greeting-name"], with: "Grace")
        app.buttons["call-greeter"].click()
        waitForLabel(app.staticTexts["result-greeter"], "Hello, Grace!")
    }

    @MainActor
    func testInvalidCalculatorTextShowsSanitizedError() throws {
        let app = launchApp()
        defer { app.terminate() }

        app.buttons["pair-calculator"].click()
        waitForLabel(app.staticTexts["status-calculator"], "Paired")
        replaceText(in: app.textFields["calculator-left"], with: "not-a-number")
        app.buttons["call-calculator"].click()
        waitForLabel(app.staticTexts["error-message"], "Enter two valid signed integers.")
        XCTAssertFalse(displayedText(app.staticTexts["error-message"]).localizedCaseInsensitiveContains("credential"))
    }

    @MainActor
    func testClosingAndReopeningWindowRestartsVisibleLifecycle() throws {
        let app = launchApp()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        let closeButton = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.click()
        XCTAssertTrue(waitForNonexistence(app.staticTexts["demo-title"], timeout: 5))

        app.activate()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["demo-title"].waitForExistence(timeout: 10))
        waitForLabel(app.staticTexts["discovery-status"], "2 producers discovered")
        waitForLabel(app.staticTexts["status-greeter"], "Discovered")
        waitForLabel(app.staticTexts["status-calculator"], "Discovered")
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["demo-title"].waitForExistence(timeout: 10))
        waitForLabel(app.staticTexts["discovery-status"], "2 producers discovered")
        return app
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with value: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(value)
    }

    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        _ label: String,
        timeout: TimeInterval = 10
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        // SwiftUI Text currently appears as `value` in macOS XCUI snapshots,
        // while other controls expose their visible copy as `label`.
        let predicate = NSPredicate(format: "label == %@ OR value == %@", label, label)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    @MainActor
    private func displayedText(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    @MainActor
    private func waitForNonexistence(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
