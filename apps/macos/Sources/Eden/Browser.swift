import EdenCore
import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.

/// What every window shares: the settings, History, the
/// downloads list and the downloads under way, hidden elements, and the
/// one floating video. Each window's Browser holds only its own tabs and
/// what is drawn over them.
@MainActor
enum Shared {
    static let prefs = Preferences()
    static let curtain = Curtain()
    static let loot = Loot()
    static let floater = Float()
    static let fetches = Fetches()
}

@MainActor
final class Browser: NSObject, ObservableObject {
    private static var activeFileImports: [UUID: ImportFile.Control] = [:]
    private static var fileImportTerminating = false

    static func cancelAllFileImports() -> Bool {
        fileImportTerminating = true
        for control in activeFileImports.values { control.cancel() }
        return !activeFileImports.isEmpty
    }

    static var hasActiveFileImports: Bool { !activeFileImports.isEmpty }
    /// With groups on, every change to the row ends with it put back in the
    /// order it is shown in (see arrangeGroupedTabs): a tab made by a link,
    /// Peek, the little window or Move to Space lands wherever its own code
    /// puts it, and is then taken to its group or out of the groups' way.
    /// ⌘1–9, ⌃Tab and the extensions' tab indexes read this row, so it and
    /// what is on screen never disagree.
    @Published private(set) var tabs: [Tab] = [] {
        didSet {
            arrangeGroupedTabs()
            if !selectedTabIDs.isEmpty {
                let valid = selectedTabIDs.intersection(Set(tabs.map(\.id)))
                if valid != selectedTabIDs { selectedTabIDs = valid }
            }
            if let selectionAnchor, !tabs.contains(where: { $0.id == selectionAnchor }) {
                self.selectionAnchor = nil
            }
        }
    }
    /// Tabs picked with Command or Shift. The active page remains where it is.
    @Published private(set) var selectedTabIDs: Set<Tab.ID> = []
    private var selectionAnchor: Tab.ID?
    @Published private(set) var splits: [TabSplit] = [] {
        // A pair taken apart can leave a peek's tab off screen.
        didSet { if peekTab != nil { followPeek() } }
    }
    /// Named tab sections in the current space, in display order.
    @Published var tabGroups: [TabGroup] = []
    @Published var editingGroupID: UUID?
    /// The group whose icon is being picked, above the line or under it
    /// (GroupIconPicker).
    @Published var iconGroupID: UUID?
    /// The tab on screen before the last change, and when it changed: a tab
    /// in the column opens as the button goes down (#625), so a tab carried
    /// from there onto the page finds its own page under the hand, and
    /// TabDrag puts this one back to split with.
    private(set) var cameFrom: (id: Tab.ID?, at: TimeInterval)?

    @Published var activeID: Tab.ID? {
        didSet {
            // The tab just left is the tab just looked at. Whether a tab has
            // gone unwatched long enough to sleep is counted from here, not
            // from when it was first picked.
            // A question the page asked while it was in the background.
            if let id = activeID, id != oldValue, let held = heldDialogs.removeValue(forKey: id) {
                DispatchQueue.main.async { held.forEach { $0.present() } }
            }
            guard oldValue != activeID else { return }
            // The pages as they were left, for their hover cards at the next
            // launch: both halves of a pair left together.
            if let left = tabs.first(where: { $0.id == oldValue }) {
                let shown = split(for: left)?.tabs ?? [left.id]
                for tab in tabs where shown.contains(tab.id) { tab.keepPicture() }
            }
            cameFrom = (oldValue, ProcessInfo.processInfo.systemUptime)
            followPeek()
            // Going to another tab ends a page's run of links (see
            // placeForLink) — but with links opened in front beside their
            // page, not going between the page and the tabs it opened: each
            // of them is in front as it opens, and you go back to the page
            // for the next.
            if !(frontLinksBeside && linkRun.map({ run in
                [oldValue, activeID].allSatisfy { $0 == run.opener || $0.map(run.opened.contains) == true }
            }) == true) {
                linkRun = nil
            }
            if veiling { stopHiding() }
            if snapping { stopSnapping() }
            if displayTab?.id == oldValue { cancelDisplay() }
            if decideTab?.id == oldValue { settleCapture() }
            clearTabSelection()
            // What was found belongs to the page just left; the words typed
            // go on to be looked for on this one.
            invalidateFindPage(retryOnActiveTab: true)
            guard let old = oldValue else { return }
            linkStatus.dismiss()
            let left = tabs.first { $0.id == old }
            left?.touch()
            if prefs.splitView, let pair = splits.first(where: { $0.contains(old) }),
               activeID.map({ !pair.contains($0) }) ?? true {
                for other in tabs where pair.others(than: old).contains(other.id) { other.touch() }
            }
            // The page to come back to, when the pair is chosen again.
            if prefs.splitView, let id = activeID,
               let index = splits.firstIndex(where: { $0.contains(id) }), splits[index].focused != id {
                splits[index].focused = id
            }
            // The switcher's order and pictures, most recently used first.
            // Focus moving within a pair isn't leaving it; a pair left is
            // one entry, under its first page.
            if prefs.splitView, let pair = splits.first(where: { $0.contains(old) }) {
                if let id = activeID, pair.contains(id) { return }
                tabSwitcher.cancel()
                if let first = tabs.first(where: { $0.id == pair.left }) {
                    tabSwitcher.left(first, alive: Set((tabs + parkedTabs).map(\.id)))
                }
                return
            }
            tabSwitcher.cancel()
            if let left { tabSwitcher.left(left, alive: Set((tabs + parkedTabs).map(\.id))) }
        }
    }

    var activeSplit: TabSplit? {
        guard prefs.splitView, let activeID else { return nil }
        return splits.first { $0.contains(activeID) }
    }

    /// The pair a tab is in, while Split View is on. Turned off, pairs are
    /// kept, as groups are, and nothing acts on them until it is back on.
    func split(for tab: Tab) -> TabSplit? {
        guard prefs.splitView else { return nil }
        return splits.first { $0.contains(tab.id) }
    }

    /// Whether a tab has a place of its own in the row: any tab but a
    /// pair's later pages, which share the first one's.
    func standsInRow(_ tab: Tab) -> Bool {
        split(for: tab).map { $0.left == tab.id } ?? true
    }

    /// The pairs' later pages, which stand in no place of their own: the
    /// tabs `standsInRow` turns away, all at once, for walks of the whole row
    /// that would otherwise look every tab up in every pair.
    private var pairedOff: Set<Tab.ID> {
        guard prefs.splitView else { return [] }
        var ids = Set<Tab.ID>()
        for pair in splits { for id in pair.tabs where id != pair.left { ids.insert(id) } }
        return ids
    }

    var displayedTabs: [Tab] {
        guard prefs.splitView, !splits.isEmpty else { return tabs }
        let off = pairedOff
        return tabs.filter { !off.contains($0.id) }
    }

    var visibleTabIDs: Set<Tab.ID> {
        guard let activeID else { return [] }
        guard let pair = activeSplit else { return [activeID] }
        return Set(pair.tabs)
    }

    /// Whether a pair can stand as it is in a row: all its tabs there, next
    /// to each other in its order, none pinned, of one kind and one group.
    /// A pair kept while Split View was off may have come apart since.
    static func holds(_ pair: TabSplit, in row: [Tab]) -> Bool {
        let places = pair.tabs.compactMap { id in row.firstIndex { $0.id == id } }
        guard pair.tabs.count >= 2, places.count == pair.tabs.count, let first = places.first,
              places == Array(first..<first + places.count) else { return false }
        let members = places.map { row[$0] }
        return members.allSatisfy { tab in
            tab.pin == nil && !tab.bench && tab.shy == members[0].shy && tab.groupID == members[0].groupID
        }
    }

    let tabSwitcher = TabSwitcher()

    /// The tab whose page is currently out in the little window. Nothing
    /// floating means no window: the two are checked against each other rather
    /// than trusted to stay in step.
    @Published private(set) var floating: Tab.ID? {
        didSet {
            guard floating == nil, floater.showing else { return }
            floater.drop()
        }
    }

    /// The tabs making sound, or paused from the player at the foot of the
    /// sidebar, the newest to start last (see Player.swift). Kept with the
    /// player off too, so that turning it on shows what already plays, but
    /// only redrawing the window while it is on: a tab starting or stopping
    /// a sound is otherwise nothing the window shows beyond its own row.
    var sounding: [Tab.ID] = [] {
        willSet { if prefs.showsPlayer { objectWillChange.send() } }
    }

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs = Shared.prefs
    let linkStatus = LinkStatus()
    /// Settings, in its own tab (see InternalPages.swift). True while the
    /// window has one; set, it is shown or closed.
    var tuning: Bool {
        get { pageTab(.settings) != nil }
        set { if newValue { show(InternalPage(.settings, settingsPage.rawValue)) } else { putAway(.settings) } }
    }
    /// The first-launch walk-through, over everything. Also from the menu.
    @Published var welcoming = false
    /// What's new, once after an update (see WhatsNew.swift).
    @Published var newsShowing = false
    /// Every version's notes: Settings › About › What's New…, in a tab.
    var notesShowing: Bool {
        get { pageTab(.notes) != nil }
        set { if newValue { show(InternalPage(.notes)) } else { putAway(.notes) } }
    }

    // MARK: - pins, as Arc keeps pages

    /// ⌘D, as in Arc: the tab in front, with the tabs picked alongside it
    /// as every menu-bar action takes them (frontTabs), pinned as rows; or,
    /// all of them pins of either kind already, unpinned. Pins are where
    /// pages are kept (#6). The column shows it happen; folded away,
    /// nothing does, so a word says so.
    func togglePinRow() {
        let tabs = frontTabs
        guard !tabs.isEmpty else { return }
        if tabs.allSatisfy({ $0.pin != nil }) {
            unpin(tabs)
            if folded { announce("Unpinned", look: .done) }
            return
        }
        let pinning = tabs.filter { $0.pin == nil && $0.isWeb && !$0.shy }
        guard !pinning.isEmpty else { return }
        pin(pinning, listed: true)
        if folded { announce("Pinned", look: .done) }
    }

    /// Another browser's bookmarks, folders and all — one profile's, or
    /// every profile's when nil — as pinned rows in a folder named after
    /// it ("Chrome Bookmarks", PinShelf.folderName(import:)), in the space in front (see PinShelf.take), and, behind them, the
    /// icons it had for those sites, so the rows wear them from the start
    /// instead of a letter each. Returns how many pages came over, and how
    /// many were pinned already. `replacing`: what came from this browser
    /// before — as recorded, nothing guessed — is taken out first, and
    /// these come fresh in its place.
    ///
    /// Only when every profile read cleanly: a file that didn't read is not
    /// an empty browser, and taking out what came before for it lost
    /// bookmarks for good (#375). Then what came before stays, what could be
    /// read is added as usual, and `kept` says so.
    @discardableResult
    func takeBookmarks(from source: ImportSource, profile: String? = nil, replacing: Bool = false) -> (added: Int, already: Int, kept: Bool) {
        let read = source.bookmarkRead(profile: profile)
        let found = read.nodes
        var kept = false
        if replacing, let earlier = ImportRecords.of(source.name), !earlier.bookmarkIDs.isEmpty {
            if read.complete {
                let taken = PinShelf.withdraw(earlier.bookmarkIDs, via: self)
                ImportRecords.forgetBookmarks(source.name, rows: taken.rows, keeping: taken.left)
            } else {
                kept = true
            }
        }
        let folder = PinShelf.folderName(import: source.name)
        let (count, already, ids) = pinShelf.take(found, into: folder)
        ImportRecords.note(source.name, bookmarks: ids, bookmarks: count)
        announce(
            kept ? "Couldn't read all of \(source.name)'s bookmarks: what came from it before was kept"
                : Bookmarks.count(found) == 0 ? "No bookmarks in \(source.name)"
                : count == 0 ? "The bookmarks from \(source.name) were all pinned already"
                : already == 0 ? "\(count) bookmarks from \(source.name), pinned in “\(folder)”"
                : "\(count) bookmarks from \(source.name), pinned in “\(folder)”, \(already) pinned already"
        )
        let urls = Bookmarks.urls(found)
        DispatchQueue.global(qos: .utility).async {
            let icons = source.icons(profile: profile, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return (count, already, kept)
    }

    /// Bring Things Over, in a tab, open while set: the browser it starts
    /// on by name, or "" for the first one found.
    var bringingIn: String? {
        get { pageTab(.importing).map { $0.page?.detail ?? "" } }
        set {
            if let newValue { show(InternalPage(.importing, newValue)) } else { putAway(.importing) }
        }
    }
    struct FileImportJob: Identifiable {
        let id: UUID
        let filename: String
        var message: String
        var completed = 0
        var total: Int?
        var cancelling = false
    }
    @Published private(set) var fileImport: FileImportJob?
    private var fileImportControl: ImportFile.Control?

    func cancelFileImport() {
        guard fileImport != nil else { return }
        fileImport?.cancelling = true
        fileImport?.message = "Cancelling…"
        fileImportControl?.cancel()
    }
    /// The sheet opened from Settings › Extensions: only the extensions
    /// ticked, on a browser that has some. Read once as it opens.
    var bringingExtensions = false

    func searchURL(for text: String) -> URL? {
        Engine.url(for: text, template: prefs.engine.template(custom: prefs.customEngine))
    }

    func destination(for typed: String) -> URL? {
        if let site = siteChip { return site.url(for: typed) }
        return Address.destination(for: typed, engine: prefs.engine.template(custom: prefs.customEngine),
                                   keywords: prefs.keywords, files: true)
    }

    /// ⌘S: the column folded away, and slid out over the page for a look
    /// while it is (see Fold.swift).
    @Published var folded = false
    @Published var peeking = false

    /// The address field, raised over a page by ⌘L. A blank tab shows it
    /// without being asked — there is nothing else for that tab to show.
    @Published var editing = false {
        // The field put away takes its chip with it.
        didSet {
            if !editing, siteChip != nil { siteChip = nil }
            if !editing, launching { launching = false }
        }
    }
    /// True while ⌘T's field is up over a page for a tab that doesn't exist
    /// yet: Return opens what was typed in a new tab, and putting the field
    /// away leaves the page you were on as it was.
    @Published private(set) var launching = false
    /// The page links were last opened behind from, and the last of them:
    /// the next one from that page goes after it (see placeForLink).
    private struct LinkRun {
        let opener: Tab.ID
        let last: Tab.ID
        /// Every tab of the run, for going between them and the page
        /// without ending it (see frontLinksBeside).
        var opened: Set<Tab.ID> = []
    }
    private var linkRun: LinkRun?
    /// The run as it was when a page's script opened a tab in front, for the
    /// ⌘-click that tab turns out to be (see openClicked).
    private var runBeforeScript: (tab: Tab.ID, run: LinkRun)?
    /// The site the list offers to search, for what has been typed so far
    /// (Settings › General › Search a site from the address field).
    private(set) var siteOffer: SearchSite? {
        get { typing.siteOffer }
        set { if typing.siteOffer != newValue { typing.siteOffer = newValue } }
    }
    /// The site Tab put in the field: what is typed next searches it.
    @Published var siteChip: SearchSite? {
        didSet {
            guard siteChip != oldValue else { return }
            // What one place suggested, or was searched for, is no answer
            // for another.
            suggester.stop()
            engineWords = ("", [])
            pastSearches = nil
            guess()
        }
    }
    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the grey ending inside it are both just
    /// answers to this string.
    ///
    /// It and what answers it live apart, in `typing`, watched by the field
    /// and its list alone: published here, every key typed drew the whole
    /// window again — every row, every pin — and the menu bar with it.
    var typed: String {
        get { typing.typed }
        set { typing.typed = newValue; guess() }
    }
    let typing = FieldState()

    /// This window's profile's (see Profiles.swift).
    let history: History
    /// What the field is offering, best first.
    private(set) var offers: [Suggestion] {
        get { typing.offers }
        set { if typing.offers != newValue { typing.offers = newValue } }
    }
    /// The rest of the best match, drawn grey after the caret. Tab takes it.
    private(set) var ending: String? {
        get { typing.ending }
        set { if typing.ending != newValue { typing.ending = newValue } }
    }
    /// Which row the arrow keys have walked to, if any.
    var picked: Int? {
        get { typing.picked }
        set { if typing.picked != newValue { typing.picked = newValue } }
    }
    /// Bumped when what was typed isn't an address and can't be searched for.
    @Published private(set) var refusals = 0
    /// Bumped whenever the cursor should go back into the field.
    @Published private(set) var focusRequest = 0 {
        didSet { focusAsked = CACurrentMediaTime() }
    }
    /// When the field was last asked for the keys and hasn't taken them yet.
    private var focusAsked: CFTimeInterval?
    /// What was typed in that moment, for the field once it has the keys.
    private var heldKeys: [NSEvent] = []

    var active: Tab? { tabs.first { $0.id == activeID } }
    /// The tab the column marks as the one you're on: none while ⌘T's field
    /// is up, whose New tab row is lit instead (Zen's), the tab that will be
    /// made being the one in front.
    var liveID: Tab.ID? { launching ? nil : activeID }
    /// Whether the address field is up: raised by ⌘T or ⌘L, or standing on
    /// a blank tab. With nothing in front there is no field until one of
    /// those keys raises it — only the window's ground.
    var fieldShowing: Bool { editing || active?.isBlank == true }

    /// What Return in the field will do, which the field says with its
    /// placeholder: ⌘T and ⌘L raise one field that looks the same for both.
    enum FieldMode: Equatable {
        /// A blank tab's own field: there is no other page to keep.
        case blank
        /// ⌘T's floating field: a tab that doesn't exist yet.
        case newTab
        /// ⌘L over a page: that page goes somewhere else.
        case thisTab
    }

    var fieldMode: FieldMode {
        if launching { return .newTab }
        if editing, active?.isBlank == false { return .thisTab }
        return .blank
    }

    /// Typed plus whatever the field is quietly finishing for you. A picked
    /// open tab shows its address, as Zen's field does beside Switch to tab:
    /// its key is its title, which says nothing of where Return goes.
    var completed: String {
        if let picked, offers.indices.contains(picked) {
            let offer = offers[picked]
            return offer.kind == .open && offer.tab != nil ? Address.pretty(offer.url) : offer.key
        }
        return typed + (ending ?? "")
    }

    // MARK: - looking for something on the page

    @Published var finding = false
    /// The AI panel's conversation about the page, while it is open.
    @Published var assisting: Assistant?
    /// The side panel, beside the page (see SidePanel.swift): up or
    /// not, and what is in it.
    @Published var sidePanelShown = false
    @Published var sidePanel: SidePanelContent?
    /// The Settings page it opens on next.
    var settingsPage: SettingsPanel.Page {
        get {
            let page = SettingsPanel.Page.named( Store.settings.string(forKey: "settings.page") ?? "") ?? .general
            return page == .ai && !AI.shipped ? .general : page
        }
        set { Store.settings.set(newValue.rawValue, forKey: "settings.page") }
    }
    /// What is looked for and what the page answered, kept apart in
    /// `seeking` for the find bar alone to watch: published here, every
    /// letter typed into Find drew the whole window again, every row and pin.
    let seeking = FindState()
    // The same words written back (the field does, as it appears) aren't
    // a Next: Return and the buttons ask for that themselves.
    var needle: String {
        get { seeking.needle }
        set {
            let old = seeking.needle
            seeking.needle = newValue
            if !resettingFind, old != newValue { look(forward: true) }
        }
    }
    var matchCase: Bool {
        get { seeking.matchCase }
        set {
            let old = seeking.matchCase
            seeking.matchCase = newValue
            if !resettingFind, old != newValue { look(forward: true) }
        }
    }
    var wholeWords: Bool {
        get { seeking.wholeWords }
        set {
            let old = seeking.wholeWords
            seeking.wholeWords = newValue
            if !resettingFind, old != newValue { look(forward: true) }
        }
    }
    /// Set when the page doesn't hold what was asked for.
    private(set) var missed: Bool {
        get { seeking.missed }
        set { seeking.missed = newValue }
    }
    private(set) var findFocus: Int {
        get { seeking.focus }
        set { seeking.focus = newValue }
    }
    /// The count and which match is current, as the page last answered.
    private(set) var findResult: PageFind.Result? {
        get { seeking.result }
        set { seeking.result = newValue }
    }

    private let pageFind = PageFind()
    private struct FindSpec: Equatable {
        let tab: Tab.ID
        let query: String
        let matchCase: Bool
        let wholeWords: Bool
    }
    private var findSpec: FindSpec?
    /// Goes up whenever what is looked for, or the page it is looked for on,
    /// changes: an answer for an older one is dropped.
    private var findGeneration: UInt64 = 0
    /// One question to the page at a time. Letters typed while it answers
    /// wait here, and only the last of them is asked next: on a long page
    /// every letter would otherwise queue a whole search of its own.
    private var findAsking: UInt64?
    private var findAsked: UInt64 = 0
    /// A new search not yet asked, and Next / Previous presses not yet sent.
    private var findFresh = false
    private var findSteps = 0
    private var resettingFind = false
    private weak var findWeb: WKWebView?

    /// A question to the page not answered yet, or one waiting to be asked.
    var findBusy: Bool { findAsking != nil || findFresh || findSteps != 0 }

    var findStatus: String? {
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = findResult else { return nil }
        guard result.available else { return "Search unavailable" }
        if result.nativeFallback {
            if wholeWords && !result.wholeWordsAvailable { return "Whole words unavailable" }
            return result.found ? "Match found" : "No matches"
        }
        guard let index = result.index, let count = result.count, count > 0 else { return "No matches" }
        return "\(index) of \(count)\(result.more ? "+" : "")"
    }

    /// ⌘F on the Settings tab: its Find a setting field takes the keys.
    @Published var settingsFind = 0

    /// Eden's own pages with a search field of their own, which ⌘F goes to
    /// as it goes to Settings' (`searchFind`).
    static let searchedPages: Set<InternalPage.Kind> = [.history, .passwords, .archive]

    /// ⌘F on one of Eden's own pages with a search field: told so it can
    /// put the keyboard in its field. Each page asks whether it is the one
    /// in front.
    @Published var searchFind = 0

    /// ⌘F has somewhere to go on the page in front other than the find bar:
    /// Settings' find field, or a page's own search.
    var findsInPage: Bool {
        guard let kind = active?.page?.kind else { return false }
        return kind == .settings || Browser.searchedPages.contains(kind)
    }

    func openFind() {
        if active?.page?.kind == .settings {
            settingsFind += 1
            return
        }
        if let kind = active?.page?.kind, Browser.searchedPages.contains(kind) {
            searchFind += 1
            return
        }
        guard active?.isWeb == true else { return }
        finding = true
        findFocus += 1
    }

    func closeFind() {
        guard finding || !needle.isEmpty || findResult != nil else { return }
        // The page's own selection back, and the match's highlight gone.
        resetFindState()
        // The keyboard back to the page, as in Safari. Left with the window,
        // the Mac's keyboard navigation handed it to the first button next.
        if let web = active?.built, let window = web.window,
           window.firstResponder === window || window.firstResponder is NSText {
            window.makeFirstResponder(web)
        }
    }

    func look(forward: Bool) {
        guard let tab = active else {
            missed = false
            findResult = nil
            return
        }

        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            missed = false
            findResult = nil
            guard findSpec != nil || findWeb != nil else { return }
            let web = findWeb ?? tab.built
            forgetFind()
            if let web { clearFind(on: web) }
            return
        }

        let web = tab.web
        let spec = FindSpec(tab: tab.id, query: needle, matchCase: matchCase, wholeWords: wholeWords)
        if findSpec != spec || findWeb !== web {
            findGeneration &+= 1
            findSpec = spec
            findWeb = web
            findFresh = true
            findSteps = 0
        } else {
            findSteps += forward ? 1 : -1
        }
        askFind()
    }

    /// Sends what is waiting to the page, unless a question is still out:
    /// its answer sends the next one.
    private func askFind() {
        guard findAsking == nil, let spec = findSpec, let web = findWeb,
              findFresh || findSteps != 0 else { return }
        findAsked &+= 1
        let asking = findAsked
        let generation = findGeneration
        let steps = findSteps
        findAsking = asking
        findFresh = false
        findSteps = 0
        Task { [weak self, weak web] in
            guard let self else { return }
            guard let web, self.activeID == spec.tab, self.active?.built === web else {
                if self.findAsking == asking { self.findAsking = nil }
                return
            }
            let result = await self.pageFind.update(
                on: web,
                query: spec.query,
                matchCase: spec.matchCase,
                wholeWords: spec.wholeWords,
                steps: steps,
                generation: generation
            )
            // Something newer took over while the page was answering.
            guard self.findAsking == asking else { return }
            self.findAsking = nil
            if !result.stale, self.findGeneration == generation, self.findSpec == spec,
               self.activeID == spec.tab, self.active?.built === web {
                self.findResult = result
                self.missed = result.available && !result.found
                    && (!result.nativeFallback || !spec.wholeWords || result.wholeWordsAvailable)
            }
            self.askFind()
        }
    }

    /// Nothing asked or waiting any more; whatever answer is out is dropped.
    private func forgetFind() {
        findGeneration &+= 1
        findSpec = nil
        findWeb = nil
        findAsking = nil
        findFresh = false
        findSteps = 0
    }

    private func clearFind(on web: WKWebView) {
        let generation = findGeneration
        Task { [pageFind] in _ = await pageFind.clear(on: web, generation: generation) }
    }

    private func resetFindState() {
        let web = findWeb
        forgetFind()
        resettingFind = true
        finding = false
        needle = ""
        matchCase = false
        wholeWords = false
        resettingFind = false
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
    }

    /// A tab or document changed under an open find bar. Keep what was typed,
    /// but retire every result and callback tied to the page that just left.
    private func invalidateFindPage(retryOnActiveTab: Bool) {
        let web = findWeb
        forgetFind()
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
        guard retryOnActiveTab, finding,
              !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tab = active, !tab.loading, tab.isWeb else { return }
        look(forward: true)
    }

    // MARK: - taking things off pages

    let curtain = Shared.curtain
    let loot = Shared.loot
    let floater = Shared.floater
    /// True while the pointer is picking things to hide.
    @Published private(set) var veiling = false
    /// The tab doing the picking, which is not always the one in front.
    private weak var picking: Tab?
    /// True while Capture…'s layer is over a page (see Snap.swift).
    @Published var snapping = false
    /// The tab it is over.
    weak var snapTab: Tab?
    /// True while the list of what is hidden here is up.
    @Published var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }

    var hereHost: String? { curtain.host(of: active?.address) }
    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        if veiling { return stopHiding() }
        guard let tab = active, tab.isWeb else { return }
        if snapping { stopSnapping() }
        reviewing = false
        veiling = true
        picking = tab
        tab.startPicking()
    }

    private func stopHiding() {
        veiling = false
        picking?.stopPicking()
        picking = nil
    }

    /// What a private tab took off its page, kept for that page only.
    private var passingVeils: [Tab.ID: [String]] = [:]

    private func passingCSS(_ id: Tab.ID) -> String {
        (passingVeils[id] ?? []).map { "\n\($0) { display: none !important; }" }.joined()
    }

    /// What a "Hidden" toast offers: that one thing back, on the page it was
    /// taken off, whichever tab is in front when it is clicked.
    private func undoHidingOffer(_ selector: String, on host: String, in tab: Tab) -> Toast.Action {
        Toast.Action("Undo") { [weak self, weak tab] in
            guard let self, let tab else { return }
            // The tab dressed again only while it is still on that site: gone
            // on to another, its page wears that one's.
            let stillThere = curtain.host(of: tab.address) == host
            if tab.shy {
                passingVeils[tab.id]?.removeAll { $0 == selector }
                if stillThere { tab.applyVeils(curtain.css(on: host) + passingCSS(tab.id)) }
                return announce("It's back", look: .done)
            }
            guard let veil = curtain.veils(on: host).first(where: { $0.selector == selector }) else { return }
            curtain.restore(veil, on: host)
            if stillThere {
                let css = curtain.css(on: host)
                tab.arm(hiding: css)
                tab.applyVeils(css)
            }
            announce("\(veil.label) is back", look: .done)
        }
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        if let tab = active, tab.shy {
            guard var list = passingVeils[tab.id], !list.isEmpty else { return }
            list.removeLast()
            passingVeils[tab.id] = list
            tab.applyVeils(curtain.css(on: hereHost) + passingCSS(tab.id))
            announce("It's back", look: .done)
            return
        }
        guard let host = hereHost, let back = curtain.undo(on: host) else { return }
        redress()
        announce("\(back.label) is back", look: .done)
    }

    /// The pointer resting on a row in the list brings that one thing back,
    /// outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        active?.unpeek(curtain.css(on: hereHost))
    }

    func restore(_ veil: Veil) {
        guard let host = hereHost else { return }
        curtain.restore(veil, on: host)
        redress()
    }

    func restoreAll() {
        guard let host = hereHost else { return }
        curtain.restoreAll(on: host)
        redress()
        reviewing = false
        announce("Everything is back", look: .done)
    }

    /// Both the page in front of you and the one that loads next time.
    private func redress() {
        guard let tab = active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    // MARK: - passwords

    /// A name and password a page has just sent, waiting to be offered a place
    /// in the keychain. Held only until you answer.
    @Published private(set) var offering: Offer?

    struct Offer: Equatable {
        let login: Login
        /// The same account is already kept, with a different password.
        let changed: Bool
    }

    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is — a list hangs from it, and a click fills the form.
    /// Nothing is put into a page until you have pointed at it.
    @Published private(set) var suggesting: Suggesting? {
        didSet {
            // The offer to use Apple Passwords went without a click on it
            // or its ✕: counted, and after twice it isn't made again.
            guard let site = oldValue?.appleOffer, suggesting?.appleOffer != site else { return }
            if offerAnswered { offerAnswered = false } else { applePasswordsOffer.unanswered() }
        }
    }
    /// The offer's row or its ✕ was clicked: not counted as unanswered.
    private var offerAnswered = false
    /// Where "Use your Apple passwords?" was offered and answered
    /// (ApplePasswordsOffer). A test gives its own.
    var applePasswordsOffer = ApplePasswordsOffer(store: Store.settings)

    struct Suggesting: Equatable {
        let tab: Tab.ID
        var spot: CGRect
        /// Without secrets: one is read only for the account picked.
        let logins: [Kept]
        /// The Mac's passkeys for a page waiting for one under its field.
        var passkeys: [Passkeys.Offered] = []
        /// The page the list was made for: its site, and whether it came in
        /// the clear. A click fills only a page that still is that one.
        let host: String
        let clear: Bool
        /// Hung from a first step's name box: a pick puts in the name alone.
        var nameOnly = false
        /// Accounts from the Mac's Passwords app (ApplePasswords.swift),
        /// names only, and the page host they were asked for. Set when the
        /// helper answers, after the list is up.
        var apple: [AppleLogin] = []
        /// Under a box for a verification code: the accounts the Mac's
        /// Passwords app keeps a code for, without the codes.
        var codes: [AppleCode] = []
        var appleHost: String?
        /// Apple Passwords is on but not paired: a row to connect.
        var appleConnect = false
        /// Apple Passwords is off and Eden keeps nothing for this site: a
        /// quiet row at the bottom offers it, once (ApplePasswordsOffer). The
        /// site it is counted against.
        var appleOffer: String?
        /// When it came up. A page can put the caret in a sign-in box
        /// itself, an invisible one under the pointer included: a click that
        /// was already on its way is not a choice, so the list takes none for
        /// its first half second, as Chrome's does.
        var shown = Date()
        /// Hung from a box that is clearly a sign-in's, with the site's
        /// other hosts' accounts; false: this host's alone.
        var wide = true
        /// Hung from a box for your name, email, phone or address: your
        /// card in Contacts (MeCard), a row per address, email or number.
        var contacts: [MeCard.Offer] = []
        /// For those: the page's number for the box, and the page they were
        /// offered on, which a pick has to find still up, origin and all.
        var box: Int?
        var page: URL?
    }
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    private var pickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    private var lowering: DispatchWorkItem?
    /// The page whose accounts were last looked up for the box the caret is
    /// in. The box reports where it is on every frame of a scroll so the
    /// list can follow it; the keychain is asked once per box, not per frame.
    private var looked: (tab: Tab.ID, host: String, clear: Bool, name: Bool, wide: Bool, code: Bool, fill: Tab.Fill?)?
    /// The sign-in box the caret is in, for a list that changes while it is
    /// there: the page's passkeys arrive when they arrive.
    private var field: (tab: Tab.ID, spot: CGRect, passwords: Bool, name: Bool, code: Bool)?
    /// Counts the boxes Apple Passwords was asked about: an answer for a box
    /// the caret has left since is dropped.
    private var appleAsk = 0

    func keepOffer() {
        guard let offer = offering else { return }
        offering = nil
        let login = offer.login
        guard Vault.save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear) else {
            announce("The keychain refused it", look: .problem)
            return
        }
        relist()
        announce(offer.changed ? "Password updated for \(login.host)" : "Password saved for \(login.host)", look: .done)
    }

    func dropOffer() { offering = nil }

    /// Never for this site. Some sites you sign into on purpose with nothing
    /// you want remembered.
    func neverOffer() {
        guard let offer = offering else { return }
        Vault.never(offer.login.host)
        offering = nil
        announce("Never for \(offer.login.host)")
    }

    /// The caret in a sign-in box: the accounts kept for this site, and the
    /// Mac's passkeys for a page waiting for one, hang from the box, and go
    /// when the caret does. Nothing is filled on its own — the way Safari
    /// does it, and what a person expects.
    private func hang(from tab: Tab, _ spot: CGRect?, passwords: Bool, name: Bool = false, wide: Bool = true, code: Bool = false,
                      fill: Tab.Fill? = nil) {
        guard let spot else {
            if field?.tab == tab.id { field = nil; appleAsk += 1 }
            if looked?.tab == tab.id { looked = nil }
            if pickedInto == tab.id { pickedInto = nil }
            guard suggesting?.tab == tab.id else { return }
            lowering?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, suggesting?.tab == tab.id else { return }
                suggesting = nil
            }
            lowering = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        lowering?.cancel()
        field = (tab.id, spot, passwords, name, code)
        guard tab.id == activeID, pickedInto != tab.id,
              let host = curtain.host(of: tab.pageAddress)
        else { return }
        // A page that came over plain http can have been written by
        // anyone on the way here — a café's network, a hotel's. It is
        // offered only what was kept from plain http too, never an
        // account kept from the https site of the same name.
        let inTheClear = tab.pageAddress?.scheme?.lowercased() == "http"
        // The same box, moved by a scroll: the list up follows it, keeping
        // its accounts and the moment it came up (a click is refused for
        // its first half second, which every frame used to start again);
        // a box with no accounts stays without, and the keychain isn't
        // asked again until the caret leaves.
        if let looked, looked.tab == tab.id, looked.host == host, looked.clear == inTheClear, looked.name == name,
           looked.wide == wide, looked.code == code, looked.fill == fill {
            if var up = suggesting, up.tab == tab.id, up.spot != spot {
                up.spot = spot
                suggesting = up
            }
            return
        }
        looked = (tab.id, host, inTheClear, name, wide, code, fill)
        if code {
            hangCodes(from: tab, spot, host: host, wide: wide)
            return
        }
        // Passwords only for a box that goes with one: a box for passkeys
        // alone has no password to put anywhere. A box that only might be a
        // sign-in's gets this host's own accounts, never the rest of the
        // site's: console.cloud.google.com's project name is not Gmail's.
        var kept = prefs.fillsPasswords && passwords
            ? Vault.kept(matching: host, wide: wide).filter { !inTheClear || $0.clear } : []
        // The account whose name the step before was sent with comes first:
        // the password page of a sign-in that asks for the name first.
        if let given = tab.givenName(),
           let at = kept.firstIndex(where: { $0.user.caseInsensitiveCompare(given) == .orderedSame }) {
            kept.insert(kept.remove(at: at), at: 0)
        }
        let known = Array(kept.prefix(5))
        // A page waiting for a passkey has it under its sign-in's boxes, not
        // under a box for your address.
        let passkeys = fill == nil ? Passkeys.shared.offered(in: tab.built) : []
        // The Mac's Passwords app, when turned on: an https page of an
        // ordinary tab only, asked about by its own host. Paired, its names
        // join the list when the helper answers; not yet, a row offers to
        // connect.
        let appleHost = prefs.applePasswords && prefs.fillsPasswords && passwords
            ? ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) : nil
        let apple = applePasswords
        let connect = appleHost != nil && apple.state == .idle && applePairing?.tab != tab.id
        // Off, and nothing of Eden's own for this site: the offer, once.
        // The row already up under this box stays up while it is there.
        let offer: String? = {
            if let up = suggesting, up.tab == tab.id, let site = up.appleOffer, site == Vault.registrable(host) { return site }
            return applePasswordsOffer.site(
                for: .init(page: tab.pageAddress, privateTab: tab.shy, frameHost: tab.fieldFrameHost,
                           passwords: passwords, kept: known.count),
                .init(appleOn: prefs.applePasswords, fills: prefs.fillsPasswords,
                      helper: ApplePasswordsOffer.benchHelper ?? ApplePasswordsOffer.helperHere,
                      testRun: Store.testing, benchAsks: ApplePasswordsOffer.benchAsks))
        }()
        appleAsk += 1
        // Asked only for the tab in front of you, in the window you are in.
        if let appleHost, apple.state == .paired, tab.built?.window?.isKeyWindow == true {
            lookUpApple(appleHost, in: tab, host: host, name: name, wide: wide)
        }
        // A box for a detail of yours: your card in Contacts, if turned on
        // and allowed.
        let box: Int? = if case .contact(_, let box) = fill { box } else { nil }
        let contacts: [MeCard.Offer] = {
            guard case .contact(let kind, _) = fill, prefs.fillsContacts, MeCard.allowed else { return [] }
            return MeCard.shared.offers(for: kind)
        }()
        guard !known.isEmpty || !passkeys.isEmpty || connect || offer != nil || !contacts.isEmpty else {
            suggesting = nil
            return
        }
        // What is under the pointer changed: the half second starts again.
        if let up = suggesting, up.tab == tab.id, up.logins == known, up.passkeys == passkeys, up.nameOnly == name,
           up.appleConnect == connect, up.apple.isEmpty, up.wide == wide, up.appleOffer == offer,
           up.contacts == contacts, up.box == box,
           up.page == (contacts.isEmpty ? nil : tab.pageAddress) {
            suggesting?.spot = spot
            return
        }
        suggesting = Suggesting(tab: tab.id, spot: spot, logins: known, passkeys: passkeys, host: host, clear: inTheClear,
                                nameOnly: name, appleHost: appleHost, appleConnect: connect, appleOffer: offer, wide: wide,
                                contacts: contacts, box: box, page: contacts.isEmpty ? nil : tab.pageAddress)
        if let offer { applePasswordsOffer.shown(on: offer) }
    }

    /// The caret in a box for a verification code: the accounts the Mac's
    /// Passwords app keeps a code for hang from it, when it is turned on.
    /// Nothing of Eden's own goes in such a box, and the offer to turn it
    /// on stays with sign-in boxes. `wide`: the box says it takes a code, so
    /// the site's other hosts' codes may come, and not paired yet a row offers
    /// to connect. Otherwise it is a guess: this host's codes alone, and no
    /// row of its own for a box that may be something else.
    private func hangCodes(from tab: Tab, _ spot: CGRect, host: String, wide: Bool) {
        appleAsk += 1
        guard prefs.applePasswords, prefs.fillsPasswords,
              let appleHost = ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy)
        else {
            suggesting = nil
            return
        }
        let apple = applePasswords
        // Asked only for the tab in front of you, in the window you are in.
        // A test run has no such window, and no real helper to ask.
        if apple.state == .paired, tab.built?.window?.isKeyWindow == true || Store.testing {
            lookUpCodes(appleHost, in: tab, host: host, wide: wide)
        }
        guard wide, apple.state == .idle, applePairing?.tab != tab.id else {
            suggesting = nil
            return
        }
        suggesting = Suggesting(tab: tab.id, spot: spot, logins: [], host: host, clear: false,
                                appleHost: appleHost, appleConnect: true)
    }

    /// Asks Apple's helper whose codes it keeps for the page, and hangs them
    /// from the box if the caret is still in it, on the same page.
    private func lookUpCodes(_ appleHost: String, in tab: Tab, host: String, wide: Bool) {
        let ask = appleAsk
        Task { [weak self] in
            guard let keeper = self?.applePasswords else { return }
            let found = await keeper.codes(for: appleHost, tab: tab.id) { [weak self] in
                self?.appleAsk == ask
            }
            guard let self, ask == appleAsk, let field, field.tab == tab.id, field.code, tab.id == activeID,
                  ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost
            else { return }
            let codes = Array(found.filter { ApplePasswords.belongs([$0.domain], to: appleHost, wide: wide) }.prefix(5))
            guard !codes.isEmpty else { return }
            suggesting = Suggesting(tab: tab.id, spot: field.spot, logins: [], host: host, clear: false,
                                    codes: codes, appleHost: appleHost, wide: wide)
        }
    }

    /// Asks Apple's helper for the names it keeps for the page, and adds
    /// them under the box if the caret is still in it, on the same page.
    private func lookUpApple(_ appleHost: String, in tab: Tab, host: String, name: Bool, wide: Bool) {
        let ask = appleAsk
        Task { [weak self] in
            // A page that moves the caret from box to box queues no backlog:
            // a question the caret has already left is never sent.
            guard let keeper = self?.applePasswords else { return }
            let found = await keeper.logins(for: appleHost, tab: tab.id) { [weak self] in
                self?.appleAsk == ask
            }
            guard let self, ask == appleAsk, let field, field.tab == tab.id, tab.id == activeID,
                  ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost
            else { return }
            let mine = suggesting?.tab == tab.id ? suggesting?.logins ?? [] : []
            let apple = Array(ApplePasswords.exactFirst(found, to: appleHost, wide: wide)
                .filter { theirs in !mine.contains { $0.user.caseInsensitiveCompare(theirs.user) == .orderedSame } }
                .prefix(5))
            guard !apple.isEmpty else { return }
            if var up = suggesting, up.tab == tab.id {
                up.apple = apple
                up.appleHost = appleHost
                up.appleConnect = false
                // New rows under the pointer: the half second starts again.
                up.shown = Date()
                suggesting = up
            } else {
                suggesting = Suggesting(tab: tab.id, spot: field.spot, logins: [], host: host, clear: false,
                                        nameOnly: name, apple: apple, appleHost: appleHost)
            }
        }
    }

    /// One of the rows from your card in Contacts: its details into the
    /// boxes of the form, if the page is still the one it was offered on.
    /// `alone` (shift held as it was clicked): into the box with the caret
    /// only.
    func choose(_ contact: MeCard.Offer, alone: Bool = false) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }) else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        guard let page = list.page, let origin = Tab.origin(of: page), Tab.origin(of: tab.pageAddress) == origin else { return }
        pickedInto = tab.id
        tab.fillContact(contact.fields, alone: alone, box: list.box, onlyOn: page, flash: !Motion.reduced) { [weak self] worked in
            if !worked { self?.announce("Couldn't find the form's boxes anymore", look: .problem) }
        }
    }

    /// One of the Passwords app's accounts, picked by name. Its password is
    /// asked for now (macOS may want Touch ID), put into the page if it is
    /// still the page it was asked for, and not kept.
    func choose(_ apple: AppleLogin) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }), let appleHost = list.appleHost else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        guard ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost,
              ApplePasswords.belongs(apple.sites, to: appleHost)
        else { return }
        pickedInto = tab.id
        if list.nameOnly {
            tab.fillName(apple.user) { [weak self] worked in
                if !worked { self?.announce("Couldn't find the sign-in fields anymore", look: .problem) }
            }
            return
        }
        Task { [weak self] in
            guard let keeper = self?.applePasswords else { return }
            let found = await keeper.password(for: apple.user, host: appleHost, tab: tab.id)
            guard let self else { return }
            guard let found else {
                announce("Apple Passwords didn't hand that password over", look: .problem)
                return
            }
            // Touch ID can take a while: the page must still be the one
            // asked for, in front, and the account still this site's.
            guard tabs.contains(where: { $0 === tab }), tab.id == activeID,
                  ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost,
                  ApplePasswords.belongs(found.sites, to: appleHost)
            else { return }
            tab.appleFill = AppleFill(host: appleHost, user: apple.user, password: found.password)
            // Over https only, on that host (Tab.fill checks both in the page).
            tab.fill(user: apple.user, password: found.password, onlyOn: URL(string: "https://\(appleHost)/")) { [weak self] worked in
                if !worked { self?.announce("Couldn't find the sign-in fields anymore", look: .problem) }
            }
        }
    }

    /// One of the Passwords app's verification codes, picked by its account.
    /// It is asked for now (macOS may want Touch ID), put into the page if it
    /// is still the page it was asked for, and not kept.
    func choose(_ code: AppleCode) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }), let appleHost = list.appleHost else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        guard ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost,
              ApplePasswords.belongs([code.domain], to: appleHost, wide: list.wide),
              let page = URL(string: "https://\(appleHost)/")
        else { return }
        pickedInto = tab.id
        Task { [weak self] in
            guard let keeper = self?.applePasswords else { return }
            let value = await keeper.code(of: code, host: appleHost, tab: tab.id)
            guard let self else { return }
            guard let value else {
                announce("Apple Passwords didn't hand that code over", look: .problem)
                return
            }
            // Touch ID can take a while: the page must still be the one
            // asked for, and in front.
            guard tabs.contains(where: { $0 === tab }), tab.id == activeID,
                  ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost
            else { return }
            tab.fillCode(value, onlyOn: page) { [weak self] worked in
                if !worked { self?.announce("Couldn't find the box for the code anymore", look: .problem) }
            }
        }
    }

    /// The row that connects Apple Passwords: the pairing starts, and the
    /// code is typed into a small card of Eden's own where the list was,
    /// not in Settings. Once paired, the caret goes back to the box and the
    /// accounts come up under it.
    func connectApplePasswords() {
        lowering?.cancel()
        // The same half second as any row: a click already on its way when
        // a page put the caret in a box isn't a choice.
        guard let list = suggesting, Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        beginApplePairing(on: list.tab, at: list.spot)
    }

    /// "Use your Apple passwords?" clicked: the switch turned on, as in
    /// Settings › Passwords, and the pairing card where the list was. Once
    /// paired, the caret goes back to the box and the accounts come up.
    func useApplePasswords() {
        lowering?.cancel()
        guard let list = suggesting, list.appleOffer != nil, Date().timeIntervalSince(list.shown) > 0.5 else { return }
        offerAnswered = true
        suggesting = nil
        prefs.applePasswords = true
        beginApplePairing(on: list.tab, at: list.spot)
    }

    /// The offer's ✕: "don't offer again", anywhere. The rest of the list
    /// stays.
    func neverOfferApplePasswords() {
        lowering?.cancel()
        guard var list = suggesting, list.appleOffer != nil, Date().timeIntervalSince(list.shown) > 0.5 else { return }
        applePasswordsOffer.dismissed()
        offerAnswered = true
        list.appleOffer = nil
        let empty = list.logins.isEmpty && list.passkeys.isEmpty && list.apple.isEmpty && !list.appleConnect
            && list.contacts.isEmpty
        suggesting = empty ? nil : list
    }

    /// For a test run only: the offer under a box of `tab`, as `hang` puts
    /// it up, `age` seconds ago; or (nil) the list taken down as the caret
    /// leaving takes it.
    func testOffer(on tab: Tab.ID?, site: String = "example.com", age: TimeInterval = 1) {
        guard Store.testing else { return }
        guard let tab else { suggesting = nil; return }
        var list = Suggesting(tab: tab, spot: CGRect(x: 40, y: 120, width: 280, height: 30), logins: [], host: site,
                              clear: false, appleOffer: site)
        list.shown = Date().addingTimeInterval(-age)
        suggesting = list
        applePasswordsOffer.shown(on: site)
    }

    /// Pairing with Apple Passwords from under a sign-in box: the card that
    /// takes the code, over the page it was asked from. Native, never in the
    /// page; the page learns nothing of it.
    @Published private(set) var applePairing: ApplePairing?

    struct ApplePairing: Equatable {
        let tab: Tab.ID
        let spot: CGRect
    }

    /// The Passwords app's connection. One for the whole app; a test gives
    /// its own, with a made-up helper.
    var applePasswords = ApplePasswords.shared
    private var pairingWatch: AnyCancellable?

    func beginApplePairing(on tab: Tab.ID, at spot: CGRect) {
        let apple = applePasswords
        applePairing = ApplePairing(tab: tab, spot: spot)
        pairingWatch = apple.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    if state == .paired { self?.endApplePairing(paired: true) }
                }
            }
        if apple.state == .idle { Task { await apple.connect() } }
    }

    /// The card goes. Paired: the caret back in the page's box, which says
    /// so again (focusin), and its accounts are asked for. Cancelled: the
    /// helper is stopped and its window with it.
    func endApplePairing(paired: Bool) {
        guard let pairing = applePairing else { return }
        applePairing = nil
        pairingWatch = nil
        if !paired, applePasswords.state != .paired { applePasswords.disconnect() }
        // Only the page it was asked from, still in front: never another.
        guard pairing.tab == activeID, let tab = tabs.first(where: { $0.id == pairing.tab }),
              let web = tab.built, let window = web.window
        else { return }
        looked = nil
        pickedInto = nil
        window.makeFirstResponder(web)
    }

    /// One of the accounts in the list, picked by name.
    func choose(_ login: Kept) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }) else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        // The tab may have gone somewhere else while the list was up: a
        // redirect, a script. What was offered for one site is never put
        // into another's page.
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        // A first step: the name alone, the password waits for its page.
        if list.nameOnly {
            tab.fillName(login.user) { [weak self] worked in
                if !worked { self?.announce("Couldn't find the sign-in fields anymore", look: .problem) }
            }
            return
        }
        // Its secret is read now, once it is picked: see `Vault.kept(for:)`.
        guard let login = Vault.login(login) else {
            announce("The keychain refused it", look: .problem)
            return
        }
        tab.fill(user: login.user, password: login.password, onlyOn: tab.pageAddress) { [weak self] worked in
            if !worked { self?.announce("Couldn't find the sign-in fields anymore", look: .problem) }
        }
        Vault.touch(login)
    }

    /// One of the passkeys in the list: the Mac's sheet for it, and the
    /// page's request answered with it.
    func choose(_ passkey: Passkeys.Offered) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }), let web = tab.built else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        Passkeys.shared.sign(in: web, with: passkey.id)
    }

    func dropChoice() { suggesting = nil }

    // The list of what is kept.

    /// Passwords, in a tab. The list is read again each time it is asked for.
    var managing: Bool {
        get { pageTab(.passwords) != nil }
        set { if newValue { show(InternalPage(.passwords)) } else { putAway(.passwords) } }
    }
    /// The list, without secrets: see `Kept` and `Vault.all()`.
    @Published private(set) var saved: [Kept] = []
    @Published var hunting = ""
    /// A Remove All… under way, off the main thread (see `forgetShown`).
    @Published private(set) var forgetting = false

    struct SiteRow {
        let host: String
        let logins: [Kept]
    }

    /// Grouped by site, filtered by what has been typed.
    var shownSites: [SiteRow] {
        let needle = hunting.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = needle.isEmpty ? saved : saved.filter {
            $0.host.contains(needle) || $0.user.lowercased().contains(needle)
        }
        let groups = Dictionary(grouping: rows, by: \.host)
        return groups.keys.sorted().map { host in
            SiteRow(host: host, logins: groups[host]!.sorted { $0.user < $1.user })
        }
    }

    func relist() { saved = Vault.all() }

    func keep(host: String, user: String, password: String) {
        guard Vault.save(host: host, user: user, password: password) else {
            announce("The keychain refused it", look: .problem)
            return
        }
        relist()
        announce("Kept for \(host)", look: .done)
    }

    func forget(_ login: Kept) {
        Vault.forget(host: login.host, user: login.user)
        relist()
    }

    /// The panel's Remove All…, or Remove N… while its search narrows the
    /// list: every account the list shows, out of the keychain, once asked.
    /// Only what is shown, so a search for one site never takes the rest
    /// with it. For moving what is kept to a manager of one's own: all at
    /// once, rather than one Remove at a time (#469). Asked, then proved the
    /// way showing one is, since it can't be undone; Return is Cancel's.
    func forgetShown() {
        let shown = shownSites.flatMap(\.logins)
        guard !shown.isEmpty, !forgetting else { return }
        let count = shown.count
        let many = count == 1 ? "1 password" : "\(count) passwords"
        Ask.sure(
            count == 1 ? "Remove 1 Password?" : "Remove \(count) Passwords?",
            detail: "They're taken out of your keychain. Only the passwords Eden keeps are removed: password managers, other apps and other browsers keep theirs. This can't be undone.",
            confirm: "Remove",
            returnCancels: true
        ) { [weak self] in
            Vault.prove("remove \(many)") { ok in
                guard ok, let self, !self.forgetting else { return }
                // A keychain delete is a few milliseconds, a few hundred of
                // them a second: off the main thread, as imports are (#380).
                self.forgetting = true
                DispatchQueue.global(qos: .userInitiated).async {
                    // Counted as the keychain answers, not as asked: one
                    // it kept is not reported gone.
                    let gone = shown.filter { Vault.forget(host: $0.host, user: $0.user) }.count
                    DispatchQueue.main.async {
                        self.forgetting = false
                        self.relist()
                        let removed = gone == 1 ? "1 password" : "\(gone) passwords"
                        self.announce(gone == count ? "Removed \(removed)"
                            : gone == 0 ? "The keychain refused them"
                            : "Removed \(gone) of \(many)")
                    }
                }
            }
        }
    }

    /// A password copied is asked for the way one shown is. It goes on this
    /// Mac's clipboard only, not to your other devices', marked concealed
    /// and transient, which is what clipboard managers go by to keep it out
    /// of their history, and it is taken off again after a minute and a
    /// half unless something else has been copied since.
    func copy(_ login: Kept) {
        Vault.prove("copy the password for \(login.host)") { [weak self] ok in
            guard ok, let self else { return }
            // Read here, once the Mac has said who this is: what the panel
            // drew its list from holds no secrets.
            guard let password = Vault.secret(of: login) else {
                self.announce("The keychain refused it", look: .problem)
                return
            }
            let board = NSPasteboard.general
            board.prepareForNewContents(with: .currentHostOnly)
            board.setString(password, forType: .string)
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let copied = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                if board.changeCount == copied { board.clearContents() }
            }
            announce("Password copied", look: .done)
        }
    }

    /// What came back from another browser's store, put in the keychain,
    /// with the sites it was told never to ask about. Saving one already
    /// kept updates it, so bringing the same in again adds nothing twice.
    /// Returns how many were kept.
    func keep(_ found: Chromium.Found) -> Int {
        var kept = 0
        for login in found.logins
        where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used, clear: login.clear) {
            kept += 1
        }
        var never = Vault.never
        found.never.forEach { never.insert($0) }
        Vault.never = never
        relist()
        return kept
    }

    /// The same, said as it lands.
    func took(_ outcome: Result<Chromium.Found, Error>, from name: String) {
        switch outcome {
        case .success(let found):
            let kept = keep(found)
            ImportRecords.note(name, passwords: kept)
            let locked = found.undecrypted > 0 ? " (\(found.undecrypted) couldn't be decrypted)" : ""
            announce((kept == 0 ? "Nothing new in \(name)" : "\(kept) passwords from \(name)") + locked)
        case .failure(Chromium.Trouble.noPassphrase):
            announce("\(name) didn't give up its keychain key", look: .problem)
        case .failure(Mozilla.Trouble.primaryPassword):
            announce("\(name) has a primary password — export your passwords from it (Settings › Passwords › ⋯ › Export) and bring in the CSV file")
        case .failure:
            announce("Nothing readable in \(name)", look: .problem)
        }
    }

    /// The other browser's history, into this one's. Off the main thread for
    /// the reading; the merge itself is a moment.
    func takePlaces(from source: ImportSource, profile: String? = nil, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = source.places(profile: profile)
            DispatchQueue.main.async {
                for place in places {
                    self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                }
                self.history.settle()
                ImportRecords.note(source.name, places: places.count)
                done(places.count)
            }
        }
    }

    /// Something another browser exported: a bookmarks page, a passwords
    /// file, or Safari's own export (see ImportFile). Read once, never copied.
    func importFile() {
        guard fileImport == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .commaSeparatedText, .plainText, .zip, .json]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Bring In"
        panel.message = "A file another browser exported: bookmarks (.html), passwords (.csv), or Safari's File › Export Browsing Data (.zip)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { announce((await takeFile(url)).said) }
    }

    /// The file's bookmarks, history and passwords, taken in as a browser's
    /// are: bookmarks as pinned rows in a folder named after the file (or
    /// Safari, for its export), without doubles; history counted once. Says
    /// what came in, and after Safari's export, that the file holds your
    /// passwords in the clear.
    struct FileTake {
        let said: String
        let bookmarks: Int
        let already: Int
        let places: Int
        let kept: Int
        let skipped: Int
        let cancelled: Bool
    }

    @discardableResult
    func takeFile(_ url: URL) async -> FileTake {
        guard !Browser.fileImportTerminating, fileImport == nil else { return FileTake(said: "An import is already running", bookmarks: 0, already: 0, places: 0, kept: 0, skipped: 0, cancelled: false) }
        let id = UUID()
        fileImport = FileImportJob(id: id, filename: url.lastPathComponent, message: "Reading…")
        let control = ImportFile.Control { [weak self] progress in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fileImport?.id == id, self.fileImport?.cancelling == false else { return }
                self.fileImport?.message = progress.message
                self.fileImport?.completed = progress.completed
                self.fileImport?.total = progress.total
            }
        }
        fileImportControl = control
        Browser.activeFileImports[id] = control
        defer {
            Browser.activeFileImports[id] = nil
            if fileImport?.id == id { fileImport = nil; fileImportControl = nil }
        }
        var added = 0, already = 0, places = 0, kept = 0, skipped = 0
        var safari = false
        var failed = false
        var mergedBookmarks = false
        do {
            let found: ImportFile.Found = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try ImportFile.read(url, control: control)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            safari = found.fromSafari
            try control.checkCancellation()
            let name = found.fromSafari ? "Safari" : url.deletingPathExtension().lastPathComponent
            if !found.bookmarks.isEmpty {
                let result = try await mergeBookmarks(found.bookmarks, into: PinShelf.folderName(import: name), control: control)
                mergedBookmarks = true
                added = result.added
                already = result.already
            }
            if !found.places.isEmpty {
                fileImport?.message = "Adding history…"
                fileImport?.completed = 0
                fileImport?.total = found.places.count
                for batch in stride(from: 0, to: found.places.count, by: 200) {
                    guard !control.isCancelled else { break }
                    let end = min(batch + 200, found.places.count)
                    for place in found.places[batch..<end] {
                        history.take(place.url, title: place.title, count: place.count, last: place.last)
                        places += 1
                    }
                    fileImport?.completed = places
                    fileImport?.total = found.places.count
                    await Task.yield()
                }
                if places > 0 { history.settle() }
            }
            if !found.passwords.isEmpty && !control.isCancelled {
                fileImport?.message = "Saving passwords…"
                fileImport?.completed = 0
                fileImport?.total = nil
                for text in found.passwords {
                    guard !control.isCancelled else { break }
                    let result = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: Vault.take(csv: text, control: control))
                        }
                    }
                    kept += result.kept
                    skipped += result.skipped
                }
            }
        } catch {
            failed = !control.isCancelled
        }
        if kept > 0 || skipped > 0 {
            saved = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Vault.all())
                }
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        var parts: [String] = []
        if added > 0 || already > 0 {
            parts.append(already == 0 ? count(added, "bookmark", "bookmarks") : "\(count(added, "new bookmark", "new bookmarks")), \(already) already here")
        }
        if places > 0 { parts.append(count(places, "place", "places")) }
        if kept > 0 || skipped > 0 {
            parts.append(skipped == 0 ? count(kept, "password", "passwords") : "\(count(kept, "password", "passwords")), \(skipped) skipped")
        }
        var said = parts.joined(separator: " · ")
        if control.isCancelled {
            said = said.isEmpty ? (mergedBookmarks ? "Import cancelled after merging bookmarks" : "Import cancelled; nothing was changed") : "Import cancelled after " + said
        }
        else if failed { said = said.isEmpty ? "That file couldn't be read" : "Import stopped after " + said }
        else if said.isEmpty { said = mergedBookmarks ? "Bookmark folders imported" : "Nothing to bring in from that file" }
        if safari, kept > 0 {
            said += " — the exported file holds your passwords in the clear: delete it now"
        }
        return FileTake(said: said, bookmarks: added, already: already, places: places, kept: kept, skipped: skipped, cancelled: control.isCancelled)
    }

    /// A file's bookmarks into the pins, the window drawing all the while:
    /// what comes in is worked out first, changing nothing (PinShelf.planned,
    /// a few milliseconds for fifteen hundred); the tabs for it are made a
    /// batch at a time, in every window showing the space, with the window
    /// free between batches, the count shown and Cancel heard before each
    /// (makeAhead); then it all comes in at once (PinShelf.take), written
    /// once, and each window's row takes up the tabs made for it.
    ///
    /// Cancelled before it comes in, nothing of it has: the tabs made are
    /// dropped, never having been in a row, and no pin, kept group or file
    /// was changed. Once in, it is in whole, in the one kept group named
    /// after the file, and Cancel stops only what follows it. The rows keep
    /// their bookmarks' ids (`keepingIDs`, ids the parse just made), so what
    /// comes in is what was planned, the tabs made for it with it; a page
    /// pinned meanwhile is counted as here already, its tab made for
    /// nothing dropped.
    private func mergeBookmarks(_ nodes: [Bookmark], into folder: String, control: ImportFile.Control) async throws
        -> (added: Int, already: Int) {
        fileImport?.message = "Merging bookmarks…"
        fileImport?.completed = 0
        fileImport?.total = nil
        try control.checkCancellation()
        let shelf = pinShelf
        let coming = shelf.planned(nodes, into: folder, keepingIDs: true)
        let windows = [self] + Browsers.all.filter { $0 !== self }
        let ids = coming.map(\.id)
        defer { for window in windows { window.dropMadeAhead(ids) } }
        fileImport?.total = coming.count
        for start in stride(from: 0, to: coming.count, by: Browser.madeAheadBatch) {
            try control.checkCancellation()
            let batch = coming[start..<min(start + Browser.madeAheadBatch, coming.count)]
            for window in windows { window.makeAhead(batch, space: shelf.space) }
            fileImport?.completed = start + batch.count
            await Task.yield()
        }
        try control.checkCancellation()
        let result = shelf.take(nodes, into: folder, keepingIDs: true)
        return (result.added, result.already)
    }

    /// How many pins' tabs are made between two turns of the window:
    /// about fifteen milliseconds' worth.
    static let madeAheadBatch = 60

    // MARK: - what is kept, and getting rid of it

    enum RecallMode {
        case history, clearing
    }

    // One state keeps closing History from leaving its clearing controls open.
    @Published var recallMode: RecallMode?
    /// History, in a tab.
    var recalling: Bool {
        get { pageTab(.history) != nil }
        set { if newValue { show(InternalPage(.history)) } else { putAway(.history) } }
    }
    /// Downloads, in a tab.
    var hoarding: Bool {
        get { pageTab(.downloads) != nil }
        set { if newValue { show(InternalPage(.downloads)) } else { putAway(.downloads) } }
    }
    /// Downloads as a card floating by its button (see DownloadsFloat).
    @Published var downloadsHanging = false

    /// Downloads, wherever Settings › Downloads › Open Downloads says.
    /// `toggles`: the button, which closes the list or the panel it opened,
    /// as a second press on an extension's button does; ⇧⌘J and the menu
    /// only ever show, as they do the tab.
    func showDownloads(toggles: Bool = false) {
        switch prefs.downloadsOpening {
        case .tab:
            hoarding = true
        case .popover:
            downloadsHanging = toggles ? !downloadsHanging : true
        case .panel:
            toggleDownloadsPanel(closes: toggles)
        }
    }
    @Published var recallHunt = ""

    /// History › Clear Browsing Data…, from the menu, its shortcut, or
    /// ⇧⌘Delete with a page editor focused. The clearing controls are part
    /// of History, so the page comes out first; History opening afresh puts
    /// the mode back to its list (see show), so the mode is set after it is
    /// out, not before (#749).
    func clearBrowsingData() {
        recalling = true
        recallMode = .clearing
    }

    /// Cookies, caches, local storage — everything a site left on this Mac,
    /// in every space. Clearing it signs you out of everything, which is
    /// the point.
    func clearSites() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        // This profile's: another profile is another browser. Their
        // sessions kept for the next launch too (SessionCookies).
        for store in Spaces.stores(of: profileID) {
            SessionCookies.shared.cleared(store)
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Signed out of everything", look: .done)
    }

    /// Only what was fetched to draw pages, not what identifies you.
    func clearCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        for store in Spaces.stores(of: profileID) {
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Cache cleared", look: .done)
    }

    func clearHistory() {
        history.forget()
        // The tabs Eden closed by itself are pages you have been to.
        archive.clear()
        // The sites' icons are a list of where you have been, too, and so
        // are the searches learned from sites visited (SiteSearch.swift).
        Favicons.shared.forgetAll()
        // The pictures of pages kept for their hover cards (PagePictures).
        PagePictures.shared.forgetAll()
        SiteSearch.forget()
        Shared.forgetDownloadAddresses()
        announce("History cleared", look: .done)
    }

    /// The last few places, for the History menu.
    var recentlyVisited: [History.Trace] {
        history.recent()
    }

    // MARK: - the camera and the microphone

    /// A page asking to see or hear you, waiting for an answer. WebKit hands
    /// over a decision handler and holds the page until it is called — so this
    /// keeps the handler and the question together, and never drops either.
    struct CaptureAsk: Equatable, Identifiable {
        let host: String
        let wants: String
        /// Location is also given for this once, and kept only when you say
        /// always; in a private tab it is never kept.
        var once = false
        var keeps = true
        var screen = false
        /// The page also asks for the Mac's own sound with the screen.
        var sound = false
        /// When it came up. A page can time a click to land where Allow is
        /// about to be: the card takes none in its first half second.
        var shown = Date()
        var id: String { host + wants }
    }

    @Published private(set) var asking: CaptureAsk?
    private var decide: ((WKPermissionDecision) -> Void)?
    /// The tab whose card `decide` answers. Leaving it, or it going away,
    /// refuses the card, as the screen's does: Allow must never reach a page
    /// you are no longer looking at.
    private weak var decideTab: Tab?
    /// WebKit's screen-sharing answers: deny (0), screen (1), window (2).
    private var decideDisplay: ((Int) -> Void)?
    private weak var displayTab: Tab?
    private var displayHeld: HeldQuestion?
    private var displayRequest: UUID?
    /// A card on screen. A screen question held for a tab behind has no card
    /// yet, so it keeps out only another screen question, not the camera,
    /// location or notifications on the tab you are on.
    private var permissionBusy: Bool { decide != nil || asking?.screen == true }
    private(set) static var displayAnswered: Int?
    private var askedAbout = ""
    private var askedRevision: UInt?

    func allowCapture() { answerCapture(.grant) }
    func allowCaptureOnce() { answerCapture(.grant, keep: false) }
    func denyCapture() { answerCapture(.deny) }

    func shareScreen() { answerDisplay(1) }
    func shareWindow() { answerDisplay(2) }
    func denyShare() { answerDisplay(0) }

    private func answerDisplay(_ decision: Int) {
        guard decideDisplay != nil, let asking, asking.screen,
              Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        finishDisplay(decision)
    }

    /// A page going away, or going elsewhere: its screen question is refused,
    /// and so is its camera, location or notifications card.
    func cancelDisplay(for webView: WKWebView? = nil) {
        if let webView, decideTab?.built === webView { settleCapture() }
        guard webView == nil || displayTab?.built === webView else { return }
        finishDisplay(0)
    }

    private func finishDisplay(_ decision: Int) {
        guard let reply = decideDisplay else { return }
        decideDisplay = nil
        displayRequest = nil
        if let tab = displayTab, let held = displayHeld {
            heldDialogs[tab.id]?.removeAll { $0 === held }
        }
        displayHeld = nil
        displayTab = nil
        if asking?.screen == true { asking = nil }
        // A test records the choice without ever opening the system picker.
        if Store.testing { Browser.displayAnswered = decision }
        reply(Store.testing ? 0 : decision)
    }

    /// A page or popup going away must settle its permission callback too,
    /// the screen's included.
    func cancelCapture() {
        cancelDisplay()
        settleCapture()
    }

    /// A camera or microphone question up for this page alone, answered no:
    /// a peek gone out of sight, whose question would pass for another tab's.
    func settleCapture(for tab: Tab) {
        if decideTab?.id == tab.id { settleCapture() }
    }

    private func settleCapture() {
        let pending = decide
        decide = nil
        decideTab = nil
        askedAbout = ""
        askedRevision = nil
        asking = nil
        pending?(.deny)
    }

    /// A setting changed while another window was showing this question.
    static func cancelSiteQuestions(keys: Set<String>, including source: Browser) {
        let browsers = Browsers.all + (Browsers.all.contains { $0 === source } ? [] : [source])
        for browser in browsers where !browser.askedAbout.isEmpty && keys.contains("capture." + browser.askedAbout) {
            browser.cancelCapture()
        }
    }

    /// Change a site's saved answer and end matching tabs' active capture.
    func setSitePermission(_ value: Bool?, kind: CaptureChoices.Kind, origin: String) {
        let keys = CaptureChoices.set(value, for: kind, origin: origin)
        Browser.cancelSiteQuestions(keys: keys, including: self)
        if kind == .notifications, value == true { SiteNotifications.shared.authorize() }
        SiteNotifications.shared.objectWillChange.send()
        guard value == false, kind.media else { return }

        let browsers = Browsers.all + (Browsers.all.contains { $0 === self } ? [] : [self])
        let tabs = browsers.flatMap { $0.tabs + $0.parkedTabs + [$0.peekTab].compactMap { $0 } }
            + LittleWindow.all.map(\.tab)
        var visited: Set<ObjectIdentifier> = []
        for tab in tabs where !tab.shy {
            guard let web = tab.built, web.configuration.websiteDataStore.isPersistent,
                  visited.insert(ObjectIdentifier(web)).inserted,
                  let url = web.url, let scheme = url.scheme, let host = url.host(),
                  Browser.origin(scheme, host, url.port ?? 0) == origin else { continue }
            if kind == .camera || kind == .cameraAndMicrophone {
                web.setCameraCaptureState(.none) {}
            }
            if kind == .microphone || kind == .cameraAndMicrophone {
                web.setMicrophoneCaptureState(.none) {}
            }
        }
    }

    private func answerCapture(_ decision: WKPermissionDecision, keep: Bool = true) {
        guard let decide, let asking, Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        if let revision = askedRevision, revision != CaptureChoices.revision(for: "capture." + askedAbout) {
            return cancelCapture()
        }
        var invalidated: Set<String> = []
        // Remembered per site, so a call you take every week asks once.
        if keep, !askedAbout.isEmpty {
            if let split = askedAbout.lastIndex(of: "|"),
               let kind = [CaptureChoices.Kind.camera, .microphone, .cameraAndMicrophone, .location, .notifications]
                   .first(where: { $0.suffix == String(askedAbout[askedAbout.index(after: split)...]) }) {
                let origin = String(askedAbout[..<split])
                if kind == .cameraAndMicrophone, decision == .deny {
                    // A combined request can include a device already allowed.
                    // Refuse only the devices for which this prompt asked.
                    for device: CaptureChoices.Kind in [.camera, .microphone]
                    where CaptureChoices.mediaDecision(device, origin: origin) == nil {
                        invalidated.formUnion(CaptureChoices.set(false, for: device, origin: origin))
                    }
                } else {
                    invalidated.formUnion(CaptureChoices.set(decision == .grant, for: kind, origin: origin))
                }
            } else {
                Store.settings.set(decision == .grant, forKey: "capture." + askedAbout)
            }
        }
        self.decide = nil
        decideTab = nil
        askedAbout = ""
        askedRevision = nil
        self.asking = nil
        Browser.cancelSiteQuestions(keys: invalidated, including: self)
        decide(decision)
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") || key.hasPrefix(Grounded.prefix) {
            Store.settings.removeObject(forKey: key)
        }
        SiteNotifications.shared.objectWillChange.send()
        announce("Camera, microphone, location and notification choices forgotten", look: .done)
    }

    /// What was last answered to a page asking where you are, in a test run
    /// — which never goes on to ask the Mac: that would put macOS's own
    /// question on the screen of whoever is working beside it.
    private(set) static var locationAnswered: String?

    // MARK: - pinning

    /// The pinned tab whose letter is being typed over, in place. There is no
    /// dialog: pinning happens at once, with a letter guessed from the address,
    /// and that letter arrives selected so the next keystroke replaces it.
    @Published var editingPin: Tab.ID?

    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }

    /// The pins drawn as squares: those not kept as rows. They come first
    /// among the pins, so a square's place in the grid is its place in the
    /// row.
    var squarePins: [Tab] { tabs.filter { $0.pin != nil && !$0.listed } }
    /// The pins kept as rows, under the squares (see Tab.listed).
    var listedPins: [Tab] { tabs.filter { $0.pin != nil && $0.listed } }

    /// `listed`: as a row under the squares rather than as a square.
    func pin(_ tab: Tab, listed: Bool = false) {
        // Drawn again even when the tab stays where it is (see unpin).
        objectWillChange.send()
        guard canPin(tab) else { return }
        leaveSplit(tab)
        if tab.pin == nil { makePin(tab, listed: listed) }
        // No dialog and no waiting cursor: the letter is taken from the
        // address and applied. Changing it is a separate act, for the day it
        // matters — which is why it is not folded into this one.
        writeSession(now: true)
    }

    /// Pins are the space's, kept on disk and shown in every window: a
    /// private tab can't be one, or its page would outlive it there.
    func canPin(_ tab: Tab) -> Bool {
        !tab.shy && tab.page == nil
    }

    /// What pinning makes of a tab, with nothing written: out of its open
    /// group (one left empty goes), its letter taken from its address, its
    /// page its home. Pinned tabs live at the head of the row, in the order
    /// they were pinned, so their letters never move under your hand: a
    /// square after the squares, a row after the rows.
    func makePin(_ tab: Tab, listed: Bool) {
        let previousGroup = tab.groupID
        tab.groupID = nil
        removeEmptyGroup(previousGroup)
        tab.pin = tab.monogram
        tab.home = tab.pending ?? tab.address
        tab.listed = listed
        settlePin(tab)
    }

    /// A square made a row, or a row a square: it keeps its letter, its
    /// page and its home, and moves to the nearer end of its new kind (the
    /// top of the rows, or the end of the squares), so it travels no
    /// further than the line between them.
    func setListed(_ tab: Tab, _ listed: Bool) {
        guard tab.pin != nil, tab.listed != listed else { return }
        objectWillChange.send()
        if editingPin == tab.id { editingPin = nil }
        tab.listed = listed
        // A square is in no kept group (see Column.swift).
        if !listed { tab.keptGroupID = nil }
        settlePin(tab, first: listed)
        writeSession(now: true)
    }

    /// A pin put in its place: the squares, then the rows, then everything
    /// else. `first`: at the head of its kind rather than the end.
    private func settlePin(_ tab: Tab, first: Bool = false) {
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        var row = tabs
        row.remove(at: here)
        let squares = row.filter { $0.pin != nil && !$0.listed }.count
        let pins = row.filter { $0.pin != nil }.count
        row.insert(tab, at: tab.listed ? (first ? squares : pins) : squares)
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { tabs = row }
    }

    /// The same tabs in another order, for the column's areas
    /// (BrowserColumn.swift); anything else is turned away.
    func rearrangeTabs(_ row: [Tab]) {
        guard row.count == tabs.count, Set(row.map(\.id)) == Set(tabs.map(\.id)),
              !row.elementsEqual(tabs, by: { $0.id == $1.id }) else { return }
        tabs = row
    }

    /// The squares ahead of the rows, each kind in its own order. Pins
    /// only; everything else is left as it is.
    static func tiered(_ pins: [Tab]) -> [Tab] {
        pins.filter { !$0.listed } + pins.filter(\.listed)
    }

    /// A pin's page, from the session: the one it was pinned at, or — for a
    /// pin from before pins kept theirs — where it was when it came back.
    static func home(of entry: Session.Entry, at url: URL) -> URL? {
        guard entry.pin != nil else { return nil }
        return entry.home.flatMap(URL.init(string:)) ?? url
    }

    /// A double-click on the pin you are on: back to the page it was pinned
    /// at, as a pin in Arc goes home (#141). Already there, or where its home
    /// sent it as it loaded (Tab.isHome), the double-click changes its
    /// letter, as it always did.
    func goHome(_ tab: Tab) {
        guard tab.pin != nil else { return }
        guard tab.wandered, let home = tab.home else { return editLetter(tab) }
        tab.go(to: home)
        rememberSession()
    }

    /// ⌘-click on a pin: if it has wandered from its home address, moves that
    /// tab into the loose tabs and opens a fresh tab for the pin at its home,
    /// or opens a new tab with the pin's address if it is already at home.
    func commandClickPin(_ tab: Tab) {
        guard tab.pin != nil else { return }
        clearTabSelection()
        if editingPin == tab.id { editingPin = nil }

        let home = tab.home ?? tab.address

        if tab.wandered, let home {
            objectWillChange.send()
            let letter = tab.pin
            let pinID = tab.pinID
            let listed = tab.listed
            let everywhere = tab.everywhere
            let wasActive = activeID == tab.id
            guard let pinIndex = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

            // A fresh tab for the pin, at its pinned address.
            let newPin = Tab(configuration: Web.configuration(space: spaceID))
            prepare(newPin)
            newPin.pin = letter
            newPin.home = home
            newPin.pinID = pinID
            newPin.listed = listed
            newPin.everywhere = everywhere
            newPin.keptGroupID = tab.keptGroupID
            newPin.name = tab.name
            newPin.go(to: home)

            // The wandered page becomes a loose tab.
            tab.pin = nil
            tab.listed = false
            tab.keptGroupID = nil
            tab.home = nil
            tab.pinID = nil
            tab.everywhere = false
            tab.name = nil

            tabs.remove(at: pinIndex)
            tabs.insert(newPin, at: pinIndex)
            let unpinnedSlot = min(pinnedCount, tabs.count)
            tabs.insert(tab, at: unpinnedSlot)

            if wasActive {
                leaving()
                activeID = newPin.id
                editing = false
                typed = ""
            }
            writeSession(now: true)
            rememberSession()
        } else if let url = home {
            open(url, foreground: false, from: tab)
        }
    }

    /// Pin menu › Replace Pinned Page with Current URL: where the pin has
    /// wandered becomes the page it goes home to, as Arc's pins can. The
    /// other windows follow through pins.json (see writeSession).
    func rehome(_ tab: Tab) {
        guard tab.pin != nil, let here = tab.address, tab.isWeb,
              !(tab.home.map { Browser.samePage($0, here) } ?? false) else { return }
        objectWillChange.send()
        tab.home = here
        writeSession(now: true)
    }

    /// The same page, give or take a trailing slash.
    static func samePage(_ one: URL, _ other: URL?) -> Bool { PinDef.samePage(one, other) }

    /// Change Letter, or a double-click on the square itself.
    func editLetter(_ tab: Tab) {
        guard tab.pin != nil else { return }
        editingPin = tab.id
    }

    /// Typed into the square. Empty leaves the letter as it was — a pinned tab
    /// with nothing on it would be a blank square you could never identify.
    func letter(_ typed: String, for tab: Tab) {
        guard let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return
        }
        tab.pin = String(first).uppercased()
    }

    func endPinEdit() {
        guard editingPin != nil else { return }
        editingPin = nil
        writeSession(now: true)
    }

    func unpin(_ tab: Tab) {
        if editingPin == tab.id { editingPin = nil }
        // The row is drawn again whether or not the tab moves. Unpinning the
        // only tab, or the last pin, leaves it where it is; `tabs` didn't
        // change, only the tab did, and the column went on drawing it as a
        // pinned square — with no letter left, an empty tile — and never as
        // a row (from X).
        objectWillChange.send()
        if tab.everywhere, let id = tab.pinID {
            // One every space shows: out of them all, as unpinning in one
            // window is out of every window.
            tab.everywhere = false
            Pins.setShared(Pins.shared(profileID).filter { $0.id != id }, from: self)
            for space in Array(parked.keys) { pinsChanged(in: space) }
        }
        release(tab)
        defer { writeSession(now: true) }
        // Back out of the pinned block, to the head of the loose tabs.
        if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
            let home = pinnedCount
            if here != home {
                tabs.move(fromOffsets: IndexSet(integer: here), toOffset: home > here ? home + 1 : home)
            }
        }
        rememberSession()
    }

    /// A pin taken out for good, at once: the × on a pinned row put down,
    /// and Delete in a pin's menu. Unpinned and closed, as Unpin and the
    /// tab's × would, but ⇧⌘T brings it back a pin, where it was, rather
    /// than a tab: taking out a pin loses more than closing a tab.
    func deletePin(_ tab: Tab) {
        guard tab.pin != nil, tabs.contains(where: { $0.id == tab.id }) else { return }
        let slot = tabs.filter { $0.pin != nil && $0.listed == tab.listed }.firstIndex { $0.id == tab.id } ?? 0
        let pin = PinGhost(letter: tab.pin ?? tab.monogram, id: tab.pinID, listed: tab.listed,
                           group: tab.keptGroupID, home: tab.home, homeTitle: tab.homeTitle, name: tab.name,
                           everywhere: tab.everywhere, slot: slot, asleep: tab.asleep)
        unpin(tab)
        close(tab)
        guard let ghost = ghosts.lastIndex(where: { $0.was == tab.id }) else { return }
        ghosts[ghost].pin = pin
    }

    /// What unpinning takes from a tab, with nothing moved or written: its
    /// letter, its home, its row and the kept group it was in, its pin.
    /// Its page, its history and its name stay, and nothing wakes.
    func release(_ tab: Tab) {
        if editingPin == tab.id { editingPin = nil }
        tab.pin = nil
        tab.listed = false
        tab.keptGroupID = nil
        tab.home = nil
        tab.pinID = nil
    }

    // MARK: - carried onto the pins, and off them

    /// Whether a tab carried onto the pins may become one there. Not a
    /// private tab (see pin), and not a pair: pinning one half would undo
    /// the pair under the hand. Pin Tab in the menu still pins the half
    /// it was asked for.
    func pinsByDrag(_ tab: Tab) -> Bool {
        tab.pin == nil && !tab.shy && split(for: tab) == nil && tabs.contains { $0.id == tab.id }
    }

    /// The place a tab let go at `proposed` among the squares (or, with
    /// `listed`, the pinned rows) would really take: past the pins every
    /// space shows, which keep the head of the block (see keepBlocks) — and
    /// a shared pin among them — and never past the end.
    func pinSlot(_ tab: Tab, listed: Bool, proposed: Int) -> Int {
        let tier = tabs.filter { $0.pin != nil && $0.listed == listed && $0.id != tab.id }
        let shared = prefs.showsSharedPins ? tier.prefix(while: \.everywhere).count : 0
        let low = tab.everywhere ? 0 : shared
        let high = tab.everywhere ? shared : tier.count
        return min(max(proposed, low), high)
    }

    /// A tab carried onto the squares and let go there (Arc's drag), the
    /// grid's own drop: pinned as Pin Tab pins it — its page, its web view
    /// and its place in history kept — or a pinned row made a square, as
    /// Show as Square does, then put at `slot` among the squares. The pin
    /// is this space's own, as Pin Tab makes it; with pins in every space
    /// on, it lands after the shared ones. A row is carried into the rows
    /// by the column's own move (move(_:to:)).
    @discardableResult
    func square(_ tab: Tab, at slot: Int) -> Bool {
        if tab.pin == nil {
            guard pinsByDrag(tab) else { return false }
            pin(tab, listed: false)
            guard tab.pin != nil else { return false }
        } else if tab.listed {
            setListed(tab, false)
        }
        let at = pinSlot(tab, listed: false, proposed: slot)
        let pins = tabs.filter { $0.pin != nil }
        var squares = pins.filter { !$0.listed && $0.id != tab.id }
        squares.insert(tab, at: min(at, squares.count))
        let row = squares + pins.filter(\.listed) + tabs.filter { $0.pin == nil }
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { tabs = row }
        writeSession(now: true)
        return true
    }

    // MARK: - the address, in the tab itself

    /// Clicking the tab you are already on turns it into the address, short
    /// form, ready to be changed.
    @Published private(set) var editingTab: Tab.ID?
    @Published var tabDraft = ""
    /// Set while that field is being used to name the tab rather than to go
    /// somewhere: the same field, the same keys, a different thing at the end.
    @Published private(set) var renamingTab = false
    /// What the field in the tab offers as you type, as ⌘L's does (#534),
    /// and the row the arrow keys are on.
    @Published private(set) var tabOffers: [Suggestion] = []
    @Published private(set) var tabPicked: Int?
    /// The address the edit began with: nothing is offered for that.
    private var tabOriginal = ""

    func beginTabEdit(_ tab: Tab) {
        // A tab with no address to show: the field over the page, as ⌘L
        // brings it.
        guard let url = tab.shownURL else {
            edit()
            return
        }
        renamingTab = false
        tabDraft = Address.editable(url)
        tabOriginal = tabDraft
        tabOffers = []
        tabPicked = nil
        editingTab = tab.id
    }

    /// Typed into the field in the tab: its list, and the rest of the
    /// address the field completes to, if any.
    func tabTyped(_ text: String) -> String? {
        tabPicked = nil
        let words = text.trimmingCharacters(in: .whitespaces)
        guard editingTab != nil, !renamingTab, !words.isEmpty, text != tabOriginal else {
            tabOffers = []
            return nil
        }
        let (offers, ending) = placeOffers(for: text)
        tabOffers = offers
        return ending
    }

    /// ↓ and ↑ in the tab's field, off either end and back to what was typed.
    func walkTab(_ step: Int) {
        guard !tabOffers.isEmpty else { return }
        switch tabPicked {
        case nil: tabPicked = step > 0 ? 0 : tabOffers.count - 1
        case let here?:
            let next = here + step
            tabPicked = (next < 0 || next >= tabOffers.count) ? nil : next
        }
    }

    /// A row of the tab's list, clicked or walked to and Return pressed.
    func takeTabOffer(_ offer: Suggestion) {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        cancelTabEdit()
        if let command = offer.command {
            command.run(on: self)
        } else if let open = offer.tab, let other = tabs.first(where: { $0.id == open }) {
            select(other)
        } else {
            tab.go(to: offer.url)
        }
    }

    /// Rename. The name the tab is wearing arrives selected, so typing
    /// replaces it; emptying the field gives the page its own title back.
    /// A square shows no name, only its letter: renaming it is changing
    /// that (editLetter), which the field in a row, never drawn on a
    /// square, left looking as if nothing happened.
    func beginTabRename(_ tab: Tab) {
        if tab.pin != nil, !tab.listed { return editLetter(tab) }
        renamingTab = true
        tabDraft = tab.label
        editingTab = tab.id
    }

    func commitTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            let typed = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.name = typed.isEmpty ? nil : typed
            cancelTabEdit()
            writeSession(now: true)
            return
        }
        if let picked = tabPicked, tabOffers.indices.contains(picked) {
            takeTabOffer(tabOffers[picked])
            return
        }
        guard let url = destination(for: tabDraft) else {
            // Stay put and say so, rather than quietly throwing the edit away.
            refusals += 1
            return
        }
        editingTab = nil
        tabOffers = []
        tabPicked = nil
        tab.go(to: url)
    }

    func cancelTabEdit() {
        editingTab = nil
        renamingTab = false
        tabDraft = ""
        tabOffers = []
        tabPicked = nil
    }

    /// A click somewhere else — the page, the column below, the rest of the
    /// strip — while a tab's address or name is being edited in the tab: what
    /// was typed is kept, as Return keeps it. An address left as it was loads
    /// nothing again, and a field left empty is let go.
    func finishTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            commitTabEdit()
            return
        }
        let draft = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || tab.address.map({ Address.editable($0) == draft }) == true
            || destination(for: draft) == nil {
            cancelTabEdit()
            return
        }
        commitTabEdit()
    }

    // MARK: - saying so

    /// The window's passing messages, at its top (Toasts).
    let toasts = Toasts()
    /// What the toast showing says, for the bench and tests.
    var announcement: String? { toasts.current?.text }
    /// Downloads while they happen (see Fetching.swift).
    let fetches = Shared.fetches

    // MARK: - one set of tab actions

    // The tab's menu, its hover card and the menu bar act through these, so
    // an action reads and does the same wherever it is asked for. Each takes
    // the tabs it acts on and never goes to them: copying, duplicating or
    // muting a tab doesn't wake it or unfold its group.

    /// What an action asked of `tab` acts on: every tab picked in the column
    /// when it is one of several picked, in the column's order, as ⌘W and a
    /// drag take them; else the tab alone.
    func acting(on tab: Tab) -> [Tab] {
        isPickedAmongOthers(tab) ? pickedTabs : [tab]
    }

    /// What the menu bar's tab commands act on: the tab in front, with the
    /// tabs picked alongside it.
    var frontTabs: [Tab] { active.map(acting(on:)) ?? [] }

    /// ⌘⇧C. The address, in the clipboard, and a line that says as much.
    func copyAddress() { copyAddresses(of: frontTabs) }

    /// The tabs' addresses, a line each.
    /// `quietly`: nothing said, where what was pressed says it (a hover
    /// card's tick).
    func copyAddresses(of tabs: [Tab], quietly: Bool = false) {
        copy(addresses: tabs.compactMap { $0.address?.absoluteString }, quietly: quietly)
    }

    /// Addresses into the clipboard, a line each, and said so unless
    /// `quietly`: a tab's, or a page's open on another device (Elsewhere).
    func copy(addresses: [String], quietly: Bool = false) {
        guard !addresses.isEmpty else { return }
        paste(addresses)
        guard !quietly else { return }
        announce(addresses.count == 1 ? "Address copied" : "\(addresses.count) addresses copied", look: .done)
    }

    /// ⌥⇧⌘C. The address without its tracking parameters (CleanLink).
    func copyCleanLink() { copyCleanLinks(of: frontTabs) }

    func copyCleanLinks(of tabs: [Tab]) {
        let links = tabs.compactMap { $0.address.map { CleanLink.clean($0).absoluteString } }
        guard !links.isEmpty else { return }
        paste(links)
        announce(links.count == 1 ? "Link copied" : "\(links.count) links copied", look: .done)
    }

    /// For pasting into notes and messages that read Markdown: a title that
    /// links, not a bare address to explain in your own words.
    func copyMarkdownLink() { copyMarkdownLinks(of: frontTabs) }

    func copyMarkdownLinks(of tabs: [Tab]) {
        let links = tabs.compactMap { tab in tab.address.map { Browser.markdownLink(tab.label, $0) } }
        guard !links.isEmpty else { return }
        paste(links)
        announce(links.count == 1 ? "Link copied" : "\(links.count) links copied", look: .done)
    }

    /// Lines of text into the clipboard, in place of what was there.
    private func paste(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Duplicate: the same page beside each tab. One comes to the front, as
    /// ⌘D once did; several open behind, each beside its own, so the page
    /// you are on stays in front.
    func duplicate(_ tabs: [Tab]) {
        let pages = tabs.compactMap { tab in tab.address.map { (url: $0, tab: tab) } }
        for page in pages { open(page.url, foreground: pages.count == 1, from: page.tab) }
    }

    /// Mute Tab, or Unmute Tab when `tab` is muted: `tab` and the tabs
    /// picked with it all one way, as the menu said, not each turned over.
    func toggleMute(_ tab: Tab) {
        mute(acting(on: tab), !tab.muted)
    }

    /// The tabs all muted, or all unmuted: a tab's menu's picked tabs, or a
    /// hover card's one tab.
    func mute(_ tabs: [Tab], _ on: Bool) {
        for each in tabs where each.muted != on { each.toggleMute() }
    }

    /// ⇧⌘M: Mute Tab or Unmute Tab, for the tab in front.
    func toggleMute() {
        guard let tab = active else { return }
        toggleMute(tab)
    }

    /// Reload, from a tab's menu: each page loaded again where it stands. A
    /// tab asleep stays asleep, its page loaded when it is gone to.
    func reload(_ tabs: [Tab]) {
        for tab in tabs where tab.built != nil { tab.reload() }
    }

    /// Put to Sleep: each page let go of now, as it would be after half an
    /// hour unseen. Not one on screen, nor one that has to stay awake (#310):
    /// for a tab alone, why not is said.
    func sleep(_ tabs: [Tab]) {
        let alone = tabs.count == 1
        for tab in tabs {
            sleep(tab) { [weak self] outcome in
                if alone, outcome != "asleep" { self?.announce("Stays awake: \(outcome)") }
            }
        }
    }

    /// Pin, or Pin as Row: each of the tabs that can be, in the column's
    /// order. Not a private tab, nor one without a page.
    func pin(_ tabs: [Tab], listed: Bool) {
        for tab in tabs where tab.pin == nil && tab.isWeb && !tab.shy { pin(tab, listed: listed) }
    }

    /// Unpin: each pin among the tabs.
    func unpin(_ tabs: [Tab]) {
        for tab in tabs where tab.pin != nil { unpin(tab) }
    }

    /// Those of `tabs` Move to Space can take: not a script's tab, nor an
    /// extension's page, nor a pin every space shows, which is in every
    /// space already. Moved, it left the shared pins as this window wrote
    /// them next, without it, and every space closed its copy.
    func movableToSpace(_ tabs: [Tab]) -> [Tab] {
        tabs.filter { tab in
            self.tabs.contains { $0.id == tab.id } && !tab.bench && !(tab.pin != nil && tab.everywhere)
                && tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil
        }
    }

    /// Move to Space: the tabs that can go, together, as Move to Space
    /// takes one and Move Group to Space a group: a space with other
    /// sign-ins asks first only when a page has unsaved form entries, once
    /// for them all. Every one is there before `then`, for New Space… to go
    /// after them. Moved one by one, a sleeping tab, with no page to ask,
    /// went at once and took you to the new space, and a page still being
    /// asked found its space gone from under it and stayed behind.
    func move(_ tabs: [Tab], toSpace id: UUID, then: (() -> Void)? = nil) {
        guard tabs.count > 1 else {
            if let tab = tabs.first { move(tab, toSpace: id, then: then) }
            return
        }
        guard prefs.usesSpaces, id != spaceID, let destination = spaces.first(where: { $0.id == id }) else { return }
        let going = movableToSpace(tabs)
        guard !going.isEmpty else { return }
        let from = spaceID
        let complete: () -> Void = { [weak self] in
            guard let self, self.spaceID == from else { return }
            let here = going.filter { tab in self.tabs.contains { $0.id == tab.id } }
            guard !here.isEmpty else { return }
            self.stepAside(from: here)
            for tab in here { self.finishMove(tab, toSpace: id, quietly: true) }
            self.writeSession(now: true)
            if let row = self.parked[id] { self.writeSession(now: true, space: id, row: row) }
            self.announce("Moved to \(destination.name)", look: .done)
            then?()
        }
        let store = Spaces.store(for: id)
        let asking = going.filter { !$0.shy && $0.store !== store }
        guard !asking.isEmpty else { return complete() }
        // Any page with something typed and not sent, asked once.
        var unsaved = false
        let asked = DispatchGroup()
        for tab in asking {
            asked.enter()
            tab.unsaved { if $0 { unsaved = true }; asked.leave() }
        }
        asked.notify(queue: .main) {
            guard unsaved else { return complete() }
            Ask.sure(
                "Move Tabs?",
                detail: "A page among them has unsaved form entries. They will reopen in “\(destination.name)” with that Space’s sign-ins, so the entries may be lost.",
                confirm: "Move",
                then: complete
            )
        }
    }

    /// Whether Move to Window can take the tabs anywhere: not pins, and not
    /// every tab this window has.
    func canMoveToWindow(_ tabs: [Tab]) -> Bool {
        let going = tabs.filter { $0.pin == nil && !$0.bench }
        guard !going.isEmpty else { return false }
        return going.count > 1 ? going.count < self.tabs.count : self.tabs.count > 1
    }

    /// A page as a Markdown link, its title the text. A backslash first, so
    /// the ones added next aren't doubled; then both brackets, either of
    /// which would end or break the link's text.
    static func markdownLink(_ title: String, _ url: URL) -> String {
        let text = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(text)](\(url.absoluteString))"
    }

    /// A toast at the top of the window (Toasts): `look` what it tells, done
    /// or gone wrong; `symbol` before a note; `action` the one thing it
    /// offers, Undo; a file just saved, shown in the Finder from
    /// it; `key` for one that changes where it stands, as the zoom does.
    func announce(_ text: String, look: Toast.Look = .note, symbol: String? = nil, action: Toast.Action? = nil,
                  file: URL? = nil, key: String? = nil) {
        let show = file.map { file in
            Toast.Action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        toasts.show(Toast(text, look: look, symbol: symbol, action: action ?? show, key: key))
    }

    /// The names extensions asked their downloads to be saved under.
    var namedDownloads: [URL: String] = [:]

    /// Tabs you closed, newest last, so ⌘⇧T can put them back where they were
    /// and the History menu can offer them by name.
    @Published private(set) var ghosts: [Ghost] = []

    /// Groups closed with Close Group, kept while a tab they held can still
    /// come back with ⌘⇧T: the first one back brings its group back too,
    /// named as it was and where it was among the others.
    private var closedGroups: [UUID: (group: TabGroup, at: Int)] = [:]

    enum CloseKind {
        case clear, group, tabs
    }

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        /// Whether the title was the page's own words (Tab.titleIsOwn).
        var titleIsOwn = false
        /// Its place in the row as it closed; moved on one by Clear when
        /// the empty tab it leaves comes in before it (see clear).
        var index: Int
        let groupID: UUID?
        /// When it was closed, to weigh against a window closed since.
        var at = Date()
        /// The other page of the pair it was in, and whether it was on that
        /// page's left: ⇧⌘T puts it back beside it, while that page is alone.
        var partner: Tab.ID? = nil
        var onLeft = false
        /// The tab it was, so a pair closed together finds its other half
        /// again when both come back (see reopen(batch:)).
        var was: Tab.ID? = nil
        /// The space it was closed in, for your other devices (Sync).
        var space: UUID? = nil
        /// The bulk close it went with: one ⇧⌘T brings back the whole of it.
        var batch: UUID? = nil
        var kind: CloseKind = .clear
        /// The tab you were on, which comes back in front.
        var front = false
        /// Silenced by hand when it closed, so it comes back the same way.
        var muted = false
        /// The page's own history when it closed (Tab.keepsake): ⇧⌘T puts
        /// it back with Back, Forward and where it was scrolled to, as Safari
        /// and Chrome do. Held only here, gone with the ghost.
        var keepsake: Keepsake? = nil
        /// The pin it was, taken out for good (deletePin): ⇧⌘T brings it
        /// back a pin.
        var pin: PinGhost? = nil

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    /// What a pin taken out for good was, for ⇧⌘T to make it again: its
    /// letter and its id, square or row, the folder it was in, its page and
    /// the title kept for it (Pins.retitle), its name, whether every space
    /// showed it, its place among the pins of its kind, and whether it was
    /// asleep.
    struct PinGhost: Equatable {
        let letter: String
        let id: UUID?
        let listed: Bool
        let group: UUID?
        let home: URL?
        let homeTitle: String
        let name: String?
        let everywhere: Bool
        let slot: Int
        let asleep: Bool
    }

    /// WebKit's interactionState is opaque; boxed so a Ghost still compares.
    struct Keepsake: Equatable {
        let state: Any
        static func == (a: Keepsake, b: Keepsake) -> Bool { (a.state as AnyObject) === (b.state as AnyObject) }
    }

    /// The bulk close under way, whose tabs are remembered
    /// together (see closingTogether).
    private var batching: (id: UUID, kind: CloseKind)?

    private var bag = Set<AnyCancellable>()
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    var dozing: Timer?
    var pressure: DispatchSourceMemoryPressure?
    /// Downloads still under way. See `keep(_:)`.
    var downloading: [WKDownload] = []
    /// alert(), confirm() and prompt() from tabs that weren't in front,
    /// waiting for them to be (see Dialogs.swift).
    var heldDialogs: [Tab.ID: [HeldQuestion]] = [:]
    /// Questions asked by a page of the pair on screen, each drawn over its
    /// own page, oldest first (see Dialogs.swift).
    @Published var paneQuestions: [PaneQuestion] = []
    /// What handOff decided, in a test run, for the bench.
    static var handedOff: [String] = []
    /// Downloads from private tabs, which the Downloads list never shows.
    var unlisted: Set<ObjectIdentifier> = []
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    var storeWatch: AnyCancellable?
    private var zoomShown = 100
    private var remembering = false
    /// Spaces (see Spaces.swift): every one, the one on screen, and the
    /// rows of tabs of the others.
    /// The window's profile's spaces only: another profile's never show
    /// here (see Profiles.swift).
    @Published var spaces: [Space]
    /// The profile this window is in, for its whole life: its spaces, its
    /// sign-ins, its history.
    let profileID: UUID
    @Published var spaceID = Space.firstID
    var parked: [UUID: Parked] = [:]
    /// How far the column's rows have followed two fingers sideways, and
    /// whether the card for a new space stands in for them (see SpaceSwipe).
    /// The distance changes with every event of the swipe, so it is kept
    /// apart, for the views that move with it alone (SwipeShift): published
    /// here, each event drew the whole window again, every row and the menu
    /// bar with it. The window hears only which way it goes, which is what
    /// decides whether a neighbour's rows are drawn.
    let spaceSwipeOffset = SwipeOffset()
    @Published private(set) var spaceSwipeSide = 0
    var spaceSwipe: CGFloat {
        get { spaceSwipeOffset.value }
        set {
            spaceSwipeOffset.value = newValue
            let side = newValue > 0 ? 1 : newValue < 0 ? -1 : 0
            if side != spaceSwipeSide { spaceSwipeSide = side }
        }
    }
    @Published var makingSpace = false
    /// A tab being sent into the Space being made from its context menu.
    var afterSpaceCreated: ((Space) -> Void)?
    /// A link's page, peeked at over this one (see Peek.swift).
    @Published var peekTab: Tab?
    /// The tab the peek was opened from: a pin wears the peek's icon while
    /// it is up (see PeekBadge).
    @Published var peekFrom: UUID?
    /// Which way the last change of space went: 1 to the next, -1 back.
    @Published var spaceStep = 1

    // MARK: - beginning and ending

    /// In SwiftUI's own window rather than one made for it (see Windows.swift).
    var inScene = false
    /// Where the column is in the window, in SwiftUI's top-left points, as
    /// last laid out: the tabs' hover cards stand beside it (TabHoverCard).
    /// Not published: nothing is drawn from it.
    var columnFrame: CGRect = .zero
    /// Its window, once it has one.
    weak var window: NSWindow? {
        didSet { if window != nil { shut = false } }
    }
    /// Its window closed and kept: the last one, closed with the app running.
    /// Its tabs sleep meanwhile (see sleepShut); back, the ones it shows wake.
    var shut = false {
        didSet { if oldValue, !shut { wakeShown() } }
    }
    /// Out of sight behind another profile's window that has taken its
    /// place, with profiles in one window (see OneWindow.swift): kept as it
    /// is, its pages loaded, until a space of its profile is chosen again.
    var tucked = false
    /// The merged window it is one of, with profiles in one window: the
    /// windows of different profiles that take turns in one place.
    var mergeID: UUID?
    /// Its window closed for good, with others open (see closeAll): it
    /// writes nothing from here on. A write still waiting (rememberSession)
    /// found its row empty, and told every other window it had no pins.
    private(set) var retired = false
    /// Its window is there to be seen — on screen, or behind a hidden app.
    /// Not one tucked behind another profile's.
    var isOpen: Bool { window != nil && !shut && !tucked }
    /// Its window fills the screen. macOS takes the window's buttons away
    /// then, so the room kept for them at the top goes too (idea 184).
    @Published var fullScreen = false
    /// The page as a card on the window's ground, the one switch for it
    /// (see CardEdge): unless Settings › Tabs › The page as a card is off,
    /// and never with the window filling the screen, where the page goes
    /// edge to edge (#607). A page's own video filling the screen is the
    /// window's to add (see ContentView.cards).
    var asCards: Bool { prefs.cards && !fullScreen }
    /// The extension a popup window was opened for (windows.create with
    /// type "popup"), or nil for a browser window. Such a window is small,
    /// the page under a thin line with its site; it is never saved, never
    /// brought back, and never the window menus act on (see Windows.swift).
    var extensionPopup: String?
    /// A sized website pop-up, kept separately from an extension's identity.
    let websitePopup: Bool
    var isPopup: Bool { websitePopup || extensionPopup != nil }
    /// Its saved state, for a window other than the oldest (see Windows.swift).
    var record = WindowRecord()
    /// Whether its rows are the session files' — the oldest window's — or
    /// its own line in windows.json.
    private(set) var usesFiles = false
    /// The first browser does what is done once for the app.
    private static var booted = false

    /// The first window: yesterday's tabs, from the session files.
    override convenience init() { self.init(record: nil) }

    /// `record`: another window's, from windows.json or ⇧⌘T, or a new
    /// window's, empty.
    init(record: WindowRecord?, websitePopup: Bool = false) {
        self.websitePopup = websitePopup
        // The profile of the space the window shows: the one it was in, or
        // the space the app was last in, for the first window.
        let shown = record?.space ?? Store.settings.string(forKey: "space.current").flatMap(UUID.init) ?? Space.firstID
        let profile = Spaces.profile(of: shown)
        profileID = profile
        let loaded = Spaces.read(profile: profile)
        spaces = loaded
        history = Profiles.history(profile)
        // With spaces off, the window is the profile's home: the session and
        // the store that were there before spaces, wherever its dot has been
        // moved to. With them on, the last space is chosen below.
        spaceID = prefs.usesSpaces
            ? loaded.first?.id ?? Space.firstID
            : (profile == Profile.personalID ? Space.firstID : Profiles.shared.profile(profile).home)
        super.init()
        let first = !Browser.booted
        Browser.booted = true
        // The session files of a profile are its oldest window's: the first
        // window's, and a window of a profile no open window is in.
        // A pop-up window never holds a profile's session files.
        usesFiles = !websitePopup && (record == nil || !Browsers.all.contains { $0.profileID == profile && $0.usesFiles && !$0.isPopup })
        if first {
            Shield.shared.enabled = prefs.shielded
            Shield.shared.compile()
            if #available(macOS 15.4, *) { Extensions.shared.start(for: self) }
            if prefs.bench {
                Bench.shared.start(for: self)
            } else if prefs.benchRefused {
                announce("“Let a script drive Eden” was turned on outside Settings, and stays off")
            }
            welcoming = !prefs.welcomed
            newsShowing = WhatsNew.due(prefs: prefs, welcoming: welcoming)
            // Once a day, quietly: is there a newer one?
            Updater.shared.checkIfDue { [weak self] line in self?.announce(line) }
            // With your other devices through iCloud, if that is on (see Sync.swift).
            Sync.shared.start()
            // An icon that arrives is looked for again by every tab showing
            // that site, in every window, not only the one that asked for it:
            // each puts on its own page's, or its nearest neighbour's. A pin
            // away from a home on that site puts on its home's too.
            Favicons.shared.arrived = { site in
                let lower = site.lowercased()
                func on(_ url: URL?) -> Bool {
                    guard let host = url.flatMap(Favicons.site) else { return false }
                    return host == lower || host == "www." + lower || lower == "www." + host
                }
                for browser in Browsers.all {
                    for tab in browser.tabs + browser.parkedTabs {
                        if on(tab.address) { tab.adoptIcon() }
                        if tab.pin != nil, on(tab.home) { tab.adoptHomeIcon() }
                    }
                }
            }
            // What a deleted space left behind, if WebKit wouldn't let it go then.
            Spaces.sweep()
        }
        // Asked to stay out of the way: it starts that way (see Fold.swift).
        folded = prefs.sideHides

        // The History menu lists the last few places, and the menu is drawn
        // from this object's changes — so a change to those is passed on.
        history.recentChanges
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // A page's passkeys for under its field, arriving while the caret
        // is already there, or going with the page's request.
        NotificationCenter.default.publisher(for: Passkeys.offeredChanged)
            .sink { [weak self] note in
                guard let self, let web = note.object as? WKWebView, let field, let tab = tab(for: web),
                      tab.id == field.tab
                else { return }
                looked = nil
                hang(from: tab, field.spot, passwords: field.passwords, name: field.name, code: field.code)
            }
            .store(in: &bag)

        // So are the pins.
        NotificationCenter.default.publisher(for: Pins.changed)
            .sink { [weak self] note in
                guard let self, !isPopup, (note.object as? Browser) !== self else { return }
                if note.userInfo?["shared"] as? Bool == true {
                    // Another profile's are nothing to this window.
                    guard (note.userInfo?["profile"] as? UUID) == profileID else { return }
                    return sharedPinsChanged()
                }
                guard let space = note.userInfo?["space"] as? UUID else { return }
                pinsChanged(in: space)
            }
            .store(in: &bag)

        // This profile's bookmarks as sync leaves them: any this Mac hasn't
        // brought into its pins yet come over (PinShelf.bringBookmarks). A
        // turn later, not in the middle of sync putting its items in place.
        NotificationCenter.default.publisher(for: Bookmarks.saved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, !isPopup, !retired, (note.object as? Bookmarks) === Profiles.bookmarks(profileID) else { return }
                PinShelf.bringBookmarks(into: self)
            }
            .store(in: &bag)

        // The spaces are every window's: one renamed, added or taken away in
        // another window is so here too.
        NotificationCenter.default.publisher(for: Spaces.changed)
            .sink { [weak self] note in
                guard let self, let all = note.object as? [Space] else { return }
                if websitePopup {
                    if !all.contains(where: { $0.id == self.spaceID }) { window?.close() }
                    return
                }
                guard !isPopup else { return }
                // This profile's alone, in the order the user arranged them.
                let list = Spaces.read(profile: profileID)
                guard list != spaces, !list.isEmpty, all.contains(where: { $0.id == list[0].id }) else { return }
                spaces = list
                if !list.contains(where: { $0.id == self.spaceID }) { enter(list[0].id) }
            }
            .store(in: &bag)

        // Yesterday's tabs, or nothing in front. The tab in front, if there
        // is one, builds its web view now, which starts a content process
        // while the window is still being drawn.
        defer {
            follow()
            if !isPopup { watchForSleep() }
            // Before the first frame: tabs whose time ran out while Eden
            // was quit are gone, rather than drawn and taken away a minute on.
            if !isPopup { closeLeftAlone() }
        }

        if let record {
            // Another window: the space it showed, and its own rows.
            self.record = record
            if prefs.usesSpaces || websitePopup, spaces.contains(where: { $0.id == record.space }) { spaceID = record.space }
            // The first window of its profile this run: its rows, if it
            // brought any (⇧⌘T, last launch's windows.json), are the
            // profile's session files from now on; a new one reads them.
            if usesFiles {
                for (key, row) in record.rows {
                    guard let space = UUID(uuidString: key), spaces.contains(where: { $0.id == space }) else { continue }
                    Session.write(now: true, space: space, row)
                }
                self.record.rows = [:]
            }
        } else if prefs.usesSpaces, spaces.contains(where: { $0.id == shown }) {
            // The space you were in, when there are spaces (see Spaces.swift).
            spaceID = shown
        }
        if record == nil { Spaces.current = spaceID }
        // A website pop-up holds only the page WebKit hands over: no pins,
        // restored tabs or warm pages from other spaces.
        guard !websitePopup else { return }
        restoreSession()
        // The bookmarks this profile had, as pinned rows, once (#6).
        PinShelf.bringBookmarks(into: self)
        // After the first frame, a space a turn: the other spaces' rows are
        // only for a swipe to show beside this one, and made here, every tab
        // of every space was made before the window could draw (see
        // preloadSpaces).
        if prefs.usesSpaces { Links.onceShown { [weak self] in self?.preloadSpaces(gradually: true) } }
    }

    /// The floating video's buttons answer the window whose video it is:
    /// set as it comes out of one (see lift).
    private func ownFloater() {
        floater.onReturn = { [weak self] in
            guard let self else { return }
            // The window closes first, and unconditionally. Hanging that on
            // finding the tab again is how a little window survives the button
            // meant to dismiss it.
            let came = self.floating
            self.land()
            if let came {
                if let space = self.parked.first(where: { $0.value.tabs.contains { $0.id == came } })?.key {
                    self.switchSpace(to: space)
                }
                if let tab = self.tabs.first(where: { $0.id == came }) { self.select(tab) }
            }
            // Never a test run's: a probe started hidden stays off every screen.
            guard !Store.testing else { return }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.contentView != nil }?.makeKeyAndOrderFront(nil)
        }
        floater.onSkip = { [weak self] seconds in
            guard let self, let id = self.floating,
                  let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == id })
            else { return }
            tab.web.evaluateInSearch(Isolate.skip(seconds))
        }
        floater.onProgress = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == id })
            else { return }
            tab.web.evaluateInSearch(Isolate.where_) { found in
                MainActor.assumeIsolated {
                    guard let pair = found as? [Any], pair.count == 2,
                          let through = pair[0] as? Double,
                          let playing = pair[1] as? Bool
                    else { return }
                    answer(through, playing)
                }
            }
        }
        floater.onPlayPause = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = (self.tabs + self.parkedTabs).first(where: { $0.id == id })
            else { return }
            tab.web.evaluateInSearch(Isolate.toggle) { playing in
                MainActor.assumeIsolated { answer((playing as? Bool) ?? true) }
            }
        }
        floater.onClose = { [weak self] in self?.land() }
    }

    /// The row of tabs the space on screen had last time, or nothing.
    /// The pins are every window's (see Pins.swift): a window new to this
    /// space has them too, with nothing in front.
    func restoreSession() {
        let saved = readRow(spaceID)
        tabGroups = (saved.groups ?? []).filter { group in
            saved.tabs.contains { $0.groupID == group.id }
        }
        let restored = restoreRow(saved, space: spaceID, groups: tabGroups)
        splits = restored.splits
        tabs += restored.tabs
        // No tab in front — left so, or a fresh start (see
        // Session.startFresh), or a window new to the space — stays so:
        // nothing in front, beside the pins, and no empty tab made for it.
        let front = saved.tabs.isEmpty || saved.active < 0 ? nil
            : restored.active.flatMap { id in tabs.first { $0.id == id } } ?? tabs.first { $0.pin == nil } ?? tabs.first
        guard let first = front else {
            activeID = nil
            return
        }
        activeID = first.id
        // Only the one you were looking at actually loads. Started hidden,
        // it waits for the extensions, which load at once then, so that
        // their scripts meant to run before the page's do (#199); a
        // visible launch keeps loading it alongside the first frame.
        if #available(macOS 15.4, *), NSApp.isHidden, Extensions.shared.starting {
            Extensions.shared.whenStarted(within: 1.5) { [weak self] in
                guard let self else { return }
                for tab in self.tabs where self.visibleTabIDs.contains(tab.id) { _ = tab.wake() }
            }
        } else {
            for tab in tabs where visibleTabIDs.contains(tab.id) { _ = tab.wake() }
        }
    }

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private func follow() {
        followStore()
        // Spaces turned off: back to the first, whose tabs are the ones there
        // were before (see Spaces.swift).
        prefs.$usesSpaces
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if websitePopup {
                    if !on, spaceID != Space.firstID { window?.close() }
                    return
                }
                guard !isPopup else { return }
                if on { preloadSpaces() } else { leaveSpaces() }
            }
            .store(in: &bag)
        // Pins in every space, or Spaces, switched: every row takes the
        // shared pins or lets them go. Received on the next turn of the run
        // loop, once the setting has changed, so the rows are built from
        // what it is now.
        prefs.$sharesPins.dropFirst().map { _ in () }
            .merge(with: prefs.$usesSpaces.dropFirst().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.sharedPinsChanged() }
            .store(in: &bag)
        // Peek stays with its tab turned off: a peek hidden behind another
        // tab goes at once, as that tab would have put it away. Left, it
        // would come back over whatever tab is in front.
        prefs.$peekStays
            .dropFirst()
            .sink { [weak self] on in
                guard let self, !on, let from = peekFrom, !visibleTabIDs.contains(from) else { return }
                closePeek()
            }
            .store(in: &bag)
        // What is on screen, read once the setting has changed: a peek
        // hidden or shown by it plays or waits (see followPeek).
        prefs.$peekStays.dropFirst().map { _ in () }
            .merge(with: prefs.$splitView.dropFirst().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.followPeek() }
            .store(in: &bag)
        prefs.$usesTabGroups
            .dropFirst()
            .sink { [weak self] on in
                guard let self, on else { return }
                // Sent before the setting changes, so it is passed on.
                arrangeGroupedTabs(on)
                writeSession(now: true)
            }
            .store(in: &bag)
        prefs.$splitView
            .dropFirst()
            .sink { [weak self] on in
                // Off, the pairs stay, as groups do; back on, the ones that
                // came apart meanwhile go. The others' files are looked at
                // when their spaces come back (see restoreRow).
                guard let self else { return }
                // Off, no page is drawn over on its own: what a page asked
                // is answered as dismissed rather than left unanswered.
                guard on else { return dropQuestions() }
                splits = splits.filter { Browser.holds($0, in: self.tabs) }
                for key in parked.keys {
                    if let row = parked[key] { parked[key]?.splits = row.splits.filter { Browser.holds($0, in: row.tabs) } }
                }
                writeSession(now: true)
            }
            .store(in: &bag)
        prefs.$shielded
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                Shield.shared.enabled = on
                Shield.shared.apply(to: tabs.compactMap { $0.built?.configuration.userContentController })
                announce(on ? "Ads and trackers blocked" : "Blocking off — reload to see the difference")
            }
            .store(in: &bag)

        // The look changes — from Settings, or from the Mac while set to
        // System — and the icons a site keeps for each scheme change with it.
        // A beat after, so the appearance has actually turned over.
        prefs.$look
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.look == .system else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)

        prefs.$bench
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                announce(on ? "Scripts can drive Eden — see ./bench" : "The bench is closed")
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now: the form
        // script looks at boxes for your card only with this on.
        prefs.$fillsContacts
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateInSearch(FormRelay.contacts(on))
                }
                if on { Task { await MeCard.shared.reload() } }
            }
            .store(in: &bag)
        // Your card read ahead, so the first box you click has it.
        if prefs.fillsContacts { Task { await MeCard.shared.reload() } }

        // Every tab's next page, and the page each is showing now (see AutoScroll.swift).
        prefs.$autoScroll
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateInSearch(on ? AutoScroll.script : AutoScroll.off)
                }
            }
            .store(in: &bag)

        // Dark pages (see Dusk.swift), turned on or off, paused, or switched
        // for a site: every tab's next page, and the page each is showing now.
        Dusk.shared.$revision
            .dropFirst()
            .sink { [weak self] _ in
                // Published before it is set; the pages read the set one.
                DispatchQueue.main.async { self?.redusk() }
            }
            .store(in: &bag)
        // A page darkened or let go: the View menu's line says which.
        Dusk.shared.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now.
        prefs.$showsLinks
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if !on { linkStatus.dismiss() }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? HoveredLink.script : HoveredLink.off, in: nil, in: .defaultClient)
                }
            }
            .store(in: &bag)

        // Every open page that hasn't a size of its own takes the new one.
        // Asleep, a tab has no page to resize; it takes it on waking.
        prefs.$pageZoom
            .dropFirst()
            .sink { [weak self] _ in
                // Published before it is stored; the tabs read the stored one.
                DispatchQueue.main.async {
                    guard let self else { return }
                    for tab in self.tabs + self.parkedTabs where tab.built != nil { tab.applyRememberedZoom() }
                }
            }
            .store(in: &bag)

        prefs.$passkeys
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                FormRelay.passkeysOffered = on
                // Each tab keeps whatever is hidden on the site it is showing:
                // re-arming with nothing would quietly restore every element
                // this person had taken off, everywhere.
                for tab in tabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                }
                announce(on ? "Passkeys offered again — reload the page" : "Sites will ask for a password instead")
            }
            .store(in: &bag)

        // The window and the menus are drawn from this object; a setting that
        // changes what they show has to be heard here.
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // Videos waiting for a click: every tab's next page view follows.
        prefs.$waitsForPlay
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { for tab in self.tabs + self.parkedTabs { tab.playbackChanged() } }
            }
            .store(in: &bag)

        // WebKit read the defaults once at the start and keeps its own copy.
        // The only way to change its mind while running is the same action
        // the Edit menu would send it, which also writes the default back.
        prefs.$autocorrect
            .dropFirst()
            .sink { [weak self] on in
                guard let self, let web = active?.built else { return }
                let selector = NSSelectorFromString("toggleAutomaticSpellingCorrection:")
                guard web.responds(to: selector) else { return }
                // Toggling is all there is, so it is only sent when the two
                // actually disagree.
                if UserDefaults.standard.bool(forKey: "WebAutomaticSpellingCorrectionEnabled") != on {
                    web.perform(selector, with: nil)
                }
                Preferences.tellWebKit(autocorrect: on)
                announce(on ? "Autocorrect on" : "Autocorrect off")
            }
            .store(in: &bag)
    }

    /// Edit › Substitutions: whether one is on in pages. WebKit keeps a
    /// single answer for every page, so the tab in front's view speaks for
    /// all of them.
    func substitutes(_ kind: Substitution) -> Bool {
        kind.isOn(in: active?.built)
    }

    /// Edit › Substitutions: one switched for every page. Sent to the page's
    /// view rather than to whatever has the keyboard, so the address field
    /// having the caret doesn't make it switch only that field.
    func toggleSubstitution(_ kind: Substitution, in web: WKWebView? = nil) {
        kind.toggle(in: web ?? active?.built ?? (tabs + parkedTabs).lazy.compactMap(\.built).first)
        objectWillChange.send()
    }

    private func relook() {
        Favicons.shared.relook(tabs.filter { !$0.asleep })
        // Dark pages are only ever put into a page while Eden is dark: a
        // change of look takes them in, or lets them go.
        redusk()
    }

    func writeSession(now: Bool = false) {
        guard !isPopup, !retired else { return }
        // The pins as they are here, for the other windows (see Pins.swift):
        // the space's own, and the ones every space shows (only from a row
        // that holds them: see PinLists.sharedToWrite).
        if prefs.showsSharedPins { keepBlocks() }
        let defs = pinDefs(tabs)
        let everywhere = Set(tabs.filter(\.everywhere).compactMap(\.pinID))
        let parts = PinLists.split(defs, shared: everywhere)
        Pins.set(spaceID, parts.own, from: self)
        if let shared = PinLists.sharedToWrite(parts.shared, showing: prefs.showsSharedPins),
           Pins.setShared(shared, from: self) {
            for space in Array(parked.keys) { pinsChanged(in: space) }
        }
        writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: now)
    }

    // MARK: - pins, the same in every window

    /// What makes this row's pinned tabs pins, in their order.
    private func pinDefs(_ row: [Tab]) -> [PinDef] {
        row.compactMap { tab -> PinDef? in
            guard let letter = tab.pin, !tab.shy else { return nil }
            if tab.pinID == nil { tab.pinID = UUID() }
            let home = (tab.home ?? tab.pending ?? tab.address)?.absoluteString ?? ""
            // Its home's title as kept (Pins.retitle) while the home is the
            // same; a new pin, or one with a new home, takes this page's own
            // title if it is there, untranslated, or none until the page
            // names itself.
            let kept = tab.pinID.flatMap(Pins.def(_:)).flatMap { $0.home == home ? $0.title : nil }
            let title = kept ?? (tab.titleIsOwn && tab.isHome(tab.address) ? tab.title : "")
            return PinDef(id: tab.pinID ?? UUID(), letter: letter, home: home, title: title,
                          name: tab.name,
                          listed: tab.listed ? true : nil,
                          group: tab.listed && !tab.everywhere ? tab.keptGroupID : nil)
        }
    }

    /// A row with the space's pins as they are now: this window's own tab
    /// for each, relettered and in order, one made asleep at its page for a
    /// pin new to this window, and the tab of a pin taken away closed. A
    /// pinned tab from before pins had ids is matched by letter and page,
    /// then by place.
    func reconcilePins(_ row: [Tab], space: UUID) -> [Tab] {
        let showing = prefs.showsSharedPins
        let shared = showing ? Pins.shared(profileID) : []
        let sharedIDs = Set(shared.map(\.id))
        let defs = PinLists.row(own: Pins.defs(space), shared: shared, showing: showing)
        var pinned = row.filter { $0.pin != nil && !$0.shy }
        let loose = row.filter { $0.pin == nil || $0.shy }
        var out: [Tab] = []
        let live = Set(defs.map(\.id))
        for def in defs {
            let found = pinned.first { $0.pinID == def.id }
                // Its pin merged into this one, of the same page, on another
                // device (SyncItems.applyPins): this one's tab now, page,
                // history and all, rather than closed for a new one.
                ?? pinned.first { tab in
                    tab.pinID.map { !live.contains($0) } == true && PinDef.samePage(tab.home, URL(string: def.home))
                }
                ?? pinned.first { $0.pinID == nil && $0.pin == def.letter && ($0.home?.absoluteString ?? "") == def.home }
                ?? pinned.first { $0.pinID == nil }
            let tab: Tab
            if let found {
                pinned.removeAll { $0 === found }
                tab = found
            } else if let made = madeAhead.removeValue(forKey: def.id) {
                // Into the row only now: wired to the window as it lands.
                prepare(made)
                tab = made
            } else {
                tab = pinTab(def, space: space)
            }
            tab.pinID = def.id
            tab.everywhere = sharedIDs.contains(def.id)
            if tab.pin != def.letter { tab.pin = def.letter }
            if tab.name != def.name { tab.name = def.name }
            if tab.listed != (def.listed == true) { tab.listed = def.listed == true }
            tab.keptGroupID = def.group
            // Only when it moved: each setting redraws the row, and every
            // window reconciles its pins whenever one of them changes.
            let home = URL(string: def.home)
            if tab.home != home { tab.home = home }
            out.append(tab)
        }
        for gone in pinned { gone.close() }
        // In the order they were written, which already holds it; a file
        // put together by hand, or an import, may not: the rows in the order
        // the kept area draws them, each group's together.
        return Browser.arrangedPins(Browser.tiered(out) + loose, groups: Pins.groups(space))
    }

    /// A new tab for a pin, at its page, not loaded until it is shown.
    /// `prepared`: wired to the window (prepare), as one going into the row
    /// at once is; one made ahead isn't until it does (madeAhead).
    ///
    /// Its page and title set before it is wired, never after: the window's
    /// watch on a tab's title takes each change as the page naming itself
    /// and writes it into history (prepare), so a pin's title set after —
    /// a bookmark's, as an import names its rows — rewrote the history of a
    /// page already there, and a cancelled import left that behind.
    private func pinTab(_ def: PinDef, space: UUID, prepared: Bool = true) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: space))
        tab.restore(url: URL(string: def.home) ?? URL(string: "about:blank")!, title: def.title, vouched: true, name: def.name)
        if prepared { prepare(tab) }
        return tab
    }

    /// Tabs made ahead for pins about to come in, by pin id, which the row
    /// picks up when they do (reconcilePins) rather than making them then.
    /// Making a tab is most of what a pin costs the window: an import's
    /// fifteen hundred, made as the row took them in, held it for a third of
    /// a second; made here a batch at a time, the window draws between
    /// (Browser.takeFile). Taken when used, and dropped when not.
    ///
    /// Until it is taken a tab made ahead is nothing to anything but itself:
    /// its page and title set, never loaded, not wired to the window (no
    /// watch on its title for history, on its address for the session, on
    /// its sound for the player), in no row, so in no session, nothing sync
    /// sends, nothing an extension or the sleep timer or the memory count
    /// sees. Its icon is only looked up among those already kept. Dropped,
    /// it leaves nothing.
    private var madeAhead: [UUID: Tab] = [:]

    /// Tabs made for `defs`, pins of `space` that are about to come in.
    func makeAhead(_ defs: some Sequence<PinDef>, space: UUID) {
        guard !isPopup, !retired, space == spaceID || parked[space] != nil else { return }
        for def in defs where madeAhead[def.id] == nil { madeAhead[def.id] = pinTab(def, space: space, prepared: false) }
    }

    /// Those not taken up, gone: the import was cancelled, or the pins
    /// changed meanwhile and a page of them is pinned already.
    func dropMadeAhead(_ ids: some Sequence<UUID>) {
        for id in ids { madeAhead.removeValue(forKey: id)?.close() }
    }

    /// Another window changed a space's pins: this window's row there follows.
    func pinsChanged(in space: UUID) {
        guard !isPopup, !retired else { return }
        if space == spaceID {
            // Drawn again even when only a pin's letter or name changed.
            objectWillChange.send()
            let row = reconcilePins(tabs, space: space)
            if row.map(\.id) != tabs.map(\.id) { tabs = row }
            splits.removeAll { pair in
                !pair.tabs.allSatisfy { id in tabs.contains { $0.id == id } }
            }
            // The pin in front taken away there. Nothing in front already
            // stays so.
            if let gone = activeID, !tabs.contains(where: { $0.id == gone }) {
                if let next = landing(after: gone, in: tabs, splits: splits) { select(next) } else { showNothing() }
            }
            writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: false)
        } else if var row = parked[space] {
            row.tabs = reconcilePins(row.tabs, space: space)
            row.splits.removeAll { pair in
                !pair.tabs.allSatisfy { id in row.tabs.contains { $0.id == id } }
            }
            // The same for a space not on screen. It took the first loose
            // tab alone, so a space of only pins, its pin in front made Only
            // in This Space from another, was left with nothing in front,
            // the pin it had been on before standing there.
            if let active = row.active, !row.tabs.contains(where: { $0.id == active }) {
                row.active = landing(after: active, in: row.tabs, splits: row.splits)?.id
            }
            parked[space] = row
        }
    }

    /// Where a row goes once the pin in front is taken away: back to the tab
    /// you were on before it, or else the first loose tab, or nothing in
    /// front, never a tab made for the purpose. A pair's later pages stand
    /// in its first one's place, as in `standsInRow`.
    private func landing(after gone: Tab.ID, in row: [Tab], splits: [TabSplit]) -> Tab? {
        let standing = row.filter { tab in
            guard prefs.splitView, let pair = splits.first(where: { $0.contains(tab.id) }) else { return true }
            return pair.left == tab.id
        }
        let before = tabSwitcher.lastLeft(among: Set(standing.map(\.id)), other: gone)
            .flatMap { id in standing.first { $0.id == id } }
        return before ?? standing.first { $0.pin == nil }
    }

    /// The shared pins ahead of the space's own, squares ahead of rows (see
    /// Browser.tiered): a drag or a Show as Row that crossed the line goes
    /// back to its side of it, where pins.json, every other space and the
    /// next launch have it.
    private func keepBlocks() {
        let pinned = tabs.filter { $0.pin != nil && !$0.shy }
        let loose = tabs.filter { $0.pin == nil || $0.shy }
        let blocked = Browser.tiered(pinned.filter(\.everywhere) + pinned.filter { !$0.everywhere })
        if !blocked.elementsEqual(pinned, by: { $0.id == $1.id }) { tabs = blocked + loose }
    }

    /// The shared pins changed, here or in another window: every row this
    /// window holds follows, the one on screen and every space parked.
    func sharedPinsChanged() {
        for space in Array(parked.keys) { pinsChanged(in: space) }
        pinsChanged(in: spaceID)
    }

    /// Pin menu › Keep in Every Space: this space's pin, shown by every
    /// space from now on, after the shared ones. This tab stays as it is;
    /// the other spaces make theirs, asleep at the pin's page.
    func shareEverywhere(_ tab: Tab) {
        guard prefs.showsSharedPins, tab.pin != nil, !tab.everywhere, !tab.shy else { return }
        writeSession(now: true)
        guard let id = tab.pinID else { return }
        let moved = PinLists.share(id, own: Pins.defs(spaceID), shared: Pins.shared(profileID))
        // The shared list first: in between, the pin is in both lists, which
        // PinLists.row counts once, so every other window keeps its tab for it.
        // The other way round it was in neither, and they closed theirs.
        Pins.setShared(moved.shared, from: self)
        Pins.set(spaceID, moved.own, from: self)
        sharedPinsChanged()
        writeSession(now: true)
    }

    /// Pin menu › Only in This Space: a shared pin kept by this space alone,
    /// first among its own. The other spaces close theirs.
    func keepHere(_ tab: Tab) {
        guard tab.everywhere, let id = tab.pinID else { return }
        let moved = PinLists.keep(id, own: Pins.defs(spaceID), shared: Pins.shared(profileID))
        Pins.set(spaceID, moved.own, from: self)
        Pins.setShared(moved.shared, from: self)
        sharedPinsChanged()
        writeSession(now: true)
    }

    /// Arc's sidebar brought over (see ImportArc.swift). Each of its spaces
    /// becomes a space here — the one of the same name if there is one,
    /// signed in with the others when Arc's used its first profile — its
    /// pinned list the space's pinned rows, in folders as Arc has them; the
    /// favourites, the icons above every space of a profile in Arc, become
    /// the pins of that profile's spaces. A lone space, with spaces off,
    /// comes into the one there is; more than one turns spaces on. Nothing
    /// twice: a pin already there isn't added again.
    @discardableResult
    func takeArc(_ sidebar: ArcSidebar, from source: ImportSource? = nil, profile: String? = nil)
        -> (spaces: Int, pins: Int) {
        var made = 0, pins = 0
        // Every address this brings in, for its icon below.
        var brought: [URL] = []
        var targets: [(id: UUID, space: ArcSidebar.Space?, profile: UUID)] = []
        // Arc's profiles become Eden's (see Profiles.swift): its first,
        // "Default", is this window's; each other one a profile of the same
        // name, made if there is none, with its spaces in it, signed in
        // with that profile's own cookies.
        let others = Set(sidebar.spaces.map(\.profile)).subtracting(["Default"])
        let named = others.isEmpty ? [:] : Arc.profileNames()
        var profileFor: [String: UUID] = ["Default": profileID]
        for folder in others.sorted() {
            let name = named[folder] ?? folder
            if let same = Profiles.shared.list.first(where: { $0.id != profileID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                profileFor[folder] = same.id
            } else {
                let home = sidebar.spaces.first { $0.profile == folder }
                    .map { Space(id: UUID(), name: $0.name, colour: 0, icon: $0.symbol, sharesSignIns: true) }
                profileFor[folder] = Profiles.shared.add(named: name, home: home).id
                // Its first space, made with it, is a space this brought in.
                if home != nil { made += 1 }
            }
        }
        if sidebar.spaces.count > 1 || (prefs.usesSpaces && !sidebar.spaces.isEmpty) {
            if !prefs.usesSpaces { prefs.usesSpaces = true }
            var all = Spaces.read()
            for arc in sidebar.spaces {
                let profile = profileFor[arc.profile] ?? profileID
                let mine = all.filter { $0.profileID == profile }
                if let same = mine.first(where: { $0.name.localizedCaseInsensitiveCompare(arc.name) == .orderedSame }) {
                    targets.append((same.id, arc, profile))
                } else {
                    let space = Space(id: UUID(), name: arc.name, colour: 0, icon: arc.symbol, sharesSignIns: true,
                                      profile: profile == Profile.personalID ? nil : profile)
                    all.append(space)
                    targets.append((space.id, arc, profile))
                    made += 1
                }
            }
            if all.count != Spaces.read().count {
                Spaces.write(all)
                spaces = Spaces.read(profile: profileID)
            }
        } else if let arc = sidebar.spaces.first, let profile = profileFor[arc.profile], profile != profileID {
            // A lone space of another Arc profile: that profile's first space.
            targets = [(Profiles.shared.profile(profile).home, arc, profile)]
        } else {
            targets = [(spaceID, sidebar.spaces.first, profileID)]
        }
        for target in targets {
            var defs = Pins.defs(target.id)
            // The pins this space had before any of this, for telling a
            // favourite that is already here from one this import is adding.
            let had = defs
            // A space's own profile's favourites, as Arc shows them above it.
            let favourites = target.space.flatMap { sidebar.favoritesByProfile[$0.profile] } ?? sidebar.favorites
            // A favourite whose site is already pinned is the pin you have,
            // however far it has gone from the address it was pinned at: Gmail
            // pinned at mail.google.com answers at mail.google.com/mail/u/0/,
            // and comparing the two as strings brought it in a second time.
            // Only against the pins that were already here: two favourites of
            // Arc's own on one site are two favourites, and stay two.
            for favourite in favourites where !had.contains(where: { Browser.samePin($0, favourite.url) })
                && !defs.contains(where: { $0.home == favourite.url.absoluteString }) {
                let host = favourite.url.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
                defs.append(PinDef(id: UUID(), letter: host.first.map { String($0).uppercased() } ?? "•",
                                   home: favourite.url.absoluteString, title: favourite.title, name: nil))
                pins += 1
                brought.append(favourite.url)
            }
            // Arc's pinned list as kept rows in groups, each of its folders
            // at the top one here, holding the pages of those inside it (see
            // ColumnTree.fromArc): every page is a row.
            let filed = ColumnTree.fromArc(target.space?.pinned ?? [], into: Pins.groups(target.id))
            brought += filed.pages.map(\.item.url)
            for page in filed.pages where !had.contains(where: { Browser.samePin($0, page.item.url) })
                && !defs.contains(where: { $0.home == page.item.url.absoluteString }) {
                let host = page.item.url.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
                defs.append(PinDef(id: UUID(), letter: host.first.map { String($0).uppercased() } ?? "•",
                                   home: page.item.url.absoluteString, title: page.item.title,
                                   name: nil, listed: true, group: page.group))
                pins += 1
            }
            // Before the pins, so the row rebuilt for them finds their groups.
            let before = Set(Pins.groups(target.id).map(\.id))
            Pins.setGroups(target.id, ColumnTree.withoutEmpty(filed.groups, keeping: before, pins: defs), from: self)
            // The other windows, another profile's among them, follow Pins.changed.
            Pins.set(target.id, defs, from: self)
            pinsChanged(in: target.id)
        }
        adoptIcons(for: brought, from: source, profile: profile)
        return (made, pins)
    }

    /// Another Chromium browser's open tabs (see ImportSession.swift), from
    /// the snapshot read when the sheet counted them, into this space: its
    /// pinned tabs as pins, the rest asleep at the end of the row, a grouped
    /// tab in the group of that name, made if missing and folded as it was.
    /// Kept whether or not tab groups are turned on, as takeAsleep keeps
    /// Arc's folders. Nothing twice: a page already in the row, or a pin
    /// already there, isn't added again.
    @discardableResult
    func takeSession(_ snapshot: SessionImport.Snapshot, from source: ImportSource? = nil, profile: String? = nil)
        -> (pins: Int, tabs: Int, groups: Int) {
        let all = snapshot.capped().windows.joined()
        var brought: [URL] = []
        var defs = Pins.defs(spaceID)
        let had = defs
        for page in all where page.pinned && !had.contains(where: { Browser.samePin($0, page.url) })
            && !defs.contains(where: { $0.home == page.url.absoluteString }) {
            let host = page.url.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
            defs.append(PinDef(id: UUID(), letter: host.first.map { String($0).uppercased() } ?? "•",
                               home: page.url.absoluteString, title: page.title, name: nil))
            brought.append(page.url)
        }
        let pins = defs.count - had.count
        if pins > 0 {
            Pins.set(spaceID, defs, from: self)
            pinsChanged(in: spaceID)
        }
        var seen = Set(tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString })
        let new = all.filter { !$0.pinned && seen.insert($0.url.absoluteString).inserted }
        var groups = tabGroups
        var made: [SessionImport.Token: UUID] = [:]
        func group(_ token: SessionImport.Token?) -> UUID? {
            guard let token, let found = snapshot.groups[token] else { return nil }
            if let id = made[token] { return id }
            let id = groups.first(where: { $0.name == found.title })?.id ?? {
                let fresh = TabGroup(id: UUID(), name: found.title, collapsed: found.collapsed)
                groups.append(fresh)
                return fresh.id
            }()
            made[token] = id
            return id
        }
        tabs += new.map { page in
            let tab = Tab(configuration: Web.configuration(space: spaceID))
            prepare(tab)
            // A title from elsewhere, which may have been translated there.
            tab.restore(url: page.url, title: page.title, vouched: false)
            tab.groupID = group(page.group)
            return tab
        }
        let newGroups = groups.count - tabGroups.count
        if groups != tabGroups {
            tabGroups = groups
            arrangeGroupedTabs()
        }
        if !new.isEmpty || pins > 0 {
            writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: true)
        }
        brought += new.map(\.url)
        adoptIcons(for: brought, from: source, profile: profile)
        return (pins, new.count, newGroups)
    }

    /// The icons for what Arc's side of the import brought in, from Arc's own
    /// cache, as the bookmarks take theirs (see takeBookmarks). A pin and a
    /// tab read the icon cache as they are made, and these were made a moment
    /// ago, when nothing had been put there for them yet: without this every
    /// one of them wears a letter until its page is opened, which is the only
    /// other way an icon arrives (see Favicons.fetch).
    private func adoptIcons(for urls: [URL], from source: ImportSource?, profile: String?) {
        guard let source, !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let icons = source.icons(profile: profile, for: urls)
            guard !icons.isEmpty else { return }
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                // The ones made before the icons arrived, now that they are here.
                for tab in self.tabs + self.parkedTabs where tab.icon == nil { tab.adoptIcon() }
                self.objectWillChange.send()
            }
        }
    }

    /// Whether a pin is the one a favourite would make: the same site, and
    /// one address inside the other (mail.google.com and
    /// mail.google.com/mail/u/0/), or failing a site to compare (a file, an
    /// about: page), the same address. github.com/me and github.com/work are
    /// two pins, and stay two. A site is its host without the www. that is
    /// not part of who it is, as a pin's letter already reads it, and its
    /// port: localhost:3000 and localhost:5173 are two sites.
    static func samePin(_ pin: PinDef, _ url: URL) -> Bool {
        guard let home = URL(string: pin.home), let mine = site(of: url), let theirs = site(of: home) else {
            return pin.home == url.absoluteString
        }
        guard mine == theirs else { return false }
        let a = folder(of: url), b = folder(of: home)
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func site(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.port.map { "\(name):\($0)" } ?? name
    }

    /// The path, ending in a slash, so that /me is never taken for the start of /media.
    private static func folder(of url: URL) -> String {
        let path = url.path().lowercased()
        return path.hasSuffix("/") ? path : path + "/"
    }

    // MARK: - this window's rows, wherever they are kept

    /// A space's row as saved: the session files' for the oldest window,
    /// this window's own record for any other.
    func readRow(_ space: UUID) -> Session.Shape {
        usesFiles ? Session.read(space: space) : (record.rows[space.uuidString] ?? Session.Shape(tabs: [], active: 0))
    }

    func writeRow(_ space: UUID, _ shape: Session.Shape, now: Bool) {
        // This Mac's open tabs, as its other devices see them (Sync.swift).
        if !websitePopup { NotificationCenter.default.post(name: Sync.tabsChanged, object: nil) }
        if usesFiles {
            Session.write(now: now, space: space, shape)
        } else {
            record.rows[space.uuidString] = shape
            if now { Browsers.save(now: true) } else { Browsers.saveSoon() }
        }
    }

    /// Every row this window has, by space: the one on screen, the parked
    /// ones, and those saved but not brought up this time. `keeping`, for
    /// a window going away (Windows.retire): each open tab's history too, so
    /// ⇧⌘T brings the window back with Back and Forward where they were.
    func allRows(keeping: Bool = false) -> [String: Session.Shape] {
        var rows: [String: Session.Shape] = [:]
        for space in spaces {
            let saved = readRow(space.id)
            if !saved.tabs.isEmpty { rows[space.id.uuidString] = saved }
        }
        rows[spaceID.uuidString] = session(tabs, active: activeID, groups: tabGroups, splits: splits, keeping: keeping)
        for (space, row) in parked {
            rows[space.uuidString] = session(row.tabs, active: row.active, groups: row.groups ?? readRow(space).groups,
                                             splits: row.splits, keeping: keeping)
        }
        return rows
    }

    /// The oldest window closed: this one is the oldest now, and its rows go
    /// into the session files, every space's — an empty row where it has
    /// none, or the closed window's would come back there.
    func becomePrimary() {
        takeFiles()
        Store.settings.set(spaceID.uuidString, forKey: "space.current")
        // SwiftUI's window, opened next launch, comes back where this one is.
        window?.saveFrame(usingName: Browsers.sceneID)
    }

    /// The oldest window of its profile closed: this one's rows go into the
    /// profile's session files, every space's — an empty row where it has
    /// none, or the closed window's would come back there.
    func takeFiles() {
        guard !usesFiles else { return }
        let rows = allRows()
        usesFiles = true
        for space in spaces {
            Session.write(now: true, space: space.id, rows[space.id.uuidString] ?? Session.Shape(tabs: [], active: 0))
        }
        record.rows = [:]
    }

    /// The last window of its profile closing, others open: its rows stay
    /// in the profile's files, written now, and nothing it does from here on
    /// touches them — the next window of the profile opens with its tabs.
    func leaveFiles() {
        guard usesFiles else { return }
        flushSession()
        record.rows = allRows()
        usesFiles = false
    }

    /// Its window closed for good, with others open: every page let go.
    func closeAll() {
        retired = true
        cancelDisplay()
        cancelCapture()
        for questions in heldDialogs.values { questions.forEach { $0.dismiss() } }
        heldDialogs = [:]
        dropQuestions()
        if floating != nil { land(covering: false) }
        if pictured != nil { unpicture() }
        if peekTab != nil { closePeek() }
        closeSidePanel()
        SidePanelPages.shared.forget(in: self)
        for tab in tabs + parkedTabs { tab.close() }
        parked = [:]
        splits = []
        tabs = []
    }

    private func session(_ tabs: [Tab], active id: Tab.ID?, groups: [TabGroup]? = nil, splits: [TabSplit] = [],
                         keeping: Bool = false) -> Session.Shape {
        var entries: [Session.Entry] = []
        // A row with nothing in front — left so, or a space not yet gone to
        // since a fresh start — stays that way in its file, rather than its
        // first tab (a pin) coming to the front next time.
        var active = id == nil ? -1 : 0
        var indices: [Tab.ID: Int] = [:]
        for tab in tabs {
            guard kept(tab), let url = tab.pending ?? tab.address ?? tab.page?.url else { continue }
            if tab.id == id { active = entries.count }
            indices[tab.id] = entries.count
            entries.append(Session.Entry(
                url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name,
                home: tab.pin == nil ? nil : tab.home?.absoluteString, groupID: tab.groupID,
                pinID: tab.pin == nil ? nil : tab.pinID,
                // A page on screen is being looked at now, not when it was
                // arrived at: quitting on it is leaving it.
                touched: visibleTabIDs.contains(tab.id) ? Date() : tab.touched,
                letGo: tab.pin == nil ? tab.letGo : nil,
                listed: tab.pin != nil && tab.listed ? true : nil,
                muted: tab.muted,
                foreignTitle: tab.titleIsOwn || tab.title.isEmpty ? nil : true,
                // Asked for only when the window goes: reading it for every
                // tab at every save would be work for nothing.
                keepsake: keeping ? tab.keepsake.map(Keepsake.init) : nil
            ))
        }
        // The tab you were on isn't kept — a private one: the one kept just
        // before it comes back in front, not the first of the row. An empty
        // one comes back as nothing in front, beside the pins: the tab just
        // before it is the last of the row, often the last page of a folded
        // group, which then came out of its folder in front.
        if let id, let at = tabs.firstIndex(where: { $0.id == id }), indices[id] == nil {
            active = tabs[at].isBlank && !tabs[at].shy ? -1 : max(0, tabs[..<at].filter(kept).count - 1)
        }
        let keptGroups = groups?.filter { group in
            entries.contains { $0.groupID == group.id }
        }
        // The pages of a split that are in the file: an empty page, or a
        // private one, isn't written. Two or more left stay a split, their
        // shares made up between them; one alone comes back as a tab.
        let savedSplits = splits.compactMap { pair -> Session.Split? in
            let written = pair.tabs.indices.filter { indices[pair.tabs[$0]] != nil }
            let places = written.compactMap { indices[pair.tabs[$0]] }
            guard places.count >= 2,
                  places == Array(places[0]..<places[0] + places.count) else { return nil }
            let sizes = written.count == pair.tabs.count || pair.sizes.count != pair.tabs.count
                ? pair.sizes : TabSplit.clamp(written.map { pair.sizes[$0] })
            return Session.Split(tabs: places, axis: pair.axis, sizes: sizes,
                                 focused: pair.focused.flatMap { indices[$0] })
        }
        return .init(tabs: entries, active: active, groups: keptGroups, splits: savedSplits)
    }

    /// Whether a tab goes into the session: not a private one or the
    /// bench's, and only a web page, local file or one of Eden's own pages.
    /// A sleeping view is blank, so `pending` must win or its page disappears.
    private func kept(_ tab: Tab) -> Bool {
        // A tab holding an extension's sign-in answer (Tab.hold) carries its
        // code in the address: that is never written down.
        let url = tab.pending ?? tab.address
        return !tab.shy && !tab.bench && tab.held == nil
            && (url?.scheme?.hasPrefix("http") == true || url?.isFileURL == true || tab.page != nil)
    }

    /// Another space's row. Its groups are the ones in its own file, the
    /// only place a space off screen keeps them: written without them, the
    /// space would lose every group it had.
    func writeSession(now: Bool, space: UUID, row: Parked) {
        let groups = row.groups ?? readRow(space).groups
        writeRow(space, session(row.tabs, active: row.active, groups: groups, splits: row.splits), now: now)
    }

    /// The session written a moment from now, for other files.
    func writeSessionSoon() { rememberSession() }

    private func rememberSession() {
        guard !remembering else { return }
        remembering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            remembering = false
            writeSession()
        }
    }

    /// The app is quitting. Whatever the debounce above was waiting out, it
    /// stops waiting: this writes straight to disk, on the thread asking to
    /// quit, before there is a process left to finish the wait on its behalf.
    func flushSession() {
        writeSession(now: true)
    }

    // MARK: - tabs

    /// A pin can be split with: its page goes into the pair as a tab of its
    /// own, and the pin stays where it is (see splittable).
    func canSplit(_ first: Tab, with second: Tab) -> Bool {
        prefs.splitView && first.id != second.id && !first.bench && !second.bench
            && first.shy == second.shy
            && tabs.contains(where: { $0.id == first.id })
            && tabs.contains(where: { $0.id == second.id })
    }

    /// Whether `tab` can go beside `target` on screen: into the split
    /// `target` is in, while it has room, or as a pair with it. Moving
    /// within its own split is always room enough.
    func canJoin(_ tab: Tab, beside target: Tab) -> Bool {
        guard canSplit(tab, with: target) else { return false }
        guard let there = split(for: target) else { return true }
        return there.contains(tab.id) || !there.isFull
    }

    /// Zen's rule for pins: a pin never goes into a pair — it keeps its
    /// place among the pins, in every window (Pins.swift) — but its page
    /// does, as a new tab beside the other page. Anything else is itself.
    private func splittable(_ tab: Tab) -> Tab {
        guard tab.pin != nil, let url = tab.address ?? tab.home else { return tab }
        let copy = Tab(configuration: Web.configuration(space: spaceID))
        prepare(copy)
        tabs.insert(copy, at: tabs.count)
        copy.go(to: url)
        return copy
    }

    /// `dragged` beside `target`, on its left or right. With `target`
    /// already in a split that has room, `dragged` joins it there and the
    /// pages are made even; alone, the two make a pair. `joining` false
    /// takes `target` out of its split first, for a pair of exactly these
    /// two (see pairPickedTabs). `dragged` leaves any split it was in.
    func pair(_ dragged: Tab, with target: Tab, onLeft: Bool, joining: Bool = true) {
        guard joining ? canJoin(dragged, beside: target) : canSplit(dragged, with: target) else { return }
        if floating == dragged.id || floating == target.id { land() }
        let dragged = splittable(dragged)
        let target = splittable(target)
        leaveSplit(dragged)
        if !joining { leaveSplit(target) }
        let oldGroup = dragged.groupID
        dragged.groupID = target.groupID
        var row = tabs.filter { $0.id != dragged.id }
        guard let index = row.firstIndex(where: { $0.id == target.id }) else { return }
        row.insert(dragged, at: onLeft ? index : index + 1)
        let members: [Tab.ID]
        if let at = splits.firstIndex(where: { $0.contains(target.id) }) {
            splits[at].insert(dragged.id, beside: target.id, before: onLeft)
            splits[at].focused = dragged.id
            members = splits[at].tabs
        } else {
            let left = onLeft ? dragged : target
            let right = onLeft ? target : dragged
            splits.append(TabSplit(tabs: [left.id, right.id], focused: dragged.id))
            members = [left.id, right.id]
        }
        tabs = row
        removeEmptyGroup(oldGroup)
        focusPane(dragged)
        for pane in tabs where members.contains(pane.id) && !pane.isBlank {
            if !pane.wake() { pane.revive() }
        }
        rememberSession()
    }

    /// ⌥⌘N, and Tabs › Split Current Page: on one page, an empty page
    /// beside it (or the two tabs picked, side by side); on a pair, the
    /// pair taken apart, both pages staying as tabs. The key that made the
    /// split puts it away, as ⌘T and ⌘L each put away what they raised
    /// (#912). It used to go to the right-hand page, which ⌃⌘→ already does.
    func splitKey() {
        if pickedSplit == nil, activeSplit != nil, let tab = active { return detachSplit(tab) }
        startSplit()
    }

    func startSplit() {
        // Two to four tabs picked in the column: those side by side.
        if pickedSplit != nil { return pairPickedTabs() }
        guard prefs.splitView, let shown = active, !shown.bench else { return }
        if let pair = activeSplit {
            if let right = tabs.first(where: { $0.id == pair.right }) { focusPane(right) }
            return
        }
        if floating == shown.id { land() }
        let current = splittable(shown)
        let right = Tab(shy: current.shy,
                        configuration: current.shy ? Web.configuration(shy: true, store: current.store)
                            : Web.configuration(space: spaceID))
        prepare(right)
        right.groupID = current.groupID
        guard let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        splits.append(TabSplit(tabs: [current.id, right.id], focused: right.id))
        tabs.insert(right, at: index + 1)
        focusPane(right)
        editing = true
        typed = ""
        focusRequest += 1
        rememberSession()
    }

    /// Tabs › Add Page to Split View: with a split on screen that has
    /// room, an empty page beside the one with the keys, to its right, as
    /// ⌥⌘N puts one beside a page alone.
    func addPaneToSplit() {
        guard prefs.splitView, let pair = activeSplit, !pair.isFull, let shown = active, !shown.bench else { return }
        let right = Tab(shy: shown.shy,
                        configuration: shown.shy ? Web.configuration(shy: true, store: shown.store)
                            : Web.configuration(space: spaceID))
        prepare(right)
        right.groupID = shown.groupID
        guard let index = tabs.firstIndex(where: { $0.id == shown.id }),
              let at = splits.firstIndex(where: { $0.id == pair.id }) else { return }
        splits[at].insert(right.id, beside: shown.id)
        splits[at].focused = right.id
        tabs.insert(right, at: index + 1)
        focusPane(right)
        editing = true
        typed = ""
        focusRequest += 1
        rememberSession()
    }

    /// Whether Add Page to Split View has somewhere to add one.
    var canAddPane: Bool {
        guard let pair = activeSplit, let shown = active else { return false }
        return !pair.isFull && !shown.bench
    }

    /// The whole split taken apart: every page stays, as a tab of its own.
    func detachSplit(_ tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }) else { return }
        splits.remove(at: index)
        rememberSession()
    }

    /// One page out of its split, the others staying together; a split
    /// left with one page is no split, and that page is a tab again. Of a
    /// pair, the same as taking it apart.
    func leaveSplit(_ tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }) else { return }
        var rest = splits[index]
        if rest.remove(tab.id) {
            if rest.focused == nil, let id = activeID, rest.contains(id) { rest.focused = id }
            splits[index] = rest
        } else {
            splits.remove(at: index)
        }
        rememberSession()
    }

    /// Once a drag of the divider is over, or once an arrow key moved it:
    /// the drag itself is followed by the stage alone (see PaneStage).
    func setSplitFraction(_ id: UUID, fraction: Double) {
        guard fraction.isFinite else { return }
        setSplitSizes(id, [fraction, 1 - fraction])
    }

    /// Each page's share at once, for three or four (two as a fraction).
    func setSplitSizes(_ id: UUID, _ sizes: [Double]) {
        guard let index = splits.firstIndex(where: { $0.id == id }),
              sizes.count == splits[index].tabs.count, sizes.allSatisfy(\.isFinite) else { return }
        let sizes = TabSplit.clamp(sizes)
        guard splits[index].sizes != sizes else { return }
        splits[index].sizes = sizes
        rememberSession()
    }

    func focusPane(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        if let pair = split(for: tab), activeSplit?.id == pair.id {
            guard activeID != tab.id else { return }
            // Both pages of the pair are on screen: a peek that stays with
            // its tab stays over either.
            if peekTab != nil, !prefs.peekStays { closePeek() }
            // Find stays open with what it was looking for, and looks in
            // this page instead (see activeID).
            cancelTabEdit()
            suggesting = nil
            looked = nil
            editing = false
            typed = ""
            activeID = tab.id
            tab.touch()
            rememberSession()
        } else {
            select(tab)
        }
    }

    /// An extension asking for a tab to be the one in front. A page of the
    /// pair on screen is in view already: the keys stay where they are, so
    /// an extension can't move typing from one page to the other.
    func activateForExtension(_ tab: Tab) {
        if let pair = activeSplit, pair.contains(tab.id) { return }
        select(tab)
    }

    /// ⌃⌘← and ⌃⌘→: the page next to it on that side, none past the ends.
    /// Of two, the page on that side.
    func focusPane(onLeft: Bool) {
        guard let pair = activeSplit, let id = activeID, let at = pair.tabs.firstIndex(of: id) else { return }
        let next = min(max(0, at + (onLeft ? -1 : 1)), pair.tabs.count - 1)
        guard let tab = tabs.first(where: { $0.id == pair.tabs[next] }) else { return }
        focusPane(tab)
    }

    /// ⌥-click on a tab in the column, or on a pin (#939):
    /// that tab beside the page on screen, as its menu's Open in Split View
    /// does, with no setting, since nothing else answers a modifier click
    /// on a tab. On the page on screen alone, an empty page beside it, as
    /// ⌥⌘N. On a half of the pair on screen, that half out of the pair and
    /// the other page left on screen, as Zen's Alt-click takes a tab out.
    /// A tab that can't go beside it (a private tab beside one that isn't,
    /// the bench's) is chosen as a plain click chooses it.
    func optionClick(_ tab: Tab) {
        clearTabSelection()
        guard prefs.splitView, let current = active, tabs.contains(where: { $0.id == tab.id }) else { return select(tab) }
        if let pair = activeSplit, pair.contains(tab.id) {
            let other = pair.partner(of: tab.id).flatMap { id in tabs.first { $0.id == id } }
            leaveSplit(tab)
            if let other { select(other) }
            return
        }
        guard tab.id == current.id || canJoin(tab, beside: current) else { return select(tab) }
        openInSplit(tab)
    }

    /// A tab's menu › Open in Split View: that tab beside the page on
    /// screen. Asked of the page on screen itself, an empty page beside it.
    func openInSplit(_ tab: Tab) {
        guard prefs.splitView, let current = active else { return }
        if tab.id == current.id { return startSplit() }
        guard split(for: tab)?.contains(current.id) != true else { return focusPane(tab) }
        guard canJoin(tab, beside: current) else { return }
        pair(tab, with: current, onLeft: false)
    }

    /// The tabs picked in the column (⌘- or ⇧-click) that are shown, in the
    /// column's order.
    private var pickedTabs: [Tab] {
        selectableTabs.filter { selectedTabIDs.contains($0.id) }
    }

    /// One of several picked: a press on it waits for the release, as a
    /// click, rather than bringing it forward as the button goes down (see
    /// TabPress), which would drop the others before the drag could take them.
    func isPickedAmongOthers(_ tab: Tab) -> Bool {
        selectedTabIDs.contains(tab.id) && visibleSelectedTabCount > 1
    }

    /// What goes with `tab` carried out of its own run, to another place in
    /// the column, another device or another window: every tab picked with
    /// it, pins of either kind and tabs alike, with their pairs, in the
    /// column's order; alone, the tab and its pair (carried(with:)). Along
    /// its own run, where kinds don't mix, only its own kind goes with it
    /// (carried(with:)).
    func travelling(with tab: Tab) -> [Tab] {
        let picked = pickedTabs
        guard picked.count > 1, picked.contains(where: { $0.id == tab.id }) else { return carried(with: tab) }
        let ids = Set(picked.flatMap { split(for: $0)?.tabs ?? [$0.id] })
        return tabs.filter { ids.contains($0.id) }
    }

    /// What a drag carries: the tab and its pair, or, when it is one of
    /// several picked, every picked tab of its kind with their pairs, in the
    /// row's order. A pin carried leaves the picked tabs where they are, and
    /// a tab leaves the pins; the picked pins of the other shape (square or
    /// row) stay too, as the shapes don't mix (see joins).
    func carried(with tab: Tab) -> [Tab] {
        let picked = pickedTabs
        guard picked.count > 1, picked.contains(where: { $0.id == tab.id }) else {
            return split(for: tab).map { pair in tabs.filter { pair.contains($0.id) } } ?? [tab]
        }
        let ids = Set(picked.filter { $0.pin == nil ? tab.pin == nil : tab.pin != nil && $0.listed == tab.listed }
            .flatMap { split(for: $0)?.tabs ?? [$0.id] })
        return tabs.filter { ids.contains($0.id) }
    }

    /// The tabs picked are already the pages of one split, all of them.
    var pickedTabsArePaired: Bool {
        let picked = pickedTabs
        guard picked.count >= 2, let pair = split(for: picked[0]) else { return false }
        return picked.allSatisfy { pair.contains($0.id) }
    }

    /// Two to four tabs picked that can go side by side: what Open 2 Tabs
    /// (3, 4) in Split View and ⌥⌘N put together. More than a split holds
    /// can't be, so the menu's item is off then and ⌥⌘N does what it does
    /// without a selection.
    var pickedSplit: [Tab]? {
        let picked = pickedTabs
        guard prefs.splitView, (2...TabSplit.most).contains(picked.count), !pickedTabsArePaired,
              picked.dropFirst().allSatisfy({ canSplit($0, with: picked[0]) }) else { return nil }
        return picked
    }

    /// Exactly two picked, of `pickedSplit`.
    var pickedPair: (left: Tab, right: Tab)? {
        guard let picked = pickedSplit, picked.count == 2 else { return nil }
        return (picked[0], picked[1])
    }

    /// The two picked tabs side by side, the first in the column on the
    /// left. Both keep their pages (nothing loads again); either one in
    /// another pair leaves it first, as a drag onto a page's edge does; a
    /// pin stays a pin and its page goes in as a tab (see splittable). The
    /// pair lands where the left one was — where the right one was when the
    /// left is a pin — and the tab asked from has the keys. The selection
    /// is done with.
    func pairPickedTabs(focus asked: Tab? = nil) {
        guard let picked = pickedSplit else { return }
        let (left, right) = (picked[0], picked[1])
        clearTabSelection()
        if left.pin != nil && right.pin == nil {
            pair(left, with: right, onLeft: true, joining: false)
        } else {
            pair(right, with: left, onLeft: false, joining: false)
        }
        // The third and fourth after them, in the column's order, each
        // beside the last page of the split (a pin as its page's copy).
        for tab in picked.dropFirst(2) {
            guard let made = split(for: right) ?? split(for: left),
                  let last = tabs.first(where: { $0.id == made.right }) else { break }
            pair(tab, with: last, onLeft: false)
        }
        if let asked, let made = split(for: asked), activeSplit?.id == made.id {
            focusPane(asked)
        }
    }

    /// The divider's menu › Swap Pages.
    /// Of three or four, the order turned round.
    func swapSplit() {
        guard let pair = activeSplit, let index = splits.firstIndex(where: { $0.id == pair.id }) else { return }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        guard members.count == pair.tabs.count, let start = tabs.firstIndex(where: { $0.id == pair.left }) else { return }
        splits[index].tabs.reverse()
        splits[index].sizes.reverse()
        var row = tabs.filter { !pair.contains($0.id) }
        row.insert(contentsOf: members.reversed(), at: min(start, row.count))
        tabs = row
        rememberSession()
    }

    /// The divider's menu › Even Out, or a double-click on it.
    func evenSplit() {
        guard let pair = activeSplit else { return }
        setSplitSizes(pair.id, TabSplit.even(pair.tabs.count))
    }

    /// The divider's menu › Close Both. Remembered as one, as Close Tabs
    /// Below is, so one ⇧⌘T brings both back as the pair they were (see
    /// reopen(batch:)); closed one by one, ⇧⌘T brought back one page alone,
    /// and a second the other, apart.
    func closeSplit() {
        guard let pair = activeSplit else { return }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        closingTogether(.tabs) { _ in
            for tab in members { close(tab) }
        }
    }

    /// An empty page of a pair given an open tab: the tab takes its place,
    /// and the empty one goes. Chosen from the list the empty page shows.
    func fill(_ blank: Tab, with tab: Tab) {
        guard let pair = split(for: blank), blank.isBlank, tab.id != blank.id, !pair.contains(tab.id),
              !tab.bench, tab.shy == blank.shy,
              let at = tabs.firstIndex(where: { $0.id == blank.id }) else { return }
        let tab = splittable(tab)
        leaveSplit(tab)
        let oldGroup = tab.groupID
        tab.groupID = blank.groupID
        var row = tabs.filter { $0.id != tab.id }
        let place = row.firstIndex(where: { $0.id == blank.id }) ?? min(at, row.count)
        row[place] = tab
        replaceSplitMember(blank.id, with: tab.id)
        tabs = row
        removeEmptyGroup(oldGroup)
        blank.close()
        activeID = tab.id
        editing = false
        typed = ""
        if !tab.wake() { tab.revive() }
        rememberSession()
    }

    /// The next page, round from the last to the first: of two, the other.
    func focusOtherPane() {
        guard let pair = activeSplit, let id = activeID, let at = pair.tabs.firstIndex(of: id),
              let other = tabs.first(where: { $0.id == pair.tabs[(at + 1) % pair.tabs.count] }) else { return }
        focusPane(other)
    }

    func moveDisplayedTab(_ tab: Tab, to index: Int) {
        let shown = displayedTabs
        guard shown.indices.contains(index),
              let representative = split(for: tab)?.left ?? (tabs.contains(where: { $0.id == tab.id }) ? tab.id : nil),
              let from = shown.firstIndex(where: { $0.id == representative }), from != index else { return }
        let moving = carried(with: tab)
        let ids = Set(moving.map(\.id))
        // The block lands beside the tab nearest the drop that stays put:
        // with several picked, the place dropped on may be one of their own.
        let passed = from < index ? Array(shown[(from + 1)...index].reversed()) : Array(shown[index..<from])
        guard let anchor = passed.first(where: { !ids.contains($0.id) }),
              moving.allSatisfy({ ($0.pin == nil) == (anchor.pin == nil) }), joins(tab, kindOf: anchor) else { return }
        var row = tabs.filter { !ids.contains($0.id) }
        guard let target = row.firstIndex(where: { $0.id == anchor.id }) else { return }
        let targetSize = split(for: anchor)?.tabs.count ?? 1
        row.insert(contentsOf: moving, at: from < index ? target + targetSize : target)
        // Picked tabs from other groups join the carried tab's, or setting
        // the row would put each back in its own (see arrangeGroupedTabs).
        let regrouped = prefs.usesTabGroups && tab.pin == nil
        let previous = regrouped ? Set(moving.compactMap(\.groupID)) : []
        if regrouped { for member in moving { member.groupID = tab.groupID } }
        tabs = row
        for id in previous where id != tab.groupID { removeEmptyGroup(id) }
        rememberSession()
    }

    /// The pins in the order they stand: what a square carried across the
    /// others changes as they make way for it (moveDisplayedTab), for a
    /// carry that keeps it here after all to put back (PinCarried).
    var pinOrder: [Tab.ID] {
        tabs.compactMap { $0.pin == nil ? nil : $0.id }
    }

    /// The pins put back in `order`, into the places the pins hold among
    /// the tabs; the other tabs keep theirs, and a pin gone since is passed
    /// over. A pin made since, which `order` can't place, leaves them all as
    /// they are: as the carry left them, which is an order the column
    /// keeps, squares ahead of rows, where a guess at its place might not be.
    func putBack(_ order: [Tab.ID]) {
        let now = pinOrder
        let present = Set(now)
        let back = order.filter { present.contains($0) }
        guard back.count == now.count, back != now else { return }
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = back.compactMap { byID[$0] }.makeIterator()
        var row = tabs
        for index in row.indices where row[index].pin != nil {
            if let pin = next.next() { row[index] = pin }
        }
        tabs = row
        rememberSession()
    }

    /// Whether a pin carried onto another may land there: a square goes
    /// among squares and a row among rows; the menu moves one between them.
    private func joins(_ tab: Tab, kindOf anchor: Tab) -> Bool {
        tab.pin == nil || anchor.pin == nil || tab.listed == anchor.listed
    }

    func dropTabIntoStrip(_ tab: Tab, before target: Tab?) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let target {
            guard target.id != tab.id,
                  let targetIndex = tabs.firstIndex(where: { $0.id == target.id }),
                  split(for: tab)?.contains(target.id) != true,
                  (tab.pin == nil) == (target.pin == nil), joins(tab, kindOf: target) else { return }
            let targetStart = split(for: target).flatMap { pair in tabs.firstIndex { $0.id == pair.left } } ?? targetIndex
            leaveSplit(tab)
            let previousGroup = tab.groupID
            tab.groupID = target.groupID
            var row = tabs.filter { $0.id != tab.id }
            row.insert(tab, at: sourceIndex < targetStart ? targetStart - 1 : targetStart)
            tabs = row
            removeEmptyGroup(previousGroup)
        } else {
            leaveSplit(tab)
            var row = tabs
            row.remove(at: sourceIndex)
            row.insert(tab, at: tab.pin == nil ? row.count : row.filter { $0.pin != nil && (tab.listed || !$0.listed) }.count)
            tabs = row
        }
        rememberSession()
    }

    /// ⌘T, the + button and the menu: the field comes up over the page in
    /// front, as Zen's and Arc's do, and the tab is made by Return, not by
    /// asking for one. There is no blank new tab to choose instead. With
    /// nothing in front it comes up over the window's empty ground the same
    /// way, and putting it away leaves nothing in front again. Only over a
    /// blank tab already in front, whose field is the same one standing on
    /// the window, or for an extension's new tab page you chose, or one
    /// still to be asked about, whose page needs a tab to show in, is it
    /// the tab. From a private tab the field still comes up for one to be
    /// asked about: a private new tab never asks.
    func launch() {
        // Again while it is up: put away, as the key that raised it, the way
        // Spotlight's does. What was typed waits for the next ⌘T (see
        // dismiss()). It used to stay up with what was typed cleared.
        if launching { putAway(); return }
        // A website's popup has no field to raise: its new tab goes to a
        // window of tabs, as ⌘T's always has from there.
        guard !websitePopup, active?.isBlank != true else {
            newTab()
            return
        }
        let shy = active?.shy == true
        if #available(macOS 15.4, *), Extensions.shared.newTabPage != nil || (!shy && Extensions.shared.newTabUnaskedAsker != nil) {
            newTab()
            return
        }
        raiseLaunchField()
    }

    /// ⌘T's field, up over whatever is in front, or over nothing: no tab is
    /// made until Return opens one. ⌘N's new window comes up with it, so
    /// typing goes straight into it (Browsers.newWindow).
    func raiseLaunchField() {
        // A peek is over the page, and the field would come up under it:
        // put away first, as a click outside it would.
        if peekInFront { closePeek() }
        // From ⌘L the words already typed come along, only where they
        // go changes; or else the words a ⌘T put away was left with, selected
        // whole when the field takes the keys, so typing over them costs nothing.
        let words = wordsToCarry ?? launchDraft.flatMap { Date() < $0.until ? $0.words : nil } ?? ""
        launchDraft = nil
        reviewing = false
        cancelTabEdit()
        siteChip = nil
        editing = true
        launching = true
        // After launching, so the list it works out is ⌘T's (see guess()).
        typed = words
        focusRequest += 1
    }

    /// What was typed into ⌘T's field when it was put away without opening
    /// anything: Escape, a click outside, ⌘W or ⌘T again. Kept for the next
    /// ⌘T for 45 seconds, as Zen keeps its own (zen.urlbar.wait-to-clear):
    /// long enough to come back to after a look at the page, not so long
    /// that an old search greets a new thought.
    private var launchDraft: (words: String, until: Date)?
    private static let launchDraftLife: TimeInterval = 45

    /// The link on the clipboard, as last looked at (FieldOffers.swift).
    var copiedLink: CopiedLink?
    /// The clipboard's change count while its link is being looked for.
    var lookingAtClipboard: Int?
    /// The change count of the copied link visited last: offered no more.
    var copiedLinkTaken: Int?

    /// The field's list worked out again for what is typed now: a link
    /// found on the clipboard since the empty field listed what it had.
    func listAgain() { guess() }

    /// The words in the field now up, for another of its keys to carry on
    /// with: ⌘T and ⌘L change where Return goes, not what was typed.
    /// Never the page's own address, which ⌘L put there and nobody typed.
    private var wordsToCarry: String? {
        guard fieldShowing, !typed.trimmingCharacters(in: .whitespaces).isEmpty,
              launching || typed != shownAddress
        else { return nil }
        return typed
    }

    /// The address ⌘L brings up. Never a name and password written into it:
    /// they would be on screen, and in whatever you copy from there.
    private var shownAddress: String {
        active?.shownURL.map { url -> String in
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user != nil || parts.password != nil
            else { return url.absoluteString }
            parts.user = nil
            parts.password = nil
            return parts.string ?? ""
        } ?? ""
    }

    /// The field raised over a page put away whole, whichever key raised
    /// it, by that key pressed again. A blank tab's field is the tab, and
    /// stays.
    private func putAway() {
        if launching { dismiss(); return }
        guard active?.isBlank == false else { return }
        editing = false
        typed = ""
    }

    func newTab() {
        if websitePopup {
            if active?.shy == true { tabDestination.newShyTab() } else { tabDestination.newTab() }
            return
        }
        // On a private tab, a new one is private too: ⌘T from a page that
        // keeps nothing and landing on one that keeps everything is how a
        // private search ends up in the history.
        if active?.shy == true {
            newShyTab()
            return
        }
        // An extension's new tab page, if one asked and you said yes. One
        // added since that also asks is still asked, over the page it would
        // take the place of: which one has new tabs stays yours to say.
        if #available(macOS 15.4, *), let page = Extensions.shared.newTabPage {
            let tab = open(page, foreground: true)
            rememberSession()
            Extensions.shared.offerNewTabPage(into: tab)
            return
        }
        // Reuse an empty tab at the chosen position, clearing its draft:
        // repeated ⌘T must not leave a row of identical empty tabs. Never
        // one in a group: ⌘T's tab is in none, and an empty tab left in a
        // group took the page typed next into it (#1151).
        if let blank = tabs.last(where: { $0.isBlank && !$0.bench && !$0.shy && split(for: $0) == nil
                                          && !(prefs.usesTabGroups && group(of: $0) != nil) }) {
            placeBlank(blank)
            if activeID != blank.id { leaving() }
            activeID = blank.id
            typed = ""
            blank.draft = ""
            editing = false
            focusRequest += 1
            rememberSession()
            // Asked here too: an empty tab already there is the one the
            // first ⌘T after adding an extension lands on.
            if #available(macOS 15.4, *) { Extensions.shared.offerNewTabPage(into: blank) }
            return
        }
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        prepare(tab)
        tabs.insert(tab, at: placeForFront())
        leaving()
        activeID = tab.id
        typed = ""
        editing = false
        focusRequest += 1
        rememberSession()
        if #available(macOS 15.4, *) { Extensions.shared.offerNewTabPage(into: tab) }
    }

    /// A new tab given an extension's new tab page, whether blank or showing
    /// another extension's: the page needs a view built from that
    /// extension's configuration, so it is a new tab in the old one's place.
    func replaceNewTab(_ tab: Tab, with url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let url = Browser.page(url)
        let page = Tab(configuration: Browser.extensionConfiguration(for: url))
        prepare(page)
        page.groupID = tab.groupID
        replaceSplitMember(tab.id, with: page.id)
        tabs[index] = page
        page.go(to: url)
        if activeID == tab.id { activeID = page.id; editing = false }
    }

    func select(_ tab: Tab, floatPrevious: Bool = true, unfoldGroup: Bool = true) {
        if let pair = split(for: tab), activeSplit?.id == pair.id, activeID != tab.id {
            focusPane(tab)
            return
        }
        // A folded group opens for the tab you go to in it. With groups off,
        // they are kept as they were and nothing about them is saved.
        if unfoldGroup, prefs.usesTabGroups, let id = tab.groupID,
           let index = tabGroups.firstIndex(where: { $0.id == id }), tabGroups[index].collapsed {
            tabGroups[index].collapsed = false
            writeSession(now: true)
        }
        // A peek is over the tab it was opened from; another tab puts it
        // away, or, with Peek stays with its tab on, hides it until that tab
        // is back (see peekInFront).
        if peekTab != nil, tab.id != activeID, !prefs.peekStays { closePeek() }
        if tab.id != activeID, let here = active, here.isBlank { here.draft = typed }
        cancelTabEdit()
        suggesting = nil
        // Back on a tab with the caret still in a box, the list may come again.
        looked = nil
        guard tab.id != activeID else { return }
        // The AI panel is about the page it was opened on.
        if assisting != nil { closeAssistant() }
        // An extension's panel opened for one tab goes and comes with it.
        sidePanelFollows(tab)
        // Coming back to the tab whose video is out brings it home first, so
        // it is never lifted and landed in the same breath.
        if floating == tab.id { land() }
        if pictured == tab.id { unpicture() }
        if floatPrevious { leaving() }
        activeID = tab.id
        tab.touch()
        // A tab brought back from last time, or waking from ⌘W while pinned,
        // opens the moment you look at it — and only if there was nothing to
        // wake is this the other case, one whose page quietly died while you
        // were elsewhere, which revive() checks for on its own.
        if !tab.wake() { tab.revive() }
        // Show the page now rather than after SwiftUI's update (see PaneStage.show(now:)).
        if activeSplit == nil, let window { PaneStage.stages.object(forKey: window)?.show(now: tab) }
        if let pair = activeSplit {
            for other in tabs where pair.contains(other.id) && other.id != tab.id {
                if !other.isBlank, !other.wake() { other.revive() }
            }
        }
        rememberSession()
        editing = false
        typed = tab.isBlank ? tab.draft : ""
    }

    /// ⌘W closes what is in front: a peek, then a card over the page (What's
    /// New), then Hide Elements, Capture or the list of what is hidden on
    /// the site, then the tabs picked in the column, or else the tab. Settings,
    /// History and the rest are tabs of their own, as in Chrome, and ⌘W on
    /// one closes it. Escape puts things away in the same order, so the two
    /// keys agree on what is in front.
    func closeFront() {
        // The floating new tab is the thing in front: ⌘W takes it away and
        // leaves the page under it.
        if launching { dismiss(); return }
        // So is the field ⌘L raised over a page. It looks the same whichever
        // key raised it, and ⌘W closed the page under it unless ⌘T had: a
        // hand that learned ⌘W on one lost a tab to the other.
        // A blank tab's field is the tab itself, and goes with it as before.
        if editing, let tab = active, !tab.isBlank {
            editing = false
            typed = ""
            return
        }
        if peekInFront { closePeek() }
        else if closePanel() { return }
        // Hide Elements, Capture and the list of what is hidden here lie
        // over the page as panels do: ⌘W puts them away, as Escape does and
        // in its order, rather than closing the page under them.
        else if veiling { toggleHiding() }
        else if snapping { stopSnapping() }
        else if reviewing { reviewing = false }
        else if !pickedTabs.isEmpty { closePickedTabs() }
        else if let tab = active { closeTab(tab) }
        // Nothing in front: the window is what is left to close, as ⌘W on a
        // lone empty tab closes it.
        else { closeWindow() }
    }

    /// Close Tab as a hand asks for it: ⌘W, the cross or a middle click on
    /// the row, the tab's menu. A tab in a group is put away rather than
    /// closed, as Arc keeps a folder's tabs (idea 398): its page is let go,
    /// its row stays in the group, and a click opens it again at the page it
    /// was on. Asked again of a row already put away, it goes for good,
    /// remembered for ⇧⌘T, as Arc's cross on a folder tab that isn't open
    /// deletes it. Everything that closes many at once (Close Other Tabs,
    /// Close Tabs Below, Clear, Close Group) and every close the browser
    /// makes on its own still closes with close(_:). Closed quietly: ⇧⌘T
    /// brings it back, and a toast for every tab closed would be noise.
    func closeTab(_ tab: Tab) {
        if putsAway(tab) { return putAway(tab) }
        // A lone empty tab, with nothing beside it, is the window: ⌘W on it
        // closes the window, as ⌘W with nothing in front does (closeFront).
        if tabs.count == 1, tab.isBlank, activeID == tab.id { return closeWindow() }
        close(tab)
    }

    /// Whether Close Tab puts this tab away rather than closing it: a page
    /// open in a group, with groups on. Not an empty tab, which has nothing
    /// to come back to, nor one already put away or asleep: that one goes.
    func putsAway(_ tab: Tab) -> Bool {
        prefs.usesTabGroups && group(of: tab) != nil && !tab.asleep && !tab.isBlank && !tab.bench
            && tab.address != nil
    }

    /// A grouped tab's page let go where it stands, as a pin is put down:
    /// out of its pair, if it was in one, the row left in the group, and you
    /// on whatever you were looking at before (see landing). It comes back
    /// at the address it had: a tab in a group keeps no page of its own to
    /// go home to, as a pin does, so this is where it was, not where it was
    /// when grouped.
    func putAway(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        // Its page goes, and its peek, hidden or not, with it.
        if peekFrom == tab.id { closePeek() }
        let partner = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        leaveSplit(tab)
        heldDialogs.removeValue(forKey: tab.id)?.forEach { $0.dismiss() }
        dropQuestions(for: tab.id)
        if floating == tab.id { land(covering: false) }
        tab.rest()
        if activeID == tab.id { land(on: landing(leaving: tab, partner: partner)) }
        tabSwitcher.forget(tab.id)
        writeSession(now: true)
    }

    /// Where you land when the tab in front goes by your hand: closed, put
    /// away, put down, cleared, or moved to another space or window. One
    /// rule for all of them, in this order:
    ///
    /// 1. the other page of its pair, as Split View always had it;
    /// 2. the tab you were on before it, woken if it sleeps (see
    ///    TabSwitcher.lastLeft) — the tabs closed, put away or put down by
    ///    hand are forgotten there (TabSwitcher.forget), or ⌘W on one pin
    ///    went back to the pin before it, and the two took turns for ever;
    /// 3. the nearest tab that looks open, the one below first, then the
    ///    one above: a loose tab, awake or asleep, or a pin or a grouped tab
    ///    only while its page is open, as the switcher offers them. Off a
    ///    pin, never another pin you weren't on before: that is how ⌘W
    ///    landed you in one pin after another instead of getting you out;
    /// 4. nothing in front. A close never makes a new tab by itself: an
    ///    empty window is what is left when there is nothing to go to.
    ///
    /// With Settings › Tabs › Closing a tab goes back off, a loose tab closed
    /// lands on its neighbour first, as it always did; only a page a link
    /// just opened in front still goes back to the page it came from. Pins,
    /// grouped tabs and Eden's own pages go back whatever the switch says:
    /// History or Settings is called up over what you were doing, and a pin
    /// or a group's tab was gone to, not come across on the way down.
    ///
    /// `gone`: the other tabs going with it, which are no place to land.
    func landing(leaving tab: Tab, partner: Tab? = nil, gone: Set<Tab.ID> = []) -> Tab? {
        let gone = gone.union([tab.id])
        if let partner, !gone.contains(partner.id), tabs.contains(where: { $0.id == partner.id }) { return partner }
        let row = tabs.filter { !gone.contains($0.id) && standsInRow($0) }
        let back = tabSwitcher.lastLeft(among: Set(row.map(\.id)), other: tab.id)
            .flatMap { id in row.first { $0.id == id } }
        let alwaysBack = prefs.closeGoesBack || tab.pin != nil || tab.page != nil
            || (prefs.usesTabGroups && group(of: tab) != nil)
        if alwaysBack, let back { return back }
        // A page a link just opened in front goes back to the page it came
        // from, while that is still the tab you were on before it: it was
        // opened at the end of the row, and its neighbour there is a tab
        // you weren't reading.
        if let back, back.id == tab.opener { return back }
        return nearest(to: tab, among: row, pins: tab.pin == nil) ?? back
    }

    /// The nearest tab to `tab` in `row` that looks open, below it first.
    private func nearest(to tab: Tab, among row: [Tab], pins: Bool) -> Tab? {
        guard let at = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
        let ids = Set(row.map(\.id))
        let open: (Tab) -> Bool = { [self] other in
            guard ids.contains(other.id), pins || other.pin == nil else { return false }
            let loose = other.pin == nil && !(prefs.usesTabGroups && group(of: other) != nil)
            return loose || !other.asleep
        }
        return tabs[(at + 1)...].first(where: open) ?? tabs[..<at].last(where: open)
    }

    /// To where `landing` said: that tab, woken if it sleeps, or nothing in
    /// front.
    private func land(on next: Tab?, floatPrevious: Bool = true) {
        if let next { select(next, floatPrevious: floatPrevious) } else { showNothing() }
    }

    /// Nothing in front: the column as it is, with no row lit, and only the
    /// window's ground where a page would be. No field stands there unless
    /// ⌘T or ⌘L raises one, and no tab is made for it.
    func showNothing() {
        if assisting != nil { closeAssistant() }
        cancelTabEdit()
        suggesting = nil
        activeID = nil
        editing = false
        typed = ""
        rememberSession()
    }

    /// ⇧⌘W: the whole window, its tabs with it, as the red button closes it.
    func closeWindow() {
        window?.performClose(nil)
    }

    /// The panel over the page put away, if one is up — for ⌘W and Escape
    /// both. Whether there was one.
    func closePanel() -> Bool {
        // Settings, History and the rest are tabs now (InternalPages.swift):
        // ⌘W closes them as it closes any tab, and Escape leaves them be.
        if newsShowing { newsShowing = false }
        else { return false }
        return true
    }

    /// ⌘W, or the cross on the tab, and every close the browser makes. The
    /// tab in front closed lands where `landing` says, and on nothing in
    /// front when there is nowhere to go: the window stays open, empty.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // Its peek, hidden or not, goes with it.
        if peekFrom == tab.id { closePeek() }
        let pair = split(for: tab)
        let partner = pair.flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        leaveSplit(tab)
        heldDialogs.removeValue(forKey: tab.id)?.forEach { $0.dismiss() }
        dropQuestions(for: tab.id)

        // A tab whose page is out in the little window takes the window with
        // it. Left alone, the window would go on holding a page belonging to a
        // tab that no longer exists.
        if floating == tab.id { land(covering: false) }

        // A pinned tab is not closed by ⌘W — it is put down. The letter keeps
        // its place, the page is let go, and you land on whatever you were
        // looking at before. Only Unpin takes it out of the row.
        if tab.pin != nil {
            // Put down is also gone home, as Arc's pins are: the pin wakes on
            // the page it was pinned at, not wherever its links had taken it.
            tab.rest(at: tab.home)
            // Only the pin in front has anywhere to leave: one put down from
            // its menu or its row while you read another page leaves you on
            // that page, as putAway does.
            if activeID == tab.id { land(on: landing(leaving: tab, partner: partner)) }
            tabSwitcher.forget(tab.id)
            writeSession(now: true)
            return
        }

        // Where to go, worked out while the tab still has its place in the
        // row to measure from.
        let next = activeID == tab.id ? landing(leaving: tab, partner: partner) : nil
        remember(tab, at: index, partner: partner?.id, onLeft: pair?.isBefore(tab.id, partner?.id) ?? false)
        tab.close()
        tabs.remove(at: index)
        removeEmptyGroup(tab.groupID)
        // Through select(), same as everywhere else you land on a tab, so one
        // that was never built yet actually wakes up instead of sitting there
        // blank until a manual reload.
        if activeID == tab.id { land(on: next) }
        tabSwitcher.forget(tab.id)
        rememberSession()
    }

    /// What Close Other Tabs closes: the tabs Clear would, less this one and
    /// the rest of its split. Pins stay, and so do tab groups, as Clear keeps
    /// them: a place kept and a section named aren't "other tabs".
    func othersToClose(but keep: Tab) -> [Tab] {
        let kept = Set(split(for: keep)?.tabs ?? [keep.id])
        return tabs.filter { !kept.contains($0.id) && $0.pin == nil && !$0.bench && group(of: $0) == nil }
    }

    /// Everything but this one, of the tabs that come and go, remembered as
    /// one so a single ⇧⌘T brings them all back, as Clear and Close Tabs
    /// Below are. You stay where you are unless that page is going.
    func closeOthers(but keep: Tab) {
        // The list is read once: closing walks the row and can add to it.
        let going = othersToClose(but: keep)
        guard !going.isEmpty else { return }
        closingTogether(.tabs) { _ in
            // Off a page being closed first, so its neighbours do not wake
            // only to be closed in turn.
            if going.contains(where: { $0.id == activeID }) { select(keep) }
            // From the bottom, so the undo brings them back in order.
            for tab in going.reversed() { close(tab) }
        }
    }

    /// The row already follows the groups' order, including folded members.
    /// Both pages of the clicked split stay; pins keep their places too.
    func tabsBelow(_ tab: Tab) -> [Tab] {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return [] }
        let members = split(for: tab)?.tabs ?? []
        let end = members.compactMap { id in tabs.firstIndex { $0.id == id } }.max().map { max(index, $0) } ?? index
        return tabs.dropFirst(end + 1).filter { $0.pin == nil }
    }

    func closeTabsBelow(_ tab: Tab) {
        let going = tabsBelow(tab)
        guard !going.isEmpty else { return }
        closingTogether(.tabs) { _ in
            // Move off a page being closed before walking the row, so its
            // neighbours do not wake only to be closed in turn.
            if going.contains(where: { $0.id == activeID }) { select(tab) }
            // Undo inserts in reverse closing order. Closing from the bottom
            // brings them back in order even if tabs above have since gone.
            for page in going.reversed() {
                // A whole group below goes too. Remember it just before its
                // last member leaves, at its place among the groups still here.
                if let id = group(of: page), tabs(in: id).count == 1,
                   let at = tabGroups.firstIndex(where: { $0.id == id }) {
                    closedGroups[id] = (tabGroups[at], at)
                }
                close(page)
            }
        }
    }

    /// ⌘W, or the tab menu's Close Tabs, with tabs picked in the column (⌘-
    /// or ⇧-click): each one closed as ⌘W closes it — a pin put down, a tab
    /// in a group put away — and all remembered as one, so one ⇧⌘T brings
    /// them back. The pages on screen go last: closed first, a neighbour
    /// would wake only to be closed.
    func closePickedTabs() {
        let going = pickedTabs, onScreen = visibleTabIDs
        guard !going.isEmpty else { return }
        clearTabSelection()
        closingTogether(.tabs) { _ in
            for tab in going where !onScreen.contains(tab.id) { closeTab(tab) }
            for tab in going where onScreen.contains(tab.id) { closeTab(tab) }
        }
    }

    /// Arc's Clear, on the line above the tabs that come and go: each of
    /// them closed as ⌘W closes it, and all of it remembered as one, so a
    /// single ⇧⌘T puts every tab back. Pins stay, and so does a tab group:
    /// a section you named is one you are keeping. The page on screen goes
    /// last, landing where ⌘W would (see landing), or on nothing in front:
    /// closed first, a neighbour would wake only to be closed. No new tab
    /// is made in its place.
    func clearTabs() {
        let going = clearable
        guard !going.isEmpty else { return }
        closingTogether { batch in clear(going, batch: batch) }
    }

    /// What Clear closes: the tabs in no group, pins aside.
    private var clearable: [Tab] { tabs.filter { $0.pin == nil && !$0.bench && group(of: $0) == nil } }

    /// Whether Clear has anything to do, for Tabs › Clear Tabs.
    var canClearTabs: Bool { !clearable.isEmpty }

    /// Tabs closed as one act: remembered together, so
    /// that one ⇧⌘T brings every one of them back (see reopen(batch:)), and
    /// the one you were on, if it went too, in front.
    private func closingTogether(_ kind: CloseKind = .clear, _ close: (UUID) -> Void) {
        let batch = UUID(), was = activeID
        batching = (batch, kind)
        defer {
            batching = nil
            if let at = ghosts.lastIndex(where: { $0.batch == batch && $0.was == was }) { ghosts[at].front = true }
        }
        close(batch)
    }

    private func clear(_ going: [Tab], batch: UUID) {
        for tab in going where !visibleTabIDs.contains(tab.id) { close(tab) }
        let onScreen = going.filter { visibleTabIDs.contains($0.id) }
        // The other page of a pair first, so the one with the keys lands
        // where it would alone rather than on a page about to go.
        for tab in onScreen where tab.id != activeID { close(tab) }
        for tab in onScreen where tab.id == activeID { close(tab) }
    }

    /// A link let go of over the tabs becomes a tab among them.
    func take(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    // A page decides what a link dragged out of it carries: never
                    // script, nor an extension's page, which would open with
                    // that extension's own powers.
                    guard let url, !["javascript", "chrome-extension", "webkit-extension"].contains(url.scheme?.lowercased() ?? "")
                    else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let url = Address.url(from: text),
                          !["javascript", "chrome-extension", "webkit-extension"].contains(url.scheme?.lowercased() ?? "")
                    else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            }
        }
        return took
    }

    /// ⌘⇧T. Back into the row at the place it left.
    func reopen() {
        // A window closed after the last tab was: the window comes back, as
        // in Safari and Chrome (see Windows.swift).
        if let window = Browsers.lastClosedAt, window > (ghosts.last?.at ?? .distantPast), Browsers.reopenWindow() { return }
        guard let ghost = ghosts.last else { return }
        reopen(ghost)
    }

    /// Each bulk close has one place in History, however many tabs it held.
    var recentlyClosed: [Ghost] {
        var batches = Set<UUID>()
        return ghosts.reversed().filter { ghost in
            guard let batch = ghost.batch else { return true }
            return batches.insert(batch).inserted
        }
    }

    func closedTitle(for ghost: Ghost) -> String {
        guard let batch = ghost.batch else { return ghost.label }
        let count = ghosts.filter { $0.batch == batch }.count
        switch ghost.kind {
        case .group: return "Closed Group"
        case .clear: return count == 1 ? "Cleared Tab" : "\(count) Cleared Tabs"
        case .tabs: return count == 1 ? "Closed Tab" : "\(count) Closed Tabs"
        }
    }

    /// What ⇧⌘T brings back: one bulk close, or the last tab or window.
    var reopenTitle: String {
        guard let last = ghosts.last, last.batch != nil,
              (Browsers.lastClosedAt ?? .distantPast) <= last.at else { return "Reopen Closed Tab" }
        return "Reopen \(closedTitle(for: last))"
    }

    /// Everything one bulk close closed, back as it was: each tab
    /// at its place, the newest closed first, so each goes into the row as
    /// it stood just before that tab left it; a closed group comes back
    /// with its first tab, named as it was. They come back asleep, as last
    /// session's tabs do, but for the one you were on, which comes back in
    /// front; the empty tab Clear left there goes, if nothing has been
    /// typed into it. Closed from somewhere else, a pin say, you stay there.
    private func reopen(batch: UUID) {
        let members = ghosts.filter { $0.batch == batch }
        ghosts.removeAll { $0.batch == batch }
        var back: [Tab.ID: Tab] = [:]
        var front: Tab?
        var made: [Tab] = []
        var regrouped = false
        for ghost in members.reversed() {
            // One of Eden's own pages opened again since: it stays the one.
            // One that is gone (InternalPage.retired) stays closed.
            if let own = InternalPage(url: ghost.url), pageTab(own.kind) != nil { continue }
            if InternalPage.retired(ghost.url) { continue }
            let tab = Tab(configuration: Web.configuration(space: spaceID))
            prepare(tab)
            let group = regroup(ghost)
            tab.groupID = group.id
            regrouped = regrouped || group.back
            tab.muted = ghost.muted
            tab.restore(url: ghost.url, title: ghost.title, vouched: ghost.titleIsOwn, state: ghost.keepsake?.state)
            tabs.insert(tab, at: safeInsertionIndex(ghost.index))
            made.append(tab)
            if let was = ghost.was { back[was] = tab }
            if ghost.front { front = tab }
            // A pair cleared together: its other half came back just before,
            // beside it already. Made a pair again as it stands, not through
            // pair(), which would take the focus and wake both pages.
            if let id = ghost.partner, let partner = back[id], canSplit(tab, with: partner) {
                if let at = splits.firstIndex(where: { $0.contains(partner.id) }) {
                    // Three or four closed together: into the split the
                    // pages after it already made again.
                    var grown = splits[at]
                    if grown.insert(tab.id, beside: partner.id, before: ghost.onLeft),
                       Browser.holds(grown, in: tabs) { splits[at] = grown }
                } else {
                    let pair = TabSplit(tabs: ghost.onLeft ? [tab.id, partner.id] : [partner.id, tab.id], focused: tab.id)
                    if Browser.holds(pair, in: tabs) { splits.append(pair) }
                }
            }
        }
        if regrouped { arrangeGroupedTabs() }
        // The tab that was in front, or, when that one can't come back (an
        // empty pane has no address to be remembered by) and nothing is in
        // front, the first of them in the row: pages brought back stay out
        // of sight behind an empty window otherwise.
        if let front {
            select(front)
        } else if activeID == nil, let first = tabs.first(where: { tab in made.contains { $0.id == tab.id } }) {
            select(first)
        }
        rememberSession()
    }

    /// One tab or bulk close, from the History menu.
    func reopen(_ ghost: Ghost) {
        if let batch = ghost.batch {
            reopen(batch: batch)
            return
        }
        ghosts.removeAll { $0.id == ghost.id }
        // A page of Eden's that is gone (InternalPage.retired) stays closed.
        if InternalPage.retired(ghost.url) { return }
        // One of Eden's own pages: through show(_:), as ⌘, or ⌘Y opens it,
        // which keeps it one tab of its kind and readies what it lists.
        if let own = InternalPage(url: ghost.url) {
            show(own)
            return
        }
        if let pin = ghost.pin {
            reopen(pin, from: ghost)
            return
        }
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        prepare(tab)
        let group = regroup(ghost)
        tab.groupID = group.id
        tab.muted = ghost.muted
        leaving()
        tabs.insert(tab, at: safeInsertionIndex(ghost.index))
        if group.back { arrangeGroupedTabs() }
        activeID = tab.id
        editing = false
        typed = ""
        // With its history, the tab wakes as one that slept: the page it
        // was on, Back and Forward, its place on the page. Without (a page
        // still arriving when it closed), from its address.
        if let keepsake = ghost.keepsake {
            tab.restore(url: ghost.url, title: ghost.title, vouched: ghost.titleIsOwn, state: keepsake.state)
            _ = tab.wake()
        } else {
            tab.go(to: ghost.url)
        }
        // Back into its split beside the page it was beside, while that page
        // is alone or its split has room.
        if let id = ghost.partner, let partner = tabs.first(where: { $0.id == id }),
           canJoin(tab, beside: partner) {
            pair(tab, with: partner, onLeft: ghost.onLeft)
        }
    }

    /// A pin taken out for good, a pin again: its letter, its id, its page
    /// and its name, back at its place among the pins of its kind and in
    /// its folder while that is still there, every space's again if it
    /// was. Taken out asleep, it comes back asleep, and you stay where you
    /// are; taken out awake, from its menu, it comes back in front, with
    /// its history if it had any, as a tab does.
    private func reopen(_ pin: PinGhost, from ghost: Ghost) {
        let tab = Tab(configuration: Web.configuration(space: spaceID))
        prepare(tab)
        tab.restore(url: ghost.url, title: ghost.title, vouched: ghost.titleIsOwn, name: pin.name,
                    state: ghost.keepsake?.state)
        tab.muted = ghost.muted
        let awake = !pin.asleep
        if awake { leaving() }
        tabs.append(tab)
        makePin(tab, listed: pin.listed)
        tab.pin = pin.letter
        tab.home = pin.home ?? ghost.url
        if let id = pin.id, !tabs.contains(where: { $0.pinID == id }) { tab.pinID = id }
        if pin.listed, let group = pin.group, keptGroups.contains(where: { $0.id == group }) { tab.keptGroupID = group }
        let pins = tabs.filter { $0.pin != nil && $0.id != tab.id }
        var tier = pins.filter { $0.listed == pin.listed }
        tier.insert(tab, at: min(pinSlot(tab, listed: pin.listed, proposed: pin.slot), tier.count))
        let row = (pin.listed ? pins.filter { !$0.listed } + tier : tier + pins.filter(\.listed))
            + tabs.filter { $0.pin == nil }
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { tabs = row }
        if pin.everywhere, prefs.showsSharedPins {
            shareEverywhere(tab)
            if let id = tab.pinID { placeShared(id, listed: pin.listed, slot: pin.slot) }
        }
        if awake { select(tab) }
        writeSession(now: true)
        // Its kept title went with its pin; written back now the pin is.
        if !pin.homeTitle.isEmpty, let id = tab.pinID { Pins.retitle(id, pin.homeTitle, from: self) }
    }

    /// A pin every space shows, just shared again (shareEverywhere puts it
    /// after the others), moved back to `slot` among the shared pins of
    /// its kind, in every space and window.
    private func placeShared(_ id: UUID, listed: Bool, slot: Int) {
        var shared = Pins.shared(profileID)
        guard let at = shared.firstIndex(where: { $0.id == id }) else { return }
        let def = shared.remove(at: at)
        let kind = shared.indices.filter { (shared[$0].listed == true) == listed }
        let to = slot < kind.count ? kind[slot] : kind.last.map { $0 + 1 } ?? shared.count
        shared.insert(def, at: to)
        if Pins.setShared(shared, from: self) { sharedPinsChanged() }
    }

    /// The group a tab coming back goes into: its own, while groups are on
    /// and it is there to go into. A group Close Group took comes back first
    /// (closedGroups), named as it was and where it was, opened; `back` says
    /// so, for the row to be arranged around it.
    private func regroup(_ ghost: Ghost) -> (id: UUID?, back: Bool) {
        var back = false
        if prefs.usesTabGroups, let id = ghost.groupID, !tabGroups.contains(where: { $0.id == id }),
           let closed = closedGroups.removeValue(forKey: id) {
            var group = closed.group
            group.collapsed = false
            tabGroups.insert(group, at: min(closed.at, tabGroups.count))
            back = true
        }
        let id = prefs.usesTabGroups && tabGroups.contains(where: { $0.id == ghost.groupID }) ? ghost.groupID : nil
        return (id, back)
    }

    private func remember(_ tab: Tab, at index: Int, partner: Tab.ID? = nil, onLeft: Bool = false) {
        // Eden's own pages have no address, only their eden:// one: kept
        // by that, so ⇧⌘T after closing History brings History back rather
        // than the tab closed before it.
        guard !tab.shy, let url = tab.address ?? tab.page?.url else { return }
        ghosts.append(Ghost(url: url, title: tab.title, titleIsOwn: tab.titleIsOwn, index: index, groupID: tab.groupID,
                            partner: partner, onLeft: onLeft, was: tab.id, batch: batching?.id,
                            kind: batching?.kind ?? .clear, muted: tab.muted,
                            keepsake: tab.keepsake.map(Keepsake.init)))
        ghosts[ghosts.count - 1].space = spaceID
        // Your other devices offer it for a few minutes (Sync).
        NotificationCenter.default.post(name: Sync.tabsChanged, object: nil)
        // Twelve steps back, a Clear counting as one: its tabs come back
        // together or not at all, however many there were.
        var steps = Set<UUID>()
        let count = ghosts.reduce(0) { total, ghost in
            guard let batch = ghost.batch else { return total + 1 }
            return steps.insert(batch).inserted ? total + 1 : total
        }
        if count > 12, let oldest = ghosts.first {
            if let batch = oldest.batch { ghosts.removeAll { $0.batch == batch } } else { ghosts.removeFirst() }
        }
        closedGroups = closedGroups.filter { id, _ in ghosts.contains { $0.groupID == id } }
    }

    /// Dragged from one place in the row to another.
    func move(_ tab: Tab, to index: Int) {
        guard tabs.indices.contains(index) else { return }
        let target = tabs[index]
        let representative = split(for: target)?.left ?? target.id
        guard let destination = displayedTabs.firstIndex(where: { $0.id == representative }) else { return }
        moveDisplayedTab(tab, to: destination)
    }

    /// Put a tab in another space. If its store changes, ask only when the
    /// page has unsaved form entries; the new view then opens in that space.
    func move(_ tab: Tab, toSpace id: UUID, then: (() -> Void)? = nil) {
        guard prefs.usesSpaces, id != spaceID,
              spaces.contains(where: { $0.id == id }),
              !movableToSpace([tab]).isEmpty
        else { return }

        let complete: () -> Void = { [weak self, weak tab] in
            guard let self, let tab, self.finishMove(tab, toSpace: id) else { return }
            then?()
        }
        guard !tab.shy, tab.store !== Spaces.store(for: id) else {
            complete()
            return
        }
        let from = spaceID
        tab.unsaved { [weak self, weak tab] unsaved in
            guard let self, let tab, self.spaceID == from,
                  self.tabs.contains(where: { $0.id == tab.id }),
                  let destination = self.spaces.first(where: { $0.id == id })
            else { return }
            if unsaved {
                Ask.sure(
                    "Move Tab?",
                    detail: "This page has unsaved form entries. It will reopen in “\(destination.name)” with that Space’s sign-ins, so the entries may be lost.",
                    confirm: "Move",
                    then: complete
                )
            } else {
                complete()
            }
        }
    }

    /// Group menu › Move Group to Space: every tab of a group, in its order,
    /// into another space, where it is the same group — its name, folded or
    /// not — after that space's own groups. As Move to Space for one tab: a
    /// space with other sign-ins asks first only when a page has unsaved
    /// form entries, once for the group. `then` once it is there, for New
    /// Space… to go after it.
    func move(group id: UUID, toSpace target: UUID, then: (() -> Void)? = nil) {
        guard prefs.usesSpaces, target != spaceID,
              let destination = spaces.first(where: { $0.id == target }),
              let group = tabGroups.first(where: { $0.id == id })
        else { return }
        let members = tabs.filter { $0.groupID == id && $0.pin == nil && !$0.bench
            && $0.address.flatMap({ Browser.extensionHost(of: $0) }) == nil }
        guard !members.isEmpty else { return }
        let from = spaceID
        let complete: () -> Void = { [weak self] in
            guard let self, self.spaceID == from else { return }
            self.finishGroupMove(group, members.filter { tab in self.tabs.contains { $0.id == tab.id } }, to: destination)
            then?()
        }
        let store = Spaces.store(for: target)
        guard members.contains(where: { !$0.shy && $0.store !== store }) else { return complete() }
        // Any page with something typed and not sent, asked once.
        var unsaved = false
        let asked = DispatchGroup()
        for tab in members where !tab.shy && tab.store !== store {
            asked.enter()
            tab.unsaved { if $0 { unsaved = true }; asked.leave() }
        }
        asked.notify(queue: .main) {
            guard unsaved else { return complete() }
            Ask.sure(
                "Move Group?",
                detail: "A page in this group has unsaved form entries. The group will reopen in “\(destination.name)” with that Space’s sign-ins, so the entries may be lost.",
                confirm: "Move",
                then: complete
            )
        }
    }

    private func finishGroupMove(_ group: TabGroup, _ members: [Tab], to destination: Space) {
        guard !members.isEmpty else { return }
        stepAside(from: members)
        for tab in members { finishMove(tab, toSpace: destination.id, group: group, quietly: true) }
        writeSession(now: true)
        if let row = parked[destination.id] { writeSession(now: true, space: destination.id, row: row) }
        announce("Moved \(group.name) to \(destination.name)", look: .done)
    }

    /// The tab on screen going with `members` to another space or window:
    /// where ⌘W would land, none of them, comes to the front instead (see
    /// landing), or nothing does — not each of them in turn on the way out,
    /// waking as it goes.
    private func stepAside(from members: [Tab]) {
        guard let here = active, members.contains(where: { $0.id == here.id }) else { return }
        // The other page of its pair first, as ⌘W has it, when that one stays.
        let partner = split(for: here).flatMap { pair in tabs.first { $0.id == pair.partner(of: here.id) } }
        land(on: landing(leaving: here, partner: partner, gone: Set(members.map(\.id))), floatPrevious: false)
    }

    @discardableResult
    private func finishMove(_ tab: Tab, toSpace id: UUID, group: TabGroup? = nil, quietly: Bool = false) -> Bool {
        guard prefs.usesSpaces, id != spaceID,
              let destination = spaces.first(where: { $0.id == id }),
              let index = tabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        if let web = tab.built { cancelDisplay(for: web) }
        // Its peek, hidden or not, doesn't follow it to another space.
        if peekFrom == tab.id { closePeek() }
        let partner = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        leaveSplit(tab)

        if floating == tab.id { land() }
        if editingTab == tab.id { cancelTabEdit() }
        // The tab in front going: where ⌘W would land (see landing), or
        // nothing in front. The window stays open and empty rather than
        // making a tab to hold its place.
        if activeID == tab.id { land(on: landing(leaving: tab, partner: partner), floatPrevious: false) }
        tabs.remove(at: index)
        removeEmptyGroup(tab.groupID)

        tab.rehome(in: id)
        // Its group stays behind: the space it goes to has groups of its own
        // — unless the whole group is going (Move Group to Space).
        tab.groupID = group?.id
        var row = parked[id] ?? loadRow(id)
        if let group {
            var groups = row.groups ?? readRow(id).groups ?? []
            if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
            row.groups = groups
        }
        // A pin is that space's pin from now on, in pins.json too: kept only
        // in its row, the next look at the space's pins (another window's
        // change, a change to the shared pins, or a relaunch before the space
        // was opened) found it in no list and closed it.
        // Squares ahead of rows there too (see Browser.tiered).
        // Its kept group stays behind, as its open one does: at the top of
        // the rows there.
        tab.keptGroupID = nil
        if tab.pin != nil, !tab.everywhere, let pin = pinDefs([tab]).first {
            let defs = Pins.defs(id).filter { $0.id != pin.id } + [pin]
            Pins.set(id, defs.filter { $0.listed != true } + defs.filter { $0.listed == true }, from: self)
        }
        let squares = row.tabs.filter { $0.pin != nil && !$0.listed }.count
        let pins = row.tabs.firstIndex { $0.pin == nil } ?? row.tabs.count
        let place = tab.pin == nil ? row.tabs.count : (tab.listed ? pins : squares)
        row.tabs.insert(tab, at: place)
        if row.active == nil { row.active = tab.id }
        parked[id] = row

        guard !quietly else { return true }
        writeSession(now: true)
        writeSession(now: true, space: id, row: row)
        announce("Moved to \(destination.name)", look: .done)
        return true
    }

    // MARK: - a tab to another window

    /// One tab to another window (move(_:toWindow:front:at:)).
    func moveToWindow(_ tab: Tab, _ target: Browser?, at point: NSPoint? = nil) {
        move([tab], toWindow: target, at: point)
    }

    /// Move to Window, from the menu, and tabs dragged out of the column
    /// (dragOut): the one way tabs go to another window. Each that can go,
    /// in the order given, goes as it is, page and all, into the other
    /// window's row where a new tab would, or into a new window: `front` —
    /// the first, unless said — in front there and the only one woken; into
    /// a space with other sign-ins they reopen with those, as Move to Space
    /// does. A new window opens where they were let go (`point`), or where
    /// new windows open. Not a pin: pins are already in every window. Not
    /// every tab of this one into a new window, which would leave an empty
    /// one behind for nothing, unless it is one tab with a page.
    func move(_ tabs: [Tab], toWindow target: Browser?, front: Tab? = nil, at point: NSPoint? = nil) {
        guard target?.isPopup != true, target !== self,
              // A window of another profile is another browser: never there.
              target.map({ $0.profileID == profileID }) ?? true else { return }
        let going = tabs.filter { tab in tab.pin == nil && !tab.bench && self.tabs.contains { $0.id == tab.id } }
        guard let first = going.first,
              target != nil || going.count < self.tabs.count || (going.count == 1 && !first.isBlank) else { return }
        let destination = target ?? Browser(record: WindowRecord(space: spaceID))
        // The tab in front, going too, hands over to one that stays first:
        // left to each tab's leaving, it went to the next of them, which
        // woke on the way out and stayed awake behind the one in front there.
        // With none staying to go to, it leaves last, when there is no
        // tab left to wake.
        stepAside(from: going)
        let inFront = going.filter { $0.id == activeID }
        // Pairs among them come apart, as one tab moved leaves its pair.
        for tab in going.filter({ $0.id != activeID }) + inFront { detach(tab) }
        destination.receive(going, front: front.flatMap { front in going.first { $0 === front } } ?? first)
        bringUp(destination, made: target == nil, at: point)
    }

    /// The window tabs were moved to, in front: a new one where they were
    /// let go, its row under the hand, or else where new windows open.
    private func bringUp(_ destination: Browser, made: Bool, at point: NSPoint?) {
        if made {
            let frame = point.map { p -> NSRect in
                let size = window?.frame.size ?? NSSize(width: 1180, height: 780)
                return NSRect(x: p.x - 120, y: p.y - size.height + 20, width: size.width, height: size.height)
            }
            Browsers.open(destination, frame: frame)
        } else {
            destination.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// A tab dragged out of the row and let go outside this window: into
    /// the window it was let go over, or a new one there, as in Chrome and
    /// Safari. False when it was let go over this window, where the drag
    /// keeps its meaning, or can't leave (a pin).
    func dragOut(_ tab: Tab, at point: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard tab.pin == nil, !tab.bench, isPastEdge(point) else { return false }
        let over = Browsers.all.first { $0 !== self && $0.isOpen && !$0.isPopup && $0.profileID == profileID && $0.window?.frame.contains(point) == true }
        // Picked with others, they all go with it, as they move together
        // along the column (carried(with:)).
        let moving = isPickedAmongOthers(tab) ? carried(with: tab).filter { $0.pin == nil && !$0.bench } : [tab]
        guard over != nil || tabs.count > moving.count else { return false }
        // After the drag has let go, not inside it.
        DispatchQueue.main.async { [weak self] in self?.move(moving, toWindow: over, front: tab, at: point) }
        return true
    }

    /// Out of this window, with a little slack: a tab let go there leaves it.
    func isPastEdge(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        return !window.frame.insetBy(dx: -12, dy: -12).contains(point)
    }

    /// Out of this row, not closed: it is on its way to another window.
    private func detach(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // Its peek, hidden or not, doesn't follow it to another window.
        if peekFrom == tab.id { closePeek() }
        if let web = tab.built { cancelDisplay(for: web) }
        let partner = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        leaveSplit(tab)
        if floating == tab.id { land() }
        if editingTab == tab.id { cancelTabEdit() }
        // As a tab moved to another space: where ⌘W would land, or nothing
        // in front, the window left open and empty (see landing).
        if activeID == tab.id { land(on: landing(leaving: tab, partner: partner), floatPrevious: false) }
        tabs.remove(at: index)
        removeEmptyGroup(tab.groupID)
        tab.groupID = nil
        writeSession(now: true)
    }

    /// A tab from another window, in front here. An empty tab left alone
    /// there makes way for it.
    func receive(_ tab: Tab) {
        receive([tab], front: tab)
    }

    /// Tabs from another window, together where a new tab would go, in
    /// their order, `front` in front: only that one woken, if it was
    /// asleep. An empty tab left alone there makes way for them.
    func receive(_ moved: [Tab], front: Tab) {
        for tab in moved {
            prepare(tab)
            if !tab.shy { tab.rehome(in: spaceID) }
        }
        let blanks = tabs.filter { $0.isBlank && !$0.bench && split(for: $0) == nil }
        var row = tabs
        row.insert(contentsOf: moved, at: placeForNew())
        tabs = row
        select(front, floatPrevious: false)
        if tabs.count - blanks.count == moved.count + pinnedCount {
            for blank in blanks { tabs.removeAll { $0 === blank }; blank.close() }
        }
        if let active, active.id == front.id, front.asleep { _ = front.wake() }
        writeSession(now: true)
    }

    /// A section can be made empty, then filled from a tab's menu.
    @discardableResult
    func addTabGroup(containing tab: Tab) -> UUID {
        let id = UUID()
        tabGroups.append(TabGroup(id: id, name: "Group \(tabGroups.count + 1)", collapsed: false))
        editingGroupID = id
        move(tab, toGroup: id)
        // A tab that can't be in a group (a pin, a private one) leaves none behind.
        removeEmptyGroup(id)
        writeSession(now: true)
        return id
    }

    /// A group renamed, in either area. An emptied name leaves it as it was.
    func renameTabGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        changeGroup(id) { $0.name = String(trimmed.prefix(200)) }
    }

    /// A group's colour, from its menu: at once, and kept.
    func setColour(_ colour: GroupColour, ofGroup id: UUID) {
        changeGroup(id) { $0.colour = colour }
    }

    /// A group's own icon, or none: an open group's first tab's site icon
    /// stands for it then, a kept one's folder.
    func setIcon(_ icon: GroupIcon?, ofGroup id: UUID) {
        changeGroup(id) { $0.icon = icon }
    }

    /// One group changed, in either area, and kept where its area keeps
    /// it: an open group in the window's session, a kept one with the pins,
    /// in every window of the space (Pins.setGroups). Nothing when nothing
    /// changed.
    func changeGroup(_ id: UUID, _ change: (inout TabGroup) -> Void) {
        switch area(ofGroup: id) {
        case .kept:
            var groups = keptGroups
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
            let before = groups[index]
            change(&groups[index])
            guard groups[index] != before else { return }
            saveKeptGroups(groups)
        case .open:
            guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
            var group = tabGroups[index]
            change(&group)
            guard group != tabGroups[index] else { return }
            tabGroups[index] = group
            writeSession(now: true)
        case nil:
            return
        }
    }

    /// The group of the tab in front, for what ⌥⌘T opens a tab in.
    var activeGroupID: UUID? { active.flatMap(group(of:)) }

    /// New Tab in Group (⌥⌘T): an empty tab at the end of the group, in front.
    /// With no group given, the group of the tab in front, else a plain new tab.
    func newTab(inGroup id: UUID? = nil) {
        guard prefs.usesTabGroups, let id = id ?? activeGroupID, tabGroups.contains(where: { $0.id == id }),
              active?.shy != true else { return newTab() }
        newTab()
        guard let tab = active, tab.groupID != id else { return }
        move(tab, toGroup: id)
    }

    /// New Group (⌃⌘N): an empty tab in a group of its own, its name being
    /// typed, as Dia makes one.
    func newGroup() {
        guard prefs.usesTabGroups, active?.shy != true else { return newTab() }
        newTab()
        guard let tab = active, tab.pin == nil, !tab.shy else { return }
        addTabGroup(containing: tab)
    }

    /// Duplicate, in a group's menu: a group of the same name, colour and
    /// icon after it, folded as it is, with a fresh tab at each of its tabs'
    /// pages, made as each is shown. Always ordinary tabs in this space:
    /// a private member stays where it is, and Eden's own pages, of which
    /// there is one each, aren't copied.
    func duplicateTabGroup(_ id: UUID) {
        guard let at = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        let original = tabGroups[at]
        let members = tabs(in: id)
        let pages = members.filter { !$0.shy }
            .compactMap { tab in (tab.restAddress ?? tab.address).map { (url: $0, title: tab.title, own: tab.titleIsOwn) } }
            .filter { InternalPage(url: $0.url) == nil }
        guard !pages.isEmpty else { return }
        let copy = TabGroup(id: UUID(), name: original.name, collapsed: original.collapsed,
                            colour: original.colour, icon: original.icon)
        tabGroups.insert(copy, at: at + 1)
        var place = members.last.flatMap { last in tabs.firstIndex { $0.id == last.id } }.map { $0 + 1 } ?? tabs.count
        for page in pages {
            let tab = Tab(configuration: Browser.extensionConfiguration(for: page.url) ?? Web.configuration(space: spaceID))
            prepare(tab)
            tab.restore(url: page.url, title: page.title, vouched: page.own)
            tab.groupID = copy.id
            tabs.insert(tab, at: safeInsertionIndex(place))
            place = (tabs.firstIndex { $0.id == tab.id } ?? place) + 1
        }
        arrangeGroupedTabs()
        writeSession(now: true)
    }

    /// Copy All Links: every tab's address in the group, a line each, in
    /// either area.
    func copyLinks(of id: UUID) {
        copy(links: links(of: id))
    }

    /// Addresses on the pasteboard, a line each, and said so.
    func copy(links: [String]) {
        guard !links.isEmpty else { return }
        paste(links)
        announce(links.count == 1 ? "Link copied" : "\(links.count) links copied", look: .done)
    }

    /// A group's tabs' addresses, for Copy All Links in its menu and on its
    /// hover card (TabHoverCard).
    func links(of id: UUID) -> [String] {
        members(ofGroup: id).compactMap { ($0.restAddress ?? $0.address)?.absoluteString }
    }

    /// A group folded or opened, in either area: a kept one in every window.
    func toggleTabGroup(_ id: UUID) {
        guard let group = columnGroup(id) else { return }
        setGroupFolded(id, !group.collapsed)
    }

    func setGroupFolded(_ id: UUID, _ folded: Bool) {
        changeGroup(id) { $0.collapsed = folded }
    }

    /// Fold All Groups / Unfold All Groups, in the space's menu and the View
    /// menu, as in Arc: every group of the space on screen at once, above
    /// the line and under it, each keeping its tabs and its place. A folded
    /// group still shows the tab in front if that is one of its own, as one
    /// folded by hand does. The kept ones fold in every window of the space,
    /// as one folded by hand does.
    func foldAllGroups(_ fold: Bool) {
        let open = tabGroups.contains { $0.collapsed != fold }
        let kept = drawsKeptGroups && keptGroups.contains { $0.collapsed != fold }
        guard open || kept else { return }
        // On the fold's spring, as a heading's click folds one, from the
        // menus and the shortcuts alike.
        withAnimation(GroupLook.fold) {
            for index in tabGroups.indices where tabGroups[index].collapsed != fold {
                tabGroups[index].collapsed = fold
            }
            if kept {
                saveKeptGroups(keptGroups.map { group in
                    var group = group
                    group.collapsed = fold
                    return group
                })
            }
        }
        writeSession(now: true)
    }

    /// Whether the space on screen has a group to fold or unfold, in
    /// either area.
    var hasColumnGroups: Bool {
        (prefs.usesTabGroups && !tabGroups.isEmpty) || drawsKeptGroups
    }

    /// Whether Fold All Groups or Unfold All Groups has anything to do.
    var canFoldAllGroups: Bool {
        (prefs.usesTabGroups && tabGroups.contains { !$0.collapsed }) || (drawsKeptGroups && keptGroups.contains { !$0.collapsed })
    }
    var canUnfoldAllGroups: Bool {
        (prefs.usesTabGroups && tabGroups.contains { $0.collapsed }) || (drawsKeptGroups && keptGroups.contains { $0.collapsed })
    }

    /// Separate Tabs: the group goes and its tabs stay where they stand, in
    /// either area: a kept group's rows stay pinned (ungroupKept).
    func removeTabGroup(_ id: UUID) {
        if area(ofGroup: id) == .kept { return ungroupKept(id) }
        guard tabGroups.contains(where: { $0.id == id }) else { return }
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        tabGroups.removeAll { $0.id == id }
        arrangeGroupedTabs()
        if editingGroupID == id { editingGroupID = nil }
        writeSession(now: true)
    }

    /// Close Group, in a group's menu: the group and every tab in it, each
    /// closed as ⌘W closes it and remembered together, so one ⌘⇧T brings
    /// the group back whole (see closedGroups, reopen(batch:)). The page on screen goes last, as
    /// with Clear, so no neighbour wakes only to be closed.
    func closeTabGroup(_ id: UUID) {
        guard let at = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        closedGroups[id] = (tabGroups[at], at)
        let going = tabs.filter { $0.groupID == id }
        closingTogether(.group) { _ in
            for tab in going where !visibleTabIDs.contains(tab.id) { close(tab) }
            for tab in going where visibleTabIDs.contains(tab.id) { close(tab) }
        }
        // The group goes with its last tab; an empty one goes here.
        if tabGroups.contains(where: { $0.id == id }) { removeTabGroup(id) }
        writeSession(now: true)
    }

    func move(_ tab: Tab, toGroup id: UUID?) {
        guard tabs.contains(where: { $0.id == tab.id }), tab.pin == nil, !tab.shy, !tab.bench,
              id == nil || tabGroups.contains(where: { $0.id == id }) else { return }
        let previousGroup = tab.groupID
        guard previousGroup != id else { return }
        // A pair is one place in the row: moved into a group or out of one,
        // both halves go, and stay a pair. Dragged apart in the row, one
        // half leaves on its own (see dropTabIntoStrip).
        let partners = split(for: tab).map { pair in tabs.filter { pair.contains($0.id) && $0.id != tab.id } } ?? []
        // Into a group that has tabs: at the end of its run. A group stands
        // where its tabs do, so a tab only marked as its own would take the
        // whole group up to its place.
        let together = Set([tab.id] + partners.map(\.id))
        let moving = tabs.filter { together.contains($0.id) }
        var row = tabs.filter { !together.contains($0.id) }
        let end: Int? = id.flatMap { id in row.lastIndex { $0.groupID == id && $0.pin == nil } }
        tab.groupID = id
        for partner in partners { partner.groupID = id }
        if let end {
            row.insert(contentsOf: moving, at: end + 1)
            tabs = row
        }
        removeEmptyGroup(previousGroup)
        arrangeGroupedTabs()
        if let id, let index = tabGroups.firstIndex(where: { $0.id == id }) {
            tabGroups[index].collapsed = false
        }
        writeSession(now: true)
    }

    /// Insert relative to a visible member, after removing the carried item.
    /// Assign the completed row once: tabs' normalization must not see a half move.
    func move(_ tab: Tab, toGroup target: GroupDropTarget, detaching: Bool = false) {
        guard tabs.contains(where: { $0 === tab }),
              let groupIndex = tabGroups.firstIndex(where: { $0.id == target.group }) else { return }
        let moving = detaching ? [tab] : carried(with: tab)
        guard moving.allSatisfy({ $0.pin == nil && !$0.shy && !$0.bench }) else { return }
        let ids = Set(moving.map(\.id))
        var anchor: Tab?
        if let member = target.member {
            guard let found = tabs.first(where: { $0.id == member }),
                  found.groupID == target.group, found.pin == nil, !found.shy, !found.bench else { return }
            if ids.contains(member) { return }
            let pair = split(for: found).flatMap { pair in
                detaching && pair.contains(tab.id) ? nil : pair
            }
            let anchorID = target.after ? pair?.right : pair?.left
            anchor = anchorID.flatMap { id in tabs.first { $0.id == id } } ?? found
        }
        var row = tabs.filter { !ids.contains($0.id) }
        let insertion: Int
        if let anchor, let index = row.firstIndex(where: { $0 === anchor }) {
            insertion = index + (target.after ? 1 : 0)
        } else {
            insertion = row.lastIndex(where: { $0.groupID == target.group }).map { $0 + 1 }
                ?? row.firstIndex(where: { $0.pin == nil }) ?? row.count
        }
        let previous = Set(moving.compactMap(\.groupID))
        if detaching { leaveSplit(tab) }
        for member in moving { member.groupID = target.group }
        row.insert(contentsOf: moving, at: insertion)
        tabGroups[groupIndex].collapsed = false
        tabs = row
        for id in previous where id != target.group { removeEmptyGroup(id) }
        writeSession(now: true)
    }

    /// Carried out of its group and let go among the tabs in none (#1009):
    /// in front of the tab in no group, or the group, `before` names, or
    /// after them all. What goes with it goes too, as into a group: the tabs
    /// picked with it, a pair whole. A group left empty goes, as with Remove
    /// from Group.
    /// `detaching`: a pair's half on its own, out of its pair too, as into
    /// a group (move(_:toGroup:detaching:)).
    func move(_ tab: Tab, outOfGroupBefore before: SideItemID?, detaching: Bool = false) {
        guard prefs.usesTabGroups, tabs.contains(where: { $0 === tab }) else { return }
        let moving = detaching ? [tab] : carried(with: tab)
        guard moving.allSatisfy({ $0.pin == nil && !$0.shy && !$0.bench }),
              moving.contains(where: { group(of: $0) != nil }) else { return }
        let ids = Set(moving.map(\.id))
        var row = tabs.filter { !ids.contains($0.id) }
        let insertion: Int? = switch before {
        case .tab(let id)?: row.firstIndex { $0.id == id && $0.pin == nil && group(of: $0) == nil }
        case .group(let id)?: row.firstIndex { $0.pin == nil && $0.groupID == id && !ids.contains($0.id) }
        case nil: nil
        }
        let previous = Set(moving.compactMap(\.groupID))
        if detaching { leaveSplit(tab) }
        for member in moving { member.groupID = nil }
        row.insert(contentsOf: moving, at: insertion ?? row.count)
        tabs = row
        for id in previous { removeEmptyGroup(id) }
        writeSession(now: true)
    }

    /// The run under the pins as the column shows it with
    /// groups on: each tab in no group, and each group with its tabs, where
    /// it stands in the row.
    var sideItems: [SideItem] { items(of: displayedTabs) }

    /// `row`'s places under the pins, in its order: a group where its first
    /// tab is, its tabs together (arrangeGroupedTabs keeps them so). The
    /// kept area's are worked out the same way (keptItems).
    func items(of row: [Tab]) -> [SideItem] {
        ColumnTree.items(row.filter { $0.pin == nil }, group: \.groupID, groups: tabGroups, keepingEmpty: false)
    }

    /// A tab in no group, or a whole group, carried to another place in the
    /// run under the pins, the others making way: the row made again in the
    /// new order, a pair whole, a group's tabs together. Written a moment
    /// later, as a tab carried along the row always was: this runs each time
    /// the hand passes a neighbour.
    func moveItem(_ id: SideItemID, to index: Int) {
        var items = sideItems
        guard let from = items.firstIndex(where: { $0.id == id }), items.indices.contains(index), from != index else { return }
        let pins = displayedTabs.filter { $0.pin != nil }
        if case .tab(let tabID) = id, let tab = tabs.first(where: { $0.id == tabID }) {
            // The tabs picked with it go with it, in their order, as one
            // block (see moveDisplayedTab): beside the nearest place passed
            // that stays — a tab not picked, or a group with a tab not
            // picked, which stays where it is with the rest of its tabs. One
            // picked from a group comes out of it, as the tab carried is in
            // none; a group left empty goes.
            let moving = carried(with: tab)
            let ids = Set(moving.map(\.id))
            let passed = from < index ? Array(items[(from + 1)...index].reversed()) : Array(items[index..<from])
            guard let anchor = passed.first(where: { item in item.tabs.contains { !ids.contains($0.id) } }) else { return }
            var rest = items.compactMap { item -> SideItem? in
                switch item {
                case .tab(let other):
                    return ids.contains(other.id) ? nil : item
                case .group(let group, let members):
                    let kept = members.filter { !ids.contains($0.id) }
                    return kept.isEmpty ? nil : .group(group, kept)
                }
            }
            guard let at = rest.firstIndex(where: { $0.id == anchor.id }) else { return }
            let shown = Set(displayedTabs.map(\.id))
            rest.insert(contentsOf: moving.filter { shown.contains($0.id) }.map(SideItem.tab), at: from < index ? at + 1 : at)
            let previous = Set(moving.compactMap(\.groupID))
            for member in moving { member.groupID = nil }
            tabs = expandingPairs(pins + rest.flatMap(\.tabs))
            for group in previous { removeEmptyGroup(group) }
        } else {
            items.insert(items.remove(at: from), at: index)
            tabs = expandingPairs(pins + items.flatMap(\.tabs))
        }
        rememberSession()
    }

    /// Reorder only among peers in the displayed section. The underlying
    /// tab row remains flat for keyboard shortcuts and the top strip.
    func move(_ tab: Tab, within group: UUID?, to index: Int) {
        let peers = tabs(in: group).filter(standsInRow)
        guard let from = peers.firstIndex(where: { $0.id == tab.id }),
              peers.indices.contains(index), from != index,
              let destination = tabs.firstIndex(where: { $0.id == peers[index].id }) else { return }
        move(tab, to: destination)
    }

    /// The row in the order it is shown: the pins, then the tabs in no group
    /// and the groups as they stand, each group's tabs together where its
    /// first one is — groups among the tabs anywhere, not above them. The
    /// one place that order is made, run after every change to the row (see
    /// `tabs`) and to a group; the groups' own list follows it. Nothing
    /// while groups are off: the row stays as you left it.
    func arrangeGroupedTabs(_ on: Bool? = nil) {
        guard on ?? prefs.usesTabGroups else { return }
        let representatives = displayedTabs
        let pins = representatives.filter { $0.pin != nil }
        let items = items(of: representatives)
        let standing = items.compactMap { item -> UUID? in
            if case .group(let group, _) = item { return group.id }
            return nil
        }
        if !tabGroups.map(\.id).starts(with: standing) {
            let placed = Set(standing)
            tabGroups = standing.compactMap { id in tabGroups.first { $0.id == id } }
                + tabGroups.filter { !placed.contains($0.id) }
        }
        let order = expandingPairs(pins + items.flatMap(\.tabs))
        // Setting the row runs this again, which then finds nothing to do.
        guard !order.elementsEqual(tabs, by: { $0.id == $1.id }) else { return }
        tabs = order
    }

    /// Each pair's left half standing for it, given back as both halves.
    func expandingPairs(_ representatives: [Tab]) -> [Tab] {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pairs = prefs.splitView ? Dictionary(splits.map { ($0.left, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        return representatives.flatMap { tab -> [Tab] in
            guard let pair = pairs[tab.id] else { return [tab] }
            return pair.tabs.compactMap { byID[$0] }
        }
    }

    /// The group a tab is shown in: none for a pin, or for a group this space
    /// doesn't have, which is shown with the loose tabs rather than lost.
    func group(of tab: Tab) -> UUID? {
        guard tab.pin == nil, let id = tab.groupID, tabGroups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func tabs(in group: UUID?) -> [Tab] {
        grouping(tabs)[group] ?? []
    }

    /// The loose tabs among `row`, by the group each is shown in (nil for
    /// none), in one walk of it: `group(of:)` looks through every group.
    private func grouping(_ row: [Tab]) -> [UUID?: [Tab]] {
        let known = Set(tabGroups.map(\.id))
        var buckets: [UUID?: [Tab]] = [:]
        for tab in row where tab.pin == nil {
            let id = tab.groupID.flatMap { known.contains($0) ? $0 : nil }
            buckets[id, default: []].append(tab)
        }
        return buckets
    }

    /// A folded group shows its name alone — and the tab you are on, if it
    /// is in there, so the page on screen always has its place in the row.
    /// In either area.
    func visibleTabs(in group: TabGroup) -> [Tab] {
        visible(group, among: members(ofGroup: group.id), off: pairedOff)
    }

    private func visible(_ group: TabGroup, among members: [Tab], off: Set<Tab.ID>) -> [Tab] {
        let shown = members.filter { !off.contains($0.id) }
        return group.collapsed ? shown.filter { $0.id == (activeSplit?.left ?? activeID) } : shown
    }

    /// A group lasts as long as its tabs: the last one gone, it goes too.
    func removeEmptyGroup(_ id: UUID?) {
        guard let id, !tabs.contains(where: { $0.groupID == id }) else { return }
        tabGroups.removeAll { $0.id == id }
        if editingGroupID == id { editingGroupID = nil }
    }

    /// The tabs as they are on screen: the squares, then each area's tabs
    /// and groups, the ones folded away in a group, above the line or under
    /// it, not among them. Tab cycling and selection ranges count these;
    /// number shortcuts also give folded groups a place of their own.
    var shownTabs: [Tab] {
        let row = displayedTabs
        let squares = row.filter { $0.pin != nil && !$0.listed }
        let kept = keptItems()
        let open = prefs.usesTabGroups ? items(of: row) : row.filter { $0.pin == nil }.map(SideItem.tab)
        return squares + (kept + open).flatMap { item -> [Tab] in
            switch item {
            case .tab(let tab): return [tab]
            case .group(let group, let members): return visible(group, among: members, off: [])
            }
        }
    }

    /// Number shortcuts count a folded group once, in either area, even
    /// while its active tab is shown below its heading: the squares, then
    /// the kept area's rows and groups, then the open area's, as they are
    /// drawn down the column. Other tab navigation keeps using shownTabs.
    var tabShortcutTargets: [(id: UUID, tab: Tab)] {
        let row = displayedTabs
        let squares = row.filter { $0.pin != nil && !$0.listed }
        let kept = keptItems()
        let open = prefs.usesTabGroups ? items(of: row) : row.filter { $0.pin == nil }.map(SideItem.tab)
        return squares.map { ($0.id, $0) } + (kept + open).flatMap { item -> [(id: UUID, tab: Tab)] in
            switch item {
            case .tab(let tab):
                return [(tab.id, tab)]
            case .group(let group, let members):
                guard group.collapsed else { return members.map { ($0.id, $0) } }
                let current = active.flatMap { columnGroupID(of: $0) == group.id ? $0 : nil }
                guard let tab = current ?? members.max(by: { $0.touched < $1.touched }) else { return [] }
                return [(group.id, tab)]
            }
        }
    }

    @Published var commandHeld = false

    /// Only nine hints, worked out once for the window rather than by each tab.
    var tabShortcutNumbers: [UUID: Int] {
        guard prefs.showsTabShortcuts, commandHeld else { return [:] }
        let shown = tabShortcutTargets
        var numbers = Dictionary(uniqueKeysWithValues: shown.prefix(8).enumerated().map { ($0.element.id, $0.offset + 1) })
        if shown.count > 8, let last = shown.last { numbers[last.id] = 9 }
        return numbers
    }

    func clearTabSelection() {
        if !selectedTabIDs.isEmpty { selectedTabIDs.removeAll() }
        selectionAnchor = nil
    }

    /// Command toggles one tab; Shift picks the visible run from the last
    /// clicked tab (or the active tab when a selection begins). With the
    /// setting on, a pin clicked with ⌘ (and no ⇧) opens a new tab or moves
    /// a wandered tab instead.
    func extendTabSelection(to tab: Tab, modifiers: NSEvent.ModifierFlags) {
        if prefs.pinCommandOpensTab, tab.pin != nil, modifiers.contains(.command), !modifiers.contains(.shift) {
            commandClickPin(tab)
            return
        }
        let shown = selectableTabs.map(\.id)
        guard let end = shown.firstIndex(of: tab.id) else { return }
        if modifiers.contains(.shift) {
            let startID = selectionAnchor ?? activeID ?? tab.id
            let start = shown.firstIndex(of: startID) ?? end
            let range = Set(shown[min(start, end)...max(start, end)])
            selectedTabIDs = modifiers.contains(.command) ? selectedTabIDs.union(range) : range
            selectionAnchor = shown[start]
        } else if modifiers.contains(.command) {
            if selectedTabIDs.isEmpty, let active = activeID,
               shown.contains(active) {
                selectedTabIDs.insert(active)
            }
            if !selectedTabIDs.insert(tab.id).inserted { selectedTabIDs.remove(tab.id) }
            selectionAnchor = tab.id
        }
    }

    private var selectableTabs: [Tab] {
        shownTabs.flatMap { tab in
            split(for: tab).map { pair in pair.tabs.compactMap { id in tabs.first { $0.id == id } } } ?? [tab]
        }
    }

    var visibleSelectedTabCount: Int {
        selectableTabs.filter { selectedTabIDs.contains($0.id) }.count
    }


    var selectedTabLinks: [String] {
        selectableTabs.compactMap { tab in
            selectedTabIDs.contains(tab.id) ? tab.address?.absoluteString : nil
        }
    }

    /// ⌃Tab, ⌃⇧Tab: the next tab on screen, round to the first again. It
    /// walks the whole row from the tab you are on, so it finds its way out
    /// even when that tab is one the row doesn't show.
    func step(_ direction: Int) {
        // From nothing in front: the first tab the column shows, or going
        // backwards the last.
        guard activeID != nil else {
            let shown = shownTabs
            if let next = direction > 0 ? shown.first : shown.last { select(entry(next)) }
            return
        }
        let shown = Set(shownTabs.map(\.id))
        guard let anchor = activeSplit?.left ?? activeID,
              shown.count > 1 || (shown.count == 1 && !shown.contains(anchor)),
              let here = tabs.firstIndex(where: { $0.id == anchor }) else { return }
        for n in 1..<tabs.count {
            let next = tabs[((here + direction * n) % tabs.count + tabs.count) % tabs.count]
            if shown.contains(next.id) { select(entry(next)); return }
        }
    }

    /// Where a key that picks a place in the row lands: a pair's page that
    /// had the keys last, not always its first.
    private func entry(_ tab: Tab) -> Tab {
        guard let pair = split(for: tab), pair.left == tab.id, let id = pair.focused,
              let focused = tabs.first(where: { $0.id == id }) else { return tab }
        return focused
    }

    /// ⌘1–8: a tab or folded group in that place, without unfolding it.
    /// With Settings › Tabs › A pin's number again goes back, the number of
    /// the pin you're on takes you back to the tab you were on before it.
    func select(index: Int) {
        let targets = tabShortcutTargets
        guard targets.indices.contains(index) else { return }
        let tab = entry(targets[index].tab)
        if prefs.pinNumberGoesBack, tab.pin != nil, activeID == tab.id, let back = tabBefore(tab) {
            select(back)
            return
        }
        select(tab, unfoldGroup: false)
    }

    /// The tab last left that is still in the row, other than `tab`.
    func tabBefore(_ tab: Tab) -> Tab? {
        let row = tabs.filter(standsInRow)
        guard let id = tabSwitcher.lastLeft(among: Set(row.map(\.id)), other: tab.id) else { return nil }
        return row.first { $0.id == id }
    }

    /// ⌃Tab: the space's tabs, the most recently used first, and the small
    /// windows beside them. Nothing changes until ⌃ is let go of
    /// (`commitTabSwitch`).
    func switchTabs(backwards: Bool) {
        // With nothing in front, too: the gesture starts on the tab left
        // last, with no card of its own (TabSwitcher.step).
        tabSwitcher.partners = switcherPartners
        tabSwitcher.step(row: switcherRow, current: activeSplit?.left ?? activeID,
                         backwards: backwards, moons: LittleWindow.stacked, behindFirst: prefs.switcherBehindFirst)
    }

    /// The row's tabs the switcher offers: not a pin put down, nor a grouped
    /// tab put away, which hold no page and are drawn dimmed in the column as
    /// closed (#1092). With `tabs.switcherLeavesOutPins` on, pinned tabs are
    /// left out (#1110). The tab you're on stays, whatever it is.
    private var switcherRow: [Tab.ID] {
        let current = activeSplit?.left ?? activeID
        let leavesOutPins = prefs.switcherLeavesOutPins
        return tabs.filter { tab in
            standsInRow(tab) && (!leavesOutPins || tab.pin == nil || tab.id == current)
                && (tab.id == current || !tab.asleep
                    || (tab.pin == nil && !(prefs.usesTabGroups && group(of: tab) != nil)))
        }.map(\.id)
    }

    /// A pair once, under its first page, pictured with its other one.
    var switcherPartners: [Tab.ID: Tab.ID] {
        prefs.splitView ? Dictionary(splits.map { ($0.left, $0.right) }, uniquingKeysWith: { first, _ in first }) : [:]
    }

    /// The row as the switcher's grid shows it, for a small window's
    /// switcher to show as its planet (see TabSwitcher.ordered).
    var switcherPlanet: [Tab.ID] {
        tabSwitcher.ordered(row: switcherRow, current: activeSplit?.left ?? activeID,
                            behindFirst: prefs.switcherBehindFirst)
    }

    /// A letter pressed on a card while a switcher is up (see
    /// TabSwitcher.Action): the card's tab, or its small window, as its ⌘
    /// key would have it. `switcher` is the one the card is in, this
    /// window's or a small window's.
    func act(_ action: TabSwitcher.Action, onCard id: Tab.ID, in switcher: TabSwitcher) {
        if let little = LittleWindow.holding(id) { return little.act(action, in: switcher) }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // A pair is one card: what's done to it is done to both its pages.
        let partner = switcher.partners[id].flatMap { other in tabs.first { $0.id == other } }
        switch action {
        case .close:
            // A pin not on screen is put down where it is and keeps its
            // card, as ⌘W puts one down, without taking you anywhere; a tab
            // in a group is put away the same way (closeTab).
            if tab.pin != nil || putsAway(tab), id != activeID, partner == nil {
                tab.rest()
                writeSession(now: true)
                return switcher.redraw()
            }
            switcher.remove(id)
            close(tab)
            if let partner { close(partner) }
        case .reload:
            tab.reload()
            partner?.reload()
        case .mute:
            tab.toggleMute()
            partner?.toggleMute()
            switcher.redraw()
        case .keep:
            break
        }
    }

    /// A tab picked in a small window's switcher: that tab, in this window,
    /// in front. A test run goes to the tab and puts nothing on a screen.
    func bringForward(_ id: Tab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        select(entry(tab))
        guard !Store.testing, let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// A click while the switcher is up, at a point in the window's own
    /// top-left coordinates: on a card, that card; outside the panel, the
    /// switcher goes. True when the click was the switcher's. Taken before any
    /// view sees it, because ⌃ is held for as long as the switcher is up, and
    /// a ⌃-click is a right-click to AppKit, not a click the card's button
    /// can be counted on to take. From #358, by oddharsh.
    func clickTabSwitcher(at point: CGPoint) -> Bool {
        tabSwitcher.click(at: point) { commitTabSwitch(picking: $0) }
    }

    func commitTabSwitch(picking id: Tab.ID? = nil) {
        guard let target = tabSwitcher.finish(picking: id) else { return }
        if let tab = tabs.first(where: { $0.id == target }) {
            select(entry(tab))
        } else {
            // A moon: its small window comes forward, and the row stays as
            // it was. Open in Eden is still what moves it in.
            LittleWindow.holding(target)?.front()
        }
    }

    /// A popup has one page; links that need tabs return to its Space.
    private var tabDestination: Browser {
        guard websitePopup else { return self }
        let destination = Browsers.ensureWindow()
        destination.switchSpace(to: spaceID)
        return destination
    }

    /// A link opened from a page lands next to the page it came from, not at
    /// the far end of the row — unless it is one of a batch, which keeps the
    /// order it came in.
    ///
    /// `link`: opened out of a page by a click (⌘-click, the middle button):
    /// after the ones that page already opened (see placeForLink).
    ///
    /// `from`: the tab it was opened out of. A private one's opens private,
    /// in the same store, as a link that asks for a new window already does.
    ///
    /// `mayWait`: opened behind the page by hand, or one of a batch of links
    /// from another app. With Settings › Tabs › Load background tabs when
    /// you go to them, such a tab keeps its address and loads nothing until
    /// it is gone to, as a tab brought back from the last session does. A
    /// tab in front always loads, and so does one an extension opens, which
    /// may be waiting on its page.
    @discardableResult
    func open(_ url: URL, foreground: Bool, atEnd: Bool = false, from source: Tab? = nil, mayWait: Bool = false,
              link: Bool = false, loose: Bool = false) -> Tab {
        if websitePopup {
            return tabDestination.open(url, foreground: foreground, atEnd: atEnd, from: source ?? active, mayWait: mayWait, link: link,
                                       loose: loose)
        }
        // One of Eden's own pages, from a link, a script or another app:
        // its own tab, one of each (see InternalPages.swift).
        if let own = InternalPage(url: url) { return show(own) }
        // An extension's own page is served only to a view built from that
        // extension's configuration.
        let url = Browser.page(url)
        let page = Browser.extensionConfiguration(for: url)
        // A new tab is in this window's space, with its sign-ins — not the
        // space of whichever window is in front, when this one is behind it.
        let tab = if let source, source.shy, page == nil {
            Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
        } else {
            Tab(configuration: page ?? Web.configuration(space: spaceID))
        }
        prepare(tab)
        // A link opened from a grouped tab joins its group, only while groups
        // are on: turned off, they sleep, and nothing new goes into one.
        // `loose`: the floating new tab's, which is ⌘T's tab and came
        // from no page. Raised over a grouped tab it went into that group,
        // where a blank ⌘T's tab never did; it goes where that one goes.
        let joins = prefs.usesTabGroups && !loose && !tab.shy && !tab.bench
        if joins, let source { tab.groupID = source.groupID }
        let apart = loose && prefs.usesTabGroups && source.map { group(of: $0) != nil } == true
        tabs.insert(tab, at: atEnd ? tabs.count : link ? placeForLink(from: source) : apart ? placeForFront() : placeForNew())
        if link, !atEnd, !foreground || frontLinksBeside { noteLink(tab, from: source) }
        if mayWait, !foreground, prefs.lazyTabs, page == nil {
            tab.restore(url: url, title: "", vouched: false)
        } else {
            tab.go(to: url)
        }
        if foreground {
            leaving()
            activeID = tab.id
            editing = false
            typed = ""
        }
        return tab
    }

    /// An extension's page sending its own tab to a website — 1Password's
    /// "Sign in" does, when its Mac app isn't connected. The page's view was
    /// built from the extension's configuration, which WebKit keeps to that
    /// extension's own pages, so the load went nowhere and the button did
    /// nothing. The tab is swapped where it stands for an ordinary one on
    /// the site: to the eye, the page went there. The other way round too:
    /// an extension sending a website's tab to one of its own pages.
    func replace(_ tab: Tab, going url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // A private tab stays private, and keeps its own sign-ins when it
        // had them; an extension's page it showed was in that extension's
        // store, so going back to the web takes a new private one.
        let page = Browser.extensionConfiguration(for: url)
        let fresh = if tab.shy {
            Tab(shy: true, bench: tab.bench, configuration: page
                ?? Web.configuration(shy: true, store: tab.store.isPersistent ? nil : tab.store))
        } else {
            Tab(bench: tab.bench, configuration: page ?? Web.configuration(space: spaceID))
        }
        // Preserve the sign-in popup's link to the page that opened it —
        // and, since a website can now start the swap, what you made of the
        // tab: a pinned one stays pinned, a named one keeps its name.
        fresh.opener = tab.opener
        fresh.popup = tab.popup
        fresh.pin = tab.pin
        fresh.listed = tab.listed
        // And it stays the same pin. With no id of its own it would be given
        // a new one, and every other window would close its tab for the old
        // pin and make a sleeping one for the new, losing the page it had
        // there; with no home, the page it was pinned at would become
        // wherever this swap went; and a pin every space shows would be
        // written back as this space's own (see writeSession).
        fresh.pinID = tab.pinID
        fresh.home = tab.home
        fresh.everywhere = tab.everywhere
        fresh.name = tab.name
        prepare(fresh)
        fresh.groupID = tab.groupID
        let wasActive = activeID == tab.id
        replaceSplitMember(tab.id, with: fresh.id)
        tabs[index] = fresh
        fresh.go(to: url)
        if wasActive { activeID = fresh.id }
        tab.close()
        rememberSession()
    }

    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.current(url) }
        return url
    }

    /// The extension an address belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// The configuration for an extension's page, or nil for anything else.
    static func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return Extensions.shared.controller.extensionContext(for: url)?.webViewConfiguration
    }

    /// A page for the bench: at the end of the row, behind whatever you are
    /// looking at, and marked as not yours. `shy`: a private one, for a test run.
    @discardableResult
    func benchOpen(_ url: URL, shy: Bool = false) -> Tab {
        let url = Browser.page(url)
        let tab = Tab(shy: shy, bench: true, configuration: shy ? nil : Browser.extensionConfiguration(for: url))
        prepare(tab)
        tabs.append(tab)
        tab.go(to: url)
        return tab
    }

    /// A link from another app. A blank tab with nothing typed in it takes
    /// the page rather than staying behind as an empty one; otherwise the
    /// page gets a tab of its own, in front.
    func arrive(_ url: URL) {
        if let active, active.isBlank, typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A page from a list of them: into the tab you are on — into a new one
    /// with ⌘ held, or when the one you are on is busy playing in the float.
    func visit(_ url: URL) {
        let apart = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let active, !apart, !active.floating {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: true, from: active)
        }
    }

    /// ⌘⇧N. A tab that keeps nothing — its own cookies, its own sign-ins, no
    /// history, and no place in tomorrow's session.
    func newShyTab() {
        if websitePopup { tabDestination.newShyTab(); return }
        // Never two empty private tabs, as ⌘T never makes two empty ones:
        // one already open is moved to the chosen position.
        if let blank = tabs.last(where: { $0.isBlank && $0.shy && !$0.bench && split(for: $0) == nil }) {
            placeBlank(blank)
            if activeID != blank.id { leaving() }
            activeID = blank.id
            typed = ""
            blank.draft = ""
            editing = false
            focusRequest += 1
            return
        }
        let tab = Tab(shy: true)
        prepare(tab)
        tabs.insert(tab, at: placeForFront())
        leaving()
        activeID = tab.id
        typed = ""
        editing = false
        focusRequest += 1
    }

    /// Tabs › Duplicate Tab. The same page, beside itself (see duplicate(_:)).
    func duplicate() { duplicate(frontTabs) }

    /// ⌘⇧V, when nothing is being typed. What is in the clipboard, if it is a
    /// place — or a search — in the tab you're on.
    func pasteAndGo() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            refusals += 1
            return
        }
        // With nothing in front, a tab of its own, never a pin of the row.
        if let active { active.go(to: url) } else { open(url, foreground: true, loose: true) }
        editing = false
        typed = ""
    }

    /// File › Export as PDF…. Unlike Print, this keeps the page's screen
    /// layout and takes its whole current length. WebKit splits only a page
    /// taller than a PDF page can be (200 inches).
    func exportPDF() {
        askWhereToSave(active, as: .pdf, ending: "pdf") { [weak self] tab, file in
            self?.exportPDF(tab, to: file)
        }
    }

    /// File › Save Page As…: the page with its pictures and styles in one
    /// web archive, as Safari's Save As makes it. It opens again in Eden
    /// or Safari, offline too.
    func savePage() {
        askWhereToSave(active, as: .webArchive, ending: "webarchive") { [weak self] tab, file in
            self?.savePage(tab, to: file)
        }
    }

    /// The save panel for a page, named after its title (or its site), in
    /// Downloads.
    private func askWhereToSave(_ tab: Tab?, as type: UTType, ending: String, then save: @escaping (Tab, URL) -> Void) {
        guard let tab, tab.isWeb, let window = tab.web.window ?? self.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (title.isEmpty ? tab.pageAddress?.host() ?? "Page" : title)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = stem.lowercased().hasSuffix(".\(ending)") ? stem : stem + ".\(ending)"
        panel.directoryURL = downloadsFolder
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let file = panel.url else { return }
            save(tab, file)
        }
    }

    /// Keep the tab the save panel was opened for, even if another is active
    /// when it finishes. The bench passes the current tab without a panel.
    func exportPDF(_ tab: Tab, to file: URL, finished: ((Bool) -> Void)? = nil) {
        guard tab.isWeb else {
            finished?(false)
            return
        }
        tab.web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            guard let self else { finished?(false); return }
            keep(result, at: file, failed: "Couldn't export page", finished: finished)
        }
    }

    /// What WebKit made of a page, written where it was asked for. Off the
    /// main thread: a long page's PDF runs to tens of megabytes, and a folder
    /// on a network or in iCloud can take its time.
    private func keep(_ result: Result<Data, Error>, at file: URL, failed: String, marked: Bool = false,
                      finished: ((Bool) -> Void)?) {
        guard case .success(let data) = result else {
            announce(failed, look: .problem)
            finished?(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let wrote = (try? data.write(to: file, options: .atomic)) != nil
            if wrote, marked { Browser.markDownloaded(file) }
            DispatchQueue.main.async {
                if wrote { self?.announce("Saved \(file.lastPathComponent)", look: .done, file: file) } else { self?.announce(failed, look: .problem) }
                finished?(wrote)
            }
        }
    }

    /// As exportPDF(_:to:finished:), for Save Page As….
    func savePage(_ tab: Tab, to file: URL, finished: ((Bool) -> Void)? = nil) {
        guard tab.isWeb else {
            finished?(false)
            return
        }
        tab.web.createWebArchiveData { [weak self] result in
            guard let self else { finished?(false); return }
            keep(result, at: file, failed: "Couldn't save page", marked: true, finished: finished)
        }
    }

    /// ⌘P. The system's print sheet, where a paginated PDF can also be saved.
    func printPage() {
        guard let tab = active, tab.isWeb, let window = NSApp.keyWindow else { return }
        Browser.printing(tab.web).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The print job for a page, or for one frame of it when WebKit names
    /// one: a page's own print() in a frame prints that frame, as in Safari.
    /// The frame's printing is outside the public framework, so it is asked
    /// for first, and a WebKit without it prints the whole page.
    static func printing(_ web: WKWebView, frame: AnyObject? = nil) -> NSPrintOperation {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        let job: NSPrintOperation
        if let frame, web.responds(to: forFrame) {
            typealias Make = @convention(c) (AnyObject, Selector, NSPrintInfo, AnyObject) -> NSPrintOperation
            job = unsafeBitCast(web.method(for: forFrame), to: Make.self)(web, forFrame, info, frame)
        } else {
            job = web.printOperation(with: info)
        }
        job.view?.frame = web.bounds
        return job
    }

    /// A space's row as its session left it, made without touching the one
    /// on screen: tabs with an address and no page yet, which cost next to
    /// nothing until one is looked at (see Spaces.swift).
    func loadRow(_ space: UUID) -> Parked {
        let saved = readRow(space)
        var restored = restoreRow(saved, space: space, groups: saved.groups ?? [])
        // As restoreSession has it: nothing in front, left so or after a
        // fresh start, stays so, and the space opens on nothing beside its
        // pins (see enter); a tab whose place no longer reads falls to the
        // first that isn't a pin.
        if saved.active < 0 {
            restored.active = nil
        } else if restored.active == nil {
            restored.active = restored.tabs.first { $0.pin == nil }?.id ?? restored.tabs.first?.id
        }
        restored.groups = saved.groups
        return restored
    }

    private func restoreRow(_ saved: Session.Shape, space: UUID, groups: [TabGroup]) -> Parked {
        var row: [Tab] = []
        var bySavedIndex: [Int: Tab] = [:]
        for (savedIndex, entry) in saved.tabs.enumerated() {
            // An empty page is never written; the first builds of Split View
            // on main wrote one for an empty half. The bookmarks page is gone
            // (InternalPage.retired): a tab left on it goes with it.
            guard let saved = URL(string: entry.url), entry.url != "about:blank", !InternalPage.retired(saved) else { continue }
            // A row read from disk is a browser or window opened afresh: a pin
            // comes back at the page it was pinned at, wherever it had been
            // taken since.
            let home = Browser.home(of: entry, at: saved)
            let url = home ?? saved
            // A pin comes back by its home's title as kept with the pins, or
            // with none kept by its host, never by what the tab last said:
            // it may have been away, or translated. Only a pin with nothing
            // kept at all, from before pins were kept apart, goes by that.
            let kept = entry.pin == nil ? nil : entry.pinID.flatMap(Pins.def(_:))?.title
            let title = kept.map { $0.isEmpty ? url.host ?? "" : $0 } ?? (url == saved ? entry.title : url.host ?? "")
            // Vouched for: a kept title, or what the session had when it said
            // that was the page's own; never a host standing in.
            let vouched = kept.map { !$0.isEmpty } ?? (url == saved && entry.foreignTitle != true)
            let tab = Tab(configuration: Web.configuration(space: space))
            prepare(tab)
            tab.restore(url: url, title: title, vouched: vouched, name: entry.name,
                        state: url == saved ? entry.keepsake?.state : nil)
            // Never later than now: a clock set wrong once would keep the tab forever.
            if let touched = entry.touched { tab.touch(at: min(touched, Date())) }
            tab.letGo = entry.letGo.map { min($0, Date()) }
            tab.muted = entry.muted
            tab.pin = entry.pin
            tab.pinID = entry.pin == nil ? nil : entry.pinID
            tab.listed = entry.pin != nil && entry.listed == true
            tab.home = home
            tab.groupID = entry.pin == nil && groups.contains(where: { $0.id == entry.groupID })
                ? entry.groupID : nil
            row.append(tab)
            bySavedIndex[savedIndex] = tab
        }
        let said = bySavedIndex[saved.active]?.id
        row = reconcilePins(row, space: space)
        // Pairs, whether Split View is on or not: off, they wait, as groups
        // do. Each tab in one pair at most, and only a pair that still holds.
        var restoredSplits: [TabSplit] = []
        var taken = Set<Tab.ID>()
        for saved in saved.splits {
            let members = saved.tabs.compactMap { bySavedIndex[$0] }
            guard members.count == saved.tabs.count, members.count <= TabSplit.most,
                  !members.contains(where: { taken.contains($0.id) }) else { continue }
            let pair = TabSplit(tabs: members.map(\.id), axis: saved.axis, sizes: saved.sizes,
                                focused: saved.focused.flatMap { bySavedIndex[$0]?.id })
            guard Browser.holds(pair, in: row) else { continue }
            restoredSplits.append(pair)
            taken.formUnion(pair.tabs)
        }
        let active = said.flatMap { id in row.contains { $0.id == id } ? id : nil }
        return Parked(tabs: row, active: active, splits: restoredSplits)
    }

    /// Another space's row put on screen in place of this one (see
    /// Spaces.swift) — empty, for one that restores its own. With nothing
    /// in front there, nothing is in front here: not the first of the row,
    /// and no empty tab made for it.
    func showRow(_ row: [Tab], active: Tab.ID?, splits restored: [TabSplit] = []) {
        // The pages on screen, kept as they were left (Tab.keepPicture): once
        // the row is replaced, the tab left is no longer in it to be found.
        for tab in tabs where visibleTabIDs.contains(tab.id) { tab.keepPicture() }
        splits = restored
        tabs = row
        activeID = active
    }

    private func replaceSplitMember(_ old: Tab.ID, with new: Tab.ID) {
        guard let index = splits.firstIndex(where: { $0.contains(old) }) else { return }
        splits[index].replace(old, with: new)
    }

    /// Where a new tab goes: beside the tab you are on — but never among the
    /// pins, which a new tab isn't one of: from a pin, it comes first after
    /// them. A link from another app, with a pin in front, landed between two
    /// (#219).
    func placeForNew() -> Int {
        if prefs.newTabPlace == .top { return pinnedCount }
        if prefs.newTabPlace == .end { return tabs.count }
        guard let here = tabs.firstIndex(where: { $0.id == activeID }) else { return tabs.count }
        let after = activeSplit.flatMap { pair in tabs.firstIndex { $0.id == pair.right } } ?? here
        return max(after + 1, pinnedCount)
    }

    /// Where ⌘T's tab goes, a private one, and a page a link opens in front
    /// of you: the end of the row, as always, unless the top was chosen.
    /// After current is for links opened from the tab you are on.
    func placeForFront() -> Int {
        prefs.newTabPlace == .top ? pinnedCount : tabs.count
    }

    /// Where a link opened behind its page goes — ⌘-click, the middle button,
    /// Open Link in New Tab — with After current: right after that page, and
    /// after the links it already opened, so a row of them reads in the order
    /// they were clicked, as in Safari, Chrome and Arc. Each went straight
    /// after the page, the last clicked first. The run ends when you go to
    /// another tab or the page goes somewhere else. Whatever the new tab
    /// position: Top and Bottom (#621) are for ⌘T and pages opened in front,
    /// and with Top a ⌘-click went to the top too, away from the page it
    /// came from — Arc keeps new tabs on top and links under their page.
    /// In a group, the run stays in it; a pair is one place.
    func placeForLink(from source: Tab?) -> Int {
        guard let source = source.flatMap({ source in tabs.first { $0.id == source.id } }) ?? active,
              let here = tabs.firstIndex(where: { $0.id == source.id }) else { return placeForNew() }
        var anchor = here
        // With links opened in front beside their page, the last of the run
        // still in the row: one of them closed on the way back to the page
        // shouldn't send the next one in front of the others.
        let lastOfRun = linkRun.flatMap { run in
            frontLinksBeside ? tabs.lastIndex { run.opened.contains($0.id) } : tabs.firstIndex { $0.id == run.last }
        }
        if let run = linkRun, run.opener == source.id,
           let last = lastOfRun, last > here,
           tabs[last].groupID == source.groupID {
            anchor = last
        }
        let after = split(for: tabs[anchor]).flatMap { pair in tabs.firstIndex { $0.id == pair.right } } ?? anchor
        return max(after + 1, pinnedCount)
    }

    /// A link just opened behind `source`: the next one goes after it.
    private func noteLink(_ tab: Tab, from source: Tab?) {
        // Every link opened behind passes here — ⌘-click, the middle button,
        // Open Link in New Tab — so ⌃Tab finds it here too. One opened in
        // front is on screen, and takes its place when it is left.
        tabSwitcher.openedBehind(tab.id)
        guard let source, tabs.contains(where: { $0.id == source.id }) else { return }
        let earlier = linkRun.flatMap { $0.opener == source.id ? $0.opened : nil } ?? []
        linkRun = LinkRun(opener: source.id, last: tab.id, opened: earlier.union([tab.id]))
    }

    /// Settings › Tabs › Links opened in front go beside their page, which
    /// counts only with After current: Top and Bottom are for pages opened
    /// in front (see placeForLink).
    var frontLinksBeside: Bool { prefs.frontLinksBeside && prefs.newTabPlace == .next }

    private func placeBlank(_ tab: Tab) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let to = placeForFront()
        // Moving an existing tab removes its old slot before inserting it.
        move(tab, to: from < to ? to - 1 : to)
    }

    /// A tab made outside the row — a peek being kept — put in it at `index`.
    func insert(_ tab: Tab, at index: Int) {
        tabs.insert(tab, at: safeInsertionIndex(index))
        rememberSession()
    }

    private func safeInsertionIndex(_ proposed: Int) -> Int {
        let index = min(max(0, proposed), tabs.count)
        guard index < tabs.count, let pair = split(for: tabs[index]), pair.left != tabs[index].id else { return index }
        // Inside a split: after its last page.
        return (tabs.firstIndex { $0.id == pair.right }).map { $0 + 1 } ?? index + 1
    }

    private func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Stepping away from a tab. A video you were watching does not stop
    /// existing because you went to look something up.
    private func leaving(spaceRequest: UUID? = nil) {
        guard prefs.floatsOnLeave, spaceFloat.pending == nil || spaceFloat.pending == spaceRequest else { return }
        lift(active, quietly: true, otherwise: otherPane, spaceRequest: spaceRequest)
    }

    /// A space changes its whole row at once, so remember the asynchronous
    /// request until WebKit answers, even if the row has since come back.
    var spaceFloat = SpaceFloatRequest()

    func leavingSpace() {
        guard prefs.floatsOnLeave, !floater.showing, pictured == nil,
              let request = spaceFloat.begin() else { return }
        leaving(spaceRequest: request)
    }

    func returnSpaceVideo() {
        if let id = floating, visibleTabIDs.contains(id) { land() }
        if let id = pictured, visibleTabIDs.contains(id) { unpicture() }
    }

    private func finishSpaceFloat(_ request: UUID?, tab: Tab, system: Bool) -> Bool {
        guard let request else { return true }
        let current = spaceFloat.finish(request)
        guard current, (tabs + parkedTabs).contains(where: { $0 === tab }),
              !visibleTabIDs.contains(tab.id), !floater.showing, pictured == nil else {
            tab.built?.evaluateInSearch(system ? NativePiP.off : Isolate.off)
            return false
        }
        return true
    }

    /// With a split on screen, the page beside the focused one: what floats
    /// when the focused one has nothing playing.
    private var otherPane: Tab? {
        guard let pair = activeSplit, let id = activeID else { return nil }
        return tabs.first { $0.id == pair.partner(of: id) }
    }

    /// Another app in front: the video comes along, as in Arc (Settings ›
    /// General). Only one lifted this way goes home on its own when Eden
    /// comes back.
    private var liftedAway = false

    func appLeft() {
        guard prefs.floatsAway, spaceFloat.pending == nil, Browsers.front == nil || Browsers.front === self else { return }
        // Still in view on another screen — a TV, a second display — while
        // you work on the one under the pointer: nothing to get out of the
        // way of, and the video stays where you put it.
        if let shown = window?.screen, let here = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }), shown != here { return }
        liftedAway = !floater.showing && pictured == nil
        lift(active, quietly: true, otherwise: otherPane)
    }

    /// Back, and still on the tab it came from: into the tab again.
    func appBack() {
        defer { liftedAway = false }
        if liftedAway, let id = floating, id == activeID { land() }
        if liftedAway, let id = pictured, id == activeID { unpicture() }
    }

    /// ⌘⇧P, for lifting one out by hand.
    func toggleFloat() {
        guard spaceFloat.pending == nil else { return }
        if floater.showing {
            land()
            return
        }
        if prefs.floatStyle == .system {
            picture(active, quietly: false, toggle: true, otherwise: otherPane)
            return
        }
        lift(active, quietly: false, otherwise: otherPane)
    }

    /// The tab whose video Eden last sent to macOS's picture in picture
    /// (Settings › General › The floating video), to bring back when you
    /// return to it, as Eden's own window lands.
    private(set) var pictured: Tab.ID?

    /// The video playing in `tab` into picture in picture (NativePiP).
    /// `toggle`: ⇧⌘P, which also brings one back.
    private func picture(_ tab: Tab?, quietly: Bool, toggle: Bool = false, otherwise: Tab? = nil, spaceRequest: UUID? = nil) {
        guard let tab, !tab.isBlank, !tab.asleep, tab.web.fullscreenState == .notInFullscreen else {
            if let otherwise { picture(otherwise, quietly: quietly, toggle: toggle, spaceRequest: spaceRequest) }
            else if let spaceRequest { _ = spaceFloat.finish(spaceRequest) }
            return
        }
        if quietly, !Players.knows(tab.address) || tab.pageAddress?.host().map(Grounded.holds) == true {
            if let otherwise { picture(otherwise, quietly: quietly, toggle: toggle, spaceRequest: spaceRequest) }
            else if let spaceRequest { _ = spaceFloat.finish(spaceRequest) }
            return
        }
        tab.web.evaluateInSearch(NativePiP.script(toggle: toggle)) { [weak self, weak tab] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let tab else {
                    if let spaceRequest { _ = self.spaceFloat.finish(spaceRequest) }
                    return
                }
                switch answer as? String {
                case "in":
                    if self.finishSpaceFloat(spaceRequest, tab: tab, system: true) { self.pictured = tab.id }
                case "out":
                    if let spaceRequest { _ = self.spaceFloat.finish(spaceRequest) }
                    if self.pictured == tab.id { self.pictured = nil }
                case "refused":
                    if let spaceRequest { _ = self.spaceFloat.finish(spaceRequest) }
                    if !quietly { self.announce("This page keeps its video to itself") }
                default:
                    if let otherwise { return self.picture(otherwise, quietly: quietly, toggle: toggle, spaceRequest: spaceRequest) }
                    if let spaceRequest { _ = self.spaceFloat.finish(spaceRequest) }
                    if !quietly { self.announce("Nothing is playing here") }
                }
            }
        }
    }

    /// Back into its tab, from macOS's picture in picture.
    func unpicture() {
        guard let id = pictured else { return }
        pictured = nil
        (tabs + parkedTabs).first { $0.id == id }?.web.evaluateInSearch(NativePiP.off)
    }

    /// The button at the top right of macOS's picture in picture, back to the
    /// video. WebKit puts it back into its page only once that page is seen,
    /// and the page is most often a tab behind another one, or behind another
    /// app: until someone shows it, the button did nothing. Its tab comes to
    /// the front, in its window, with Eden, and the tab you were on keeps
    /// its own video where it is rather than taking the window's place.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if pictured == tab.id { pictured = nil }
        select(tab, floatPrevious: false)
        Browsers.show(self)
        NSApp.activate()
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house — into a small window that stays above everything.
    /// `otherwise`: the other page of a pair, tried when this one has
    /// nothing playing.
    private func lift(_ tab: Tab?, quietly: Bool, otherwise: Tab? = nil, spaceRequest: UUID? = nil) {
        // One floating video at a time: one still in Eden's window from
        // before picture in picture was chosen stays the only one out.
        if prefs.floatStyle == .system {
            guard !floater.showing else { return }
            return picture(tab, quietly: quietly, otherwise: otherwise, spaceRequest: spaceRequest)
        }
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        guard let tab, tab.isWeb, !tab.asleep, !floater.showing else {
            if let otherwise { lift(otherwise, quietly: quietly, spaceRequest: spaceRequest) }
            else if let spaceRequest { _ = spaceFloat.finish(spaceRequest) }
            return
        }
        // A video filling the screen stays in its own space, as in Safari.
        // Its page is lent to WebKit's full-screen window, and moving it out
        // into the floating one left that window up, empty and black, to
        // come back to.
        guard tab.web.fullscreenState == .notInFullscreen else {
            if let spaceRequest { _ = spaceFloat.finish(spaceRequest) }
            return
        }
        // On its own, only from a site whose video is the point of the site.
        // A hero background on a studio's home page is a video too, and it
        // followed people around the desktop. Nor from one you grounded in
        // its site card. ⌘⇧P still lifts from anywhere.
        // And only with a video playing there, as the page says (see
        // MediaKeys.watch): leaving a paused one on YouTube took a picture
        // of the page and a look through it, 20 to 30 ms, for nothing.
        if quietly, !Players.knows(tab.address) || tab.pageAddress?.host().map(Grounded.holds) == true
            || !(tab.playingVideo || tab.noisy) {
            if let otherwise { lift(otherwise, quietly: quietly, spaceRequest: spaceRequest) }
            else if let spaceRequest { _ = spaceFloat.finish(spaceRequest) }
            return
        }
        // A picture of the page as it is, asked for in the same breath as the
        // isolation and before it: the page's process answers in the order
        // it is asked, so the picture is of the page before anything moved.
        // Isolating only once the picture is back would be a tenth of a
        // second late, and a muted video, which WebKit stops when nobody can
        // see it, might no longer be playing. The whole of the picture
        // covers the tab when the video lands, until the page has settled
        // there.
        //
        // At no more than a million and a bit pixels, the size of the page in
        // points or less: WebKit paints a picture of a page on the processor,
        // and one of the whole page at a Retina screen's size took half a
        // second (YouTube, 1412×728 points: 480 ms; 110 ms at one pixel a
        // point). The video's frame is cut from it at about the little
        // window's size anyway, and the tab's picture is up for a moment.
        let shape = tab.web.bounds.size
        let fine = tab.web.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let most = (1_200_000 * shape.width / max(shape.height, 1)).squareRoot()
        let picture = WKSnapshotConfiguration()
        picture.afterScreenUpdates = false
        picture.snapshotWidth = NSNumber(value: Double(min(shape.width, most) / fine))
        var shot: NSImage??
        var found: Any??
        var alone: NSImage??
        // Going to another tab, the stage holds on to this page, unseen,
        // until it is in the little window or has nothing to float.
        let stage = tab.web.superview as? StageView
        stage?.keep(tab.web)
        func all() {
            guard let shot, let found, let alone else { return }
            lifted(tab, shot: shot, alone: alone, found: found, quietly: quietly, otherwise: otherwise, spaceRequest: spaceRequest)
            stage?.letGo(tab.web)
        }
        tab.web.takeSnapshot(with: picture) { image, _ in
            MainActor.assumeIsolated {
                shot = .some(image)
                all()
            }
        }
        tab.web.evaluateInSearch(Isolate.on) { answer in
            MainActor.assumeIsolated {
                found = .some(answer)
                all()
            }
        }
        // And one of the video alone, asked for in the same breath after the
        // isolation, for the little window's still. Cut from the first, the
        // still carried whatever the page draws over the video, which the
        // little window never shows: the player's controls and gradients,
        // its watermark, captions, a dialog. The window opened on them, and
        // they vanished as the still came off (#543). Painted with the rest
        // of the page hidden, this one costs little.
        tab.web.takeSnapshot(with: picture) { image, _ in
            MainActor.assumeIsolated {
                alone = .some(image)
                all()
            }
        }
    }

    /// The page isolated, or not, and pictured as it was before: into the
    /// little window, or on to the other page of a pair.
    private func lifted(_ tab: Tab, shot: NSImage?, alone: NSImage?, found answer: Any?, quietly: Bool, otherwise: Tab?, spaceRequest: UUID? = nil) {
        guard let found = answer as? [String: Any], found["floating"] as? Bool == true else {
            if let otherwise { return lift(otherwise, quietly: quietly, spaceRequest: spaceRequest) }
            if let spaceRequest { _ = spaceFloat.finish(spaceRequest) }
            if !quietly { announce("Nothing is playing here") }
            return
        }
        guard finishSpaceFloat(spaceRequest, tab: tab, system: false) else { return }
        // Out again before it had settled in its tab: the page isn't as it
        // was left yet, and the picture from the first time still is.
        var left = shot
        if landed?.tab == tab.id {
            left = landed?.picture
            landing.end()
        }
        leftAs = left.map { (tab.id, $0) }
        floating = tab.id
        tab.floating = true
        ownFloater()
        let still = alone.flatMap { alone in
            Float.still(
                of: alone,
                picture: (found["alone"] as? [NSNumber] ?? []).map(\.doubleValue),
                page: (found["page"] as? [NSNumber] ?? []).map(\.doubleValue)
            )
        }
        floater.lift(tab.web, still: still)
    }

    /// The page as it was when its video went out, for covering the tab with
    /// while it lands.
    private var leftAs: (tab: Tab.ID, picture: NSImage)?
    /// The tab covered now, and with what, until its page has settled.
    private var landed: (tab: Tab.ID, picture: NSImage)?
    private let landing = Settling()

    /// Back into its tab. The stage takes the page again on its next layout,
    /// which is what the self-healing there is for.
    ///
    /// The tab shows the page as it was left until the page is that again
    /// (see Isolate.off). Put back as it comes, it showed the video alone at
    /// the little window's size, then the page around it, then the video
    /// growing into its place. `covering`: false for a tab on its way out,
    /// with nobody to see it land.
    func land(covering: Bool = true) {
        // Another window's video: that window takes it back.
        if floating == nil, let owner = Browsers.all.first(where: { $0 !== self && $0.floating != nil }) {
            return owner.land(covering: covering)
        }
        // The window closes whatever else is true. Tying that to the bookkeeping
        // is how a little window outlives the thing that opened it.
        if floater.showing { floater.drop() }
        let left = leftAs
        leftAs = nil
        guard let id = floating, let tab = (tabs + parkedTabs).first(where: { $0.id == id }) else { return }
        floating = nil
        // One landing at a time: one still settling elsewhere is uncovered now.
        landing.end()
        if covering, let left, left.tab == id {
            tab.cover(with: left.picture)
            landed = left
        }
        tab.floating = false
        tab.web.evaluateInSearch(Isolate.off)
        guard landed != nil else { return }
        landing.watch(tab.web, within: 1.5) { [weak self, weak tab] in
            guard let self, let landed = self.landed else { return }
            self.landed = nil
            tab?.uncover(landed.picture)
        }
    }

    func prepare(_ tab: Tab) {
        tab.delegate = self
        // With two pages up, the keys going to the other one — Tab walked
        // past the last field of this one — make it the focused page, so the
        // outline, ⌘L and the site card follow what is being typed into.
        tab.onHomeTitle = { [weak self] tab, title in
            guard let self, let id = tab.pinID else { return }
            Pins.retitle(id, title, from: self)
        }
        tab.onKeys = { [weak self] tab in
            guard let self, let pair = activeSplit, pair.contains(tab.id), activeID != tab.id else { return }
            focusPane(tab)
        }
        tab.onLink = { [weak self] tab, address in
            guard let self, prefs.showsLinks, visibleTabIDs.contains(tab.id) else { return }
            linkStatus.show(address, over: tab.built)
        }
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = curtain.host(of: tab.address) else { return }
            // A private tab writes nothing down, hidden.json included: taken
            // off this page only.
            if tab.shy {
                passingVeils[tab.id, default: []].append(selector)
                tab.applyVeils(curtain.css(on: host) + passingCSS(tab.id))
                announce("Hidden on this page", look: .done, action: undoHidingOffer(selector, on: host, in: tab))
                return
            }
            curtain.hide(selector, label: label, note: note, on: host)
            let css = curtain.css(on: host)
            tab.arm(hiding: css)
            tab.applyVeils(css)
            announce("Hidden", look: .done, action: undoHidingOffer(selector, on: host, in: tab))
        }
        tab.onPickEnd = { [weak self] tab in
            guard let self, picking === tab else { return }
            veiling = false
            picking = nil
        }
        tab.onImageMenu = { [weak self] tab, url in self?.showImageMenu(for: tab, at: url) }
        tab.onImageItem = { [weak self] tab, url, copy in
            guard let self, let web = tab.built else { return }
            if copy { copyImage(at: url, in: tab) } else { downloadImage(at: url, from: web) }
        }
        tab.searchName = { [weak self] in self.map { $0.prefs.engine.name(custom: $0.prefs.customEngine) } }
        tab.onSearch = { [weak self] tab, text in
            guard let self, let url = self.searchURL(for: text) else { return }
            // From a private tab, the search is private too (see open(_:foreground:atEnd:from:)).
            self.open(url, foreground: true, from: tab)
        }
        tab.onStoreAdd = { [weak self] tab in self?.addFromStore(tab) }
        // The middle button on a link opens it beside the tab you are on, as
        // it does in every other browser (see MiddleRelay).
        // From a private tab, the new one is private too, as for ⌘-click.
        tab.onMiddleClick = { [weak self] tab, url, front in self?.openClicked(url, foreground: front, from: tab, view: tab.built) }
        tab.onCross = { [weak self] tab, url in self?.replace(tab, going: url) }
        tab.onFileLink = { [weak self] tab, url, blank in
            if blank { self?.open(url, foreground: true, from: tab) } else { tab.go(to: url) }
        }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. Nothing is filled on
        // its own — the way Safari does it, and what a person expects.
        tab.onField = { [weak self] tab, spot, passwords, name, wide, code, fill in
            self?.hang(from: tab, spot, passwords: passwords, name: name, wide: wide, code: code, fill: fill)
        }

        tab.onCredentials = { [weak self] tab, host, user, password, clear in
            // an extension's own page isn't a site: Bitwarden's unlock pin was offered as its password.
            guard let self, prefs.savesPasswords, !password.isEmpty, !tab.shy,
                  !Vault.isNever(host), tab.address.flatMap(Browser.extensionHost(of:)) == nil
            else { return }
            // A password manager extension that asked Chrome's way to do the
            // saving itself.
            if #available(macOS 15.4, *), Extensions.shared.passwordSavingTakenBy != nil { return }
            // Just filled from the Passwords app: it is kept there already.
            if tab.appleFill?.matches(host: host, user: user, password: password) == true { return }
            let known = Vault.kept(for: host)
            // Nothing to ask about one that is already known. Only that
            // account's secret is read, not every one kept for the site.
            if var same = known.first(where: { $0.user == user }).flatMap(Vault.login), same.password == password {
                // Where it was last used is where it is offered from now on.
                same.clear = clear
                Vault.touch(same)
                return
            }
            let offer = Offer(
                login: Login(host: host, user: user, password: password, used: nil, clear: clear),
                changed: known.contains { $0.user == user }
            )
            guard offering != offer else { return }
            offering = offer
        }
        tab.onPickTrouble = { [weak self] _, _ in
            self?.announce("Couldn't hide that", look: .problem)
        }

        // The toast doubles as the zoom read-out: it keeps being rewritten
        // where it stands while you pinch, and goes a moment after you stop.
        tab.onZoom = { [weak self] _, value in
            guard let self else { return }
            let percent = Int((value * 100).rounded())
            guard percent != zoomShown else { return }
            zoomShown = percent
            announce("\(percent)%", symbol: "plus.magnifyingglass", key: "zoom")
        }

        // Kept by the tab, so they go with it: kept by the window, they
        // stayed as long as it was open, for every tab it had ever made. A
        // tab come from another window is wired to this one alone.
        tab.wiring = []

        // What plays, and what the player paused, for the player at the foot
        // of the sidebar (Player.swift).
        Publishers.CombineLatest(tab.$noisy.removeDuplicates(), tab.$stilled.removeDuplicates())
            .dropFirst()
            .sink { [weak self, weak tab] noisy, stilled in
                guard let self, let tab else { return }
                heard(tab, noisy: noisy, stilled: stilled)
            }
            .store(in: &tab.wiring)

        // A page's title lands a beat after the page itself, and a history
        // entry that only ever holds an address is half a memory.
        // Anywhere a tab lands is worth remembering for next launch.
        tab.$address
            .dropFirst()
            .sink { [weak self] _ in self?.rememberSession() }
            .store(in: &tab.wiring)

        tab.$muted
            .dropFirst()
            .sink { [weak self] _ in self?.rememberSession() }
            .store(in: &tab.wiring)

        tab.$title
            .dropFirst()
            .sink { [weak self, weak tab] title in
                // A translated title is the page's in your words, not its own:
                // history keeps the page's (Translate.swift).
                guard let tab, !tab.shy, tab.translator == nil, let url = tab.address else { return }
                self?.history.retitle(url, title)
            }
            .store(in: &tab.wiring)
    }

    /// Put the cursor back in the field, from wherever asked.
    func askFocus() { focusRequest += 1 }

    /// A key typed between ⌘T and the field taking the keys, kept for it.
    ///
    /// The field comes a turn or two of the run loop after it is asked for —
    /// later still with Split View, where it waits for the stage to say where
    /// the page is — and a hand already typing got there first: the first
    /// letter or two went to the page being left, or nowhere. Held for half
    /// a second at most, and only typing: a key with ⌘ or ⌃ is a shortcut.
    func holdKey(_ event: NSEvent) -> Bool {
        guard let asked = focusAsked, CACurrentMediaTime() - asked < 0.5,
              fieldShowing, editingTab == nil,
              event.modifierFlags.intersection([.command, .control]).isEmpty
        else { return false }
        if heldKeys.isEmpty {
            // The field never came: what was typed goes where it would have.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.heldKeys.isEmpty else { return }
                self.focusAsked = nil
                self.letGo(in: event.window)
            }
        }
        heldKeys.append(event)
        return true
    }

    /// The field has the keys: what was held goes to it, in order.
    func fieldFocused(in window: NSWindow) {
        focusAsked = nil
        letGo(in: window)
    }

    private func letGo(in window: NSWindow?) {
        let held = heldKeys
        heldKeys = []
        // Straight to the window, which hands a key to whatever has the
        // keys: not back through the app, whose monitor would hold it again.
        for event in held { window?.sendEvent(event) }
    }

    // MARK: - guessing

    /// Nothing asked yet: the field empty, or holding the address ⌘L put
    /// there, untouched. Either way it lists what ⌘T's empty field lists, as
    /// Zen's ⌘L and ⌘T do, the only difference being where Return goes; and
    /// Return takes no row unpicked (see submit).
    var nothingAsked: Bool {
        typed.trimmingCharacters(in: .whitespaces).isEmpty
            || (siteChip == nil && fieldMode == .thisTab && typed == shownAddress)
    }

    private func guess() {
        if nothingAsked {
            suggester.stop()
            engineWords = ("", [])
            // A field emptied starts again from the history as it is now.
            if siteChip == nil { pastSearches = nil }
        }

        // A site in the field: its search for what is typed after it, what
        // you searched it for before, and your engine's suggestions when the
        // site is your engine (see engineQuestion).
        if let site = siteChip {
            siteOffer = nil
            ending = nil
            picked = nil
            let words = typed.trimmingCharacters(in: .whitespaces)
            let search = site.url(for: words).map { [Suggestion(key: words, title: "Search with \(site.name)", url: $0, kind: .search)] } ?? []
            offers = search + searchedOffers(for: words, on: site)
            if !words.isEmpty { askEngine() }
            return
        }

        guard !nothingAsked else {
            // The empty page of a pair lists the open tabs to bring in
            // itself (SplitView's OpenTabsUntilTyped).
            let paired = active.map { $0.isBlank && split(for: $0) != nil } ?? false
            offers = fieldShowing && !paired ? startingOffers() : []
            ending = nil
            picked = nil
            siteOffer = nil
            return
        }
        // "red": Reddit's search, a Tab away.
        let site = prefs.searchesSites
            ? SiteSearch.match(typed, learnedToo: profileID == Profile.personalID, keywords: prefs.keywords) { [history] in history.visits(to: $0.map(\.host)) }
            : nil
        if siteOffer != site { siteOffer = site }

        (offers, ending) = placeOffers(for: typed)
        // Pages open on your other devices and not here, after where Return
        // goes (Elsewhere).
        if active?.shy != true {
            let elsewhere = Elsewhere.matching(typed, in: Sync.shared.elsewhere, openHere: openHere).map(Suggestion.init)
            if !elsewhere.isEmpty {
                let shown = Set(elsewhere.map { History.identity(for: $0.url) })
                let rest = offers.dropFirst().filter { !shown.contains(History.identity(for: $0.url)) }
                offers = Array(offers.prefix(1)) + elsewhere + rest
            }
        }
        // The open tabs that answer to what is typed, and the groups and
        // spaces it names (FieldOffers.swift).
        offers = groupAndSpaceOffers(for: typed, after: withOpenTabs(offers, for: typed))
        // A row that was picked stops being the right row the moment the
        // question changes.
        picked = nil
        askEngine()
    }

    // MARK: - the engine's suggestions

    /// Asks the engine for the words it would suggest, when Settings ›
    /// General › Suggestions from your search engine is on and these words
    /// may leave the Mac (EngineSuggest.sendable). What it said for the
    /// words before stays, those that still fit, until it answers these:
    /// rows that came and went with every key would be a list nobody could
    /// read.
    let suggester = EngineSuggester()
    /// The engine's last words, and what they answered.
    private var engineWords: (asked: String, words: [String]) = ("", [])

    /// The question this field may ask the engine, or nil when it may not:
    /// the switch off, a private tab, a site or a shortcut in charge,
    /// or words that look like anything but a search.
    func engineQuestion(for typed: String) -> URL? {
        guard prefs.engineSuggests, active?.shy != true,
              EngineSuggest.sendable(typed)
        else { return nil }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let site = siteChip {
            // A site in the field is asked only when it is your engine: the
            // switch says your engine, so words typed to Reddit never go to
            // Google, nor words typed to Google when DuckDuckGo is yours.
            guard Engine.bareHost(of: prefs.engine.template(custom: prefs.customEngine)) == site.host else { return nil }
        } else if Keyword.match(typed, in: prefs.keywords) != nil {
            return nil
        }
        return EngineSuggest.url(for: words, engine: prefs.engine, test: EngineSuggest.testEndpoint)
    }

    /// Where a suggestion taken from the list goes: the site in the field,
    /// or the engine.
    private func suggestionURL(for words: String) -> URL? {
        if let site = siteChip { return site.url(for: words) }
        return searchURL(for: words)
    }

    /// Rows for what a site was searched for before: the last few before a
    /// word is typed, then those the words begin. `typedBefore` is what
    /// stands before the words in the field ("yt " for a shortcut), so a row
    /// walked to puts back the whole of what would be typed.
    private func searchedOffers(for words: String, on site: SearchSite, typedBefore: String = "") -> [Suggestion] {
        let needle = words.lowercased()
        let past = searchedBefore(on: site).filter { $0.lowercased().hasPrefix(needle) && $0.lowercased() != needle }
        return past.prefix(words.isEmpty ? 5 : 3).compactMap { word in
            site.url(for: word).map { Suggestion(key: typedBefore + word, title: "", url: $0, kind: .searched) }
        }
    }

    /// What the site in the field was searched for before, newest first:
    /// read from the history once when the site goes in, not at every key.
    /// Never in a private tab, whose field says nothing of where you have been.
    private func searchedBefore(on site: SearchSite) -> [String] {
        guard active?.shy != true else { return [] }
        if let pastSearches, pastSearches.site == site.id { return pastSearches.words }
        let host = site.host.split(separator: "/").first.map(String.init) ?? site.host
        let words = SiteSearch.pastSearches(on: site, in: history.everything(matching: host))
        pastSearches = (site.id, words)
        return words
    }
    private var pastSearches: (site: SearchSite.ID, words: [String])?

    private func askEngine() {
        guard let question = engineQuestion(for: typed) else {
            suggester.stop()
            engineWords = ("", [])
            return
        }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Until the answer: last time's words that still begin with these.
        let lower = words.lowercased()
        let places = Set(offers.map { $0.key.lowercased() })
        let still = engineWords.words.filter {
            $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower && !places.contains($0.lowercased())
        }
        if !still.isEmpty { offers += engineOffers(still) }
        suggester.ask(question, words: words) { [weak self] answer in
            guard let self else { return }
            // Typed on since, or the field gone: nothing to answer.
            guard self.typed.trimmingCharacters(in: .whitespacesAndNewlines) == words,
                  self.fieldShowing, self.engineQuestion(for: self.typed) != nil
            else { return }
            let mine = self.offers.filter { $0.kind != .suggested }
            // A row of the engine's that the arrow keys are on stays put.
            if let picked = self.picked, picked >= mine.count { return }
            self.engineWords = (words, answer)
            let places = Set(mine.map { $0.key.lowercased() })
            self.offers = mine + self.engineOffers(answer.filter { !places.contains($0.lowercased()) })
        }
    }

    private func engineOffers(_ words: [String]) -> [Suggestion] {
        words.prefix(EngineSuggest.most).compactMap { word in
            suggestionURL(for: word).map { Suggestion(key: word, title: "", url: $0, kind: .suggested) }
        }
    }

    /// What an address field offers for what is typed in it, and the rest of
    /// the address it would complete to: ⌘L's field and the one in the tab
    /// ask the same question (#534).
    func placeOffers(for typed: String) -> (offers: [Suggestion], ending: String?) {
        // Three places and, if it can't be a place, a search. Open tabs are
        // added after the first of them (FieldOffers.swift), the tab's group
        // and space rows last.
        // The pages you keep are pins, which are tabs, so they come with the
        // open tabs, asleep or in a folded folder as well (#6).
        var list = history.suggestions(for: typed, limit: 3)
        // Last in the list, and only when what was typed cannot be a place.
        if !typed.isEmpty, Address.url(from: typed) == nil {
            if let (keyword, rest) = Keyword.match(typed, in: prefs.keywords),
               let asked = Engine.url(for: rest, template: keyword.template) {
                list.append(Suggestion(key: typed, title: "Search with \(keyword.name)", url: asked, kind: .search))
                // A shortcut is a site put in the field, typed out: what you
                // searched it for before, as under the site's chip.
                let site = SearchSite(name: keyword.name, host: keyword.name, template: keyword.template)
                let before = String(typed.prefix(while: { !$0.isWhitespace })) + " "
                list += searchedOffers(for: rest, on: site, typedBefore: before)
            } else if let asked = searchURL(for: typed) {
                list.append(
                    Suggestion(key: typed, title: "Search with \(prefs.engine.name(custom: prefs.customEngine))", url: asked, kind: .search)
                )
            }
        }
        // First, not last: typing "settings" to reach Settings is the whole
        // point, and it would otherwise sit under a search for the word.
        let command = AddressCommand.matching(typed, in: self)
        if let command { list.insert(.command(command), at: 0) }
        // A partial command goes last, so Return still does what it did.
        if let near = AddressCommand.near(typed, in: self) { list.append(.command(near)) }
        // The menus' commands and Settings' pages, as Arc's Command Bar has
        // them: under the rest, never the row Return takes.
        if !list.isEmpty { list += AddressCommand.listed(typed, in: self).map(Suggestion.command) }
        // Neither a page already open nor a command has an address to
        // complete towards. And with a command on top, Return runs it: a
        // grey ending in the field ("history" finishing as history.com)
        // would promise a place Return doesn't go to.
        let places = list.filter { $0.kind != .open && !$0.kind.isCommand }
        let ending = command != nil ? nil : history.completion(for: typed, among: places)
        // Worked out from the addresses, before a search page's row is read
        // as the words it searched: the grey ending still finishes an address.
        return (readAsSearches(list, typed: typed), ending)
    }

    /// A page from history that is a search's results reads as the search
    /// it was, "naruto vs one piece" on Reddit, instead of its address
    /// (reddit.com/search/?q=naruto%20vs%20one%20piece): the words, the
    /// site's name, and the mark of a past search. It still goes to that
    /// page. One that is the search the field is already offering, your
    /// engine for exactly what was typed, isn't shown twice.
    private func readAsSearches(_ list: [Suggestion], typed: String) -> [Suggestion] {
        guard list.contains(where: { $0.kind == .visited }) else { return list }
        let engine = prefs.engine.template(custom: prefs.customEngine)
        let sites = [SearchSite(name: prefs.engine.name(custom: prefs.customEngine),
                                host: Engine.bareHost(of: engine) ?? "", template: engine)]
            + prefs.keywords.filter { Keyword.accepts($0.template) }.map {
                SearchSite(name: $0.name, host: $0.name, template: $0.template)
            }
            + SiteSearch.builtIn
            + (profileID == Profile.personalID ? SiteSearch.learned : [])
        let asked = typed.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        return list.compactMap { place in
            guard place.kind == .visited,
                  let (site, words) = sites.lazy.compactMap({ site in
                      SiteSearch.words(in: place.url, searchedOn: site).map { (site, $0) }
                  }).first
            else { return place }
            if site.template == engine, words.lowercased() == asked { return nil }
            // "naruto+vs" and "naruto%20vs" are two pages but one search.
            guard seen.insert(site.host + " " + words.lowercased()).inserted else { return nil }
            return Suggestion(key: words, title: site.name, url: place.url, kind: .searched)
        }
    }

    /// On a new tab's empty field, before anything is typed: the page in
    /// front on the device you just put down, and pages closed there a
    /// moment ago (Elsewhere). Never in a private tab.
    func elsewhereOffers() -> [Suggestion] {
        guard active?.shy != true else { return [] }
        let devices = Sync.shared.elsewhere
        let now = Date().timeIntervalSince1970
        let open = openHere
        let carry = Elsewhere.continuing(from: devices, now: now, frontHere: nil)
            .flatMap { open.contains(History.identity(for: URL(string: $0.page.url) ?? URL(fileURLWithPath: "/"))) ? nil : $0 }
        let closed = Elsewhere.closed(on: devices, now: now, openHere: open, limit: 2)
            .filter { $0.page.url != carry?.page.url }
        return (carry.map { [$0] } ?? []).map(Suggestion.init) + closed.map(Suggestion.init)
    }

    /// The tabs of this profile's windows, every space's, as `(window,
    /// space, tab)`: never a private tab's. By the address each would come
    /// back at (Tab.restAddress), as your other devices are told.
    private var profileTabs: [(browser: Browser, space: UUID, tab: Tab)] {
        // This window always, and first, whether or not it is listed yet.
        let windows = [self] + Browsers.all.filter { $0 !== self && $0.profileID == profileID && !$0.isPopup }
        return windows.flatMap { window in
            ([(window.spaceID, window.tabs)] + window.parked.map { ($0.key, $0.value.tabs) }).flatMap { space, row in
                row.filter { !$0.shy && !$0.bench }.map { (window, space, $0) }
            }
        }
    }

    /// Every page open in this profile's windows, by History.identity.
    var openHere: Set<String> {
        Set(profileTabs.compactMap(\.tab.settledIdentity))
    }

    /// A page from another device, here: its tab if it is open in any of
    /// this profile's windows and spaces — the one in its own space, then
    /// this window's, first — never a second; otherwise opened in the space
    /// it was open in, when this window has it, read as far down and as an
    /// article if it was. The window it went to, which may be another one of
    /// the profile's.
    @discardableResult
    func open(_ offer: Elsewhere.Offer) -> Browser {
        guard let url = URL(string: offer.page.url) else { return self }
        let identity = History.identity(for: url)
        // Showing it, and going nowhere else: a tab on its way to another
        // page would carry on there.
        let found = profileTabs.filter { $0.tab.settledIdentity == identity }
        let space = offer.page.space
        let arrival = Tab.Arrival(page: url, scroll: offer.page.scroll, reading: offer.page.reading == true,
                                  from: offer.deviceName)
        if let hit = found.first(where: { $0.browser === self && $0.space == space })
            ?? found.first(where: { $0.space == space }) ?? found.first(where: { $0.browser === self }) ?? found.first {
            if hit.space != hit.browser.spaceID { hit.browser.switchSpace(to: hit.space) }
            hit.browser.raise(hit.tab)
            // Shown as it was left there, when there was anything to carry:
            // now if that very page is in, else once it has come in — a tab
            // waking builds its view before its page is there.
            if arrival.scroll != nil || arrival.reading {
                let showing = hit.tab.built != nil && !hit.tab.loading
                    && hit.tab.restAddress.map(History.identity(for:)) == identity
                if showing { hit.browser.arrive(hit.tab, arrival) } else { hit.tab.arrival = arrival }
            }
            return hit.browser
        }
        if let space, prefs.usesSpaces, space != spaceID, spaces.contains(where: { $0.id == space }) {
            switchSpace(to: space)
        }
        let tab = open(url, foreground: true, from: active, loose: true)
        tab.arrival = arrival
        return self
    }

    /// That very tab in front — not the page of its pair focused last, as a
    /// click on the pair would — and its window raised.
    func raise(_ tab: Tab) {
        select(tab)
        guard !Store.testing, let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// A page carried on from another device, now in: as an article if it
    /// was read so, as far down as it was, and said.
    func arrive(_ tab: Tab, _ arrival: Tab.Arrival) {
        let scroll = { [weak self, weak tab] in
            guard let self, let tab, let built = tab.built else { return }
            var said = "Continued from \(arrival.from)"
            if let scroll = arrival.scroll {
                let script = "window.scrollTo(0, \(scroll) * Math.max(0, document.documentElement.scrollHeight - window.innerHeight))"
                built.evaluateJavaScript(script) { _, _ in }
                if scroll > 0 { said += " at \(Int((scroll * 100).rounded()))%" }
            }
            self.announce(said, symbol: "laptopcomputer.and.iphone")
        }
        guard arrival.reading, !tab.reader else { return scroll() }
        tab.toggleReader { _ in scroll() }
    }

    /// What is open, most recently looked at first, filtered by what has been
    /// typed. Not the tab in front, which the field is raised over — unless
    /// `front`: the address field raised from another app (Launcher.swift)
    /// is raised over none.
    func openPages(matching typed: String, front: Bool = false) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return tabs
            .filter { (front || $0.id != activeID) && !$0.isBlank }
            .filter { tab in
                guard !needle.isEmpty else { return true }
                let address = tab.address.map { Address.pretty($0) } ?? ""
                return tab.label.lowercased().contains(needle) || address.contains(needle)
            }
            .sorted { $0.touched > $1.touched }
            .prefix(needle.isEmpty ? 6 : 3)
            .compactMap { tab in
                guard let url = tab.address else { return nil }
                return Suggestion(
                    key: tab.label,
                    title: Address.pretty(url),
                    url: url,
                    kind: .open,
                    tab: tab.id
                )
            }
    }

    /// A row clicked in the list, taken directly rather than through the
    /// keyboard's selection. The pointer and the arrow keys are answering the
    /// same question but must not share an answer: a list that appears under a
    /// resting cursor would otherwise rewrite the field before you had moved.
    func take(_ offer: Suggestion) {
        if let command = offer.command {
            command.run(on: self)
        } else if let elsewhere = offer.elsewhere {
            open(elsewhere)
        } else if let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) {
            // From the empty page of a pair, as Return takes it (submit):
            // that tab comes into the pair.
            if let blank = active, blank.isBlank, split(for: blank) != nil,
               tab.shy == blank.shy, split(for: tab)?.contains(blank.id) != true {
                fill(blank, with: tab)
            } else {
                select(tab)
            }
        } else if launching || active == nil {
            // With nothing in front, a tab of its own, never a pin of the row.
            open(offer.url, foreground: true, from: active, loose: true)
        } else {
            active?.go(to: offer.url)
        }
        editing = false
        typed = ""
        picked = nil
    }

    /// A backspace means the ending was not wanted. Recomputing it on the very
    /// next keystroke is right; putting it back on this one is what makes a
    /// field impossible to shorten.
    func stopCompleting() { ending = nil }

    /// Tab with a site offered: the site goes into the field as a chip, and
    /// what was typed to name it is let go. True when it did.
    func lockSiteOffer() -> Bool {
        guard prefs.searchesSites, siteChip == nil, let site = siteOffer else { return false }
        siteOffer = nil
        typed = ""
        siteChip = site
        return true
    }

    /// Tab, or the right arrow at the end of the line: take what is offered.
    func acceptEnding() {
        guard let ending, !ending.isEmpty else { return }
        typed += ending
    }

    /// The arrow keys walk the list, and walking off the top lets go of it.
    func walk(_ step: Int) {
        guard !offers.isEmpty else { return }
        switch picked {
        case nil:
            picked = step > 0 ? 0 : offers.count - 1
        case let here?:
            let next = here + step
            picked = (next < 0 || next >= offers.count) ? nil : next
        }
    }

    // MARK: - the address field

    /// ⌘L. The current address comes up selected, so typing over it replaces it
    /// and Escape puts it back.
    func edit() {
        // Nothing in front has no page for the field to send somewhere else:
        // ⌘L raises ⌘T's, whose Return opens a tab, and again puts it away.
        if active == nil, !websitePopup {
            if launching { dismiss() } else { launch() }
            return
        }
        // Again while it is up over the page: put away, as Escape would.
        if editing, !launching, active?.isBlank == false {
            putAway()
            return
        }
        // From ⌘T, what was typed stays, for this page now.
        let words = wordsToCarry
        launching = false
        // Up before its words: the list they bring is worked out as ⌘L's,
        // which lists for the page's own address what ⌘T's empty field does.
        editing = true
        typed = words ?? shownAddress
        focusRequest += 1
    }

    func dismiss() {
        // The floating new tab was never a tab: nothing is left behind but
        // what was typed, for the next ⌘T to carry on with.
        if launching {
            launchDraft = (typed, Date().addingTimeInterval(Self.launchDraftLife))
            launching = false
            siteChip = nil
            editing = false
            typed = ""
            return
        }
        // Esc with a site in the field: the site goes, the field stays.
        if siteChip != nil {
            siteChip = nil
            return
        }
        // Esc on the empty page of a pair: the page isn't wanted after all.
        if let tab = active, tab.isBlank, split(for: tab) != nil {
            editing = false
            typed = ""
            close(tab)
            return
        }
        // A blank tab has nothing behind the field to go back to.
        guard active?.isBlank == false else { return }
        editing = false
        typed = ""
    }

    /// Shift-Return, once Settings › Browsing › Shift-Return searches with
    /// has an engine (#848): exactly what was typed, searched there. The
    /// row picked, the ending offered, a site in the field and a site
    /// shortcut are all passed over — the words go as they are, the way a
    /// search for an address someone typed would. False, with none chosen,
    /// leaves the key to Return.
    @discardableResult
    func submitToShiftEngine() -> Bool {
        guard let engine = prefs.shiftEngine else { return false }
        guard let url = Engine.url(for: typed, template: engine.template(custom: prefs.shiftCustom)) else {
            refusals += 1
            return true
        }
        siteChip = nil
        picked = nil
        if launching || active == nil {
            // The floating new tab, as Return: a tab of its own. So is
            // anything sent with nothing in front, never a pin of the row.
            open(url, foreground: true, from: active, loose: true)
        } else {
            active?.go(to: url)
        }
        editing = false
        typed = ""
        return true
    }

    /// Return. A row picked from the list wins; otherwise what the field was
    /// finishing for you wins; otherwise what you actually typed. If none of
    /// those is a place, nothing happens and the field says so.
    ///
    /// `aside`: ⌘Return, as in Safari. The place opens in a new tab and the
    /// tab you were on is left as it was, behind it unless `front` (⇧⌘Return)
    /// asks to go there.
    func submit(aside: Bool = false, front: Bool = false) {
        // A page already open is switched to, not opened again.
        if let picked, offers.indices.contains(picked),
           let id = offers[picked].tab,
           let tab = tabs.first(where: { $0.id == id }) {
            // From the empty page of a pair: that tab comes into the pair.
            if let blank = active, blank.isBlank, split(for: blank) != nil, !aside,
               tab.shy == blank.shy, split(for: tab)?.contains(blank.id) != true {
                fill(blank, with: tab)
                return
            }
            select(tab)
            editing = false
            typed = ""
            return
        }

        // The row the arrow keys chose, or else the top one: a command on
        // top is what Return does (a group's or a space's row is never on
        // top: FieldOffers.swift). Walked past, Return goes where it always
        // went. On the empty field nothing is
        // chosen until an arrow key chooses it, nor on ⌘L's untouched
        // address: its list starts with the copied link, which Return
        // mustn't visit unasked. Return there goes to the address.
        let unasked = nothingAsked ? nil : offers.first
        let chosen = (picked.flatMap { offers.indices.contains($0) ? offers[$0] : nil }) ?? unasked
        // The copied link is an address once read, opened as any is: in a
        // new tab after ⌘T, beside with ⌘Return.
        var copied: URL?
        if case .copiedLink(let change)? = chosen?.command {
            guard let url = copiedLinkURL(change) else { return }
            copied = url
        } else if let command = chosen?.command {
            command.run(on: self)
            editing = false
            typed = ""
            picked = nil
            return
        }

        let target: URL?
        if let copied {
            target = copied
        } else if let picked, offers.indices.contains(picked) {
            target = offers[picked].url
        } else if ending != nil {
            target = Address.url(from: completed)
        } else {
            target = destination(for: typed)
        }

        guard let url = target else {
            refusals += 1
            return
        }
        // eden://settings and the rest: the page's own tab, one of each.
        if let page = InternalPage(url: url) {
            show(page)
            picked = nil
            return
        }
        if launching || active == nil, !aside {
            // The floating new tab: what was typed gets a tab of its own, and
            // the page the field was raised over stays as it was. With
            // nothing in front, a tab of its own too, never a pin of the row.
            open(url, foreground: true, from: active, loose: true)
        } else if aside {
            // Opened behind the page by hand, as a ⌘-clicked link is: it may
            // wait to load (Settings › Tabs › Load background tabs…).
            open(url, foreground: front, from: active, mayWait: true)
        } else {
            active?.go(to: url)
        }
        editing = false
        typed = ""
    }

    // MARK: - the page

    func zoom(by factor: CGFloat) { active?.magnify(by: factor) }
    func resetZoom() { active?.resetZoom() }

    /// ⌘⇧R. The article, and nothing that was arranged around it.
    // MARK: - dark pages

    /// Whether ⇧⌘D has anything to do: on, not paused, and the frame dark,
    /// since a light frame darkens nothing.
    var canDusk: Bool { canDusk(active) }

    /// The same for a given tab: the site card's, which in Split View can be
    /// the page beside the one with the keys.
    func canDusk(_ tab: Tab?) -> Bool {
        prefs.darkensPages && !Dusk.shared.paused && Dusk.frameIsDark
            && Dusk.host(of: tab?.pageAddress) != nil
    }

    /// ⇧⌘D: the site you're on, darkened or left as it is, the other way
    /// from now. Kept for the site; in a private tab, for this page alone.
    func toggleDusk() {
        guard canDusk, let tab = active else { return }
        dusk(!tab.dusked, tab)
    }

    func dusk(_ on: Bool, _ tab: Tab) {
        guard let host = Dusk.host(of: tab.pageAddress) else { return }
        if tab.shy {
            tab.built?.evaluateInSearch(Dusk.shared.forced(for: host, on))
        } else {
            Dusk.shared.choose(on, for: host, native: tab.duskNative)
        }
    }

    /// ⌥⇧⌘D: every page as its site made it, until pressed again or Eden
    /// quits. For showing someone a site the way they see it.
    func pauseDusk() {
        guard prefs.darkensPages else { return }
        Dusk.shared.pause(!Dusk.shared.paused)
        announce(Dusk.shared.paused ? "Pages as their sites made them, until ⌥⇧⌘D" : "Light pages darkened again")
    }

    /// The darkening as it now stands, into every tab's next page and the
    /// page each is showing: taken over, let go, or, for a site not known
    /// yet, looked at.
    private func redusk() {
        for tab in tabs + parkedTabs {
            tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
            guard let web = tab.built else { continue }
            let host = Dusk.host(of: tab.pageAddress)
            if Dusk.shared.unsure(host) { duskLook(tab) } else { web.evaluateInSearch(Dusk.shared.update(for: host)) }
        }
    }

    /// A page on a site not known to be light, looked at from outside as it
    /// is drawn (see Dusk.look). Light, and it is darkened now, and every
    /// page of the site after it from its first frame; dark, and it is left
    /// with nothing in it.
    func duskLook(_ tab: Tab) {
        guard let web = tab.built, let url = web.url, let host = Dusk.host(of: url),
              Dusk.shared.unsure(host), !tab.dusked else { return }
        Dusk.look(at: web) { [weak self, weak tab] dark in
            MainActor.assumeIsolated {
                guard let self, let tab, let dark, tab.built === web, web.url == url, Dusk.shared.unsure(host) else { return }
                tab.duskNative = dark
                // A private tab remembers nothing, not even this.
                if !tab.shy { Dusk.shared.saw(host, dark: dark) }
                guard !dark, let script = Dusk.shared.script(for: host, light: true) else { return }
                web.evaluateInSearch(script)
                tab.arm(hiding: self.curtain.css(on: self.curtain.host(of: tab.address)))
            }
        }
    }

    func toggleReader() {
        guard let tab = active else { return }
        tab.toggleReader { [weak self] worked in
            guard !worked else { return }
            self?.announce("Nothing to read on this page")
        }
    }

    // A peek has the page in front; the tab underneath stays where it was.
    func reload(fromOrigin: Bool = false) { ((peekInFront ? peekTab : nil) ?? active)?.reload(fromOrigin: fromOrigin) }
    func back() { active?.back() }
    func forward() { active?.forward() }
}

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Every navigation is decided in `decide` below; this form of the
    /// question also hands over the page's preferences, the only place a
    /// site allowed to play sound by itself can say so (see Autoplay). Only
    /// a page that is allowed to load, in the tab's own frame, is touched.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        decide(webView, action) { [weak self] policy in
            // Revoke before WebKit can run the old document's unload handlers.
            // A nil target is a new window, not this tab leaving its document.
            if policy == .allow, action.targetFrame?.isMainFrame == true {
                self?.popupTab(for: webView)?.popupGesture.clear()
            }
            if policy == .allow, action.targetFrame?.isMainFrame ?? true, let url = action.request.url {
                let shy = self?.tab(for: webView)?.shy == true || !webView.configuration.websiteDataStore.isPersistent
                Autoplay.apply(to: preferences, for: url, shy: shy,
                               made: webView.configuration.mediaTypesRequiringUserActionForPlayback)
                PrivacySignal.apply(to: preferences, shy: shy)
            }
            decisionHandler(policy, preferences)
        }
    }

    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    private func decide(
        _ webView: WKWebView,
        _ action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // "Download Image" from the page's own context menu and a link with
        // the `download` attribute arrive as an ordinary-looking action with
        // this one flag set. ("Download Linked File" doesn't come this way:
        // see contextMenuDidCreateDownload below.) Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        // A sign-in sent by the page's own script, which the page's side of
        // Forms.swift never hears about: no submit event, no button. The
        // policy question still comes, while the boxes are still filled.
        if action.navigationType == .formSubmitted, action.sourceFrame.isMainFrame,
           action.targetFrame?.isMainFrame == true {
            tab(for: webView)?.formSent()
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView)
            || ExtensionAuth.handOver(url, mainFrame: action.targetFrame?.isMainFrame == true, browser: self, from: webView)
            || AISignIn.intercept(url, mainFrame: action.targetFrame?.isMainFrame == true, in: tab(for: webView), browser: self) {
            decisionHandler(.cancel)
            return
        }

        // 0.0.0.0, as a dev server prints it: this Mac, as localhost (see
        // Address.reachable). Only the page itself; a frame goes nowhere.
        if action.targetFrame?.isMainFrame == true, let local = Address.reachable(url) {
            decisionHandler(.cancel)
            webView.open(local)
            return
        }

        // An extension's rule sending a site to one of its pages (Norma's
        // block page): that page needs another view too.
        if #available(macOS 15.4, *), routeRuleRedirect(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // A website returning to a public extension page needs another view.
        if #available(macOS 15.4, *), routeExtensionReturn(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // An extension's page sending its own tab to a website (see
        // replace(_:going:)).
        if #available(macOS 15.4, *), ["http", "https"].contains(scheme),
           action.targetFrame?.isMainFrame ?? true,
           webView.url?.scheme == Extensions.scheme,
           let tab = tab(for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.replace(tab, going: url) }
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it.
        //
        // The middle button is not judged here. WebKit hands the browser a
        // navigation action for a ⌘-click and none at all for a middle one,
        // and where it does report a button it answers with a mask — 1 left,
        // 2 right, 4 middle — so a check for 2 here would have meant the right
        // button, not the middle (see MiddleRelay, which is where the middle
        // button is answered).
        //
        // Should a WebKit ever hand one over for the middle button after all,
        // it is cancelled: MiddleRelay has already opened the link in a tab of
        // its own, and letting this one through would take the page there too.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            decisionHandler(.cancel)
            return
        }
        // The chosen modified click: a peek at the link, over this
        // page (see Peek.swift). Only from a tab in the row — within a peek,
        // a link just goes.
        if prefs.peeksLinks, action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.intersection([.shift, .command, .option, .control]) == prefs.peekClick.flags,
           let from = tab(for: webView), !peekInFront {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.peek(url, from: from) }
            return
        }
        // A plain click in a pin, on a link to another site: a peek too (see
        // peeksFromPin). Links into the page's frames
        // are the page's own business. A link the site sends out by way of
        // itself, as Google's results go by google.com/goto, is asked about
        // again at the redirect, still as a click — by then webView.url is
        // already where it is going, so the page it was on is the one in the
        // history.
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
           action.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let from = tab(for: webView), peeksFromPin(url, in: from, on: webView.backForwardList.currentItem?.url) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.peek(url, from: from) }
            return
        }
        if action.navigationType == .other, action.targetFrame?.isMainFrame == true,
           let from = tab(for: webView), followsPeek(url, in: from) {
            decisionHandler(.cancel)
            return
        }
        // From popupTab, not tab(for:): a peek or a small window is not in
        // the row, and a link from a private one must open private too.
        if action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            openClicked(url, foreground: action.modifierFlags.contains(.shift), from: popupTab(for: webView), view: webView)
            decisionHandler(.cancel)
            return
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetFrame?.isMainFrame ?? true, let tab = tab(for: webView) {
            let host = curtain.host(of: url)
            tab.arm(hiding: curtain.css(on: host), to: url)
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(tab.contentController ?? webView.configuration.userContentController, for: host)
            // The frames that were told about the last page's darkening go
            // with it.
            tab.duskFrames.removeAll()
            // And the frames that played, and the count to the media keys.
            tab.leaving()
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            handOff(url, scheme: scheme, action: action, from: webView)
        }
    }

    /// Unlike tabs.update(), a website's navigation must be checked against
    /// web_accessible_resources before using an extension view.
    @available(macOS 15.4, *)
    private func routeExtensionReturn(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard let tab = tab(for: webView) else { return false }
        let source = tab.extensionReturn.source(for: action)
        guard let requested = action.request.url else { return false }
        let target = Extensions.current(requested)
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab)
    }

    /// WebKit marks the navigation it starts for a content rule's redirect
    /// (`_isContentExtensionRedirect`); a page can't. What a page could reach
    /// is still all it gets: the file must be one the extension exposes to
    /// the site the tab was going to, as Chrome requires of a redirect to an
    /// extension's file.
    @available(macOS 15.4, *)
    private func routeRuleRedirect(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard action.targetFrame?.isMainFrame == true,
              action.responds(to: NSSelectorFromString("_isContentExtensionRedirect")),
              (action.value(forKey: "_isContentExtensionRedirect") as? Bool) == true,
              let tab = tab(for: webView), let requested = action.request.url
        else { return false }
        let source = tab.extensionReturn.ruleSource(for: action)
        let target = Extensions.current(ExtensionRedirectPolicy.ruleTarget(requested))
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab, fromRule: true)
    }

    @available(macOS 15.4, *)
    private func handOverExtensionReturn(_ target: URL, source: URL, from webView: WKWebView, tab: Tab, fromRule: Bool = false) -> Bool {
        guard !tab.shy,
              let context = Extensions.shared.controller.extensionContext(for: target),
              context.isLoaded, context.webViewConfiguration != nil,
              ExtensionRedirectPolicy.allows(target: target, sourceOrigin: source, manifest: context.webExtension.manifest, fromRule: fromRule)
        else { return false }
        let revision = tab.extensionReturn.revision
        DispatchQueue.main.async { [weak self, weak tab, weak webView] in
            guard let self, let tab, let webView,
                  self.tab(for: webView)?.id == tab.id,
                  tab.extensionReturn.revision == revision else { return }
            self.replace(tab, going: target)
        }
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cancelDisplay(for: webView)
        guard let navigation else { return }
        tab(for: webView)?.extensionReturn.started(navigation, at: webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let tab = tab(for: webView) else { return }
        let redirect = tab.extensionReturn.redirected(navigation, to: webView.url)
        guard let redirect, #available(macOS 15.4, *),
              handOverExtensionReturn(Extensions.current(redirect.target), source: redirect.source, from: webView, tab: tab)
        else { return }
        webView.stopLoading()
    }

    /// An address for another app — mail, a call, a meeting. The page itself
    /// may ask, or a frame of the page's own site — Zoom's, Teams' and
    /// Slack's "open the app" pages load it into a frame of their own from a
    /// script — or a click inside any frame. A frame from another site that
    /// asks on its own (an advertisement, say) is ignored. And the other app
    /// opens only once you have said so, as in Safari — except a mail or
    /// phone link you just clicked on, which is exactly what it says.
    private func handOff(_ url: URL, scheme: String, action: WKNavigationAction, from webView: WKWebView) {
        let clicked = action.navigationType == .linkActivated
        let source: WKFrameInfo? = action.sourceFrame
        let top = webView.url?.host()?.lowercased() ?? ""
        let asker = source?.securityOrigin.host.lowercased() ?? ""
        let ownSite = source?.isMainFrame == true
            || (!top.isEmpty && !asker.isEmpty && Vault.registrable(asker) == Vault.registrable(top))
        // No target frame is a new window asked for: the frame asking is
        // judged, as for any other frame.
        guard action.targetFrame?.isMainFrame ?? false || clicked || ownSite else {
            if Store.testing { Browser.handedOff.append("\(scheme): ignored") }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if Store.testing { Browser.handedOff.append("\(scheme): no app") }
            return
        }
        // A test run can't show the question (see Dialogs): it says it would.
        if Store.testing {
            Browser.handedOff.append("\(scheme): asked")
            return
        }
        if clicked, ["mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        // Over its own tab only, as a page's own questions are (see ask).
        ask(from: webView, show: {
            let alert = NSAlert()
            alert.messageText = "Open \u{201C}\(name)\u{201D}?"
            alert.informativeText = "\(webView.url?.host() ?? "This page") wants to open \(name)."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            Dialogs.show(alert, over: webView) { answer in
                guard answer == .alertFirstButtonReturn else { return }
                NSWorkspace.shared.open(url)
            }
        }, drop: {})
    }

    /// A link that asks for a new window gets a new tab. The configuration
    /// WebKit hands over has to be the one the new view is built with, or the
    /// opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let opener = popupTab(for: webView) else { return nil }
        let clicked = opener.popupGesture.take(origin: PopupGesture.origin(action.sourceFrame), mainFrame: action.sourceFrame.isMainFrame)
        if !clicked {
            // A second window for a click that already had its one: the
            // duplicate one click must not make, said nowhere.
            if opener.popupGesture.spent() { return nil }
            // No click just before: refused, and the tab says so (see
            // BlockedPopups.swift), unless you allowed pop-ups from this site
            // and it is the site's own page or frame asking.
            guard popupsAllowed(opener, from: action.sourceFrame, top: opener.committed ?? webView.url) else {
                opener.noteBlocked(action.request.url)
                return nil
            }
        }
        let from = opener.id
        // The link menu's Open Link in New Tab, asked for in the last second.
        // Read once: reading it takes it.
        let behind = (webView as? PageView)?.takeBehind() == true
        // Its Open Link in Split View, the same way.
        let beside = (webView as? PageView)?.takeBeside() == true
        let popup = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        // A link clicked open in a new tab, to a site Settings sends to
        // another space: there instead, without its opener, which is in
        // another space's store anyway (see SpaceRoutes.swift). A window
        // the page opens from a script, or sizes, keeps its opener here.
        if clicked, !beside, !popup, action.navigationType == .linkActivated,
           (action.request.httpMethod ?? "GET").uppercased() == "GET",
           let url = action.request.url, sendToSpace(url, from: opener) {
            return nil
        }
        // WebKit's copy of the opener's configuration still holds the
        // opener's user content controller — its scripts and its message
        // handlers. Shared, the new tab claimed the opener's handlers as its
        // own, and closing or sleeping it took them off the opener's page:
        // right-click on a picture on X, after following a link out of it,
        // did nothing at all. Each tab gets a controller of its own.
        configuration.userContentController = WKUserContentController()
        // The opener's copy is what its view was made with, maybe before
        // Settings › Videos wait for a click last moved.
        configuration.mediaTypesRequiringUserActionForPlayback = Web.playback
        // A new window a pin's page asked for on a click — a target="_blank"
        // link, or window.open from the click, as Gmail's links and many
        // sites' do, often by way of a redirect on their own site — opens in
        // the peek rather than the row (see peekWindow). Only on a click:
        // a window the page opens by itself, even from a site allowed
        // pop-ups, takes the tab path as before. A window sized by the page,
        // "Sign in with…", is left alone, as is a modified click, and so is
        // anything that isn't a web page (about:blank, data:, blob:).
        if clicked, !behind, !beside, !popup, !peekInFront, opener.pin != nil,
           [.linkActivated, .other].contains(action.navigationType),
           action.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let url = action.request.url, Browser.peekable(url) {
            let page = peekWindow(configuration, from: opener, going: url)
            opener.popupGesture.opened(page.id)
            return page.web
        }
        let tab = Tab(shy: opener.shy, configuration: configuration)
        tab.popup = popup
        tab.opener = from
        if clicked { opener.popupGesture.opened(tab.id) }
        // A small window's page opening another (X's links out, by way of
        // t.co): a small window of its own, a step down from this one, not a
        // tab in the browser's window, which came forward over it (#1041).
        // A window the page sizes still opens as Settings says below.
        if !behind, !beside, !(prefs.popupWindows && (windowFeatures.width != nil || windowFeatures.height != nil)),
           LittleWindow.holding(opener.id) != nil {
            prepare(tab)
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            LittleWindow.show(tab, for: self)
            return tab.web
        }
        if prefs.popupWindows, windowFeatures.width != nil || windowFeatures.height != nil {
            let sourceSpace = parked.first { $0.value.tabs.contains { $0 === opener } }?.key ?? spaceID
            let popup = Browser(record: WindowRecord(space: sourceSpace), websitePopup: true)
            popup.prepare(tab)
            popup.tabs = [tab]
            popup.activeID = tab.id
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            let screen = (webView.window?.screen ?? NSScreen.main)?.visibleFrame
            let frame = screen.map { Browsers.popupFrame(width: windowFeatures.width?.doubleValue,
                                                        height: windowFeatures.height?.doubleValue, on: $0) }
            Browsers.open(popup, frame: frame)
            return tab.web
        }
        // The link menu's Open Link in New Tab: behind this tab, where a
        // ⌘-click's goes (see open(_:foreground:)).
        let destination = tabDestination
        destination.prepare(tab)
        if behind || beside {
            if prefs.usesTabGroups, !tab.shy, !tab.bench { tab.groupID = opener.groupID }
            destination.tabs.insert(tab, at: destination.placeForLink(from: opener))
            destination.noteLink(tab, from: opener)
            // Open Link in Split View: beside the page it came from, the two
            // as a pair, with the keys, as a peek kept beside is. Paired while
            // it is still blank, so the pair wakes nothing WebKit is about to
            // load into it. A pair that can't be made, or a link out of a
            // site's own pop-up window, whose tab opens in another window,
            // leaves it behind.
            if beside, destination === self { pair(tab, with: opener, onLeft: false) }
        } else if clicked, destination === self, frontLinksBeside {
            // Settings › Tabs › Links opened in front go beside their page:
            // where a ⌘-click's goes, after the ones the page already opened,
            // in click order, its group and its pair kept. A window the page
            // opens with no click goes to the end, as before.
            if let run = linkRun { runBeforeScript = (tab.id, run) }
            if prefs.usesTabGroups, !tab.shy, !tab.bench { tab.groupID = opener.groupID }
            tabs.insert(tab, at: placeForLink(from: opener))
            noteLink(tab, from: opener)
            activeID = tab.id
            editing = false
        } else {
            // From a grouped tab it joins the group, as a link opened behind
            // does: Settings says a link from a group stays in it, and it
            // landed outside, at the end of the row. Still where a page
            // opened in front goes, only inside the group — arrangeGroupedTabs
            // keeps the row in group order, so the end of the row is the end
            // of the group.
            if prefs.usesTabGroups, !tab.shy, !tab.bench, destination === self, let group = group(of: opener) {
                tab.groupID = group
                if let index = tabGroups.firstIndex(where: { $0.id == group }), tabGroups[index].collapsed {
                    tabGroups[index].collapsed = false
                }
            }
            destination.tabs.insert(tab, at: destination.placeForFront())
            if clicked, let run = destination.linkRun { destination.runBeforeScript = (tab.id, run) }
            destination.activeID = tab.id
            destination.editing = false
        }
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// A link clicked open in a tab by Eden itself (⌘-click, the middle
    /// button): one click, one tab. When the page's own script already
    /// opened a window for that click, it is the tab — put where the click
    /// asked, behind unless ⇧ was held — and no second one opens. Otherwise
    /// the click is spent, and a window.open after it gets nothing.
    private func openClicked(_ url: URL, foreground: Bool, from source: Tab?, view: WKWebView?) {
        let opener = view.flatMap { popupTab(for: $0) }
        if let made = opener?.popupGesture.claim(),
           let tab = Browsers.all.lazy.flatMap(\.tabs).first(where: { $0.id == made }) {
            let run = runBeforeScript?.tab == made ? runBeforeScript?.run : nil
            runBeforeScript = nil
            if !foreground, activeID == tab.id, let source, tabs.contains(where: { $0.id == source.id }) {
                activeID = source.id
            }
            // The script's tab went where a page opened in front goes; it is
            // the ⌘-click's, so it goes where the ⌘-click's would have.
            if let source, tabs.contains(where: { $0.id == source.id }), source.id != tab.id,
               split(for: tab) == nil, let at = tabs.firstIndex(where: { $0.id == tab.id }) {
                if frontLinksBeside {
                    // It already went beside the page as a click's, and
                    // counted in the run: the run as it was before it.
                    linkRun = run?.opener == source.id ? run : nil
                } else if !foreground, run?.opener == source.id {
                    linkRun = run
                }
                tabs.remove(at: at)
                if prefs.usesTabGroups, !tab.shy, !tab.bench { tab.groupID = source.groupID }
                tabs.insert(tab, at: placeForLink(from: source))
                if !foreground || frontLinksBeside { noteLink(tab, from: source) }
            }
            return
        }
        // To a site Settings sends to another space: there, in front.
        if sendToSpace(url, from: source) { return }
        open(url, foreground: foreground, from: source, mayWait: true, link: true)
    }

    /// Anything the window can't show is something to keep instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A redirect (3xx) has nowhere to be shown and carries no content of
        // its own, but must be followed rather than downloaded — even if its
        // headers say `application/binary` or `application/octet-stream`, as
        // youtube.com and some servers do on their redirects.
        if let http = response.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        // A server that says "attachment" means a file to keep, even one
        // WebKit could show. Gmail's download button loads the attachment
        // into a hidden frame and counts on exactly that: a PDF shown there
        // instead was the button doing nothing at all.
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        // A text file already on this Mac that WebKit has no type for — a
        // hosts file, a .yaml, a Dockerfile — is shown as text, as in Safari
        // and Chrome, rather than copied into Downloads (#525). And one it
        // does show as text is read as UTF-8: WebKit took a file's text for
        // Windows-1252, and every accent in it came out as two letters.
        // Read off the main thread, a file on a slow share included; the
        // decision waits for it, and the window doesn't.
        let plain = response.response.mimeType?.lowercased() == "text/plain"
        if !response.canShowMIMEType || plain, response.isForMainFrame,
           let url = response.response.url, url.isFileURL {
            let showable = response.canShowMIMEType
            Task.detached(priority: .userInitiated) {
                let text = LocalText.contents(of: url)
                await MainActor.run {
                    guard let text else {
                        decisionHandler(showable ? .allow : .download)
                        return
                    }
                    decisionHandler(.cancel)
                    webView.load(text, mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: url)
                }
            }
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        keep(download, from: webView)
        dropEmpty(webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download, from: webView)
        dropEmpty(webView)
    }

    /// Download Linked File in the right-click menu. WebKit starts the
    /// download and hands it to a delegate that answers this name, outside
    /// the public framework; unanswered, the file was fetched and went nowhere.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        keep(download, from: webView)
    }

    /// A tab that has shown nothing, and whose first page turned out to be a
    /// file: a download link that opens in a new tab, as a course site's
    /// attachments do. The file goes on arriving without it. Kept, the tab
    /// held the file's address, came back with the session, and downloaded
    /// the file again each time it was opened. It forgets the address; and
    /// when a page's link opened it, it closes, as in Safari and Chrome, and
    /// you are back on that page. A tab you opened yourself stays, as a new
    /// tab, and so does a window's only tab: closing it would close the
    /// window.
    private func dropEmpty(_ webView: WKWebView) {
        guard let tab = tab(for: webView), tab.committed == nil, tab.pin == nil else { return }
        // Without its address, it is not offered back by ⇧⌘T either.
        tab.forget()
        guard let opener = tab.opener, tabs.count > 1 else { return }
        if tab.id == activeID, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        close(tab)
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(
        _ download: WKDownload,
        from suppliedWebView: WKWebView? = nil,
        continuing entry: FetchEntry? = nil,
        operationID: UUID? = nil,
        helper: WKWebView? = nil
    ) {
        let webView = suppliedWebView ?? download.webView
        // Find privacy before publishing the entry. A private transfer is
        // still tracked internally so its delegate and Finder progress clean
        // up correctly, but it never enters the shared Downloads panel.
        let isPrivate = entry == nil && webView.map {
            !$0.configuration.websiteDataStore.isPersistent || anyTab(for: $0)?.shy == true
        } == true
        download.delegate = self
        if !downloading.contains(where: { $0 === download }) { downloading.append(download) }
        if isPrivate { unlisted.insert(ObjectIdentifier(download)) }
        else { unlisted.remove(ObjectIdentifier(download)) }
        guard fetches.start(
            download,
            owner: self,
            webView: webView,
            listed: !isPrivate,
            entry: entry,
            operationID: operationID,
            helper: helper
        ) else {
            relinquish(download)
            download.cancel { _ in }
            return
        }
        // A true resume may continue the preserved target without asking its
        // delegate for a destination again. Publish Finder progress as soon
        // as the resumed WKDownload is attached; `going` coalesces a later
        // destination callback for the same URL.
        if entry != nil, let destination = entry?.destination {
            fetches.going(download, to: destination, cancel: finderCancellation(for: download))
        }
    }

    /// Pause an active download. WebKit's cancellation callback is the
    /// authoritative source of resume data and also owns cleanup if no
    /// delegate failure callback arrives.
    func pauseDownload(_ entry: FetchEntry) {
        guard entry.canPause, let operation = fetches.beginStop(entry, action: .pause) else { return }
        stopDownload(operation)
    }

    func resumeDownload(_ entry: FetchEntry) {
        guard let operation = fetches.beginResume(entry), let data = operation.resumeData else { return }
        operation.webView.resumeDownload(fromResumeData: data) { download in
            self.continueDownload(download, operation)
        }
    }

    /// From the start, to the folder it went to, under the name it was asked
    /// for: numbered afresh, " 2" and on, past whatever is there now, the
    /// last attempt's half-written file let go first.
    func retryDownload(_ entry: FetchEntry) {
        let folder = entry.destination?.deletingLastPathComponent() ?? downloadsFolder
        guard let operation = fetches.beginRetry(entry, destination: { Self.free(entry.retryName, in: folder) }),
              let request = operation.request else { return }
        operation.webView.startDownload(using: request) { download in
            self.continueDownload(download, operation)
        }
    }

    private func continueDownload(_ download: WKDownload, _ operation: Fetches.StartOperation) {
        guard fetches.accepts(operation) else {
            download.cancel { _ in }
            return
        }
        keep(
            download, from: operation.webView, continuing: operation.entry, operationID: operation.operationID,
            helper: operation.helper ? operation.webView : nil
        )
    }

    /// Active rows stop; paused and failed rows are removed and release their
    /// in-memory resume data and the store they were asked with.
    func cancelDownload(_ entry: FetchEntry) {
        switch entry.state {
        case .downloading:
            guard let operation = fetches.beginStop(entry, action: .cancel) else { return }
            stopDownload(operation)
        case .pausing:
            _ = fetches.upgradeStopToCancel(entry)
        case .resuming:
            fetches.removeStarting(entry)
        case .paused, .failed:
            fetches.removeStopped(entry)
        }
    }

    /// A space deleted: its downloads go with it, whatever they were doing,
    /// as Cancel or Remove would take them, and with them the store they
    /// kept and any view made to ask with it. Its cookies can then be
    /// erased, and nothing is asked with them again.
    func forgetDownloads(of store: WKWebsiteDataStore) {
        for entry in fetches.entries where entry.store === store { cancelDownload(entry) }
    }

    private func stopDownload(_ operation: Fetches.StopOperation) {
        let fetches = self.fetches
        operation.download.cancel { resumeData in
            DispatchQueue.main.async {
                guard let ended = fetches.stopped(operation, resumeData: resumeData) else { return }
                ended.owner.relinquish(operation.download)
            }
        }
    }

    /// Called for both delegate completion and WKDownload.cancel completion;
    /// idempotence handles WebKit choosing either callback order.
    func relinquish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        unlisted.remove(ObjectIdentifier(download))
    }

    private func finderCancelled(_ download: WKDownload) {
        guard let operation = fetches.beginFinderStop(download) else { return }
        stopDownload(operation)
    }

    private func finderCancellation(for download: WKDownload) -> @Sendable () -> Void {
        { [weak self, weak download] in
            DispatchQueue.main.async {
                guard let self, let download else { return }
                self.finderCancelled(download)
            }
        }
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }

    /// The camera or microphone, for a tab's page or an extension's popup.
    ///
    /// Remembered for the origin that asked — http://site and https://site,
    /// or another port, are other sites — and never for a private tab, which
    /// leaves nothing behind. An extension's page asking — its popup, or a
    /// frame of its own inside a website (a recorder's camera bubble) — is
    /// named as the extension and remembered for it, never for the site it
    /// sits in: allowing the bubble must not give the site the camera.
    func askedForCapture(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, type: WKMediaCaptureType,
                         decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // An extension capturing, however it went about it: the pill says so.
        if #available(macOS 15.4, *) { ExtensionCapture.shared.watchCapture(webView, frame: frame) }
        let asker = frame.securityOrigin
        let host: String
        let site: String
        if Browser.extensionScheme(asker.protocol) {
            host = Browser.extensionName(asker.host)
            site = "\(asker.protocol.lowercased())://\(asker.host.lowercased())"
        } else {
            host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
            site = origin.host.isEmpty ? host : "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
        }
        let key = "\(site)|\(type.rawValue)"
        let shy = !webView.configuration.websiteDataStore.isPersistent || (popupTab(for: webView)?.shy ?? false)

        if !shy, type == .cameraAndMicrophone {
            if CaptureChoices.combinedBlocked(origin: site) { return decisionHandler(.deny) }
            if CaptureChoices.combinedAllowed(origin: site) { return decisionHandler(.grant) }
        } else if !shy, let kind = type == .camera ? CaptureChoices.Kind.camera : type == .microphone ? .microphone : nil,
                  let remembered = CaptureChoices.mediaDecision(kind, origin: site) {
            return decisionHandler(remembered ? .grant : .deny)
        }
        // Asked over its own page only, as a page's other questions are (see
        // ask): a tab behind, or the other page of a pair, waits until you go
        // to it, and is asked then — never over the page you are on.
        var wants = Browser.name(for: type)
        if !shy, type == .cameraAndMicrophone {
            if CaptureChoices.mediaDecision(.camera, origin: site) == true { wants = "microphone" }
            else if CaptureChoices.mediaDecision(.microphone, origin: site) == true { wants = "camera" }
        }
        let revision = CaptureChoices.revision(for: "capture." + key)
        ask(from: webView, show: { [weak self] in
            guard let self else { return decisionHandler(.deny) }
            guard shy || revision == CaptureChoices.revision(for: "capture." + key) else { return decisionHandler(.deny) }
            // One question at a time. A second page asking while the first is
            // still waiting is refused rather than queued behind it.
            guard !permissionBusy else { return decisionHandler(.deny) }
            decide = decisionHandler
            // A peek's own page, which isn't in the row: its question goes
            // when it does, or when it is hidden (see followPeek).
            decideTab = tab(for: webView) ?? (peekTab?.built === webView ? peekTab : nil)
            askedAbout = shy ? "" : key
            askedRevision = shy ? nil : revision
            asking = CaptureAsk(host: host, wants: wants)
        }, drop: { decisionHandler(.deny) })
    }

    /// WebKit's private delegate lets Eden ask before opening the system picker.
    /// Extension pages use separate delegates.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func askedToShareScreen(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                            systemAudio: Bool, decisionHandler: @escaping (Int) -> Void) {
        guard decideDisplay == nil, decide == nil, let tab = (tabs + parkedTabs).first(where: { $0.built === webView })
        else { return decisionHandler(0) }
        let request = UUID()
        displayRequest = request
        displayTab = tab
        decideDisplay = decisionHandler
        let asker = frame.securityOrigin
        let host = origin.host.isEmpty ? (tab.address?.host() ?? "This page") : origin.host
        let named = Browser.extensionScheme(asker.protocol) ? Browser.extensionName(asker.host) : host
        // Recheck ownership when a background tab's question is shown.
        displayHeld = ask(from: webView, show: { [weak self, weak webView] in
            guard let self, displayRequest == request else { return }
            guard let webView, activeID == tab.id, tab.built === webView, decide == nil else { return cancelDisplay() }
            asking = CaptureAsk(host: named, wants: "screen", screen: true, sound: systemAudio)
        }, drop: { [weak self] in
            guard let self, displayRequest == request else { return }
            cancelDisplay()
        })
    }

    /// An extension's own scheme, today's or the one it had before.
    static func extensionScheme(_ scheme: String) -> Bool {
        ["chrome-extension", "webkit-extension"].contains(scheme.lowercased())
    }

    /// An extension by the name it shows, for a question it asks.
    static func extensionName(_ id: String) -> String {
        if #available(macOS 15.4, *), let found = Extensions.shared.installed.first(where: { $0.id.lowercased() == id.lowercased() }) {
            return found.name
        }
        return "An extension"
    }

    /// A page asking where you are. WebKit asks this through a delegate
    /// method that isn't public on the Mac; unanswered, every page is refused.
    ///
    /// Only the page on screen, and only for itself: the tab in front, and
    /// the page's own origin or a frame of that same origin. WebKit already
    /// keeps frames from elsewhere out unless the page lets them in
    /// (allow="geolocation"); here they don't get to borrow the page's
    /// answer at all. Remembered per origin, as the camera is, and never for
    /// a private tab.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func askedForLocation(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let give: (WKPermissionDecision) -> Void = { decision in
            guard Store.testing else { return decisionHandler(decision) }
            Browser.locationAnswered = decision == .grant ? "granted" : "denied"
            decisionHandler(.deny)
        }
        // WebKit names the page's origin for a frame it let in, whoever the
        // frame is: the frame's own is what counts.
        let site = Browser.origin(origin.protocol, origin.host, origin.port)
        let asker = frame.securityOrigin
        guard let tab = tab(for: webView), tab.id == activeID, !origin.host.isEmpty,
              let page = webView.url, let scheme = page.scheme, let host = page.host(),
              site == Browser.origin(scheme, host, page.port ?? 0),
              Browser.origin(asker.protocol, asker.host, asker.port) == site
        else { return give(.deny) }
        let key = "\(site)|location"
        if !tab.shy, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            return give(remembered ? .grant : .deny)
        }
        // One question at a time, as for the camera.
        guard !permissionBusy else { return give(.deny) }
        decide = give
        decideTab = tab
        askedAbout = tab.shy ? "" : key
        askedRevision = tab.shy ? nil : CaptureChoices.revision(for: "capture." + key)
        let named = Browser.extensionScheme(origin.protocol) ? Browser.extensionName(origin.host) : origin.host
        asking = CaptureAsk(host: named, wants: "location", once: true, keeps: !tab.shy)
    }

    /// A page asking to send notifications. Asked over its own page, as the
    /// camera is, and only for the page's own origin; kept per origin under
    /// the same "capture." keys, so Forget choices takes it back. A private
    /// tab, or Settings › Privacy's switch off, is refused without a card.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func askedForNotifications(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
        let site = Browser.origin(origin.protocol, origin.host, origin.port)
        guard prefs.siteNotifications, let tab = tab(for: webView), !tab.shy, webView.configuration.websiteDataStore.isPersistent,
              !origin.host.isEmpty,
              let page = webView.url, let scheme = page.scheme, let host = page.host(),
              Browser.origin(scheme, host, page.port ?? 0) == site
        else { return decisionHandler(false) }
        if let remembered = SiteNotifications.choices[site] { return decisionHandler(remembered) }
        let revision = CaptureChoices.revision(for: "capture.\(site)|notifications")
        ask(from: webView, show: { [weak self] in
            guard let self else { return decisionHandler(false) }
            guard revision == CaptureChoices.revision(for: "capture.\(site)|notifications") else { return decisionHandler(false) }
            guard !permissionBusy else { return decisionHandler(false) }
            decide = { decision in
                if decision == .grant { SiteNotifications.shared.authorize() }
                decisionHandler(decision == .grant)
                SiteNotifications.shared.objectWillChange.send()
            }
            decideTab = tab
            askedAbout = "\(site)|notifications"
            askedRevision = revision
            asking = CaptureAsk(host: origin.host, wants: "notifications")
        }, drop: { decisionHandler(false) })
    }

    /// "scheme://host[:port]", the way an origin is kept for its answers.
    static func origin(_ scheme: String, _ host: String, _ port: Int) -> String {
        let scheme = scheme.lowercased(), host = host.lowercased()
        let standard = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host)" + (port == 0 || standard ? "" : ":\(port)")
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        // A popup window is the one page it opened: when that
        // page closes itself (a sign-in, once done), the
        // window goes too, as in Chrome, instead of staying on a blank tab.
        if isPopup, tabs.count == 1 {
            window?.close()
            return
        }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if let opener = tab.opener, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        tab.pin = nil
        close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if websitePopup { cancelCapture() }
        popupTab(for: webView)?.popupGesture.clear()
        // What is open here changed, for what says so (OpenPages).
        NotificationCenter.default.post(name: OpenPages.changed, object: nil)
        guard let tab = tab(for: webView) else {
            // A small window's page came: what failed before it is over.
            littleTab(for: webView)?.failure = nil
            // A peek or a small window opens at the size the site has, or
            // the one in Settings, as a tab does: neither is in the row,
            // and both opened at 100% (#691).
            if let page = peekTab?.built === webView ? peekTab : littleTab(for: webView) {
                page.applyRememberedZoom()
            }
            return
        }
        tab.didCommit()
        // A page that went somewhere else starts a new run of links.
        if linkRun?.opener == tab.id { linkRun = nil }
        tab.extensionReturn.finished(navigation)
        if tab.id == activeID {
            invalidateFindPage(retryOnActiveTab: false)
            linkStatus.dismiss()
        }
        tab.failure = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
        // A tab waking from sleep: the new document is in, and a moment
        // after it is on screen the picture of the old one can go. Its first
        // frame takes it off sooner (see Tab.build); this is for the page
        // that has none, or whose first frame comes later than this.
        tab.uncover(after: 0.45)
    }

    /// Where the window is, for a page asking `window.outerWidth`,
    /// `outerHeight`, `screenX` and `screenY`. Unanswered, WebKit tells it a
    /// window of no size at the bottom of the screen, and Google Docs, on a
    /// Safari before 26.4, takes `outerWidth / innerWidth` for the browser's
    /// zoom: from 0 it took the smallest it knows, a quarter, and drew the
    /// document at a quarter of the screen's sharpness (#666). Safari answers
    /// with its window. This answers with the window as tall as it is, but
    /// only as wide as the page: the column beside a page is no chrome of
    /// Safari's, and with it counted `outerWidth - innerWidth` passed 160,
    /// which Discord reads as DevTools docked open and signs you out (#916).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, getWindowFrameWithCompletionHandler done: @escaping (CGRect) -> Void) {
        done(windowFrame(for: webView))
    }

    /// The window a page reads as its own: the one it is in, or, a tab's page
    /// kept out of it behind the tab in front, this browser's. A page that
    /// loads there still has the width it was shown at, and Docs would take
    /// that over nothing, and keep the quarter for as long as the page lives.
    func windowFrame(for webView: WKWebView) -> CGRect {
        let shown: WKWebView? = webView.window != nil ? webView
            : (active?.web.window != nil ? active?.web : nil)
        guard let shown, let frame = shown.window?.frame else { return window?.frame ?? .zero }
        // The page's own width, at its own place across; the window's height
        // and place down, as the bars over a page are the browser's chrome.
        let page = shown.convert(shown.bounds, to: nil)
        guard page.width > 0 else { return frame }
        return CGRect(x: frame.minX + page.minX, y: frame.minY, width: page.width, height: frame.height)
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        (webView as? PageView)?.showFirstFrame()
        // Dark pages: a page's first frame is what it looks like.
        if let tab = tab(for: webView) { duskLook(tab) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showFirstFrame()
        guard let tab = anyTab(for: webView), let url = tab.address else { return }
        tab.uncover()
        // And again once it has all come in, for a page that drew its look
        // late, or never had a first frame to say so.
        duskLook(tab)
        // The find bar still open over a page that has just come in: look
        // for the same words on it.
        if tab.id == activeID, finding, findSpec == nil,
           !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            look(forward: true)
        }
        tellStore(tab)
        if let arrival = tab.arrival {
            tab.arrival = nil
            // Only the page it was for: one gone to instead takes none of it.
            if History.identity(for: url) == History.identity(for: arrival.page) { arrive(tab, arrival) }
        }
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // A page in a language you always translate, or one that slept
        // translated (Translate.swift). Nothing at all while it's off.
        tab.translateIfWanted()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        history.record(url, title: tab.title)
        // The page on screen as it came in, once it has drawn, for its hover
        // card at the next launch: the tab in front when Eden quits is never
        // left, so it is kept from here.
        if visibleTabIDs.contains(tab.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak tab] in tab?.keepPicture() }
        }
        // A site's home page that says where its search is (OpenSearch):
        // with Search a site on, it joins the list (see SiteSearch.learn).
        if prefs.searchesSites, profileID == Profile.personalID, url.scheme == "https", url.path.isEmpty || url.path == "/" {
            webView.evaluateInSearch(SiteSearch.lookup) { value in
                guard let text = value as? String, let description = URL(string: text) else { return }
                MainActor.assumeIsolated { SiteSearch.learn(from: url, description: description) }
            }
        }
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        let tab = tab(for: webView) ?? littleTab(for: webView)
        tab?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        // Nor is a video or sound file opened as a page: WebKit's own player
        // takes it over and ends the load with "plug-in handled load" (204),
        // as in Safari, while the video plays. Answered as a failure, it
        // covered the playing video with "The page didn't load".
        guard !(nsError.domain == "WebKitErrorDomain" && code == 204) else { return }
        tab?.failure = message(for: code)
    }

    private func message(for code: Int) -> String {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The connection isn't secure."
        default:
            return "The page didn't load."
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.built === webView }
    }

    /// A small window's tab (see Little.swift). This browser looks after its
    /// pages without it being one of its tabs, so tab(for:) never finds it,
    /// and a link that failed to load there left the window blank.
    private func littleTab(for webView: WKWebView) -> Tab? {
        LittleWindow.all.first { $0.tab.built === webView }?.tab
    }

    /// Popups belong to the view that received the gesture, including pages
    /// in a Peek or Little window that have no row in this browser yet.
    func popupTab(for webView: WKWebView) -> Tab? {
        guard webView.navigationDelegate === self else { return nil }
        return anyTab(for: webView)
            ?? (peekTab?.built === webView ? peekTab : nil)
            ?? littleTab(for: webView)
    }

    /// The tab a page belongs to, in the space on screen or another: a page
    /// still loading when you went to another space finishes there, and
    /// still goes into History with its icon.
    func anyTab(for webView: WKWebView) -> Tab? {
        tab(for: webView) ?? parkedTabs.first { $0.built === webView }
    }
}

// MARK: - keeping files

extension Browser: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let chosen = fetches.destination(for: download)
        let name = Browser.fileName(asked ?? suggestedFilename)
        let file = chosen ?? whereToSave(name)
        guard let file else {
            if let ended = fetches.destinationCancelled(download) {
                ended.owner.relinquish(download)
            } else {
                relinquish(download)
            }
            completionHandler(nil)
            return
        }
        fetches.going(download, to: file, cancel: finderCancellation(for: download))
        // A retry is numbered afresh from the name asked for, or the one you
        // gave it: never from "report 2.pdf", whose own " 2" is not its name.
        if chosen == nil { fetches.entry(for: download)?.retryName = prefs.asksWhereToSave ? file.lastPathComponent : name }
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let entry = fetches.entry(for: download)
        let source = download.originalRequest?.url ?? entry?.request?.url
        let file = download.progress.fileURL ?? entry?.destination
        let listed = !unlisted.contains(ObjectIdentifier(download))
        let ended = fetches.finish(download, file: file)
        (ended?.owner ?? self).relinquish(download)
        guard ended != nil else { return }
        guard let file else {
            announce("Download finished", look: .done)
            return
        }
        guard listed else {
            announce("Saved \(file.lastPathComponent)", look: .done)
            return
        }
        if #available(macOS 15.4, *), let asked = source,
           let id = ExtensionShims.askedDownloads.removeValue(forKey: asked) {
            ExtensionShims.ownDownloads[id, default: []].insert(file.path)
        }
        saved(file, from: source, keepsAddress: entry?.addressForgotten != true)
    }

    /// The download button in the bar WebKit draws over a PDF. WebKit has the
    /// file already and hands it over whole — to a delegate that answers
    /// this name, outside the public framework, and to nobody otherwise: the
    /// button did nothing at all.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data?,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?
    ) {
        guard let data, let file = whereToSave(suggestedFilename ?? "") else { return }
        do {
            try data.write(to: file)
            Browser.markDownloaded(file)
            // A private page's file is named once and listed nowhere, as in
            // `downloadDidFinish`: the list is written to disk and outlives it.
            if webView.configuration.websiteDataStore.isPersistent, anyTab(for: webView)?.shy != true {
                saved(file, from: originatingURL)
            } else {
                announce("Saved \(file.lastPathComponent)", look: .done)
            }
        } catch {
            announce("Download failed", look: .problem)
        }
    }

    /// A page's own print(): the Print… item in a page's own menu, or ⌘P in
    /// an editor that keeps the key for itself (the page has it first, see
    /// `pageFirst`). WebKit hands it to a delegate that answers this name,
    /// outside the public framework, and to nobody otherwise: the button did
    /// nothing at all, and neither did ⌘P.
    ///
    /// The page waits while the sheet is up, as it does in Safari: WebKit
    /// holds its script until `done`, and draws the pages meanwhile. Only the
    /// tab in front of the window you are in may ask, one sheet at a time: a
    /// tab behind, or another window's, is answered with nothing, as Safari
    /// does. And a site that asks again each time the sheet is cancelled
    /// asks no more after the second cancel within ten seconds, until the
    /// tab goes to another site (see PrintSheet).
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(
        _ webView: WKWebView,
        printFrame frame: NSObject,
        pdfFirstPageSize: CGSize,
        completionHandler done: @escaping () -> Void
    ) {
        guard let window = webView.window, window.isKeyWindow, window.attachedSheet == nil,
              let tab = anyTab(for: webView), tab.id == activeID, !tab.isBlank,
              PrintSheet.allows(tab)
        else { done(); return }
        let sheet = PrintSheet(tab) { done() }
        Browser.printing(webView, frame: frame).runModal(
            for: window, delegate: sheet,
            didRun: #selector(PrintSheet.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: Unmanaged.passRetained(sheet).toOpaque()
        )
    }

    /// Where a file goes: the downloads folder, or wherever you say when
    /// Settings says to ask. Nil when the question was cancelled. The name
    /// comes from the page, so only its last part is taken: never a path
    /// out of the folder.
    private func whereToSave(_ name: String) -> URL? {
        let name = Browser.fileName(name)
        guard prefs.asksWhereToSave else { return Browser.free(name, in: downloadsFolder) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloadsFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func fileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        return ["", ".", "..", "/"].contains(last) ? "download" : last
    }

    /// A file written here from a page — the PDF bar's download, Save Page
    /// As… — marked as downloaded, as WebKit marks a download's: macOS checks
    /// it when it is first opened, as any other. No address goes with it, so
    /// a private page's says no more than an ordinary one's.
    nonisolated static func markDownloaded(_ file: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Eden",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        var file = file
        try? file.setResourceValues(values)
    }

    private func saved(_ file: URL, from source: URL?, keepsAddress: Bool = true) {
        loot.add(Keep(name: file.lastPathComponent, from: source?.host() ?? "", path: file.path, date: Date(),
                      address: keepsAddress ? Keep.address(of: source) : nil))
        announce("Saved \(file.lastPathComponent)", look: .done, file: file)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        guard let ended = fetches.fail(download, error: error, resumeData: resumeData) else { return }
        ended.owner.relinquish(download)
        if ended.announceFailure { announce("Download failed", look: .problem) }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}

/// What a page's print() is waiting on: told when the sheet has gone,
/// printed or cancelled, so WebKit can let the page's script go on. The
/// sheet's context keeps it alive until then.
@MainActor
final class PrintSheet: NSObject {
    private let done: () -> Void
    private let tab: Tab.ID
    private let site: String?

    init(_ tab: Tab, _ done: @escaping () -> Void) {
        self.tab = tab.id
        self.site = PrintSheet.site(of: tab)
        self.done = done
    }

    /// The sheets a page's print() had cancelled, by tab, on the site it
    /// was on: its origin, not its address, which the page itself can
    /// change with history.pushState between two print()s. Two cancels
    /// within ten seconds and the site asks no more, until the tab goes to
    /// another site or closes.
    private struct Cancels {
        var site: String?
        var when: [Date] = []
        var blocked = false
    }
    private static var cancelled: [Tab.ID: Cancels] = [:]

    private static func site(of tab: Tab) -> String? {
        guard let page = tab.committed else { return nil }
        return "\(page.scheme ?? "")://\(page.host() ?? ""):\(page.port.map(String.init) ?? "")"
    }

    /// Whether this tab's site may bring the sheet up again.
    static func allows(_ tab: Tab) -> Bool {
        guard let seen = cancelled[tab.id], seen.site == site(of: tab) else {
            cancelled[tab.id] = nil
            return true
        }
        return !seen.blocked
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintSheet>.fromOpaque(contextInfo).release() }
        if !success {
            var seen = PrintSheet.cancelled[tab].flatMap { $0.site == site ? $0 : nil } ?? Cancels(site: site)
            let now = Date()
            seen.when = seen.when.filter { now.timeIntervalSince($0) < 10 } + [now]
            if seen.when.count >= 2 { seen.blocked = true }
            PrintSheet.cancelled[tab] = seen
        }
        done()
    }
}

// MARK: - Eden's own pages, in tabs (see InternalPages.swift)

extension Browser {
    /// The tab in this window's row showing that kind of page, if any.
    func pageTab(_ kind: InternalPage.Kind) -> Tab? {
        tabs.first { $0.page?.kind == kind }
    }

    /// ⌘, ⌘Y ⇧⌘J and the menus: the page's tab, brought forward if it is
    /// open, made otherwise. An empty tab in front becomes the page rather
    /// than being left behind it; a private one doesn't — these pages are
    /// never private, as Chrome's settings never open in an incognito
    /// window — and the page opens beside it.
    @discardableResult
    func show(_ page: InternalPage) -> Tab {
        // A pop-up window holds its one page: Eden's own open beside it.
        if websitePopup { return tabDestination.show(page) }
        if page.kind == .settings, let detail = page.detail, let section = SettingsPanel.Page.named( detail) {
            settingsPage = section
        }
        if page.kind == .passwords { relist() }
        if page.kind == .history, pageTab(.history) == nil { recallMode = .history }
        let tab: Tab
        if let open = pageTab(page.kind) {
            tab = open
            // Asked for another section, or another browser to bring
            // things from: the open tab moves there, without a step back.
            if page.detail != nil, open.page != page {
                open.show(page, stepping: false)
                objectWillChange.send()
            }
        } else {
            if let blank = active, blank.isBlank, !blank.shy, !blank.bench, blank.pin == nil,
               blank.draft.isEmpty, typed.isEmpty {
                tab = blank
            } else {
                tab = Tab(configuration: Web.configuration(space: spaceID))
                prepare(tab)
                tabs.insert(tab, at: placeForNew())
            }
            tab.show(page)
        }
        if launching { dismiss() }
        editing = false
        typed = ""
        if activeID != tab.id { select(tab) }
        writeSessionSoon()
        return tab
    }

    /// From one of these pages to another — Settings' "Passwords…", Bring
    /// Things Over's "Show passwords": the same tab goes there, and Back
    /// comes back, as a link would. Unless that page is already open in a
    /// tab of its own, which is then the one shown.
    func lead(to page: InternalPage) {
        guard let here = active, here.page != nil, pageTab(page.kind) == nil else {
            show(page)
            return
        }
        if page.kind == .settings, let detail = page.detail, let section = SettingsPanel.Page.named( detail) {
            settingsPage = section
        }
        // As show(_:) does: the list read before the page is drawn.
        if page.kind == .passwords { relist() }
        here.show(page)
        writeSessionSoon()
    }

    /// The page's tab closed, as ⌘W would close it. For the bench, and the
    /// last few callers that put a panel away.
    func putAway(_ kind: InternalPage.Kind) {
        guard let tab = pageTab(kind) else { return }
        close(tab)
    }

    /// Settings moved to another of its sections: the tab's address says
    /// so, and comes back there after a relaunch.
    func settingsMoved(to section: SettingsPanel.Page) {
        guard let tab = pageTab(.settings), tab.page?.detail != section.rawValue else { return }
        tab.show(InternalPage(.settings, section.rawValue), stepping: false)
        writeSessionSoon()
    }
}
