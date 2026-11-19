import Foundation

// Handoff between Eden on your devices: the activity that carries a page in
// Eden, which pages may go from one device to another at all, and how a page
// was left there — how far down it was read, whether as an article, in which
// space — carried beside its address. The Mac app (Handoff.swift) and the iOS
// app (EdenApp.swift) both take and offer pages by these rules, and both list
// the activity in their Info.plist. A page taken is a page from another
// device like any other (Elsewhere.Offer): opened the same way as one picked
// from your other devices' tabs.

public enum Continuity {
    /// Eden's own activity: a page in Eden, on any of your devices.
    public static let browsing = "com.subhajit.eden.beta.browsing"

    /// The page, when it may be handed over: an http or https address with a
    /// host and no name or password in it. NSUserActivity raises on any
    /// webpageURL that isn't http or https, so nothing else is ever set.
    public static func page(_ address: URL?) -> URL? {
        guard let address, let scheme = address.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = address.host(), !host.isEmpty,
              address.user(percentEncoded: false) == nil, address.password(percentEncoded: false) == nil
        else { return nil }
        return address
    }

    /// What a handed-off page carries beside its address and title, which
    /// the activity carries itself: how far down it is read, whether as an
    /// article, its space, and the device. A few short strings, whatever the
    /// page: Handoff's payload is small, and a page's title is the page's
    /// to make as long as it likes.
    public static func info(scroll: Double?, reading: Bool, space: UUID?, device: String, kind: DeviceTabs.Kind) -> [String: String] {
        var info = [Keys.device: capped(device), Keys.kind: kind.rawValue]
        if let scroll { info[Keys.scroll] = String(DeviceTabs.Page.scroll(scroll)) }
        if reading { info[Keys.reading] = "1" }
        if let space { info[Keys.space] = space.uuidString }
        return info
    }

    /// A handed-off page, as a page from another device: as it was left,
    /// when it says; else only its address and title — from an Eden from
    /// before, or another browser.
    public static func offer(_ address: URL, title: String?, info: [AnyHashable: Any]?) -> Elsewhere.Offer {
        let said = { (key: String) in info?[key] as? String }
        let page = DeviceTabs.Page(url: address.absoluteString, title: title ?? "",
                                   space: said(Keys.space).flatMap(UUID.init(uuidString:)),
                                   scroll: said(Keys.scroll).flatMap(Double.init).map(DeviceTabs.Page.scroll),
                                   reading: said(Keys.reading) == "1" ? true : nil)
        let device = said(Keys.device).map(capped).flatMap { $0.isEmpty ? nil : $0 }
        let kind = said(Keys.kind).flatMap(DeviceTabs.Kind.init(rawValue:)) ?? .mac
        return Elsewhere.Offer(device: "", deviceName: device ?? "another device", kind: kind, page: page)
    }

    /// A device's name as it goes, at most 128 bytes, cut between whole
    /// characters: one character can be a letter with a thousand marks on it.
    static func capped(_ name: String) -> String {
        var out = "", bytes = 0
        for character in name {
            bytes += character.utf8.count
            guard bytes <= 128 else { break }
            out.append(character)
        }
        return out
    }

    enum Keys {
        static let scroll = "eden.scroll"
        static let reading = "eden.reading"
        static let space = "eden.space"
        static let device = "eden.device"
        static let kind = "eden.kind"
    }
}
