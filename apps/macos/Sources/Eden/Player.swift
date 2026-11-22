import SwiftUI

// What plays in another tab, at the foot of the sidebar: the tab's icon
// and title, its pause, and a click on it to go there. Paused from here, it
// stays, with its play and a cross to put it away, until it plays again,
// its page goes or the tab sleeps.
//
// Off unless turned on in Settings › Appearance › Tabs. Off, nothing of it
// reaches a page: the pause
// is two lines of script run in Eden's world when it is pressed, and
// never before.
//
// For the newest tab to make a sound that is out of sight: not the page on
// screen, nor the other page of a pair on screen, nor one out in the
// floating window, which has its own controls. Of this space's row only:
// a tab left playing in another space keeps playing (see Spaces.swift), and
// shows here once you are back in its space, if it is still out of sight.
//
// The pause looks in the page and in each frame below it that played (the
// frames MediaKeys keeps), pauses what plays and remembers it; then WebKit
// pauses whatever a script can't reach — a player in a shadow root, one
// never put in the page. Only what was remembered can be played again, so
// with nothing remembered the row goes once the page is quiet, rather than
// offer a play that would do nothing.

enum Player {
    /// What plays here, paused and remembered: the page sees its media
    /// paused, as by its own button, and nothing of who did it. How many.
    static let still = """
    (function () {
      var held = [];
      document.querySelectorAll('audio, video').forEach(function (el) {
        if (el.paused) return;
        held.push(el);
        el.pause();
      });
      window.__officeStilled = held;
      return held.length;
    })()
    """

    /// What `still` paused, playing again: whatever the page played again
    /// itself, or took out of the page, is left as it is.
    static let again = """
    (function () {
      var held = window.__officeStilled || [];
      window.__officeStilled = null;
      held.forEach(function (el) {
        if (!el.paused || !el.isConnected) return;
        var played = el.play();
        if (played && played.catch) played.catch(function () {});
      });
      return held.length;
    })()
    """
}

extension Browser {
    /// The tab the player is for: the newest to make a sound, of the ones
    /// in this row that are out of sight. Nil with the switch off.
    var player: Tab? {
        guard prefs.showsPlayer else { return nil }
        let shown = visibleTabIDs
        for id in sounding.reversed() where !shown.contains(id) && id != floating {
            if let tab = tabs.first(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    /// A tab's sound started or stopped, or the player paused it or let it
    /// go. Started, it is the newest; quiet and not paused from the player,
    /// it has nothing to show.
    func heard(_ tab: Tab, noisy: Bool, stilled: Bool) {
        if noisy {
            guard sounding.last != tab.id else { return }
            sounding.removeAll { $0 == tab.id }
            sounding.append(tab.id)
        } else if !stilled {
            sounding.removeAll { $0 == tab.id }
        }
    }
}

/// The row itself, above the doors at the foot of the sidebar. A card's
/// hairline rather than a tab's ground, so it never reads as one more tab.
struct PlayerRow: View {
    @Environment(\.greys) private var greys
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            Mark(icon: tab.icon, letter: tab.monogram, size: prefs.sideMark)
            Text(tab.label)
                .font(.system(size: prefs.sideTitle))
                .lineLimit(1)
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .fadesOut(tab.label)
            Spacer(minLength: 0)
            if tab.stilled && hovering {
                // Paused from here and not wanted again: the row goes until
                // the tab plays again. A cross, as a tab's.
                SquareButton(symbol: "xmark", help: "Put Away", glyph: 11) { tab.stilled = false }
                    .transition(.opacity)
            }
            SquareButton(symbol: tab.stilled ? "play.fill" : "pause.fill", help: tab.stilled ? "Play" : "Pause") {
                if tab.stilled { tab.playAgain() } else { tab.still() }
            }
        }
        .padding(.leading, Metrics.rowInset)
        .padding(.trailing, Metrics.rowCrossInset)
        .frame(height: prefs.sideRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(hovering ? greys.hover : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        // The buttons take their own clicks; the rest of the row is the way
        // to the tab.
        .onTapGesture { browser.select(tab) }
        .onHover { hovering = $0 }
        .help("Go to the tab")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: tab.stilled)
    }
}

/// A small button wearing the face a tab's line does (RowSquare): the
/// player's, and the hover card's (TabHoverCard).
struct SquareButton: View {
    let symbol: String
    let help: String
    var glyph: CGFloat = 10
    var size: CGFloat = RowCross.size
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            RowSquare(symbol: symbol, hovering: hovering, glyph: glyph, size: size)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
    }
}
