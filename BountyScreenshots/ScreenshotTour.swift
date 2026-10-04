import XCTest

/// Drives the app in the Simulator to capture pitch screenshots against the dev backend. Not a regression
/// suite: run on demand with `xcodebuild test -scheme Bounty -only-testing:BountyScreenshots/ScreenshotTour`.
/// Env (via TEST_RUNNER_ prefix): DEMO_KEY (backend DEMO_LOGIN_KEY), SHOTS_DIR, DEMO_HANDLE.
@MainActor
final class ScreenshotTour: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var shotsDir: URL { URL(fileURLWithPath: env["SHOTS_DIR"] ?? "/tmp/shots-bounty") }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedOnboarding", "YES",
            "-BountyDemoHandle", env["DEMO_HANDLE"] ?? "demo-poster",
            "-BountyDemoKey", env["DEMO_KEY"] ?? "",
            "-BountyDebugScreen", screen,
        ]
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: shotsDir.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ element: XCUIElement, _ timeout: TimeInterval = 30) {
        if !element.waitForExistence(timeout: timeout) {
            snap("zz-debug-missing")
            XCTFail("Missing \(element)")
        }
    }

    /// Taps until `next` shows up (a tap during an entrance animation or a save can be dropped).
    private func tap(_ button: XCUIElement, until next: XCUIElement, attempts: Int = 3, timeout: TimeInterval = 20) {
        for _ in 0..<attempts {
            // PillButton's press style ignores XCUITest's instant tap on some screens; a short press lands.
            if button.exists, button.isHittable { button.press(forDuration: 0.15) }
            if next.waitForExistence(timeout: timeout) { return }
        }
        snap("zz-debug-stuck")
        XCTFail("\(next) never appeared")
    }

    /// Demo job → AI checklist → fund review, from a fresh Post form.
    private func draftDemoJob(_ app: XCUIApplication) {
        wait(app.buttons["Demo job"])
        app.buttons["Demo job"].tap()
        app.buttons["Draft the proof checklist"].tap()
        wait(app.staticTexts["What counts as done"], 60)
        // Let the drafted items and entrance animation settle.
        sleep(2)
    }

    func testCardCheckout() {
        let app = launch("post")
        draftDemoJob(app)
        snap("01-ai-checklist")

        tap(app.buttons["Looks right"], until: app.staticTexts["Fund your job"])
        sleep(1)
        snap("02-fund-review")

        let pay = app.buttons["Pay $16.50 & fund job"]
        tap(app.buttons["Pay $16.50"], until: pay)
        let card = app.textFields["Card number"]
        tap(pay, until: card, timeout: 30)
        sleep(1)
        snap("03-payment-sheet")

        card.tap()
        card.typeText("4242424242424242")
        app.textFields["MM / YY"].typeText("1234")
        app.textFields["CVC"].typeText("123")
        let zip = app.textFields["ZIP"]
        if zip.exists { zip.tap(); zip.typeText("48104") }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pay $16.50'")).firstMatch.tap()
        wait(app.buttons["Done"], 90)
        sleep(1)
        snap("03b-funded")
        app.buttons["Done"].tap()
    }

    func testUSDCCheckout() {
        let app = launch("post")
        draftDemoJob(app)
        tap(app.buttons["Looks right"], until: app.staticTexts["Fund your job"])
        app.buttons["USDC"].tap()
        sleep(1)
        snap("04a-fund-review-usdc")
        app.buttons["Pay 15 USDC"].tap()
        wait(app.navigationBars["Fund with USDC"], 30)
        sleep(1)
        snap("04-usdc-checkout")
    }
}

extension ScreenshotTour {
    func testDebugLooksRight() {
        let app = launch("post")
        draftDemoJob(app)
        print("REDO-AT \(Date())")
        app.buttons["Redo"].press(forDuration: 0.15)
        sleep(8)
        let button = app.buttons["Looks right"]
        print("LOOKS-RIGHT exists=\(button.exists) enabled=\(button.isEnabled) hittable=\(button.isHittable) frame=\(button.frame)")
        button.press(forDuration: 0.15)
        FileManager.default.createFile(atPath: "/tmp/shots-bounty/pressed", contents: nil)
        sleep(12)
        for i in 0..<6 { snap("zz-burst-\(i)"); usleep(400_000) }
        print("BUTTON-LABEL-AFTER \(app.buttons.matching(NSPredicate(format: "label IN {'Looks right', 'Saving…'}")).firstMatch.label)")
        sleep(3)
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        snap("zz-debug-after")
        print("FUND-VISIBLE \(app.staticTexts["Fund your job"].exists)")
        for text in app.staticTexts.allElementsBoundByIndex { print("TEXT: \(text.label)") }
        for b in app.buttons.allElementsBoundByIndex { print("BUTTON: \(b.label) enabled=\(b.isEnabled)") }
    }
}
