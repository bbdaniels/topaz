import XCTest

/// SecurityTool: Loupe's keychain items through /usr/bin/security, so one
/// "Always Allow" survives rebuilds (Ben, 2026-11-08). These test the command
/// lines and the output parsing; none of them touches the keychain.
final class SecurityToolTests: XCTestCase {
    func testAReadNamesServiceAndAccountAndAsksForTheSecretOnly() {
        XCTAssertEqual(SecurityTool.findArguments(service: "com.claudehud.vault", account: "secrets"),
                       ["find-generic-password", "-s", "com.claudehud.vault", "-a", "secrets", "-w"])
        XCTAssertEqual(SecurityTool.deleteArguments(service: "com.claudehud.vault", account: "secrets"),
                       ["delete-generic-password", "-s", "com.claudehud.vault", "-a", "secrets"])
    }

    func testAWriteCarriesTheSecretAsHexOnStandardInputWithoutT() throws {
        let secret = Data(#"{"k":"café \"q\" sp"}"#.utf8)
        let line = try XCTUnwrap(SecurityTool.addCommand(service: "com.claudehud.vault", account: "secrets", secret: secret))
        XCTAssertEqual(line, "add-generic-password -U -s com.claudehud.vault -a secrets -X 7b226b223a22636166c3a9205c22715c22207370227d\n")
        XCTAssertFalse(line.contains("-T"), "-T on an existing item raises a keychain password dialog")
        XCTAssertFalse(line.contains("café"), "the secret never appears as text")
    }

    func testNamesThatNeedQuotingOrAnOverlongLineAreRefused() {
        let s = Data("x".utf8)
        XCTAssertNil(SecurityTool.addCommand(service: "Claude Code-credentials", account: "a", secret: s))
        XCTAssertNil(SecurityTool.addCommand(service: "svc", account: "a b", secret: s))
        XCTAssertNil(SecurityTool.addCommand(service: "svc", account: "a\n-T", secret: s))
        XCTAssertNil(SecurityTool.addCommand(service: "svc", account: "a", secret: Data()))
        XCTAssertNotNil(SecurityTool.addCommand(service: "svc", account: "a", secret: Data(repeating: 65, count: 2000)))
        XCTAssertNil(SecurityTool.addCommand(service: "svc", account: "a", secret: Data(repeating: 65, count: 2100)),
                     "security -i reads at most 4096 bytes a line")
    }

    func testPlainOutputLosesItsNewline() {
        XCTAssertEqual(SecurityTool.secret(fromOutput: Data(#"{"a":1} x"#.utf8 + [10])), Data(#"{"a":1} x"#.utf8))
        XCTAssertEqual(SecurityTool.secret(fromOutput: Data("sk-ant-sid01-abc\n".utf8)), Data("sk-ant-sid01-abc".utf8))
    }

    func testHexOutputForANonASCIISecretIsDecoded() {
        // What the Mac printed for this secret (27.2, 2026-11-08).
        let out = Data("7b226b223a22636166c3a9205c22715c22207370227d\n".utf8)
        XCTAssertEqual(SecurityTool.secret(fromOutput: out), Data(#"{"k":"café \"q\" sp"}"#.utf8))
        XCTAssertEqual(SecurityTool.secret(fromOutput: Data("7B22\n".utf8)), Data(#"{""#.utf8))
    }

    func testHexRoundTrips() {
        let bytes = Data((0...255).map { UInt8($0) })
        XCTAssertEqual(SecurityTool.unhex(Data(SecurityTool.hex(bytes).utf8)), bytes)
        XCTAssertNil(SecurityTool.unhex(Data("abc".utf8)))
        XCTAssertNil(SecurityTool.unhex(Data("zz".utf8)))
        XCTAssertNil(SecurityTool.unhex(Data()))
    }

    func testExitStatusesMapToResults() {
        XCTAssertEqual(SecurityTool.readResult(status: 0, output: Data("s3cret\n".utf8)), .found(Data("s3cret".utf8)))
        XCTAssertEqual(SecurityTool.readResult(status: 44, output: Data()), .notFound)
        XCTAssertEqual(SecurityTool.readResult(status: 51, output: Data()), .failed(51))
    }
}
