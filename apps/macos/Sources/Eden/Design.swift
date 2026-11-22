import EdenCore
import SwiftUI
import AppKit

// Lifted from Office Inspiration, with the ground turned white: there the work
// floats on an off-white canvas, here the page *is* the ground and everything
// the browser draws has to get out of its way.
//
// Every colour is a pair — one for a light window, one for a dark — and
// resolves itself against whatever appearance the window has. The window
// takes its appearance from the app, and the app from Settings › Appearance:
// light, dark, or whatever the Mac is doing. Nothing else in the code knows
// which it is.
enum Palette {
    static let ground = Color(nsColor: NS.ground)
    static let ink = Color(nsColor: NS.ink)             // neutral-900 · neutral-100
    static let muted = Color(nsColor: NS.muted)         // neutral-500
    static let faint = Color(nsColor: NS.faint)         // neutral-300 · neutral-700
    static let hairline = Color(nsColor: NS.hairline)   // neutral-200 · neutral-800
    static let wash = Color(nsColor: NS.wash)           // the live tab
    /// The live pin: among squares that already wear a faint grey, the one
    /// you are on stands out from them as a live row does from the white.
    static let pinLive = Color(nsColor: NS.pinLive)
    static let hover = Color(nsColor: NS.hover)         // the one under the pointer
    /// Around the page's card, with the tabs down the side: the column and
    /// the gaps share it, a touch off the page's white, so
    /// the card reads as one (see CardEdge).
    static let frame = Color(nsColor: NS.frame)
    /// The column's own greys, on that ground: the live tab, the one under the
    /// pointer, the resting pin squares and the live pin. The white column's
    /// wash, hover and pinLive all but vanished on it (Drice: the pins' squares
    /// and the open tab no longer showed), so these keep the same steps of
    /// contrast from the frame that those kept from the white.
    static let sideWash = Color(nsColor: NS.sideWash)
    static let sideHover = Color(nsColor: NS.sideHover)
    static let sideTile = Color(nsColor: NS.sideTile)
    static let sidePinLive = Color(nsColor: NS.sidePinLive)
    /// The only two that aren't grey: a connection nobody can read on the
    /// way, and one anybody can (see SiteCard.swift).
    static let safe = Color(nsColor: NS.safe)           // green-700 · green-400
    static let unsafe = Color(nsColor: NS.unsafe)       // amber-700 · amber-400

    /// The same colours for the AppKit corners of the app — a text field's
    /// ink, a window's background — which want an NSColor and keep it.
    enum NS {
        static let ground = pair(1.0, 0.11)
        static let ink = pair(0.09, 0.93)
        static let muted = pair(0.55, 0.58)
        static let faint = pair(0.83, 0.32)
        static let hairline = pair(0.91, 0.20)
        static let wash = pair(0.937, 0.175)
        static let pinLive = pair(0.90, 0.21)
        static let hover = pair(0.965, 0.15)
        static let frame = pair(0.955, 0.075)
        static let sideWash = pair(0.895, 0.155)
        static let sideHover = pair(0.915, 0.13)
        static let sideTile = pair(0.925, 0.115)
        static let sidePinLive = pair(0.86, 0.19)
        /// The resting traffic lights, drawn by hand when the app is behind.
        static let resting = pair(0.80, 0.30)
        static let safe = tint(light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50))
        static let unsafe = tint(light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14))

        private static func tint(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }

        private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? dark : light, alpha: 1)
            }
        }
    }
}

/// The greys of the column's rows, pins and buttons, for the ground they lie
/// on: the white's (a panel, the column with the page edge to
/// edge) or the window's beside the page's card, set by the column for
/// what is in it (see SideBar.onFrame). Read through the environment, so a
/// row, a pin or a door is the same view on either ground.
struct Greys {
    let wash: Color
    let hover: Color
    let tile: Color
    let pinLive: Color

    static let white = Greys(wash: Palette.wash, hover: Palette.hover,
                             tile: Palette.wash.opacity(0.55), pinLive: Palette.pinLive)
    static let frame = Greys(wash: Palette.sideWash, hover: Palette.sideHover,
                             tile: Palette.sideTile, pinLive: Palette.sidePinLive)
}

private struct GreysKey: EnvironmentKey {
    static let defaultValue = Greys.white
}

extension EnvironmentValues {
    var greys: Greys {
        get { self[GreysKey.self] }
        set { self[GreysKey.self] = newValue }
    }
}

