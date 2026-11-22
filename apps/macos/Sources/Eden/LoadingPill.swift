import AppKit
import SwiftUI

// The page in front, still loading, as the strip above it says.
//
// The row's ring says it too, but it is small, off to the side, and gone
// with the column folded away. A page that is slow to come looked the same
// as one that had stuck. While it loads, a small pill sits in the middle of
// the band of window above the page's card. It breathes twice while the
// page is asked for; a page still not there by then has the pill widen into
// a track with a brighter block running through it, left to right, for as
// long as it takes. Once the page is in, the pill draws in to its middle and
// fades. In the window's ink, at the strengths measured off the indicator it
// is copied from.

/// The pill in the band above the page, while the tab in front loads.
struct LoadingPill: View {
    @ObservedObject var tab: Tab
    @ObservedObject var prefs: Preferences
    /// The Mac's Reduce Motion, read here so that turning it on or off
    /// mid-load reaches the pill at once, as Reduce animations does through
    /// the settings.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PillStrip(on: tab.loading, still: reduceMotion || prefs.instantMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The band and its pill. Core Animation rather than a SwiftUI animation: it
/// runs for as long as a page takes, a whole minute for a slow one, and
/// SwiftUI would work out every frame of it on the main thread, the thread
/// the loading page is waiting on too. Moved by the render server, it costs
/// the app one call when the pill widens and nothing else once it is going.
private struct PillStrip: NSViewRepresentable {
    let on: Bool
    let still: Bool

    func makeNSView(context: Context) -> PillView { PillView() }
    func updateNSView(_ view: PillView, context: Context) {
        // Still first, so a page that starts loading under Reduce Motion
        // never begins to move.
        view.still = still
        view.on = on
    }

    final class PillView: NSView {
        /// What the pill is doing: nothing, breathing while the page is
        /// asked for, running while it is slow to come, or held still under
        /// Reduce Motion.
        private enum Phase { case idle, breathing, running, held }

        /// The pill, which clips the block running through it.
        private let pill = CALayer()
        private let block = CALayer()
        private var phase = Phase.idle
        /// The pill as a dim track, as it runs and while it draws in after,
        /// rather than bright, as it breathes or is held.
        private var dimmed = false
        /// When the breathing began, so breaths put back after the view
        /// rejoins a window carry on where they were rather than start over.
        private var breathBegan: CFTimeInterval = 0
        /// The breathing turning into the run, once the page has been on
        /// its way long enough.
        private var widening: DispatchWorkItem?

        /// The pill's height, and its width breathing, at the bottom and the
        /// top of a breath, and running.
        private static let height: CGFloat = 4
        private static let low: CGFloat = 42
        private static let high: CGFloat = 48
        private static let track: CGFloat = 128
        /// Half a breath, in and out twice before the pill widens, and how
        /// faint it gets between breaths: gone, as the one it is copied
        /// from is.
        private static let breath: CFTimeInterval = 0.8
        private static let breathing: TimeInterval = 4 * breath
        private static let faint: Swift.Float = 0
        /// How long the pill takes to widen, one run of the block with the
        /// pause after it, the run alone, and the pill drawing in once the
        /// page is there.
        private static let widen: CFTimeInterval = 0.75
        private static let cycle: CFTimeInterval = 1.125
        private static let crossing: CFTimeInterval = 0.75
        private static let leave: CFTimeInterval = 0.4
        /// The track, and the block and a breath at their brightest: the
        /// window's ink at these strengths, about what the measured white
        /// was over its own dark ground.
        private static let dim: CGFloat = 0.22
        private static let bright: CGFloat = 0.8

        var on = false {
            didSet { if on != oldValue { on ? begin() : end() } }
        }

        /// Reduce Motion or Reduce animations. Turned either way while the
        /// page loads, the pill changes over then, not with the next page;
        /// turned on while it draws in, it is gone at once.
        var still = false {
            didSet {
                guard still != oldValue else { return }
                if on {
                    begin()
                } else if still {
                    pill.removeAllAnimations()
                    block.removeAllAnimations()
                }
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            pill.cornerRadius = Self.height / 2
            pill.cornerCurve = .continuous
            pill.masksToBounds = true
            pill.opacity = 0
            pill.bounds = CGRect(x: 0, y: 0, width: Self.high, height: Self.height)
            block.bounds = CGRect(x: 0, y: 0, width: Self.track, height: Self.height)
            block.position = CGPoint(x: -Self.track / 2, y: Self.height / 2)
            // Only what is animated on purpose moves: a new place, size or
            // colour is there at once.
            let none: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(),
                                            "backgroundColor": NSNull(), "opacity": NSNull()]
            pill.actions = none
            block.actions = none
            pill.addSublayer(block)
            layer?.addSublayer(pill)
        }

        required init?(coder: NSCoder) { nil }

        /// Seen, never pressed: the band is also where the window is dragged
        /// from (see Fold).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        /// The colours are resolved against the window's appearance, so they
        /// are set again whenever that changes.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paint()
        }

