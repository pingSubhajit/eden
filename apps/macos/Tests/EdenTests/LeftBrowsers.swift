import XCTest
@testable import Eden

/// A suite that ends with a browser of its own still in Browsers.all fails
/// the run (#33).
///
/// Browsers.all is one list for the whole test process, and it decides
/// which window holds its profile's session files. A browser a suite
/// registers and leaves there lives on through every later suite: it keeps
/// following pin and setting changes, writing its space as it last saw it,
/// and every later window is taken for a second window of its profile. So a
/// suite takes out what it registers, with Browsers.discard in a defer set
/// before any assertion. This looks once the suite has ended, its class
/// tearDown included, so a suite may still keep a browser across its own
/// tests. What it finds is taken out too, so the suites after it run as
/// they would alone.
final class LeftBrowsers: NSObject, XCTestObservation {
    private static let shared = LeftBrowsers()
    private static var watching = false

    /// The suites running now, outermost first, with the browsers listed as
    /// each began.
    private var running: [(suite: XCTestSuite, before: Set<ObjectIdentifier>)] = []

    static func watch() {
        guard !watching else { return }
        watching = true
        XCTestObservationCenter.shared.addTestObserver(shared)
    }

    func testSuiteWillStart(_ testSuite: XCTestSuite) {
        running.append((testSuite, MainActor.assumeIsolated { Set(Browsers.all.map(ObjectIdentifier.init)) }))
    }

    func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        guard let began = running.popLast(), began.suite === testSuite else { return }
        // Only a class's suite: the run's and the bundle's hold every class.
        guard testSuite.tests.contains(where: { $0 is XCTestCase }) else { return }
        MainActor.assumeIsolated {
            // The scene's browser is made once, the first time something
            // needs one, and is the process's for good.
            let left = Browsers.all.filter { !began.before.contains(ObjectIdentifier($0)) && !$0.inScene }
            guard !left.isEmpty else { return }
            left.forEach(Browsers.discard)
            // The suite's own run has stopped, and one that has stopped
            // can't take an issue; the run around it is still going.
            running.last?.suite.testRun?.record(XCTIssue(
                type: .assertionFailure,
                compactDescription: "\(testSuite.name) left \(left.count) browser(s) in Browsers.all; "
                    + "take each one out with Browsers.discard"))
        }
    }
}

/// Starts LeftBrowsers before the first suite does. XCTest asks every test
/// class for its suite while it puts a whole run together, before any of
/// them runs. A run of chosen tests asks only their classes, so the check
/// is for the whole run, the one where suites meet.
final class LeftBrowsersWatch: XCTestCase {
    override class var defaultTestSuite: XCTestSuite {
        LeftBrowsers.watch()
        return super.defaultTestSuite
    }
}
