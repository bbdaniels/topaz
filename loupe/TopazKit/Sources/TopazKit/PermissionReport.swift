import ApplicationServices
import os

/// Each helper logs, once at launch, the permissions macOS applies to it now,
/// as `permissions: Accessibility=yes` (subsystem its bundle id, category
/// Permissions, at notice level so the log keeps it): what the check answers
/// for this process, not what System Settings lists, since a grant made to
/// an earlier signature stays listed but is never applied. topaz-build.sh
/// reads the line after an install; asks for nothing.
public enum PermissionReport {
    public static func log(subsystem: String) {
        let accessibility = AXIsProcessTrusted() ? "yes" : "no"
        Logger(subsystem: subsystem, category: "Permissions")
            .notice("permissions: Accessibility=\(accessibility, privacy: .public)")
    }
}
