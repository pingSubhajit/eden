import CoreGraphics
import Foundation

// A site's own icon, as iPhone and iPad find it: what a page declares, the
// best of it first, and the colour the icon wears. The Mac's Favicons finds
// its icons the same way, by the same scores, with SVG and inline icons it
// can draw besides.

public enum IconPick {
    /// Which site an address is, for its icon: its host, and its port when
    /// it names one — localhost:3000 and localhost:4321 are two projects.
    /// The port a scheme has anyway doesn't count.
    public static func site(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased()
        guard let port = url.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) else { return host }
        return "\(host):\(port)"
    }

    /// Asks the page what icons it declares, each as rel, href (made whole
    /// by the page), sizes, type and media.
    public static let probe = """
    (function () {
      var out = [];
      var links = document.querySelectorAll('link[rel]');
      for (var i = 0; i < links.length; i++) {
        var l = links[i];
        var rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') < 0) continue;
        out.push({
          href: l.href,
          rel: rel,
          sizes: (l.getAttribute('sizes') || '').toLowerCase(),
          type: (l.getAttribute('type') || '').toLowerCase(),
          media: (l.getAttribute('media') || '').toLowerCase()
        });
      }
      return out;
    })();
    """

    /// Declared icons tried for one page, best first; favicon.ico makes six.
    static let tried = 5

    /// Best first, of what `page` declared: a crisp icon around 32–64 pixels,
    /// then the touch icon, then the file at the site's root that every site
    /// has had since 1999. Only what can be drawn from its bytes alone: no
    /// SVG, nothing written into the page as data:, nothing but http(s).
    /// One meant for the other appearance is passed over; one meant for this
    /// one comes first.
    public static func rank(_ declared: [[String: String]], page: URL, dark: Bool) -> [URL] {
        var scored: [(URL, Int)] = []
        for entry in declared {
            guard let href = entry["href"], let url = URL(string: href, relativeTo: page)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { continue }
            let rel = entry["rel"] ?? "", sizes = entry["sizes"] ?? "", type = entry["type"] ?? ""
            if sizes == "any" || type.contains("svg") || url.pathExtension.lowercased() == "svg" { continue }
            let scheme = appearance(entry["media"])
            if scheme == (dark ? .light : .dark) { continue }
            var score = 25
            if rel.contains("apple-touch") { score = 40 }
            if let px = sizes.split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 10
                case 24..<48: score = 45
                case 48..<128: score = 50
                case 128..<260: score = 42
                default: score = 20
                }
            }
            if scheme != .any { score += 40 }
            scored.append((url, score))
        }
        var list = Array(scored.sorted { $0.1 > $1.1 }.map(\.0).prefix(tried))
        if let root = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL, site(root) != nil { list.append(root) }
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Where a site keeps its icon by custom, for one whose page hasn't been
    /// seen: its touch icon, then favicon.ico.
    public static func guesses(for url: URL) -> [URL] {
        guard site(url) != nil else { return [] }
        return ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: url)?.absoluteURL }
    }

    private enum Appearance { case any, light, dark }

    /// What a `media` attribute says about the appearance, if anything.
    private static func appearance(_ media: String?) -> Appearance {
        let text = (media ?? "").lowercased()
        guard text.contains("prefers-color-scheme") else { return .any }
        if text.contains("dark") { return .dark }
        if text.contains("light") { return .light }
        return .any
    }

    /// An icon's own colour, as sRGB nought to one, for the glow round a
    /// pinned tab in front, as Dia's has: the hue most of its coloured pixels
    /// share, so Gmail is its red rather than the brown its four colours
    /// average to. Nil for an icon with too little colour in it, GitHub's
    /// black cat or a letter. Drawn small, each coloured pixel goes in one of
    /// twelve hues, counted by how coloured it is; the fullest hue's pixels,
    /// averaged, are the colour. (The Mac's IconAccent, measured the same.)
    public static func accent(of image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        struct Bin { var weight = 0.0, r = 0.0, g = 0.0, b = 0.0 }
        var bins = [Bin](repeating: Bin(), count: 12)
        var opaque = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            opaque += 1
            let r = Double(pixels[i]) / 255 / alpha, g = Double(pixels[i + 1]) / 255 / alpha
            let b = Double(pixels[i + 2]) / 255 / alpha
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high == 0 ? 0 : (high - low) / high
            guard saturation > 0.35, high > 0.3 else { continue }
            let hue: Double
            switch high {
            case r: hue = ((g - b) / (high - low)).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / (high - low) + 2
            default: hue = (r - g) / (high - low) + 4
            }
            let bin = Int(((hue < 0 ? hue + 6 : hue) * 2).rounded(.down)) % 12
            bins[bin].weight += saturation
            bins[bin].r += r * saturation
            bins[bin].g += g * saturation
            bins[bin].b += b * saturation
        }
        // A few coloured pixels in a grey icon aren't its colour.
        guard let top = bins.max(by: { $0.weight < $1.weight }), opaque > 0, top.weight > opaque * 0.08
        else { return nil }
        return (top.r / top.weight, top.g / top.weight, top.b / top.weight)
    }

    /// The ink of an icon that is one grey drawn on nothing of its own —
    /// GitHub's black cat, a white letter — which a tile of the same tone
    /// all but hides: drawn on its own, it is turned over to the other. Nil
    /// for an icon with colour in it, one in a mid grey, or one that brings
    /// its own ground, a square or a circle filled to its edges, which reads
    /// on any tile as it is.
    public static func ink(of image: CGImage) -> Ink? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var opaque = 0.0, clear = 0.0, coloured = 0.0, light = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            if alpha < 0.1 { clear += 1 }
            guard alpha > 0.5 else { continue }
            opaque += 1
            let r = Double(pixels[i]) / 255 / alpha, g = Double(pixels[i + 1]) / 255 / alpha
            let b = Double(pixels[i + 2]) / 255 / alpha
            let high = max(r, g, b), low = min(r, g, b)
            if high > 0.3, (high - low) / high > 0.35 { coloured += 1 }
            light += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let total = Double(side * side)
        // Drawn on nothing: a good part of it shows the tile through. A ring
        // of corners round a filled circle is about a fifth.
        guard opaque > total * 0.05, clear > total * 0.15, coloured < opaque * 0.08 else { return nil }
        let tone = light / opaque
        if tone < 0.3 { return .dark }
        if tone > 0.75 { return .light }
        return nil
    }

    /// The tone of an icon's ink (`ink(of:)`).
    public enum Ink: Sendable {
        case dark, light
    }
}
