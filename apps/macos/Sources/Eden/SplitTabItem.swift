import SwiftUI

/// A split's one place in the column. Its pages are lines, one under the
/// other — two, three or four — joined by hairlines: halves side by side in
/// 232 points would cut most titles to a dozen letters.
///
/// The page the keys go to wears the live grey, there at once as on any
/// tab, from one half to the other too.
///
/// The pair reads as one thing: a faint ground of its own under both halves
/// and an outline round them, with a fine line between the halves while
/// neither is lit. Two lit halves — the live one and the one under the
/// pointer — meet square where they touch, so the two greys join with no
/// notch between their corners.
struct SplitTabItem: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// Its pages, in order: two to four. Each half watches its own.
    let pages: [Tab]
    /// One line's height.
    let height: CGFloat
    let live: Bool
    var focusedID: Tab.ID? = nil
    let interactive: Bool

    @Environment(\.greys) private var greys
    @State private var hovered: Tab.ID?
    /// Carried and about to come apart: the half that stays dims.
    @ObservedObject private var separation = PairSeparation.shared

    private var focused: Tab.ID? { live ? (focusedID ?? browser.activeID) : nil }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(pages.indices, id: \.self) { index in
                half(at: index)
            }
        }
        .overlay(alignment: .top) {
            // A line between each two, gone while either is lit.
            ZStack(alignment: .top) {
                ForEach(1..<max(1, pages.count), id: \.self) { index in
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, Metrics.rowInset)
                        .offset(y: CGFloat(index) * height - 0.5)
                        .opacity(lit(pages[index - 1]) || lit(pages[index]) ? 0 : 1)
                }
            }
            .allowsHitTesting(false)
        }
        .background {
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(greys.tile)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split tabs")
        .animation(Motion.quick, value: hovered)
    }

    /// A half wearing a grey: the live one, a selected one, the one under
    /// the pointer.
    private func lit(_ tab: Tab) -> Bool {
        focused == tab.id || hovered == tab.id || browser.selectedTabIDs.contains(tab.id)
    }

    private func half(at index: Int) -> some View {
        let tab = pages[index]
        return SplitTabHalf(
            browser: browser,
            prefs: prefs,
            tab: tab,
            focused: focused == tab.id,
            first: index == 0,
            last: index == pages.count - 1,
            joinedBefore: index > 0 && lit(pages[index - 1]),
            joinedAfter: index < pages.count - 1 && lit(pages[index + 1]),
            height: height,
            interactive: interactive,
            hovered: $hovered
        )
        .frame(maxWidth: .infinity, maxHeight: height)
        .opacity(staying(tab) ? 0.35 : 1)
        .animation(Motion.quick, value: separation.leaving)
    }

    /// The other pages of the one a carried split is letting go of.
    private func staying(_ tab: Tab) -> Bool {
        guard let leaving = separation.leaving, leaving != tab.id else { return false }
        return pages.contains { $0.id == leaving }
    }
}

private struct SplitTabHalf: View {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let focused: Bool
    /// The top line.
    let first: Bool
    /// The bottom line.
    let last: Bool
    /// The line above this one is lit too: the corners
    /// where the two touch are square, so the greys meet without a notch.
    let joinedBefore: Bool
    /// The half after it is lit too.
    let joinedAfter: Bool
    private var joined: Bool { joinedBefore || joinedAfter }
    let height: CGFloat
    let interactive: Bool
    @Binding var hovered: Tab.ID?
    @State private var selectedOnPress = false

    private var hovering: Bool { hovered == tab.id }
    private var title: String { tab.label.isEmpty ? "New Tab" : tab.label }
    private var playing: Bool { !tab.loading && (tab.noisy || tab.muted) }
    private var editing: Bool { browser.editingTab == tab.id }
    /// What the page warns of, on the half you're on: a glyph before its
    /// title (TabTitle).
    private var warning: AtRest? { focused ? AtRest.warning(tab.restAddress) : nil }

    private var laidOut: some View {
        row
            .padding(.trailing, Metrics.rowCrossInset)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The half in front is lit at once, as a row is.
            .background { ground.animation(nil, value: focused).animation(Motion.quick, value: joined) }
            .frame(height: height)
            .contentShape(Rectangle())
    }

