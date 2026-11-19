import SwiftUI

// One kind of passing message for every window of both apps, after Dia's: a
// glass capsule that drops in at the top centre with a little bounce, says
// one thing — what was just done, an offer to undo it, or what went wrong —
// and slips back up a moment later. What is done is told by a check that
// draws itself in once the capsule has landed. One at a time: said again,
// the same toast says it again where it stands; a passing note never cuts
// an offer short, though the outcome of something done since does. Read out
// by VoiceOver, every one.
//
// Measured from Dia 1.57 frame by frame: it drops from 28 points above,
// scaled to 94%, and overshoots by 5 before it settles, about half a second
// after it begins; the check follows a quarter of a second in; it rests a
// second and a bit, then goes up, shrinks, fades and blurs in 150 ms.

/// A passing message (Toasts).
public struct Toast: Identifiable {
    /// What it tells: something done (a check draws itself in), a note, or
    /// something that went wrong.
    public enum Look: Equatable, Sendable {
        case done, note, problem
    }

    /// The one thing it offers: Reopen, Show in Finder. `identifier` names
    /// its button for VoiceOver's rotor and for tests.
    public struct Action {
        public let title: String
        public let identifier: String?
        public let perform: @MainActor () -> Void

        public init(_ title: String, identifier: String? = nil, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.identifier = identifier
            self.perform = perform
        }
    }

    public fileprivate(set) var id = UUID()
    public var text: String
    public var look: Look
    /// An SF Symbol before the text, for a note or a problem; something done
    /// wears the check.
    public var symbol: String?
    public var action: Action?
    /// Toasts of one key are one: shown again, it changes where it stands
    /// rather than coming in anew (the zoom as a pinch goes on).
    public var key: String?

    public init(_ text: String, look: Look = .note, symbol: String? = nil, action: Action? = nil, key: String? = nil) {
        self.text = text
        self.look = look
        self.symbol = symbol
        self.action = action
        self.key = key
    }
}

/// A window's toasts: the one showing, and one waiting behind an offer.
@MainActor
public final class Toasts: ObservableObject {
    @Published public private(set) var current: Toast?
    /// Moved on whenever the toast showing is said again, for its check to
    /// draw itself again.
    @Published public private(set) var said = 0

    private var waiting: Toast?
    private var leaving: Task<Void, Never>?
    private var held = false

    public init() {}

    public func show(_ toast: Toast) {
        if var current, Self.same(current, toast) {
            // The same thing again: said again where it stands.
            let id = current.id
            current = toast
            current.id = id
            self.current = current
            return shown(toast)
        }
        // An offer to undo stays its time: a passing note (the zoom, a space's
        // name) waits behind it, the latest only. What came of something done
        // since, done or gone wrong, is newer news, and takes its place, and
        // what waited is older than it.
        if let current, current.action != nil, toast.action == nil, toast.look == .note {
            waiting = toast
            return
        }
        waiting = nil
        withAnimation(.default) { current = toast }
        shown(toast)
    }

    /// On screen, or said again there: read out, its check drawn, its time
    /// begun. Never before it shows, so one waiting is read out once.
    private func shown(_ toast: Toast) {
        AccessibilityNotification.Announcement(toast.text).post()
        said += 1
        schedule()
    }

    /// Gone now: its time up, its action taken, or dismissed.
    public func dismiss() {
        leaving?.cancel()
        withAnimation(.default) { current = nil }
        if let next = waiting {
            waiting = nil
            show(next)
        }
    }

    /// Kept while the pointer is on it; its time starts again once it leaves.
    public func hold(_ on: Bool) {
        held = on
        on ? leaving?.cancel() : schedule()
    }

    /// The offer taken: gone first, so whatever the action says of itself
    /// ("It's back") is what shows after it.
    func perform(_ action: Toast.Action) {
        dismiss()
        action.perform()
    }

    private func schedule() {
        leaving?.cancel()
        guard let toast = current, !held else { return }
        let lifetime = Self.lifetime(toast)
        leaving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private static func same(_ one: Toast, _ other: Toast) -> Bool {
        if let key = one.key, key == other.key { return true }
        return one.action == nil && other.action == nil && one.text == other.text && one.look == other.look
    }

    /// How long it stays: Dia's two seconds for a few words, longer as there
    /// are more to read, and an offer long enough to be taken up.
    static func lifetime(_ toast: Toast) -> Double {
        if toast.action != nil { return 5 }
        let reading = 1.0 + Double(toast.text.count) / 20
        return min(max(2, reading), toast.look == .problem ? 6 : 4.5)
    }
}

// MARK: - the capsule

/// Where a window's toast shows: laid over its content at the top, centred,
/// `top` points down.
public struct ToastHost: View {
    @ObservedObject var toasts: Toasts
    var top: CGFloat

    public init(_ toasts: Toasts, top: CGFloat = 26) {
        self.toasts = toasts
        self.top = top
    }

    @Environment(\.accessibilityReduceMotion) private var reduced

