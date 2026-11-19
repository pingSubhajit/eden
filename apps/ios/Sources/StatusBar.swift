import SwiftUI
import UIKit

/// The status bar's style, from SwiftUI, which has no say in it of its own:
/// dark writing over a light page and light over a dark one, as Safari
/// does, whatever the phone's appearance. Leaving it `.default` follows the
/// appearance again.
struct StatusBarStyle: UIViewRepresentable {
    let style: UIStatusBarStyle

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.style = style
    }

    static func dismantleUIView(_ probe: Probe, coordinator: ()) {
        probe.style = .default
    }

    /// Finds the window scene the browser is in, and sets the style there.
    final class Probe: UIView {
        var style: UIStatusBarStyle = .default {
            didSet { if style != oldValue { apply() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let scene = window?.windowScene else { return }
            StatusBarWindow.shared.set(style, in: scene)
        }
    }
}

/// A window of nothing over the app's own, there only so its controller can
/// say how the status bar looks: the system asks the window on top. It takes
/// no touch and shows nothing, so everything beneath is as it was.
@MainActor
private final class StatusBarWindow {
    static let shared = StatusBarWindow()
    private var window: UIWindow?
    private let controller = StyleController()

    func set(_ style: UIStatusBarStyle, in scene: UIWindowScene) {
        if window?.windowScene !== scene {
            let made = PassingWindow(windowScene: scene)
            made.windowLevel = .normal + 1
            made.backgroundColor = .clear
            made.rootViewController = controller
            made.accessibilityElementsHidden = true
            made.isHidden = false
            window = made
        }
        controller.style = style
    }
}

/// Lets every touch through to the windows beneath.
private final class PassingWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private final class StyleController: UIViewController {
    var style: UIStatusBarStyle = .default {
        didSet { if style != oldValue { setNeedsStatusBarAppearanceUpdate() } }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { style }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    // Turning stays the app's to decide, as if this window weren't here.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        self.view = view
    }
}
