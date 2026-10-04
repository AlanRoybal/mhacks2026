import XCTest

/// Lets a script drive the app: write commands to $SHOTS_DIR/cmd, one per line, and wait for cmd to
/// disappear. Commands: `tap x y` (0-1 of the screen), `press x y seconds`, `type text`, `wait seconds`,
/// `swipe up|down`, `spring tap|press x y [seconds]` (system UI: lock screen, alerts), `allow` (accept a
/// system permission alert), `lock`, `home`, `open` (bring the app back), `quit`.
/// Screenshots are taken from the host with `simctl io screenshot`, since XCUITest's own view of the
/// screen goes stale after some navigations.
@MainActor
final class RemoteControl: XCTestCase {
    func testRemote() {
        executionTimeAllowance = 3600
        let env = ProcessInfo.processInfo.environment
        let dir = env["SHOTS_DIR"] ?? "/tmp/shots-bounty"
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedOnboarding", "YES",
            "-BountyDemoHandle", env["DEMO_HANDLE"] ?? "demo-poster",
            "-BountyDemoKey", env["DEMO_KEY"] ?? "",
        ]
        // No start screen: the normal launch, which also asks for notification permission.
        if let screen = env["START_SCREEN"], !screen.isEmpty { app.launchArguments += ["-BountyDebugScreen", screen] }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launch()
        let cmd = "\(dir)/cmd"
        let deadline = Date().addingTimeInterval(45 * 60)
        while Date() < deadline {
            guard let text = try? String(contentsOfFile: cmd, encoding: .utf8) else { usleep(200_000); continue }
            for line in text.split(separator: "\n").map(String.init) {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                switch parts.first {
                case "tap", "press":
                    let n = (parts.count > 1 ? parts[1] : "0.5 0.5").split(separator: " ").compactMap { Double($0) }
                    let point = app.coordinate(withNormalizedOffset: CGVector(dx: n[0], dy: n[1]))
                    if parts.first == "press" { point.press(forDuration: n.count > 2 ? n[2] : 1) } else { point.tap() }
                case "spring":
                    let words = (parts.count > 1 ? parts[1] : "").split(separator: " ").map(String.init)
                    let n = words.dropFirst().compactMap { Double($0) }
                    let point = springboard.coordinate(withNormalizedOffset: CGVector(dx: n[0], dy: n[1]))
                    if words.first == "press" { point.press(forDuration: n.count > 2 ? n[2] : 1) } else { point.tap() }
                case "springlabel":
                    // springlabel <seconds> <text>: long-press the first system UI element whose label contains text.
                    let words = (parts.count > 1 ? parts[1] : "").split(separator: " ", maxSplits: 1).map(String.init)
                    let element = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words.count > 1 ? words[1] : "")).firstMatch
                    if element.waitForExistence(timeout: 5) { element.press(forDuration: Double(words[0]) ?? 1.5) }
                case "allow":
                    let allow = springboard.alerts.buttons["Allow"]
                    if allow.waitForExistence(timeout: 5) { allow.tap() }
                case "lock":
                    XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
                case "home":
                    XCUIDevice.shared.press(.home)
                case "open":
                    app.activate()
                case "type":
                    app.typeText(parts.count > 1 ? parts[1] : "")
                case "wait":
                    usleep(UInt32((Double(parts.count > 1 ? parts[1] : "1") ?? 1) * 1_000_000))
                case "swipe":
                    if parts.last == "down" { app.swipeDown() } else { app.swipeUp() }
                case "quit":
                    try? FileManager.default.removeItem(atPath: cmd)
                    return
                default:
                    break
                }
                usleep(300_000)
            }
            try? FileManager.default.removeItem(atPath: cmd)
        }
    }
}
