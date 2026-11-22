import EdenCore
import XCTest
@testable import Eden

/// Settings' rows (SettingsIndex): merged controls write the keys the two
/// switches did, new defaults reach only keys never touched, and an
/// explicit off on a switch that left Settings stays off.
@MainActor
final class SettingsIndexTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "settings-index-\(getpid())", 1)
        super.setUp()
    }

    private let touched = ["sidebar", "manner", "sidebar.settled", "sidebar.icons", "sidebar.foldIcons", "tabs.compact",
                           "toolbar.left", "sidebar.position", "tabs.sleep", SleepPace.key, "float.leave", "float.away",
                           "pins.home", "pins.peek", "links.peek", "links.peekClick", "pages.120", "pages.120.mode",
                           "swipe.history", "links.show", "float.flicks", "spaces", "pins.list", "pins.folders",
                           "search.shift", "search.shiftCustom"]

    private func fresh(_ body: () -> Void) {
        let saved = touched.map { ($0, Store.settings.object(forKey: $0)) }
        defer { for (key, value) in saved { Store.settings.set(value, forKey: key) } }
        touched.forEach(Store.settings.removeObject(forKey:))
        body()
    }

    func testIdsAreUniqueAndEveryGroupIsReal() {
        XCTAssertEqual(Set(SettingsIndex.items.map(\.id)).count, SettingsIndex.items.count)
        for item in SettingsIndex.items {
            XCTAssertNotNil(SettingsIndex.group(item.group), item.id)
            XCTAssertLessThanOrEqual(item.detail.count, 90, item.id)
            if let parent = item.parent { XCTAssertNotNil(SettingsIndex.item(parent), item.id) }
        }
    }

    func testOldSectionNames() {
        XCTAssertEqual(SettingsPanel.Page.named("shortcuts"), .keyboard)
        XCTAssertEqual(SettingsPanel.Page.named("downloads"), .general)
        XCTAssertEqual(SettingsPanel.Page.named("privacy"), .privacy)
    }

    func testDefaultsForUntouchedKeys() {
        fresh {
            let prefs = Preferences()
            XCTAssertEqual(prefs.fastPages, .onPower)
            XCTAssertTrue(prefs.holdsHistory)
            XCTAssertEqual(prefs.sleepChoice, .normal)
            XCTAssertEqual(prefs.floatOwn, .tabs)
            XCTAssertEqual(prefs.peekChoice, .shift)
            // Nothing written just for reading them.
            for key in ["pages.120.mode", "swipe.history"] {
                XCTAssertNil(Store.settings.object(forKey: key), key)
            }
        }
    }

    func testExplicitChoicesStand() {
        fresh {
            Store.settings.set(false, forKey: "pages.120")
            Store.settings.set(false, forKey: "swipe.history")
            Store.settings.set(false, forKey: "links.show")
            Store.settings.set(false, forKey: "float.flicks")
            let prefs = Preferences()
            XCTAssertEqual(prefs.fastPages, .never)
            XCTAssertFalse(prefs.holdsHistory)
            XCTAssertFalse(prefs.showsLinks)
            XCTAssertFalse(prefs.floatFlicks)
            Store.settings.set(true, forKey: "pages.120")
            XCTAssertEqual(Preferences().fastPages, .always)
        }
    }

    func testMergedControlsWriteTheOldKeys() {
        fresh {
            let prefs = Preferences()
            prefs.sidePosition = .right
            XCTAssertEqual(Store.settings.string(forKey: "sidebar.position"), "right")
            prefs.sleepChoice = .never
            XCTAssertEqual(Store.settings.object(forKey: "tabs.sleep") as? Bool, false)
            prefs.sleepChoice = .sooner
            XCTAssertEqual(Store.settings.object(forKey: "tabs.sleep") as? Bool, true)
            XCTAssertEqual(Store.settings.string(forKey: SleepPace.key), "sooner")
            prefs.floatOwn = .tabsOrApps
            XCTAssertEqual(Store.settings.object(forKey: "float.leave") as? Bool, true)
            XCTAssertEqual(Store.settings.object(forKey: "float.away") as? Bool, true)
            prefs.floatOwn = .never
            XCTAssertEqual(Store.settings.object(forKey: "float.leave") as? Bool, false)
            XCTAssertEqual(Store.settings.object(forKey: "float.away") as? Bool, false)
            prefs.peekChoice = .off
            XCTAssertEqual(Store.settings.object(forKey: "links.peek") as? Bool, false)
            prefs.peekChoice = .optionCommand
            XCTAssertEqual(Store.settings.object(forKey: "links.peek") as? Bool, true)
            XCTAssertEqual(Store.settings.string(forKey: "links.peekClick"), "optionCommand")
        }
    }

    func testSetUpLikeArcAndUndo() {
        fresh {
            let prefs = Preferences()
            prefs.sidePosition = .right
            let before = prefs.arcSnapshot
            XCTAssertFalse(prefs.looksLikeArc)
            XCTAssertEqual(prefs.setUpLikeArc(), ["tabs on the left", "Spaces"])
            XCTAssertTrue(prefs.looksLikeArc)
            prefs.restore(before)
            XCTAssertEqual(prefs.sidePosition, .right)
            XCTAssertFalse(prefs.usesSpaces)
        }
    }

    /// Pinned rows, their folders and pins keeping their site are always
    /// on (#6): their switches leave Settings, and what they kept goes.
    func testPinSwitchesAreGone() {
        fresh {
            for key in ["pins.list", "pins.folders", "pins.home", "pins.peek"] { Store.settings.set(false, forKey: key) }
            _ = Preferences()
            for key in ["pins.list", "pins.folders", "pins.home", "pins.peek"] {
                XCTAssertNil(Store.settings.object(forKey: key), key)
            }
            for id in ["pins.list", "pins.folders", "pins.keep"] { XCTAssertNil(SettingsIndex.item(id), id) }
        }
    }

    /// The tabs are only ever down a side, with their titles (#27): what
    /// the tabs across the top, the column as icons only and their switches
    /// kept goes at launch, their rows leave Settings, and the side is the
    /// one choice left, on the left until asked otherwise.
    func testOnlyTheSidebarIsLeft() {
        fresh {
            let gone = ["sidebar", "manner", "sidebar.settled", "sidebar.icons", "sidebar.foldIcons",
                        "tabs.compact", "toolbar.left"]
            Store.settings.set(false, forKey: "sidebar")
            Store.settings.set("top", forKey: "manner")
            for key in gone.dropFirst(2) { Store.settings.set(true, forKey: key) }
            let prefs = Preferences()
            for key in gone { XCTAssertNil(Store.settings.object(forKey: key), key) }
            XCTAssertEqual(prefs.sidePosition, .left)
            for id in ["tabs.layout", "sidebar.foldIcons", "toolbar.left", "tabs.compact"] {
                XCTAssertNil(SettingsIndex.item(id), id)
            }
            XCTAssertNotNil(SettingsIndex.item("sidebar.position"))
            XCTAssertTrue(SettingsIndex.apply("sidebar.position", "right", to: prefs))
            XCTAssertEqual(prefs.sidePosition, .right)
            XCTAssertFalse(SettingsIndex.apply("sidebar.position", "top", to: prefs))
        }
    }

    /// Shift-Return's engine (#848): off until picked, kept when picked,
    /// and Off takes the key away again rather than writing an empty one.
    func testShiftEngineOffUntilPicked() {
        fresh {
            XCTAssertNil(Preferences().shiftEngine)
            XCTAssertNil(Store.settings.object(forKey: "search.shift"), "nothing written just for reading it")
            let prefs = Preferences()
            prefs.shiftEngine = .google
            XCTAssertEqual(Store.settings.string(forKey: "search.shift"), "google")
            XCTAssertEqual(Preferences().shiftEngine, .google)
            prefs.shiftEngine = .custom
            prefs.shiftCustom = "https://example.com/?q=%s"
            let again = Preferences()
            XCTAssertEqual(again.shiftEngine, .custom)
            XCTAssertEqual(again.shiftCustom, "https://example.com/?q=%s")
            prefs.shiftEngine = nil
            XCTAssertNil(Store.settings.object(forKey: "search.shift"))
            XCTAssertNil(Preferences().shiftEngine)
            Store.settings.set("not-an-engine", forKey: "search.shift")
            XCTAssertNil(Preferences().shiftEngine, "an unknown name reads as off")
        }
    }

    func testFindByWords() {
        XCTAssertTrue(SettingsIndex.find("vertical tabs").contains { $0.id == "sidebar.position" })
        XCTAssertTrue(SettingsIndex.find("pip").contains { $0.id == "float.own" })
        XCTAssertTrue(SettingsIndex.find("autoplay").contains { $0.id == "media.click" })
        XCTAssertTrue(SettingsIndex.find("spelling").contains { $0.id == "autocorrect" })
        XCTAssertTrue(SettingsIndex.find("split").contains { $0.id == "note.split" })
        XCTAssertTrue(SettingsIndex.find("shift enter").contains { $0.id == "search.shift" })
        XCTAssertTrue(SettingsIndex.find("").isEmpty)
        XCTAssertTrue(SettingsIndex.find("zzzz nothing").isEmpty)
    }
}