        /// A layer's animations are dropped when its view leaves the window,
        /// so they are put back when it arrives in one again, where the pill
        /// had got to.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            paint()
            guard window != nil else { return }
            switch phase {
            case .breathing: breathe()
            case .running: run(widening: false)
            case .idle, .held: break
            }
        }

        private func paint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let ink = Palette.NS.ink
                pill.backgroundColor = ink.withAlphaComponent(dimmed ? Self.dim : Self.bright).cgColor
                block.backgroundColor = ink.withAlphaComponent(Self.bright).cgColor
            }
            // The turn from bright to dim as the pill widens holds the
            // colours of the appearance it began in: in another, the track
            // takes its own colour at once rather than at the turn's end.
            pill.removeAnimation(forKey: "dim")
        }

        /// A page on its way: the pill breathes, or under Reduce Motion
        /// simply shows, as it is at the top of a breath.
        private func begin() {
            widening?.cancel()
            widening = nil
            pill.removeAllAnimations()
            block.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.bounds.size.width = Self.high
            pill.opacity = 1
            CATransaction.commit()
            dimmed = false
            if still {
                phase = .held
                paint()
                return
            }
            phase = .breathing
            breathBegan = CACurrentMediaTime()
            paint()
            breathe()
            // Most pages are in before this: those still on their way have
            // the pill widen and run.
            let next = DispatchWorkItem { [weak self] in
                guard let self, self.on, self.phase == .breathing else { return }
                self.run(widening: true)
            }
            widening = next
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.breathing, execute: next)
        }

        /// In and out, a little wider at the top of each breath, from
        /// nothing at first.
        private func breathe() {
            guard window != nil else { return }
            let glow = CABasicAnimation(keyPath: "opacity")
            glow.fromValue = Self.faint
            glow.toValue = 1
            let swell = CABasicAnimation(keyPath: "bounds.size.width")
            swell.fromValue = Self.low
            swell.toValue = Self.high
            let since = max(0, CACurrentMediaTime() - breathBegan)
            for breath in [glow, swell] {
                breath.timeOffset = since
                breath.duration = Self.breath
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            pill.add(glow, forKey: "glow")
            pill.add(swell, forKey: "swell")
        }

        /// The pill as a track with the block running through it, again and
        /// again. `widening`: grown out of a breath, from wherever the breath
        /// had got to, rather than there already.
        private func run(widening: Bool) {
            let from = pill.presentation()
            let width = from?.bounds.width ?? Self.high
            let opacity = from?.opacity ?? 1
            pill.removeAnimation(forKey: "glow")
            pill.removeAnimation(forKey: "swell")
            phase = .running
            dimmed = true
            let brightColour = pill.backgroundColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.bounds.size.width = Self.track
            pill.opacity = 1
            paint()
            CATransaction.commit()
            guard window != nil else { return }
            if widening {
                let grow = CABasicAnimation(keyPath: "bounds.size.width")
                grow.fromValue = width
                grow.toValue = Self.track
                grow.duration = Self.widen
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                pill.add(grow, forKey: "grow")
                let rise = CABasicAnimation(keyPath: "opacity")
                rise.fromValue = opacity
                rise.toValue = 1
                rise.duration = Self.widen / 2
                pill.add(rise, forKey: "rise")
                let dim = CABasicAnimation(keyPath: "backgroundColor")
                dim.fromValue = brightColour
                dim.toValue = pill.backgroundColor
                dim.duration = Self.widen
                pill.add(dim, forKey: "dim")
            }
            // From just off the track's leading end to just off its trailing
            // end at an even pace, then a pause with the track empty. The
            // track grows from its middle, so the block's places are from its
            // leading edge as it is at the time.
            let cross = CAKeyframeAnimation(keyPath: "position.x")
            cross.values = [-Self.track / 2, Self.track * 1.5, Self.track * 1.5]
            cross.keyTimes = [0, NSNumber(value: Self.crossing / Self.cycle), 1]
            cross.calculationMode = .linear
            cross.duration = Self.cycle
            cross.repeatCount = .infinity
            block.add(cross, forKey: "cross")
        }

        /// The page is in: the pill draws in to its middle and fades, then
        /// stops, so nothing no one can see is drawn again on every frame.
        private func end() {
            widening?.cancel()
            widening = nil
            phase = .idle
            let from = pill.presentation()
            let width = from?.bounds.width ?? pill.bounds.width
            let opacity = from?.opacity ?? pill.opacity
            pill.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.bounds.size.width = 0
            pill.opacity = 0
            CATransaction.commit()
            guard window != nil, !still, opacity > 0 else {
                block.removeAllAnimations()
                return
            }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                // Unless the next page started loading meanwhile.
                guard let self, self.phase == .idle else { return }
                self.block.removeAllAnimations()
            }
            let shrink = CABasicAnimation(keyPath: "bounds.size.width")
            shrink.fromValue = width
            shrink.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            for going in [shrink, fade] {
                going.duration = Self.leave
                going.timingFunction = CAMediaTimingFunction(name: .easeIn)
                pill.add(going, forKey: going.keyPath)
            }
            CATransaction.commit()
        }
    }
}
