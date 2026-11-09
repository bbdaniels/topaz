import XCTest

final class DictationLightTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func info(_ state: String, pid: String = "4242") -> [AnyHashable: Any] {
        ["state": state, "pid": pid]
    }

    func testListeningLightsAndStoppedPutsItOut() {
        var light = DictationLight(topazPid: 4242)
        XCTAssertFalse(light.isLit(at: t0))
        light.receive(info("listening"), at: t0)
        XCTAssertTrue(light.isLit(at: t0))
        light.receive(info("stopped"), at: t0 + 0.5)
        XCTAssertFalse(light.isLit(at: t0 + 0.5))
        XCTAssertNil(light.expires)
    }

    /// A lost "stopped" leaves the gem blue for at most `stale`.
    func testWithoutARefreshTheLightGoesOutByItself() {
        var light = DictationLight(topazPid: 4242)
        light.receive(info("listening"), at: t0)
        XCTAssertTrue(light.isLit(at: t0 + DictationLight.stale - 0.01))
        XCTAssertFalse(light.isLit(at: t0 + DictationLight.stale))
        XCTAssertEqual(light.expires, t0 + DictationLight.stale)
    }

    func testARefreshKeepsItLit() {
        var light = DictationLight(topazPid: 4242)
        light.receive(info("listening"), at: t0)
        light.receive(info("listening"), at: t0 + 2)
        XCTAssertTrue(light.isLit(at: t0 + 4))
        XCTAssertEqual(light.expires, t0 + 2 + DictationLight.stale)
    }

    /// Only the Topaz that launched this app counts.
    func testAnotherTopazIsIgnored() {
        var light = DictationLight(topazPid: 4242)
        light.receive(info("listening", pid: "999"), at: t0)
        XCTAssertFalse(light.isLit(at: t0))
        light.receive(info("listening"), at: t0)
        light.receive(info("stopped", pid: "999"), at: t0)
        XCTAssertTrue(light.isLit(at: t0), "another Topaz's stop put it out")
        light.receive(["state": "listening"], at: t0 + 1)
        XCTAssertEqual(light.lastListening, t0, "a notification without a pid counted")
    }

    func testWithoutTopazAnyPosterCounts() {
        var light = DictationLight(topazPid: nil)
        light.receive(["state": "listening"], at: t0)
        XCTAssertTrue(light.isLit(at: t0))
    }

    func testUnknownOrMissingStatesChangeNothing() {
        var light = DictationLight(topazPid: 4242)
        light.receive(info("listening"), at: t0)
        light.receive(info("paused"), at: t0 + 1)
        light.receive(nil, at: t0 + 1)
        light.receive(["pid": "4242"], at: t0 + 1)
        XCTAssertEqual(light.lastListening, t0)
    }
}