/// Light, dark, or the Mac's own — the one choice that colours everything.
enum Look: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    /// What the app is told to be. Nothing, for "system": the app then
    /// follows the Mac, and changes with it.
    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    /// Set on the app rather than on the window, so every panel, alert and
    /// sheet — and every page, which follows the window it is in — agrees.
    ///
    /// Never from inside whatever is happening when it is asked for: the
    /// switch in Settings changes it from within an animation, over a panel
    /// in transition, and re-skinning every window in the middle of that is
    /// how a window ends up with a layer that takes clicks and shows
    /// nothing. The next turn of the run loop is soon enough.
    func apply() {
        let wanted = appearance
        DispatchQueue.main.async {
            guard NSApp.appearance !== wanted, NSApp.appearance?.name != wanted?.name else { return }
            NSApp.appearance = wanted
        }
    }
}

enum Metrics {
    /// The band across the column's top that the traffic lights sit in,
    /// with back, forward and reload beside them. The window's title bar is
    /// grown to match it, so the lights come down level with the doors
    /// rather than sitting above them.
    static let strip: CGFloat = 52
    /// With the tabs down the side the page is a card: this far from the
    /// window's edges (and from the column, folded away), and its corners
    /// this round.
    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 10
    /// Back, forward and reload: three doors and the air before the next
    /// one.
    static let helm: CGFloat = 3 * 26 + 2 * 2 + 8
    /// The same three doors again, in the sidebar, where they sit right of
    /// the lights instead. The column already has 10 of horizontal padding
    /// of its own before this even starts. 72 put the back door's box 3
    /// points from the zoom button and its chevron 12, "a little tight"
    /// (feedback, 22 Oct 2026): at 80 the chevron is 20 points clear of the
    /// lights, about the 19 the window leaves on their left, as a toolbar's
    /// first item sits in Safari. A column too narrow for that gives back
    /// what it must (SideBar.lights), down to where it was.
    static let sideLights: CGFloat = 80
    /// The three doors' own width, without the air after them.
    static let helmDoors: CGFloat = 3 * 26 + 2 * 4
    /// The address field raised over another app (Launcher.swift); over a
    /// page it is as wide as Omnibox.Layout makes it.
    static let fieldWidth: CGFloat = 560
    /// A tab's line in the column, and what is drawn as one beside it (a
    /// group's heading, a split, the row that makes a new tab): how round
    /// its corners are, the air before its icon, between its icon and its
    /// title, and after its cross. Its height and its icon's and title's
    /// sizes follow Roomy Tabs (Preferences.sideRow, sideMark, sideTitle).
    static let rowRadius: CGFloat = 9
    static let rowInset: CGFloat = 10
    static let rowSpacing: CGFloat = 8
    static let rowCrossInset: CGFloat = 7

    /// The column of titles down the left, in the way that has one.
    static let side: CGFloat = 232
    static let sideMin: CGFloat = 176
    static let sideMax: CGFloat = 440
}

/// The handle on an edge that pulls: the column's, the side panel's and the
/// one between two pages in Split View. Not a line the edge's whole height —
/// a short pill in the middle of it, as macOS and iPadOS draw theirs, that
/// grows a little and darkens under the pointer and while it is held. What
/// takes the pointer is still the whole edge; only the drawing is small.
enum Grip {
    static let width: CGFloat = 4
    /// Its length at rest, and under the pointer or held.
    static let rest: CGFloat = 28
    static let lit: CGFloat = 40
}

