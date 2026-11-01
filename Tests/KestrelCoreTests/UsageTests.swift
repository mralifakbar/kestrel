import XCTest
@testable import KestrelCore

final class UsageTests: XCTestCase {
    func testPace() {
        // Half the window gone, 75% used: burning 1.5× faster than the window allows.
        let w = LimitWindow(label: "Week", used: 0.75, resetsAt: Date().addingTimeInterval(3.5 * 86400), windowSeconds: 7 * 86400)
        XCTAssertEqual(w.pace ?? 0, 1.5, accuracy: 0.01)
        XCTAssertTrue(w.paceText.contains("Ahead"))
        XCTAssertEqual(w.remaining, 0.25, accuracy: 0.0001)

        let calm = LimitWindow(label: "Session", used: 0.1, resetsAt: Date().addingTimeInterval(2.5 * 3600), windowSeconds: 5 * 3600)
        XCTAssertEqual(calm.paceText, "Under pace")

        let noReset = LimitWindow(label: "Extra", used: 0.2, resetsAt: nil, windowSeconds: nil)
        XCTAssertNil(noReset.pace)
    }

    func testJWTSubject() {
        // {"alg":"none"}.{"sub":"auth0|user_123"}.
        let jwt = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdXRoMHx1c2VyXzEyMyJ9."
        XCTAssertEqual(UsageLimits.jwtSubject(jwt), "auth0|user_123")
        XCTAssertNil(UsageLimits.jwtSubject("not-a-jwt"))
    }

    func testDates() {
        XCTAssertNotNil(UsageLimits.date("2026-11-01T10:00:00.123Z"))
        XCTAssertNotNil(UsageLimits.date("2026-11-01T10:00:00Z"))
        XCTAssertNil(UsageLimits.date("yesterday"))
    }
}
