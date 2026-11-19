import CryptoKit
import EdenCore
import ImageIO
import Observation
import SwiftUI
import UIKit

// Site icons on iPhone and iPad, for the pins, as the Mac's wear theirs.
//
// WebKit doesn't hand these over, so a page that finishes is asked what it
// declares (EdenCore's IconPick), and the best of those is fetched once and
// kept as a small PNG by its site. A pin whose site has never been seen
// tries where sites keep their icons by custom, so it has one before its
// page is first opened. Never for a private tab, and Clear History takes
// them all.

@MainActor
@Observable
final class SiteIcons {
    static let shared = SiteIcons()

    /// What has been found, by site (IconPick.site), watched: a pin puts on
    /// its icon the moment it arrives.
    private var found: [String: UIImage] = [:]
    /// Sites whose kept icon has been looked for since launch.
    @ObservationIgnored private var looked: Set<String> = []
    /// Sites a page has declared an icon for since launch: not asked again.
    @ObservationIgnored private var learned: Set<String> = []
    @ObservationIgnored private var busy: Set<String> = []
    @ObservationIgnored private let accents = NSCache<UIImage, UIColor>()
    /// Kept for an icon found to have no colour, so it isn't measured again.
    @ObservationIgnored private let colourless = UIColor.clear

    /// Drawn no larger than this, in pixels: a pin's icon at 28 points, 3x.
    private nonisolated static let largest = 96
    /// An icon kept longer than this is asked for again when its site is.
    private static let keeps: TimeInterval = 7 * 24 * 3600

    private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }

    private static func file(_ site: String) -> URL {
        let name = SHA256.hash(data: Data(site.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".png")
    }

    /// The icon of `url`'s site, if one has been found; looked for, kept or
    /// fetched, otherwise, to arrive in a moment.
    func icon(for url: URL?) -> UIImage? {
        guard let url, let site = IconPick.site(url) else { return nil }
        if let image = found[site] { return image }
        if !looked.contains(site) {
            looked.insert(site)
            Task { await recall(site, at: url) }
        }
        return nil
    }

    /// The colour an icon wears (IconPick.accent), nil for one with too
    /// little colour in it.
    func accent(of image: UIImage) -> Color? {
        if let known = accents.object(forKey: image) { return known == colourless ? nil : Color(uiColor: known) }
        let measured = image.cgImage.flatMap(IconPick.accent(of:)).map {
            UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
        }
        accents.setObject(measured ?? colourless, forKey: image)
        return measured.map(Color.init(uiColor:))
    }

    /// A page finished: what it declares asked for and fetched, once a
    /// launch for its site, unless the icon kept for it is recent.
    func learn(from tab: Tab, at url: URL) {
        guard !tab.isPrivate, let site = IconPick.site(url), !learned.contains(site), !busy.contains(site) else { return }
        if let age = Self.age(of: Self.file(site)), age < Self.keeps {
            learned.insert(site)
            return
        }
        busy.insert(site)
        let dark = tab.webView.traitCollection.userInterfaceStyle == .dark
        Task {
            defer { busy.remove(site) }
            let declared = (await tab.ask(IconPick.probe) as? [[String: String]]) ?? []
            if await fetch(IconPick.rank(declared, page: url, dark: dark), for: site) { learned.insert(site) }
        }
    }

    /// Clear History: every icon kept goes.
    func forgetAll() {
        try? FileManager.default.removeItem(at: Self.folder)
        found = [:]
        looked = []
        learned = []
    }

    /// The icon kept for `site`, or, with none, the ones sites keep by
    /// custom at their root.
    private func recall(_ site: String, at url: URL) async {
        let file = Self.file(site)
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: file) }.value
        if let data, let image = UIImage(data: data) {
            found[site] = image
            return
        }
        guard !busy.contains(site) else { return }
        busy.insert(site)
        defer { busy.remove(site) }
        _ = await fetch(IconPick.guesses(for: url), for: site)
    }

    /// The first of `candidates` that is an image, kept for `site`.
    private func fetch(_ candidates: [URL], for site: String) async -> Bool {
        for candidate in candidates {
            guard let png = await Self.download(candidate),
                  let image = UIImage(data: png) else { continue }
            found[site] = image
            let file = Self.file(site)
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? png.write(to: file, options: .atomic)
            }
            return true
        }
        return false
    }

    /// The icon at `url`, drawn as a PNG no larger than `largest`: the
    /// biggest of the sizes a .ico holds, and nothing that isn't an image,
    /// is too small to be one, or runs past two megabytes.
    private nonisolated static func download(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let frames = 0..<CGImageSourceGetCount(source)
        let width = { (index: Int) -> Int in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        guard let best = frames.max(by: { width($0) < width($1) }), width(best) >= 16 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: largest,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let drawn = CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary) else { return nil }
        return UIImage(cgImage: drawn).pngData()
    }

    private static func age(of file: URL) -> TimeInterval? {
        let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        return written.map { Date().timeIntervalSince($0) }
    }
}
