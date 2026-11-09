import XCTest
import Carbon.HIToolbox

/// HotKeyCenter through Carbon itself: a hot key event made by hand and sent
/// to the application target reaches the action, as the window server's
/// would. A handler given the wrong user data, or left installed after its
/// center is gone, crashes or misfires here, the kind of launch crash
/// 3f6b602 fixed in Loupe.
final class HotKeyCenterTests: XCTestCase {
    private func press(_ id: UInt32, signature: OSType = HotKeyCenter.signature) -> OSStatus {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                                   EventAttributes(kEventAttributeNone), &event), noErr)
        guard let event else { return OSStatus(eventNotHandledErr) }
        defer { ReleaseEvent(event) }
        var hk = EventHotKeyID(signature: signature, id: id)
        XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         MemoryLayout<EventHotKeyID>.size, &hk), noErr)
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    func testAPressReachesItsAction() {
        let center = HotKeyCenter()
        XCTAssertEqual(center.installStatus, noErr)
        var fired: [String] = []
        let a = center.add { fired.append("a") }
        let b = center.add { fired.append("b") }
        XCTAssertEqual(press(b), noErr)
        XCTAssertEqual(press(a), noErr)
        XCTAssertEqual(fired, ["b", "a"])
    }

    func testOtherSignaturesAndUnknownIdsPassThrough() {
        let center = HotKeyCenter()
        var fired = 0
        let a = center.add { fired += 1 }
        XCTAssertNotEqual(press(a, signature: 0x4F54_4852), noErr)
        XCTAssertNotEqual(press(a + 100), noErr)
        center.unregister(a)
        XCTAssertNotEqual(press(a), noErr)
        XCTAssertEqual(fired, 0)
    }

    func testAGoneCenterLeavesNoHandler() {
        var fired = 0
        var center: HotKeyCenter? = HotKeyCenter()
        let a = center!.add { fired += 1 }
        weak let gone = center
        center = nil
        XCTAssertNil(gone)
        XCTAssertNotEqual(press(a), noErr)
        XCTAssertEqual(fired, 0)
    }

    func testARealChordRegistersAndReleases() {
        let center = HotKeyCenter()
        // Control-Option-Shift-Command-F19: a chord nothing else holds.
        let result = center.register(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)) {}
        guard case .success(let id) = result else { return XCTFail("refused: \(result)") }
        center.unregister(id)
    }
}
