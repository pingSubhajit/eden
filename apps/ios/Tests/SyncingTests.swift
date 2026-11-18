import EdenCore
import Foundation
import Testing
@testable import Eden

/// What this device syncs with the Mac (Syncing): bookmarks as the Mac's
/// tree, and the settings as the Mac's own items, the same keys and JSON.
@MainActor
struct SyncingTests {
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-\(UUID().uuidString).json")

    private func freshDefaults() -> UserDefaults {
        let name = "eden-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theMacsFoldersArriveWholeAndShowAsOneList() throws {
        let docs = Bookmark.site("Docs", try #require(URL(string: "https://docs.example/")))
        let news = Bookmark.site("News", try #require(URL(string: "https://news.example/")))
        let tree = [Bookmark.folder("Work", [docs]), news]
        let store = BookmarkStore(file: file)
        var told = 0
        store.saved = { told += 1 }

        store.adopt(SyncItems.applyBookmarks(SyncItems.bookmarks(tree)))
        #expect(store.roots == tree, "the folder kept as the Mac has it")
        #expect(store.items.map(\.title) == ["Docs", "News"])
        #expect(told == 0, "what came from another device isn't sent back as a change")

        store.remove(at: IndexSet(integer: 0))
        #expect(store.roots.first?.children == [], "taken out of its folder, the folder stays")
        #expect(told == 1)
        #expect(SyncItems.applyBookmarks(SyncItems.bookmarks(store.roots)) == store.roots)
    }

    @Test func aSiteAddedHereGoesAtTheEndOfTheTopLevel() throws {
        let store = BookmarkStore(file: file)
        store.adopt([Bookmark.folder("Work", [])])
        store.add(try #require(URL(string: "https://new.example/")), title: "New")
        #expect(store.roots.map(\.title) == ["Work", "New"])
    }

    @Test func theSettingsAreTheMacsItems() {
        let settings = Settings(store: freshDefaults())
        settings.engine = .kagi
        settings.blocks = false
        let items = settings.syncItems
        #expect(items["set:search.engine"] == "\"kagi\"")
        #expect(items["set:shield"] == "false")
        #expect(Set(items.keys) == Settings.synced)
        #expect(Settings.synced.isSubset(of: Set(SyncItems.knownSettings.map { "set:" + $0 })),
                "keys the Mac knows, so neither deletes the other's")
    }

    @Test func settingsFromTheMacAreTakenAndTold() {
        let settings = Settings(store: freshDefaults())
        var told = 0
        settings.changed = { told += 1 }
        settings.applySynced(["set:search.engine": "\"custom\"", "set:search.custom": "\"https://find.example/?q=%s\"",
                              "set:shield": "false", "set:look": "\"dark\""])
        #expect(settings.engine == .custom)
        #expect(settings.searchTemplate == "https://find.example/?q=%s")
        #expect(settings.blocks == false)
        #expect(told == 3)
        settings.applySynced(settings.syncItems)
        #expect(told == 3, "the same again changes nothing")
    }

    @Test func aCustomEngineWithoutItsAddressSearchesTheStandardOne() {
        let settings = Settings(store: freshDefaults())
        settings.engine = .custom
        #expect(settings.searchTemplate == Engine.standard.template(custom: ""))
    }

    @Test func readingModeAsksForMarkdownCopiesOnlyOnceTurnedOn() {
        let store = freshDefaults()
        let settings = Settings(store: store)
        #expect(!settings.readsTwins)
        settings.readsTwins = true
        #expect(Settings(store: store).readsTwins, "kept under the Mac's own key")
        #expect(store.bool(forKey: "reader.twins"))
    }

    @Test func syncIsOnUnlessTurnedOffButNeverInATestRun() {
        #expect(Settings(store: freshDefaults()).syncs)
        #expect(!Syncing.possible)
    }
}
