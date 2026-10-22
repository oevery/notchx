import Foundation
import IOKit.pwr_mgt

@MainActor
protocol KeepAwakeAsserting: AnyObject {
    func acquire() -> Bool
    func release() -> Bool
}

/// Prevents idle display/system sleep. Explicit sleep and lid closure remain OS-owned.
@MainActor
final class KeepAwakeAssertion: KeepAwakeAsserting {
    private var assertionID: IOPMAssertionID?

    func acquire() -> Bool {
        guard assertionID == nil else { return true }
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NotchX Keep Awake" as CFString, &identifier
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = identifier
        return true
    }

    func release() -> Bool {
        guard let assertionID else { return true }
        guard IOPMAssertionRelease(assertionID) == kIOReturnSuccess else { return false }
        self.assertionID = nil
        return true
    }
}
