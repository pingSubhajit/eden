import XCTest
@testable import EdenCore

/// The one kind of passing message (Toasts): one at a time, said again where
/// it stands, an offer never cut short by a passing note, timed by what it
/// has to say.
@MainActor
final class ToastsTests: XCTestCase {
    func testTheLatestReplacesTheOneShowing() throws {
        let toasts = Toasts()
        toasts.show(Toast("Address copied", look: .done))
        toasts.show(Toast("History cleared", look: .done))
        XCTAssertEqual(toasts.current?.text, "History cleared")
    }

    func testTheSameThingAgainIsSaidWhereItStands() throws {
        let toasts = Toasts()
        toasts.show(Toast("Address copied", look: .done))
        let first = try XCTUnwrap(toasts.current?.id)
        let said = toasts.said
        toasts.show(Toast("Address copied", look: .done))
        XCTAssertEqual(toasts.current?.id, first, "not a new toast coming in")
        XCTAssertEqual(toasts.said, said + 1, "its check drawn again")

        toasts.show(Toast("110%", key: "zoom"))
        let zoom = try XCTUnwrap(toasts.current?.id)
        toasts.show(Toast("125%", key: "zoom"))
        XCTAssertEqual(toasts.current?.id, zoom, "a key's toast changes where it stands")
        XCTAssertEqual(toasts.current?.text, "125%")
    }

    func testAnOfferIsNotCutShortByAPassingNote() throws {
        let toasts = Toasts()
        var reopened = false
        toasts.show(Toast("Closed “Example”", action: Toast.Action("Reopen") { reopened = true }))
        toasts.show(Toast("110%", key: "zoom"))
        XCTAssertEqual(toasts.current?.text, "Closed “Example”", "the offer stays its time")
        toasts.perform(try XCTUnwrap(toasts.current?.action))
        XCTAssertTrue(reopened)
        XCTAssertEqual(toasts.current?.text, "110%", "the note waiting comes next")
    }

    func testWhatCameOfSomethingDoneSinceTakesTheOffersPlace() {
        let toasts = Toasts()
        toasts.show(Toast("Saved kept.pdf", look: .done, action: Toast.Action("Show in Finder") {}))
        toasts.show(Toast("Saved shy.pdf", look: .done))
        XCTAssertEqual(toasts.current?.text, "Saved shy.pdf")
    }

    func testWhatAnActionSaysOfItselfStays() throws {
        let toasts = Toasts()
        toasts.show(Toast("Hidden", look: .done, action: Toast.Action("Undo") { [toasts] in
            toasts.show(Toast("It's back", look: .done))
        }))
        toasts.perform(try XCTUnwrap(toasts.current?.action))
        XCTAssertEqual(toasts.current?.text, "It's back")
    }

    func testANoteWaitingIsDroppedWhenNewerNewsComes() throws {
        let toasts = Toasts()
        toasts.show(Toast("Closed “Example”", action: Toast.Action("Reopen") {}))
        toasts.show(Toast("110%", key: "zoom"))
        toasts.show(Toast("Address copied", look: .done))
        toasts.show(Toast("125%", key: "zoom"))
        XCTAssertEqual(toasts.current?.text, "125%")
        toasts.dismiss()
        XCTAssertNil(toasts.current, "the older zoom doesn't come back")
    }

    func testHowLongEachStays() {
        XCTAssertEqual(Toasts.lifetime(Toast("Copied")), 2, "Dia's two seconds for a few words")
        XCTAssertGreaterThan(Toasts.lifetime(Toast(String(repeating: "word ", count: 14))), 2, "longer to read")
        XCTAssertEqual(Toasts.lifetime(Toast("Closed", action: Toast.Action("Reopen") {})), 5, "long enough to take up")
        XCTAssertLessThanOrEqual(Toasts.lifetime(Toast(String(repeating: "word ", count: 80))), 4.5)
        XCTAssertLessThanOrEqual(Toasts.lifetime(Toast(String(repeating: "word ", count: 80), look: .problem)), 6)
    }

    func testItGoesWhenItsTimeIsUpAndStaysWhileHeld() async throws {
        let toasts = Toasts()
        toasts.show(Toast("Copied"))
        toasts.hold(true)
        try await Task.sleep(for: .seconds(2.3))
        XCTAssertNotNil(toasts.current, "kept while the pointer is on it")
        toasts.hold(false)
        try await Task.sleep(for: .seconds(2.3))
        XCTAssertNil(toasts.current)
    }
}
