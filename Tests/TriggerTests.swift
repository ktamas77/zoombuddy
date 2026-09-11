import XCTest
@testable import ZoomBuddy

final class TriggerTests: XCTestCase {
    func testMentions() {
        XCTAssertTrue(Trigger.mentions("Alex, Alexander", in: "So Alexander, what do you think?"))
        XCTAssertTrue(Trigger.mentions("Alex", in: "ALEX?"))
        XCTAssertFalse(Trigger.mentions("Tom", in: "tomorrow we ship"))
        XCTAssertFalse(Trigger.mentions("", in: "anything"))
        XCTAssertFalse(Trigger.mentions("Alex", in: "nobody here"))
    }
}
