import AppKit
import EdenCore

// What the field offers besides places and searches, after Zen's floating
// bar: before anything is typed (or over ⌘L's own address, untouched), the
// link on the clipboard, your open tabs and the sites you go to most; while typing, the open tabs that answer to
// it, with Switch to Tab, and the tab groups and spaces it names, with Open.
// ⌘K's switcher used to be the way to an open tab; the one field ⌘T and ⌘L
// raise is now.

/// A link on the clipboard the field offers to visit, as Zen's Visit from
/// clipboard does.
struct CopiedLink: Equatable {
    /// The pasteboard's change count when it was seen: a copy since is
    /// another link, or none.
    let change: Int
    /// The link, when it could be read without macOS asking first (see
    /// Clipboard.look); nil when only its being a link is known.
    let url: URL?
    /// When the field first saw it: it is offered for a minute from then.
    let seen: Date
}

/// Whether the clipboard holds a link, asked without reading it where macOS
/// would ask you first. Since macOS 15.4 an app reading the pasteboard on
/// its own is stopped by an alert, unless you've allowed it; asking only
/// whether what is there looks like a link isn't. The link itself is read
/// when you choose to visit it (Browser.copiedLinkURL).
@MainActor
enum Clipboard {
    static func look(_ answer: @escaping @MainActor (CopiedLink?) -> Void) {
        let board = NSPasteboard.general
        let change = board.changeCount
        func read() -> CopiedLink? {
            link(in: board).map { CopiedLink(change: change, url: $0, seen: Date()) }
        }
        guard #available(macOS 15.4, *), board.accessBehavior != .alwaysAllow else {
            // Before 15.4 nothing asks; allowed, nothing asks either. Read
            // now, answered a turn later as the asking path is, so the list
            // being made when it was asked is never made again inside it.
            let link = read()
            Task { @MainActor in answer(link) }
            return
        }
        guard board.accessBehavior != .alwaysDeny else { return answer(nil) }
        Task { @MainActor in
            let found = try? await board.detectedPatterns(for: [\NSPasteboard.DetectedValues.probableWebURL])
            let linked = found?.contains(\NSPasteboard.DetectedValues.probableWebURL) == true
            answer(linked ? CopiedLink(change: change, url: nil, seen: Date()) : nil)
        }
    }

    /// The clipboard's text as a web address, if that is all it is.
    static func link(in board: NSPasteboard = .general) -> URL? {
        guard let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains(where: \.isWhitespace),
              let url = Address.url(from: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }
}

extension Browser {
    /// How long a copied link is offered for, from when the field first saw
    /// it: Zen's offer, too, goes once the copy is a minute old.
    static let copiedLinkLife: TimeInterval = 60

    /// The list before anything is typed, on ⌘T's empty field and under
    /// ⌘L's untouched address alike (Browser.nothingAsked): the link on the
    /// clipboard, the page in front on the device you just put down and
    /// pages closed there a moment ago (Elsewhere), your open tabs, most
    /// recent first, then the sites you go to most that aren't open. Never
    /// your history in a private tab. Nothing is picked until an arrow key
    /// picks it: Return on the empty field still does nothing, and on ⌘L's
    /// address goes to that address.
    func startingOffers() -> [Suggestion] {
        var list: [Suggestion] = []
        if let link = offerableCopiedLink { list.append(copiedLinkRow(link)) }
        list += elsewhereOffers()
        let open = Array(openPages(matching: "").prefix(4))
        list += open
        if active?.shy != true {
            let taken = Set(list.map { History.identity(for: $0.url) }).union(openHere)
            list += history.topSites(limit: 10)
                .filter { !taken.contains($0.key) }
                .prefix(5)
                .map { Suggestion(key: $0.address, title: $0.title, url: $0.url, kind: .visited) }
        }
        lookAtClipboard()
        return list
    }

