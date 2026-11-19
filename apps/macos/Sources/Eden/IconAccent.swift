import AppKit
import EdenCore

/// A site icon's own colour, for the glow round a pinned tab while it is
/// the one in front, as Dia's has: the hue most of its coloured pixels
/// share, so Gmail is its red rather than the brown its four colours
/// average to. An icon with too little colour in it, GitHub's black cat
/// or a letter, has none, and its tab is lit as any other is.
enum IconAccent {
    private static let cache = NSCache<NSImage, NSColor>()
    /// Kept for an icon found to have no colour, so it isn't measured again.
    private static let none = NSColor.clear

    @MainActor static func of(_ image: NSImage) -> NSColor? {
        if let known = cache.object(forKey: image) { return known == none ? nil : known }
        let found = measure(image)
        cache.setObject(found ?? none, forKey: image)
        return found
    }

    /// Drawn small, each coloured pixel goes in one of twelve hues, counted
    /// by how coloured it is; the fullest hue's pixels, averaged, are the
    /// colour.
    private static func measure(_ image: NSImage) -> NSColor? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

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
        return NSColor(srgbRed: top.r / top.weight, green: top.g / top.weight, blue: top.b / top.weight, alpha: 1)
    }
}

/// Whether a site icon is one grey drawn on nothing (IconPick.ink) that a
/// ground of the same tone would all but hide, and is to be turned over to
/// the other: GitHub's black cat in a dark column, a white letter in a light
/// one.
enum IconInk {
    private static let cache = NSCache<NSImage, AnyObject>()

    @MainActor static func needsTurning(_ image: NSImage, dark: Bool) -> Bool {
        let ink: IconPick.Ink?
        if let known = cache.object(forKey: image) {
            ink = (known as? NSNumber).map { $0.boolValue ? .dark : .light }
        } else {
            ink = image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(IconPick.ink(of:))
            cache.setObject(ink.map { NSNumber(value: $0 == .dark) } ?? NSNull(), forKey: image)
        }
        return ink == (dark ? .dark : .light)
    }
}
