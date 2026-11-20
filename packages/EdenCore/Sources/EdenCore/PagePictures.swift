import CryptoKit
import Foundation
import os

// Pictures of pages, kept on disk by their address, so a tab brought back at
// the next launch shows its page before the page is loaded again: on iPhone
// its card in the tab overview, on the Mac its hover card in the column. Each
// app draws and shrinks its own pictures and hands them here as JPEG.
//
// Never a private tab's: the apps don't hand those over. Kept apart by the
// website store the page was drawn with, as well as by its address: a space
// or a profile signed in as someone else shows its own inbox, never the one
// another space's picture caught. Clear History takes them all, since a
// folder of pages is a list of where you have been. One not kept again for a
// month is let go of at launch: a page gone back to is kept again each time
// it is left.
//
// Every write, read, clearing and pruning goes through one queue, in the
// order asked: a clearing never has a write land after it and bring a page
// back, nor a pruning take a picture kept again since it looked.
//
// The iPhone kept its cards' pictures by address alone before, in "cards",
// every space's in the same name: whose sign-in each showed can't be told,
// so none of them is read, and the folder goes with the first pruning.

public final class PagePictures: Sendable {
    public static let shared = PagePictures(
        folder: Store.folder.appendingPathComponent("page-pictures", isDirectory: true),
        unscoped: Store.folder.appendingPathComponent("cards", isDirectory: true)
    )

    /// How long a picture not kept again stays.
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    /// Taken before a picture is drawn, and handed back with it: a picture
    /// begun before Clear History is of a page that has been forgotten since.
    public struct Ticket: Sendable, Equatable {
        fileprivate let clearings: Int
    }

    public let folder: URL
    /// Where pictures were kept before stores counted, to be let go of.
    private let unscoped: URL?
    private let queue = DispatchQueue(label: "com.subhajit.eden.page-pictures", qos: .utility)
    /// How many times every picture has been cleared.
    private let clearings = OSAllocatedUnfairLock(initialState: 0)

    public init(folder: URL, unscoped: URL? = nil) {
        self.folder = folder
        self.unscoped = unscoped
    }

    /// Where the picture of `url`, drawn with the website store `store` (nil
    /// for WebKit's default), is kept: named by a hash of the page and the
    /// store, the same page however its fragment or host's case reads
    /// (History.identity), and never the address itself, which a folder
    /// listing would show.
    public func file(for url: URL, store: UUID?) -> URL {
        let key = History.identity(for: url) + "\u{0}" + (store?.uuidString ?? "default")
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".jpg")
    }

    /// To take before drawing a picture to keep.
    public func ticket() -> Ticket {
        Ticket(clearings: clearings.withLock { $0 })
    }

    /// `url`'s picture, kept in place of the one before, unless everything
    /// was cleared after `ticket` was taken.
    public func keep(_ picture: Data, for url: URL, store: UUID?, ticket: Ticket) {
        let file = file(for: url, store: store)
        let folder = folder
        queue.async { [clearings] in
            guard clearings.withLock({ $0 }) == ticket.clearings else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? picture.write(to: file, options: .atomic)
        }
    }

    /// `url`'s picture, if one is kept.
    public func kept(for url: URL, store: UUID?) async -> Data? {
        let file = file(for: url, store: store)
        return await withCheckedContinuation { done in
            queue.async(qos: .userInitiated) { done.resume(returning: try? Data(contentsOf: file)) }
        }
    }

    /// Whether `url` has a picture kept, without reading it or waiting on
    /// the queue: a guess at what kept will find.
    public func has(_ url: URL, store: UUID?) -> Bool {
        FileManager.default.fileExists(atPath: file(for: url, store: store).path)
    }

    /// Clear History: every picture kept goes, and none drawn before now is
    /// kept after.
    public func forgetAll() {
        clearings.withLock { $0 += 1 }
        let folders = [folder, unscoped].compactMap { $0 }
        queue.async { for folder in folders { try? FileManager.default.removeItem(at: folder) } }
    }

    /// Pictures not kept again since `lifetime` before `now` go, and those
    /// kept before stores counted.
    public func prune(now: Date = Date()) {
        let folder = folder
        let unscoped = unscoped
        queue.async(qos: .background) {
            let manager = FileManager.default
            if let unscoped { try? manager.removeItem(at: unscoped) }
            let key = URLResourceKey.contentModificationDateKey
            guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [key]) else { return }
            let oldest = now.addingTimeInterval(-PagePictures.lifetime)
            for file in files {
                guard let kept = (try? file.resourceValues(forKeys: [key]))?.contentModificationDate,
                      kept < oldest else { continue }
                try? manager.removeItem(at: file)
            }
        }
    }

    /// Once everything asked of the queue so far is done.
    public func settled() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }
}