/// The pill itself (see Grip). `resting`: drawn, faint, before the pointer
/// comes; otherwise it is only there once the pointer is on the edge.
struct EdgeGrip: View {
    let lit: Bool
    var resting = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(lit ? Palette.muted : Palette.faint)
            .frame(width: Grip.width, height: lit ? Grip.lit : Grip.rest)
            .opacity(lit || resting ? 1 : 0)
            .animation(Motion.quick, value: lit)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// One spring for anything that moves between two places, one for anything that
// arrives or leaves. Using the same two everywhere is most of why a thing feels
// like a single piece of software rather than a pile of views.
// When macOS Reduce Motion is on in System Settings, or Reduce animations in
// Eden's own, transitions become immediate so the interface does not jump
// or slide.
enum Motion {
    /// Whether interface transitions should be immediate, following the
    /// Mac's own accessibility setting or Eden's Reduce animations.
    static var reduced: Bool {
        instant || (testReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// A test run's stand-in for the Mac's Reduce Motion, so what Reduce
    /// animations does alone can be seen on a Mac that has it on.
    nonisolated(unsafe) static var testReduceMotion: Bool?

    /// Settings › Appearance › Reduce animations, for Eden alone: every
    /// transition is immediate, as under Reduce Motion, and so are the fades
    /// Reduce Motion keeps. The tab ⌘1–⌘9 picks is lit at once, the page
    /// shows at once, a panel is there or gone. Kept here rather than read
    /// from the settings each time, since quick is asked for in nearly every
    /// row's body; Preferences sets it as it reads and writes the switch.
    nonisolated(unsafe) static var instant = false

    nonisolated static let instantKey = "motion.instant"

    /// `seconds`, or none with Reduce animations on: for the fades that run
    /// on a length of their own rather than on the animations below.
    static func seconds(_ seconds: TimeInterval) -> TimeInterval {
        instant ? 0 : seconds
    }

    /// `animation`, or none with Reduce animations on, the same way.
    static func timed(_ animation: Animation) -> Animation? {
        instant ? nil : animation
    }

    /// Whether the Mac is short of power: Low Power Mode is on, or it is hot
    /// enough that macOS is holding its processors back. Then the two springs
    /// below become a short ease-out. A spring keeps moving long after it
    /// looks done: glide takes about 0.5 s to settle, 30 frames that SwiftUI
    /// works out one by one on the main thread, which is the thread a busy or
    /// slowed Mac takes time from first, and every frame it misses shows as a
    /// stutter. 0.16 s is 10 frames, and is over before a missed one shows.
    /// Read at the moment something moves, so it follows the switch at once.
    /// Only once it is turned on in Settings › General (Preferences.lightMotion).
    static var light: Bool {
        guard Store.settings.bool(forKey: lightKey) else { return false }
        return lowPowerMode || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// The same switch, with Low Power Mode on and nothing else: idle tabs
    /// sleep sooner then (see Browser.sleepAfter). Heat alone doesn't count,
    /// since what a sleeping tab gives back is mostly memory, and a hot Mac
    /// has enough of that.
    static var savingPower: Bool {
        Store.settings.bool(forKey: lightKey) && lowPowerMode
    }

    nonisolated static let lightKey = "motion.light"

    /// Low Power Mode, from Battery in System Settings, or a test run's stand-in
    /// for it: only an admin can turn the real one on.
    nonisolated(unsafe) static var testLowPower: Bool?

    private static var lowPowerMode: Bool {
        testLowPower ?? ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static var glide: Animation? {
        reduced ? nil : light ? .easeOut(duration: 0.16) : .spring(response: 0.34, dampingFraction: 0.82)
    }

    static var settle: Animation? {
        reduced ? nil : light ? .easeOut(duration: 0.16) : .spring(response: 0.30, dampingFraction: 0.86)
    }

    static var quick: Animation? {
        reduced ? nil : .easeOut(duration: 0.14)
    }

    /// How far a tab gives while it is pressed (see Give): enough to feel
    /// under the pointer, about 7 points on a column row.
    static let give: CGFloat = 0.97

    /// The folded column coming out over the page, and going back.
    /// On glide it was slow both ways, next to Arc and Dia timed frame by
    /// frame on the same Mac: each slides its sidebar 90% of the way out in
    /// about 95ms and back in about 70ms, where glide took over 200ms. These
    /// match them. Going in is damped all the way, since nothing is arriving
    /// to settle. Fold.slide moves the window's buttons on the same numbers,
    /// in Core Animation's terms.
    static func fold(out: Bool) -> (response: Double, damping: Double) {
        out ? (0.14, 0.86) : (0.13, 1)
    }

    static func folding(out: Bool) -> Animation? {
        let spring = fold(out: out)
        return reduced ? nil : .spring(response: spring.response, dampingFraction: spring.damping)
    }
}

/// Wrong address, said without a dialog: the field shivers and stops.
struct Shake: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard !Motion.reduced else { return ProjectionTransform(.identity) }
        // Three there-and-backs, tapering to nothing, so it settles rather than
        // stopping mid-swing.
        let decay = 1 - travel
        return ProjectionTransform(
            CGAffineTransform(translationX: sin(travel * .pi * 6) * 7 * decay, y: 0)
        )
    }
}

extension View {
    /// What a popover holds, on the ground colour. From macOS 26 a popover
    /// clips what it holds to its own rounded glass; before, an opaque
    /// background was drawn out to the content's square edges, past the
    /// popover's rounded corners (macOS 15, by email). There the popover is
    /// handed the colour and fills its own shape with it, arrow included.
    /// `card`: drawn as its own rounded card, with an edge, on macOS 26.
    func popoverGround(card: Bool = false) -> some View {
        modifier(PopoverGround(card: card))
    }

    /// A line too long for its room fades out at its end, as Dia's titles
    /// do, rather than being cut short with an ellipsis. One that fits is
    /// left as it is. `text` is what it says, for which way it reads: an
    /// Arabic or Hebrew title keeps its beginning, on the right, and fades
    /// on the left, as an ellipsis would have been put there.
    func fadesOut(_ text: String) -> some View {
        modifier(FadeOut(backwards: text.readsRightToLeft))
    }
}

private struct FadeOut: ViewModifier {
    let backwards: Bool

    /// One view however long the line, not one for a line that fits and
    /// another for one that doesn't: a line moving as it crosses from one to
    /// the other (a pinned row's title as its slash comes, SideRow) would be
    /// a new view, put in where it ends up rather than carried there.
    func body(content: Content) -> some View {
        Overrun(backwards: backwards) {
            content.fixedSize(horizontal: true, vertical: false)
        }
        .mask {
            // The line itself, unseen, says how long it is.
            Overrun.Veil(backwards: backwards) {
                content.fixedSize(horizontal: true, vertical: false).hidden()
                Rectangle()
                LinearGradient(colors: [.black, .clear],
                               startPoint: backwards ? .trailing : .leading,
                               endPoint: backwards ? .leading : .trailing)
            }
        }
    }
}

/// A line at its own length, or at the room it is given when that is less,
/// from its start either way: its leading end, or for a line that reads
/// right to left its trailing one.
private struct Overrun: Layout {
    let backwards: Bool
    /// How far the end of a line too long for its room fades.
    static let fade: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let line = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        return CGSize(width: min(line.width, proposal.width ?? line.width), height: line.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let line = first.sizeThatFits(.unspecified)
        first.place(at: CGPoint(x: backwards ? bounds.maxX : bounds.minX, y: bounds.midY),
                    anchor: backwards ? .trailing : .leading, proposal: ProposedViewSize(line))
    }

    /// The mask over it: whole while the line fits, and fading over its last
    /// `fade` points where it runs past its room. Its three parts are the
    /// line, to measure, the solid part, and the fade, put beside the solid
    /// part only when the line runs over, and out of the way otherwise.
    struct Veil: Layout {
        let backwards: Bool

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions()
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard subviews.count == 3 else { return }
            let line = subviews[0].sizeThatFits(.unspecified)
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(line))
            let over = line.width > bounds.width + 0.5
            let fade = over ? min(Overrun.fade, bounds.width) : 0
            let solid = CGSize(width: bounds.width - fade, height: bounds.height)
            subviews[1].place(at: CGPoint(x: backwards ? bounds.maxX : bounds.minX, y: bounds.minY),
                              anchor: backwards ? .topTrailing : .topLeading, proposal: ProposedViewSize(solid))
            subviews[2].place(at: CGPoint(x: backwards ? bounds.minX : bounds.maxX, y: bounds.minY),
                              anchor: backwards ? .topLeading : .topTrailing,
                              proposal: ProposedViewSize(width: fade, height: bounds.height))
        }
    }
}

extension String {
    /// Its first letter is Hebrew or Arabic (or Syriac, Thaana, N'Ko and
    /// the rest of that block), so it reads from the right.
    var readsRightToLeft: Bool {
        guard let first = unicodeScalars.first(where: { $0.properties.isAlphabetic }) else { return false }
        switch first.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }
}

private struct PopoverGround: ViewModifier {
    let card: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if card {
                content
                    .background(Palette.ground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            } else {
                content.background(Palette.ground)
            }
        } else {
            content.presentationBackground(Palette.ground)
        }
    }
}

