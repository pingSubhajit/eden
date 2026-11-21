import EdenCore
import Foundation
@testable import Eden

/// A space of the test world as a new install has it, for the suites that
/// draw or carry the column, and for those that leave things behind.
///
/// The whole target runs in one process, in one world: Store.world is fixed
/// by whichever suite runs first, whatever the others' EDEN_PROBE says. So
/// what one suite leaves in a space — its pins and kept groups, the pins its
/// profile shows in every space, a window's saved tabs and tab groups (which
/// the next window of the space starts with), other devices' tabs pretended
/// for it — is what the next suite's window finds. A suite that draws the
/// column starts from this; one that writes those things ends with it.
@MainActor
enum CleanWorld {
    /// The space's pins, kept groups and saved session gone, its profile's
    /// shared pins too, and no other device's tabs: written, before anything
    /// is read back.
    static func reset(space: UUID = Space.firstID, profile: UUID = Profile.personalID) {
        Pins.forget(space)
        Pins.forgetShared(of: profile)
        Session.write(now: true, space: space, Session.Shape(tabs: [], active: 0))
        Sync.shared.pretend([], on: Sync.shared.on)
        Disk.drain()
    }
}
