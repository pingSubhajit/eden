import Foundation

// When this device last did an ask about each of its pages (#13). An ask says
// which of this device's tabs it was made from (their stamp, DeviceTabs.at:
// CloseAsk.seen). One made from tabs stamped before this device's last doing
// for that page was made without seeing it: a device offline meanwhile, its
// ask arriving after a newer one was done and deleted. Nothing newer is left
// to weigh it against, so this is what does: such an ask is answered without
// being done (SyncItems.dueAsks). Both times are this device's, so no other
// device's clock decides.
//
// They are told on one clock that only goes forward (`latest`): a stamp and a
// doing are each later than every one before, by a millisecond if the wall
// clock was put back. And this device's tabs are stamped afresh after each ask
// it does (stamp), even one that changed nothing, such as opening a page
// already open: whoever sees its tabs after that has seen the doing.
//
// Kept on disk, written once the tabs that answer the asks are (written), for
// a month (life): an ask stands three days by the clock of the device that
// asked, which may run ahead of this one's.

public struct AnsweredPages: Codable, Equatable, Sendable {
    /// When an ask about each page was last done here, by History.identity.
    public private(set) var pages: [String: Double] = [:]
    /// The latest stamp or doing given out: the next is later.
    public private(set) var latest: Double = 0

    public init() {}

    /// How long a doing is kept: far longer than an ask stands, so one from
    /// a device whose clock runs days ahead still meets it.
    public static let life: Double = 30 * 24 * 60 * 60

    /// When the newest ask was done here: tabs stamped before it are stamped
    /// afresh (stamp).
    public var newest: Double { pages.values.max() ?? 0 }

    /// A time later than every one given out before: now, or a millisecond
    /// past the latest if the clock was put back.
    private mutating func next(_ now: Double) -> Double {
        latest = max(now, latest + 0.001)
        return latest
    }

    /// Asks about `done` pages done now.
    public mutating func done(_ done: some Sequence<String>, at now: Double) {
        let at = next(now)
        for page in done { pages[page] = at }
    }

    /// Whether an ask about `page` made from this device's tabs as stamped
    /// `seen` came before the last ask done about it. An ask that doesn't
    /// say, from an Eden from before, is never out of date: it is weighed
    /// as it always was.
    public func outdated(_ page: String, seen: Double?) -> Bool {
        guard let seen, let done = pages[page] else { return false }
        return seen < done
    }

    /// Only the doings an ask could still arrive about.
    public mutating func prune(now: Double) {
        pages = pages.filter { now - $0.value <= Self.life }
    }

    /// The stamp for this device's tabs: `kept`, the stamp of the same tabs
    /// said before, unless an ask was done since; else a new one, later than
    /// every stamp and doing before it. `published`: the stamp the other
    /// devices last had from this one, which is all an ask can have seen,
    /// so one later than any of them comes next even after a relaunch.
    public mutating func stamp(kept: Double?, published: Double?, now: Double) -> Double {
        latest = max(latest, published ?? 0)
        if let kept, kept >= newest {
            latest = max(latest, kept)
            return kept
        }
        return next(now)
    }

    // MARK: - on disk

    private static var file: URL { Store.file("answered-pages.json") }

    /// As last written, or none.
    public static func read() -> AnsweredPages {
        guard let data = try? Data(contentsOf: file),
              let pages = try? JSONDecoder().decode(AnsweredPages.self, from: data) else { return AnsweredPages() }
        return pages
    }

    /// Written, and whether it reached the disk: the asks answered with it
    /// count as done only then. Asked once the tabs that answer them are on
    /// disk (SyncItems.answer), of a copy taken up only if it landed: one
    /// that didn't leaves the asks standing, and the record as it was, so a
    /// retry, or a relaunch, does them again rather than taking them for
    /// done with what they changed not on disk.
    @MainActor
    public func written() -> Bool {
        let pages = self
        let mark = Disk.mark()
        let files = Disk.recording { Disk.write(Self.file) { try? JSONEncoder().encode(pages) } }
        return Disk.drain(since: mark, only: files)
    }
}
