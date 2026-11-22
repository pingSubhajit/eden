import CoreText
import SwiftUI

extension View {
    /// Sets this text in Astheric Extra Light at `size`, Eden's face for
    /// headings and larger text (Typeface). Only for 20 points or more: a
    /// face this light goes thin and grey below that, so anything smaller
    /// stays in SF.
    public func displayFont(_ size: CGFloat) -> some View {
        modifier(DisplayFont(size: size))
    }
}

/// The size grows and shrinks with the text size people choose on iPhone, as
/// the title text style does, whichever face it is set in; the Mac has no
/// such setting, and it stays as given.
private struct DisplayFont: ViewModifier {
    @ScaledMetric private var size: CGFloat

    init(size: CGFloat) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .title)
    }

    func body(content: Content) -> some View {
        content.font(Typeface.display(size))
    }
}

/// Eden's two typefaces. Astheric Extra Light for headings and larger text,
/// the way the mark and the icon are Eden's own: page titles, the welcome,
/// the start page's headings. SF for everything else, which is the system
/// font and needs nothing from here.
enum Typeface {
    /// Astheric Extra Light at exactly `size`, already scaled (displayFont).
    /// On a device without Astheric it is New York, light, the system's own
    /// serif, so a heading still reads as one.
    static func display(_ size: CGFloat) -> Font {
        guard let name = displayName else { return .system(size: size, weight: .light, design: .serif) }
        return .custom(name, fixedSize: size)
    }

    /// The PostScript name of the Astheric Extra Light this device has, if it
    /// has one. Looked up once.
    static let displayName: String? = candidates.first(where: isInstalled)

    /// The licensed face first, then the trial copy installed on the owner's
    /// Mac, which stands in until the licensed files are bundled.
    /// TODO(type): bundle the licensed files in both apps and drop the trial
    /// copy's name (TODO.md, #37).
    static let candidates = ["Astheric-ExtraLight", "FONTSPRINGDEMO-AsthericVariableExtLtRegular"]

    /// CoreText hands back another font for a name it doesn't have, so a
    /// face is there only when the font made by its name has that name.
    static func isInstalled(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == name
    }
}
