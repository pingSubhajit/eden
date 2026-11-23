import EdenCore
import SwiftUI

// Reading mode's article finding, its look and the Markdown renderer for
// sites' Markdown twins are EdenCore's (Reader, Markdown), shared with Eden
// for iPhone and iPad; here is the Mac's own part: the look it keeps, and its
// light and dark switch.

extension Reader {
    /// Light, dark, or as the window is: chosen on an article, and kept for
    /// the next one. Light whenever reading mode doesn't follow the window.
    static var look: Look {
        get {
            guard Store.settings.object(forKey: "reader.follows") as? Bool ?? true else { return .light }
            return Store.settings.string(forKey: "reader.look").flatMap(Look.init) ?? .system
        }
        set { Store.settings.set(newValue.rawValue, forKey: "reader.look") }
    }

    /// Puts a look on the page (EdenCore's Reader.apply).
    static func apply(_ look: Look) -> String {
        apply(ReadingLook(rawValue: look.rawValue) ?? .system)
    }
}

/// The article's own light and dark, in its corner while it is up, with
/// reading mode following the window (Settings › General). Quiet until the
/// pointer comes to it.
struct ReaderLook: View {
    let tab: Tab
    @State private var look = Reader.look
    @State private var hovering = false
    @Environment(\.colorScheme) private var window

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Look.allCases) { each in
                Button {
                    look = each
                    Reader.look = each
                    tab.built?.evaluateJavaScript(Reader.apply(each))
                } label: {
                    Image(systemName: each == .light ? "sun.max" : each == .dark ? "moon" : "circle.lefthalf.filled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(look == each ? Palette.ink : Palette.muted)
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(look == each ? Palette.wash : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(each == .system ? "As the window is" : each.title)
            }
        }
        .padding(3)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        // In the article's colours, which may not be the window's.
        .environment(\.colorScheme, look == .dark ? .dark : look == .light ? .light : window)
        .opacity(hovering ? 1 : 0.55)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: look)
        .padding(14)
        // An article read in another tab may have been given another look
        // since: the one kept is the one it wears when it comes back.
        .onAppear { tab.built?.evaluateJavaScript(Reader.apply(look)) }
    }
}