    /// The open tabs among what is typed, after the row Return takes, as
    /// Zen lists them under its first row: a page already open is offered
    /// as that tab, never again as a place to load, which looks the same
    /// and would open it a second time. On the empty page of a pair, first:
    /// it is there to bring a page in.
    func withOpenTabs(_ offers: [Suggestion], for typed: String) -> [Suggestion] {
        var open = openPages(matching: typed)
        let pair = active.flatMap { blank in blank.isBlank ? split(for: blank) : nil }
        if let blank = active, let pair {
            open = open.filter { offer in
                guard let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) else { return false }
                return !pair.contains(id) && !tab.bench && tab.shy == blank.shy
            }
        }
        guard !open.isEmpty else { return offers }
        let shown = Set(open.map { History.identity(for: $0.url) })
        let places = offers.filter { $0.tab != nil || !shown.contains(History.identity(for: $0.url)) }
        if pair != nil { return open + places }
        // The row Return takes stays first, whatever it is.
        guard let first = offers.first else { return open }
        return [first] + open + places.filter { $0.id != first.id }
    }

    /// The tab groups and spaces whose names hold what is typed, offered as
    /// Open, last of the field's own rows and never first: a command on top
    /// is what Return does (see submit), and Return goes where the words
    /// say. Two of each at most, and only once two letters are typed.
    func groupAndSpaceOffers(for typed: String, after offers: [Suggestion]) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2, !offers.isEmpty else { return offers }
        let groups = prefs.usesTabGroups
            ? tabGroups.filter { $0.name.lowercased().contains(needle) }.prefix(2).map { AddressCommand.group($0.id) }
            : []
        let others = prefs.usesSpaces
            ? spaces.filter { $0.id != spaceID && $0.name.lowercased().contains(needle) }.prefix(2).map { AddressCommand.space($0.id) }
            : []
        return offers + (groups + others).compactMap { command in
            name(of: command).map { Suggestion(key: $0, title: "", url: Self.nowhere, kind: .command(command.suggested)) }
        }
    }

    /// What a group's or a space's row is called in the field, as its key.
    private func name(of command: AddressCommand) -> String? {
        switch command {
        case .group(let id): return tabGroups.first { $0.id == id }?.name
        case .space(let id): return spaces.first { $0.id == id }?.name
        default: return nil
        }
    }

    /// Where a row that goes nowhere points: a command's.
    static var nowhere: URL { URL(fileURLWithPath: "/") }

    /// What a row says beyond its suggestion, from this window: the group an
    /// open tab is in; Open for a group or a space, with where it is; the
    /// link a clipboard row would visit.
    func context(for offer: Suggestion) -> Omnibox.Row.Context {
        if offer.kind == .open, let id = offer.tab, let tab = tabs.first(where: { $0.id == id }),
           let group = group(of: tab), let name = tabGroups.first(where: { $0.id == group })?.name {
            return .init(badge: name)
        }
        switch offer.command {
        case .group(let id)?:
            let group = tabGroups.first { $0.id == id }?.name ?? ""
            let space = prefs.usesSpaces ? spaces.first { $0.id == spaceID }?.name : nil
            return .init(name: "Open", badge: space.map { "\($0) / \(group)" } ?? group, symbol: "folder")
        case .space(let id)?:
            let space = spaces.first { $0.id == id }
            return .init(name: "Open", badge: space?.name, symbol: space?.icon ?? "square.stack.3d.up")
        case .copiedLink(_)?:
            return .init(symbol: "doc.on.clipboard", action: "Visit from clipboard")
        default:
            return .init()
        }
    }

    /// A group opened from the field: the tab you were on last in it, which
    /// unfolds it as going to any of its tabs does.
    func openGroup(_ id: UUID) {
        guard let tab = tabs(in: id).max(by: { $0.touched < $1.touched }) else { return }
        select(tab)
    }

    // MARK: - the link on the clipboard

    /// The copied link, while it is still to be offered: copied in the last
    /// minute, not visited yet, and not the page in front (copied from it
    /// with ⇧⌘C, say).
    private var offerableCopiedLink: CopiedLink? {
        guard let link = copiedLink, link.change == NSPasteboard.general.changeCount,
              link.change != copiedLinkTaken, Date().timeIntervalSince(link.seen) < Self.copiedLinkLife
        else { return nil }
        if let url = link.url, let here = active?.address, History.identity(for: url) == History.identity(for: here) {
            return nil
        }
        return link
    }

    private func copiedLinkRow(_ link: CopiedLink) -> Suggestion {
        Suggestion(key: link.url.map { Address.pretty($0) } ?? "A link you copied", title: "",
                   url: link.url ?? Self.nowhere, kind: .command(AddressCommand.copiedLink(change: link.change).suggested))
    }

    /// Looks again once the clipboard has changed since it last looked, and
    /// lists the link when the answer comes, if the field is still empty.
    private func lookAtClipboard() {
        let change = NSPasteboard.general.changeCount
        guard copiedLink?.change != change, lookingAtClipboard != change else { return }
        lookingAtClipboard = change
        Clipboard.look { [weak self] link in
            guard let self, self.lookingAtClipboard == change else { return }
            self.lookingAtClipboard = nil
            // Nothing there is remembered as looked at too, seen too long
            // ago to offer, so the same copy isn't looked at again.
            self.copiedLink = link ?? CopiedLink(change: change, url: nil, seen: .distantPast)
            guard link != nil, self.fieldShowing, self.picked == nil, self.nothingAsked else { return }
            self.listAgain()
        }
    }

    /// The link copied as `change`, read now, as you asked for it (macOS
    /// may ask first); nil, and why said, if the clipboard has changed since
    /// it was offered or can't be read. A row a little over its minute is
    /// still taken: what matters once it is chosen is that it is still the
    /// same copy, not how long the list stood open.
    func copiedLinkURL(_ change: Int) -> URL? {
        guard NSPasteboard.general.changeCount == change else {
            announce("The clipboard has changed since", look: .problem)
            return nil
        }
        guard let url = Clipboard.link() else {
            announce("Couldn't read the link on the clipboard", look: .problem)
            return nil
        }
        copiedLinkTaken = change
        return url
    }

    /// The copied link taken with the pointer: opened where a clicked row's
    /// address opens. Return and ⌘Return go through submit instead, which
    /// opens it as it opens any address, beside or in front.
    func followCopiedLink(_ change: Int) {
        guard let url = copiedLinkURL(change) else { return }
        if launching {
            open(url, foreground: true, from: active, loose: true)
        } else {
            (active ?? tabs.first)?.go(to: url)
        }
    }
}
