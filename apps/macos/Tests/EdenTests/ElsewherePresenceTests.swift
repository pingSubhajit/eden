import EdenCore
import XCTest
@testable import Eden

/// What the column watches of your other devices' tabs (ElsewherePresence):
/// how many each has open in each space, told only when that changes, so a
/// tab moved into this space on another device brings its group here, and
/// one group growing as another shrinks makes room for it.
@MainActor
final class ElsewherePresenceTests: XCTestCase {
    private let work = UUID(), home = UUID()

    private func device(_ id: String, _ spaces: [UUID?]) -> DeviceTabs {
        DeviceTabs(device: id, name: id, kind: .iphone,
                   tabs: spaces.map { DeviceTabs.Page(url: "https://example.com/", title: "", space: $0) }, at: 0)
    }

    private func place(_ id: String, _ space: UUID?) -> ElsewherePresence.Place {
        ElsewherePresence.Place(device: id, space: space)
    }

    func testCountsEachDeviceInEachSpace() {
        let presence = ElsewherePresence()
        XCTAssertFalse(presence.hasTabs)
        presence.set([device("phone", [work, work, nil])])
        XCTAssertEqual(presence.counts, [place("phone", work): 2, place("phone", nil): 1])
        XCTAssertTrue(presence.hasTabs)
    }

    func testATabMovedToAnotherSpaceIsAChange() {
        let presence = ElsewherePresence()
        presence.set([device("phone", [work])])
        var told = 0
        let watching = presence.objectWillChange.sink { told += 1 }
        presence.set([device("phone", [work])])
        XCTAssertEqual(told, 0, "the same counts again say nothing")
        presence.set([device("phone", [home])])
        XCTAssertEqual(told, 1, "still a tab open, but in another space")
        watching.cancel()
    }

    func testOneGroupGrowingAsAnotherShrinksIsAChange() {
        let presence = ElsewherePresence()
        presence.set([device("phone", [work]), device("pad", [work, work, work, work])])
        var told = 0
        let watching = presence.objectWillChange.sink { told += 1 }
        presence.set([device("phone", [work, work, work, work]), device("pad", [work])])
        XCTAssertEqual(told, 1, "five in the space either way, but not in the same groups")
        watching.cancel()
    }
}