/// The page as a card in the window, with the tabs down the side: round
/// corners, a hairline edge and a soft shadow under it. The shadow is drawn
/// by a shape behind the page, never by the page's own layers, which would
/// make WebKit's drawing go through it; the page's view is rounded by its own
/// layer as well (see StageView), since a web view is AppKit's and a clip of
/// SwiftUI's is not always carried down to it. Two pages side by side are a
/// card each, drawn by the stage that holds them (see PaneStage).
struct CardEdge: ViewModifier {
    let on: Bool

    // One shape of view, on or off: a page whose view were rebuilt as the
    // card comes and goes (Settings' page as a card, a video taking the
    // screen) would be handed to a new stage just as WebKit takes it to its
    // full screen window. Off, the clip reaches far past the page and cuts
    // nothing, and the edge and shadow are clear.
    func body(content: Content) -> some View {
        content
            .clipShape(CardShape(on: on))
            .background {
                CardShape(on: on)
                    .fill(on ? Palette.ground : .clear)
                    .shadow(color: .black.opacity(on ? CardEdge.shadow : 0), radius: 6, y: 1)
            }
            .overlay {
                CardShape(on: on)
                    .strokeBorder(Color.primary.opacity(on ? CardEdge.edge : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    /// How dark the shadow and the edge are, for the stage's own cards too.
    static let shadow: Double = 0.07
    static let edge: Double = 0.08
}

/// The card's outline: round at its corners, or, off, a rectangle reaching
/// far past the page on every side.
private struct CardShape: InsettableShape {
    let on: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        guard on else { return Path(rect.insetBy(dx: -10_000, dy: -10_000)) }
        return RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> CardShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}
