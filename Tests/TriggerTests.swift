import XCTest
@testable import ZoomBuddy

final class TriggerTests: XCTestCase {
    func testMentions() {
        XCTAssertTrue(Trigger.mentions("Tamas, Thomas", in: "So Thomas, what do you think?"))
        XCTAssertTrue(Trigger.mentions("Tamas", in: "TAMAS?"))
        XCTAssertFalse(Trigger.mentions("Tom", in: "tomorrow we ship"))
        XCTAssertFalse(Trigger.mentions("", in: "anything"))
        XCTAssertFalse(Trigger.mentions("Tamas", in: "nobody here"))
    }
}
