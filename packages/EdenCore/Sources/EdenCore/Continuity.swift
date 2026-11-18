import Foundation

// Handoff between Eden on your devices: the activity that carries a page in
// Eden, and which pages may go from one device to another at all. The Mac
// app (Handoff.swift) and the iOS app (EdenApp.swift) both take and offer
// pages by these rules, and both list the activity in their Info.plist.

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
}
