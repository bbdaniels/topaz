import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "SecurityTool")

// Loupe's keychain items, read and written through Apple's /usr/bin/security
// (Ben, 2026-11-08, "option 1").
//
// Loupe is signed with a self-signed certificate that has no team id, so an
// item's access list names each build by its code hash, and "Always Allow"
// held only until the next rebuild: every rebuild asked again. The security
// tool is signed by Apple and does not change with Loupe's builds, so once
// Ben allows it for an item, that holds. An item it creates trusts it from
// the start. The cost, accepted by Ben: any process running as Ben can read
// these items through the same tool without a prompt, as it already can
// Claude Code's own sign in.
//
// Rules, learned on the Mac (27.2, 2026-11-08):
// - No secret goes in argv. A write is one `add-generic-password` command fed
//   to `security -i` on standard input, the secret as hex (`-X`), so quotes and
//   spaces in it need no escaping. Interactive mode reads a line of at most
//   4096 bytes, so a longer command is refused, and every write is read back.
// - An update never passes `-T`: on an item that exists, -T asks to change its
//   access list, which raises a keychain password dialog. Without it, -U only
//   replaces the data, and a new item trusts its creator, the tool, anyway.
// - `find-generic-password -w` prints the secret and a newline, or, when the
//   secret has any byte that is not printable ASCII, its hex. Exit 44: no
//   such item.
// - A security process waiting on a dialog is never killed (killing one left
//   the login keychain locked, 2026-11-08). A call stops waiting after its
//   timeout and reports it; while that process is still outstanding, every
//   new call returns `busy` at once instead of starting another, so a dialog
//   Ben has not answered cannot pile up processes behind it.
// - Nothing here logs a secret, and every call runs on the caller's thread,
//   which must not be the main one.
enum SecurityTool {
    static let path = "/usr/bin/security"
    /// `security`'s exit status when the item does not exist.
    static let notFoundStatus: Int32 = 44
    /// Interactive mode reads lines into a 4096-byte buffer.
    static let maxCommandBytes = 4095

    enum Read: Equatable {
        case found(Data)
        case notFound
        case failed(Int32)
        case timedOut
        case busy
    }

    enum Write: Equatable {
        case saved
        /// The service or account has characters the command line cannot carry
        /// unquoted, or the command would not fit in one line.
        case refused
        case failed(Int32)
        /// Read back, the item does not hold what was written.
        case mismatch
        case timedOut
        case busy
    }

    // MARK: - Commands (pure)

    static func findArguments(service: String, account: String) -> [String] {
        ["find-generic-password", "-s", service, "-a", account, "-w"]
    }

    static func deleteArguments(service: String, account: String) -> [String] {
        ["delete-generic-password", "-s", service, "-a", account]
    }

    /// Names that `security -i` splits correctly without quoting.
    static func isPlainName(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    /// The line `security -i` reads to add or update an item; nil when the
    /// names need quoting or the line is too long. No -T (see above).
    static func addCommand(service: String, account: String, secret: Data) -> String? {
        guard isPlainName(service), isPlainName(account), !secret.isEmpty else { return nil }
        let line = "add-generic-password -U -s \(service) -a \(account) -X \(hex(secret))\n"
        return line.utf8.count <= maxCommandBytes ? line : nil
    }

    static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func unhex(_ s: Data) -> Data? {
        guard !s.isEmpty, s.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            guard let hi = nibble(s[i]), let lo = nibble(s[s.index(after: i)]) else { return nil }
            out.append(hi << 4 | lo)
            i = s.index(i, offsetBy: 2)
        }
        return out
    }

    /// The secret in `find-generic-password -w`'s output: the text less its
    /// newline, or the bytes its hex stands for. A secret that is itself an
    /// even run of hex digits reads as hex; Loupe's items (a JSON blob, the
    /// legacy keys and cookies) never are.
    static func secret(fromOutput out: Data) -> Data {
        var text = out
        if text.last == UInt8(ascii: "\n") { text.removeLast() }
        return unhex(text) ?? text
    }

    static func readResult(status: Int32, output: Data) -> Read {
        switch status {
        case 0: return .found(secret(fromOutput: output))
        case notFoundStatus: return .notFound
        default: return .failed(status)
        }
    }

    // MARK: - Calls

    /// Reads an item's secret.
    static func read(service: String, account: String, timeout: TimeInterval) -> Read {
        switch run(findArguments(service: service, account: account), input: nil, timeout: timeout) {
        case .exited(let status, let output):
            let result = readResult(status: status, output: output)
            if case .failed(let s) = result {
                logger.error("Reading \(service, privacy: .public)/\(account, privacy: .public) failed: exit \(s)")
            }
            return result
        case .timedOut: return .timedOut
        case .busy: return .busy
        case .notStarted: return .failed(-1)
        }
    }

    /// Adds the item or replaces its secret, then reads it back.
    static func save(service: String, account: String, secret: Data, timeout: TimeInterval) -> Write {
        guard let command = addCommand(service: service, account: account, secret: secret) else {
            logger.error("Not saving \(service, privacy: .public)/\(account, privacy: .public): names need quoting or the secret is too long")
            return .refused
        }
        switch run(["-i"], input: Data(command.utf8), timeout: timeout) {
        case .exited(0, _): break
        case .exited(let status, _):
            logger.error("Saving \(service, privacy: .public)/\(account, privacy: .public) failed: exit \(status)")
            return .failed(status)
        case .timedOut: return .timedOut
        case .busy: return .busy
        case .notStarted: return .failed(-1)
        }
        switch read(service: service, account: account, timeout: timeout) {
        case .found(let stored) where stored == secret: return .saved
        case .timedOut: return .timedOut
        case .busy: return .busy
        default:
            logger.error("Saved \(service, privacy: .public)/\(account, privacy: .public), but it reads back different")
            return .mismatch
        }
    }

    /// Deletes an item; true when it is gone or was never there.
    @discardableResult
    static func delete(service: String, account: String, timeout: TimeInterval) -> Bool {
        switch run(deleteArguments(service: service, account: account), input: nil, timeout: timeout) {
        case .exited(0, _), .exited(notFoundStatus, _): return true
        default: return false
        }
    }

    // MARK: - Process

    private enum Outcome {
        case exited(Int32, Data)
        case timedOut
        case busy
        case notStarted
    }

    private static let lock = NSLock()
    private static var outstanding = false

    /// Runs the tool, single flight. Its standard error, which can echo item
    /// attributes, is read and dropped; standard output goes only to the caller.
    private static func run(_ arguments: [String], input: Data?, timeout: TimeInterval) -> Outcome {
        let claimed: Bool = lock.withLock {
            if outstanding { return false }
            outstanding = true
            return true
        }
        guard claimed else {
            logger.warning("security is still waiting on an earlier call; not starting another")
            return .busy
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            lock.withLock { outstanding = false }
            exited.signal()
        }
        var output = Data()
        let drained = DispatchGroup()
        do {
            try process.run()
        } catch {
            lock.withLock { outstanding = false }
            logger.error("Could not start security: \(error.localizedDescription, privacy: .public)")
            return .notStarted
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            output = out.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            _ = err.fileHandleForReading.readDataToEndOfFile()
        }
        if let input {
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            logger.warning("security has not answered in \(Int(timeout)) s (a dialog may be waiting); stopped waiting, left it running")
            return .timedOut
        }
        drained.wait()
        return .exited(process.terminationStatus, output)
    }
}
