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

    /// The PostScript name of the Astheric Extra Light this app can draw in.
    /// Looked up once, after the app's own copy is registered, so it is
    /// there on every device and not only one that has it installed.
    static let displayName: String? = {
        register(facesIn: Bundle.main.resourceURL?.appendingPathComponent(folder, isDirectory: true))
        return candidates.first(where: isInstalled)
    }()

    /// Where both apps keep their copy, in their resources: brand/Fonts in
    /// the repository, copied in by the Mac's build.sh and by the iPhone's
    /// project as a folder.
    static let folder = "Fonts"

    /// The licensed face's name first, so its file only has to replace the
    /// trial copy in brand/Fonts, then the trial copy the apps carry for now.
    static let candidates = ["Astheric-ExtraLight", "FONTSPRINGDEMO-AsthericVariableExtLtRegular"]

    /// Makes every font file in `folder` usable by name in this process only:
    /// nothing is installed on the device. A file that fails to register,
    /// one registered already or one that isn't a font, is left as it is:
    /// the lookup after this checks which faces are really there, and falls
    /// back when Astheric isn't one of them.
    static func register(facesIn folder: URL?) {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// CoreText hands back another font for a name it doesn't have, so a
    /// face is there only when the font made by its name has that name.
    static func isInstalled(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == name
    }
}
