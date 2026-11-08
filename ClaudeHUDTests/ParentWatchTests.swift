import XCTest

final class ParentWatchTests: XCTestCase {
    func testTheParentIsReadFromTopazPid() {
        XCTAssertEqual(ParentWatch.parentPid(["TOPAZ_PID": "4242"]), 4242)
        XCTAssertEqual(ParentWatch.parentPid(["TOPAZ_PID": " 4242 "]), 4242)
    }

    func testNoParentWithoutAUsablePid() {
        XCTAssertNil(ParentWatch.parentPid([:]))
        XCTAssertNil(ParentWatch.parentPid(["TOPAZ_PID": ""]))
        XCTAssertNil(ParentWatch.parentPid(["TOPAZ_PID": "topaz"]))
        XCTAssertNil(ParentWatch.parentPid(["TOPAZ_PID": "1"]))
        XCTAssertNil(ParentWatch.parentPid(["TOPAZ_PID": "-5"]))
    }

    /// A live process that is killed fires the watch once, and only then.
    func testTheWatchFiresWhenTheProcessExits() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        var count = 0
        let exited = expectation(description: "exit seen")
        let source = ParentWatch.watch(child.processIdentifier) {
            count += 1
            exited.fulfill()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(count, 0, "fired while the process was alive")
        child.terminate()
        wait(for: [exited], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(count, 1)
        _ = source
    }

    /// A parent that died before the watch was armed still ends ClaudeHUD.
    func testTheWatchFiresForAProcessAlreadyGone() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let exited = expectation(description: "exit seen")
        let source = ParentWatch.watch(child.processIdentifier) { exited.fulfill() }
        wait(for: [exited], timeout: 5)
        _ = source
    }
}