    public var body: some View {
        ZStack {
            if let toast = toasts.current {
                ToastCapsule(toasts: toasts, toast: toast)
                    .id(toast.id)
                    .transition(reduced ? .opacity : ToastMotion.transition)
            }
        }
        .padding(.top, top)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Dia's motion: in from above, a little bounce, and up and out quickly.
private struct ToastMotion: ViewModifier {
    var y: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: Double = 1
    var blur: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .top)
            .offset(y: y)
            .opacity(opacity)
            .blur(radius: blur)
    }

    static var transition: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ToastMotion(y: -28, scale: 0.938, opacity: 0, blur: 6), identity: ToastMotion())
                .animation(.spring(response: 0.32, dampingFraction: 0.48)),
            removal: .modifier(active: ToastMotion(y: -24, scale: 0.967, opacity: 0, blur: 6), identity: ToastMotion())
                .animation(.easeInOut(duration: 0.15))
        )
    }
}

private struct ToastCapsule: View {
    @ObservedObject var toasts: Toasts
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(toast.text)
                .font(ToastCapsule.font)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let action = toast.action {
                Button(action.title) { toasts.perform(action) }
                    .buttonStyle(.plain)
                    .font(ToastCapsule.font.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier(action.identifier ?? "toast-action")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 38)
        .modifier(ToastGlass())
        .contentShape(Capsule())
        .onHover { toasts.hold($0) }
        // As wide as it has to be, up to a line a long title can't stretch
        // across the window.
        .frame(maxWidth: 440)
        // Read as one line; one with an action keeps its button its own.
        .accessibilityElement(children: toast.action == nil ? .combine : .contain)
        .accessibilityIdentifier("toast")
    }

    @ViewBuilder
    private var icon: some View {
        switch toast.look {
        case .done:
            ToastCheck(said: toasts.said)
        case .note:
            if let symbol = toast.symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            }
        case .problem:
            Image(systemName: toast.symbol ?? "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    /// Dia's 13 points, medium, on the Mac; the text size the person chose on
    /// iPhone and iPad.
    static var font: Font {
        #if os(iOS)
        .subheadline.weight(.medium)
        #else
        .system(size: 13, weight: .medium)
        #endif
    }
}

/// Liquid Glass where there is any; the system's material before it.
private struct ToastGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }
    }
}

// MARK: - the check

/// Dia's check, drawn in once the capsule has landed: a dot that grows into
/// a disc, a small burst around it, and the check cut out of it. Drawn
/// again whenever the same thing is said again.
private struct ToastCheck: View {
    let said: Int
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorScheme) private var scheme
    /// Set once it is on screen: what plays the check the first time, a
    /// keyframe animation playing only when what it watches changes.
    @State private var shown = false

    private struct Phase {
        var disc: CGFloat = 0
        var burst: CGFloat = 0
        var rays: Double = 0
        var check: CGFloat = 0
    }

    var body: some View {
        if reduced {
            mark(Phase(disc: 1, burst: 0, rays: 0, check: 1))
        } else {
            mark(Phase())
                .hidden()
                .overlay {
                    KeyframeAnimator(initialValue: Phase(), trigger: Trigger(shown: shown, said: said)) { phase in
                        mark(phase)
                    } keyframes: { _ in
                        KeyframeTrack(\.disc) {
                            LinearKeyframe(0, duration: 0.24)
                            CubicKeyframe(0.25, duration: 0.05)
                            SpringKeyframe(1.12, duration: 0.12, spring: .snappy)
                            SpringKeyframe(1, duration: 0.14, spring: .smooth)
                        }
                        KeyframeTrack(\.burst) {
                            LinearKeyframe(0, duration: 0.36)
                            CubicKeyframe(1, duration: 0.18)
                        }
                        KeyframeTrack(\.rays) {
                            LinearKeyframe(0, duration: 0.36)
                            LinearKeyframe(1, duration: 0.05)
                            LinearKeyframe(0, duration: 0.14)
                        }
                        KeyframeTrack(\.check) {
                            LinearKeyframe(0, duration: 0.42)
                            CubicKeyframe(1, duration: 0.16)
                        }
                    }
                }
                .onAppear { shown = true }
        }
    }

    private struct Trigger: Equatable {
        let shown: Bool
        let said: Int
    }

    private func mark(_ phase: Phase) -> some View {
        ZStack {
            // The burst: short rays thrown out from the disc as it lands.
            ForEach(0..<8, id: \.self) { ray in
                Capsule()
                    .fill(scheme == .dark ? Color.white : Color.black)
                    .frame(width: 1.5, height: 3)
                    .offset(y: -(8 + 4 * phase.burst))
                    .rotationEffect(.degrees(Double(ray) * 45))
                    .opacity(phase.rays)
            }
            // Solid, as Dia's: the glass would wash a tint of the text grey.
            Circle()
                .fill(scheme == .dark ? Color.white : Color.black)
                .frame(width: 14, height: 14)
                .scaleEffect(phase.disc)
            // The check cut out of the disc, so the glass shows through it.
            CheckShape()
                .trim(from: 0, to: phase.check)
                .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 7, height: 5.5)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
