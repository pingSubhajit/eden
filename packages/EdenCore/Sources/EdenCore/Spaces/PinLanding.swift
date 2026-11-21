import Foundation

// Where a pin's trip home came to rest. A pinned address often sends the tab
// on as it loads: a mail app's to its inbox, a dashboard's to its first view,
// a sign-in back to where it was asked from, sometimes through several pages
// and seconds apart. The pin is still at home there, and only going on from
// it is leaving.
//
// Time can't tell the two apart: a redirect may take seconds, and a link may
// be clicked half a second after the page appears. Your hand can. Wherever
// the page goes by itself after reaching its home is the home's doing, until
// you touch the page (a click, a key, a scroll) or send it somewhere from the
// browser; from then on, where it goes is yours.

public struct PinLanding: Equatable, Sendable {
    /// The page the last trip home came to rest at, when its home sent it
    /// on; nil when it stayed where it was pinned.
    public private(set) var landed: URL?
    /// Out on a trip home that nobody has touched yet.
    private var travelling = false

    public init() {}

    /// A pin given its home while showing `page`: out on a trip there
    /// already when that is the page, a load under way included, so where
    /// the page goes on to as it lands is home too.
    public init(home: URL?, showing page: URL?) {
        travelling = PinDef.samePage(home, page)
    }

    /// The tab's address moved to `page`.
    public mutating func moved(to page: URL, home: URL?) {
        guard let home else {
            self = PinLanding()
            return
        }
        if PinDef.samePage(home, page) {
            travelling = true
            landed = nil
        } else if travelling {
            landed = page
        }
    }

    /// The page was touched, or sent somewhere from the browser: the trip,
    /// if one was under way, is over where it is.
    public mutating func touched() {
        travelling = false
    }

    /// Whether a pin of that home showing `page` is at home: at the page it
    /// was pinned at, or where its last trip there came to rest.
    public func atHome(_ home: URL?, showing page: URL?) -> Bool {
        guard home != nil, page != nil else { return false }
        return PinDef.atHome(home, showing: page) || PinDef.samePage(landed, page)
    }
}
