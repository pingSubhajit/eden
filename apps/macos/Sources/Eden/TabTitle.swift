import SwiftUI

/// A tab's title: always the page's own, on the tab you're on as on any
/// other. Where the page on the tab you're on warns (AtRest.warning), a
/// small glyph comes before the title and says why in its tooltip: an open
/// lock for plain http, a triangle for a name shown as the punycode it is.
/// The title itself never gives way to it.
struct TabTitle: View {
    let label: String
    /// What the page warns of, on the tab you're on; nil on every other.
    let warning: AtRest?
    let size: CGFloat
    let colour: Color

    var body: some View {
        HStack(spacing: 4) {
            if let warning {
                Image(systemName: warning.kind == .notSecure ? "lock.open" : "exclamationmark.triangle")
                    .font(.system(size: size - 2, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .help(Self.note(warning))
                    .accessibilityLabel(Self.note(warning))
            }
            Text(label)
                .font(.system(size: size))
                .lineLimit(1)
                .foregroundStyle(colour)
                .fadesOut(label)
        }
    }

    /// What the glyph means, as its tooltip says it.
    private static func note(_ warning: AtRest) -> String {
        warning.kind == .notSecure
            ? "Not secure"
            : "Shown as \(warning.lead + warning.name): its name could pass for another site's"
    }
}
