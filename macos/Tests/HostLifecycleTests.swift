import XCTest
@testable import Headroom

/// Which supervisor owns `host/headroom_server.py`. The orphan guard on the
/// other side of the app-owned mode is `host/test_parent_watch.py`.
final class HostLifecycleTests: XCTestCase {

    func testAbsentValueIsTheLaunchAgent() {
        // Every install from before this setting existed has no stored value,
        // and must keep the host it already had.
        XCTAssertEqual(HostLifecycle.resolve(nil), .launchAgent)
    }

    func testStoredValuesRoundTrip() {
        for mode in HostLifecycle.allCases {
            XCTAssertEqual(HostLifecycle.resolve(mode.rawValue), mode)
        }
    }

    func testUnknownValueFallsBackRatherThanFailing() {
        // A mode written by a newer build reaching an older one. Falling back
        // to the LaunchAgent leaves the host supervised by something; treating
        // it as app-owned would leave this build supervising nothing, and the
        // symptom would read as a dead board.
        XCTAssertEqual(HostLifecycle.resolve("smAppService"), .launchAgent)
        XCTAssertEqual(HostLifecycle.resolve(""), .launchAgent)
    }

    /// The toggle is worded "keep running", so on must be the LaunchAgent.
    /// Inverting this ships every existing install a host that dies on quit.
    func testKeepRunningOnMeansLaunchAgent() {
        XCTAssertEqual(HostLifecycle.resolve(nil), .launchAgent)
        XCTAssertNotEqual(HostLifecycle.appOwned, HostLifecycle.resolve(nil))
    }
}