    private var handled: some View {
        laidOut
            .modifier(OneClick(double: false) {
                guard interactive, !selectedOnPress, TabClick.flags.intersection([.command, .shift, .option]).isEmpty else { return }
                browser.clearTabSelection()
                if focused { browser.beginTabEdit(tab) }
                else { browser.focusPane(tab) }
            })
            .modifier(ModifiedTabClick {
                if interactive && !editing { browser.extendTabSelection(to: tab, modifiers: $0) }
            })
            .modifier(OptionClick { if interactive && !editing { browser.optionClick(tab) } })
            .overlay {
                if browser.selectedTabIDs.contains(tab.id) {
                    RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if interactive { MiddleClick { browser.closeTab(tab) } }
            }
            .onHover { over in
                if over { hovered = tab.id }
                else if hovered == tab.id { hovered = nil }
            }
            .tabHoverCard(tab, in: browser, enabled: interactive && !editing)
            .contextMenu {
                if interactive { TabMenu(browser: browser, tab: tab, close: { browser.closeTab(tab) }) }
            }
            .background {
                if interactive && browser.prefs.splitView {
                    SplitDropZone(browser: browser, tab: tab, kind: .strip)
                }
            }
    }

    var body: some View {
        handled
            .accessibilityElement(children: editing ? .contain : .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(focused ? "Focused page" : "")
            .accessibilityHint(interactive ? "Click to focus this page; right-click for tab actions" : "")
            .accessibilityAction(named: "Focus page") { browser.focusPane(tab) }
            .accessibilityAction(named: "Close tab") { if interactive { browser.closeTab(tab) } }
            // Its speaker is hidden with the line's other controls: the same
            // press, named.
            .accessibilityAction(named: tab.muted ? "Unmute tab" : "Mute tab") {
                if interactive && playing { tab.toggleMute() }
            }
    }

    /// The grey's shape: round, but square on the side it shares with the
    /// other half while that one is lit too.
    private var shape: UnevenRoundedRectangle {
        let round = Metrics.rowRadius
        // Square where it meets a lit neighbour; round at the ends and
        // beside one that isn't.
        let before: CGFloat = !first && joinedBefore ? 0 : round
        let after: CGFloat = !last && joinedAfter ? 0 : round
        let radii = RectangleCornerRadii(topLeading: before, bottomLeading: after, bottomTrailing: after, topTrailing: before)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
    }

    @ViewBuilder
    private var ground: some View {
        if focused {
            ZStack(alignment: .leading) {
                Rectangle().fill(greys.wash)
                if prefs.showsReading {
                    GeometryReader { geo in
                        ReadingFill(meter: tab.meter, width: geo.size.width)
                    }
                }
            }
            .clipShape(shape)
        } else if browser.selectedTabIDs.contains(tab.id) {
            shape.fill(greys.wash)
        } else if hovering {
            shape.fill(greys.hover)
        }
    }

    private var row: some View {
        HStack(spacing: Metrics.rowSpacing) {
            titleContent
                .padding(.leading, Metrics.rowInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height)
                .contentShape(Rectangle())
                .modifier(TabPress(enabled: interactive && !editing && !browser.isPickedAmongOthers(tab), active: focused, selected: $selectedOnPress) {
                    browser.clearTabSelection()
                    browser.focusPane(tab)
                })
                // Just after the icon, as a tab's line has it; outside the
                // press, so muting a page doesn't also focus it.
                .overlay(alignment: .leading) {
                    if playing && !editing {
                        let mark = prefs.glyph == .icons || !tab.isBlank
                        Speaker(tab: tab)
                            .padding(.leading, Metrics.rowInset + (mark ? prefs.sideMark + Metrics.rowSpacing : 0))
                    }
                }
            if !editing {
                if interactive, let number = shortcutNumbers[tab.id] {
                    TabShortcutNumber(number: number)
                }
                status
                // Each line has its own cross at its own end.
                if interactive { closeButton }
            }
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        if editing {
            TabAddressField(browser: browser)
                .frame(height: 16)
        } else {
            HStack(spacing: Metrics.rowSpacing) {
                if prefs.glyph == .icons || !tab.isBlank {
                    let mark = prefs.sideMark
                    Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: mark, dim: tab.asleep)
                        .frame(width: mark, height: mark)
                }
                // As a tab's line has it: just after the icon. Its place: the
                // speaker is laid over it, outside the line's press (see
                // `row`).
                if playing { Color.clear.frame(width: RowCross.size, height: RowCross.size) }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                }
                PopupSign(browser: browser, tab: tab)
                TranslateSign(tab: tab)
                // The page is asking something, over its half of the stage.
                if browser.paneQuestions.contains(where: { $0.tab == tab.id }) {
                    Circle()
                        .fill(Palette.muted)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Asking a question")
                }
                TabTitle(label: title, warning: warning, size: prefs.sideTitle,
                         colour: focused ? Palette.ink : hovering ? Palette.ink.opacity(0.7) : Palette.muted)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if tab.loading && !hovering {
            Ring(size: 10)
                .padding(.trailing, 3)
        }
    }

    /// Each line's own cross, a tab's (RowCross); the click taken by
    /// CloseClick.
    private var closeButton: some View {
        RowCross(height: height)
            .opacity(hovering ? 1 : 0)
            .overlay {
                CloseClick(armed: hovering) { browser.closeTab(tab) }
                    .frame(width: RowCross.reachWidth, height: height)
            }
    }
}
