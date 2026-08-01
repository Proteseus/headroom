import XCTest
@testable import Headroom

/// The decisions behind offering an app update. See docs/updater.md.
///
/// Everything here is deliberately reachable without a network, a bundle or a
/// signed binary, because none of those exist on a runner — and because the
/// install half cannot be tested at all: it replaces the app that would be
/// running the test.
final class UpdateCheckTests: XCTestCase {

    private let os = "15.3.0"

    private func feed(
        version: String? = "1.5.0",
        url: String? = "https://updates.centaur-labs.io/Headroom-macOS.zip",
        minMacOS: String? = "14.0"
    ) -> UpdateFeed {
        UpdateFeed(
            schema: 1, version: version, published: nil, url: url,
            sha256: nil, size: nil, minMacOS: minMacOS, notesMD: nil
        )
    }

    // MARK: Version ordering

    /// The reason the updater reuses `HostVersion.isNewer` rather than
    /// comparing strings: `sort -V` in update-app.sh orders these the same way,
    /// and the release history has already been through 1.0.10 and 1.0.11.
    func testTenBeatsNineWithinAPatchLine() {
        XCTAssertEqual(HostVersion.isNewer("1.4.10", than: "1.4.9"), true)
        XCTAssertEqual(HostVersion.isNewer("1.4.9", than: "1.4.10"), false)
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertEqual(HostVersion.isNewer("1.4.1", than: "1.4.1"), false)
    }

    func testShorterVersionsPadWithZero() {
        XCTAssertEqual(HostVersion.isNewer("1.5", than: "1.4.9"), true)
        XCTAssertEqual(HostVersion.isNewer("1.4", than: "1.4.0"), false)
    }

    /// nil rather than a guess. Declining to offer beats offering a downgrade.
    func testNonNumericVersionsRefuseToCompare() {
        XCTAssertNil(HostVersion.isNewer("1.5.0-beta", than: "1.4.1"))
        XCTAssertNil(HostVersion.isNewer("1.4.1", than: ""))
    }

    // MARK: Decoding

    /// The whole point of every field being optional. A feed carrying only the
    /// two keys that matter still decodes, so a future release that drops a
    /// field cannot strand builds that are already out there.
    func testDecodesWithEveryOptionalMissing() throws {
        let json = Data(#"{"version":"1.5.0","url":"https://x/y.zip"}"#.utf8)
        let decoded = try UpdateCheck.decode(json)
        XCTAssertEqual(decoded.version, "1.5.0")
        XCTAssertNil(decoded.sha256)
        XCTAssertNil(decoded.minMacOS)
    }

    /// The other half of the same rule: a key this build has never heard of
    /// must not fail the document. This is what makes the feed additive.
    func testUnknownFutureKeysAreIgnored() throws {
        let json = Data(#"""
        {"version":"1.5.0","url":"https://x/y.zip","channel":"beta",
         "delta":{"from":"1.4.9","url":"https://x/d.patch"}}
        """#.utf8)
        let decoded = try UpdateCheck.decode(json)
        XCTAssertEqual(decoded.version, "1.5.0")
    }

    func testSnakeCaseKeysMapToProperties() throws {
        let json = Data(#"""
        {"version":"1.5.0","url":"https://x/y.zip",
         "min_macos":"14.0","notes_md":"### Fixed"}
        """#.utf8)
        let decoded = try UpdateCheck.decode(json)
        XCTAssertEqual(decoded.minMacOS, "14.0")
        XCTAssertEqual(decoded.notesMD, "### Fixed")
    }

    func testMalformedJSONThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try UpdateCheck.decode(Data("not json".utf8)))
    }

    // MARK: What gets offered

    func testOffersANewerVersion() {
        let found = UpdateCheck.evaluate(
            feed: feed(), installed: "1.4.1", osVersion: os)
        XCTAssertEqual(found?.version, "1.5.0")
    }

    func testDoesNotOfferTheInstalledVersion() {
        XCTAssertNil(UpdateCheck.evaluate(
            feed: feed(version: "1.4.1"), installed: "1.4.1", osVersion: os))
    }

    /// A feed that has rolled backwards — a bad publish, a restored bucket —
    /// must not walk everyone down a version.
    func testDoesNotOfferADowngrade() {
        XCTAssertNil(UpdateCheck.evaluate(
            feed: feed(version: "1.3.0"), installed: "1.4.1", osVersion: os))
    }

    func testRefusesANonHTTPSURL() {
        XCTAssertNil(UpdateCheck.evaluate(
            feed: feed(url: "http://updates.centaur-labs.io/y.zip"),
            installed: "1.4.1", osVersion: os))
    }

    func testRefusesAFeedMissingVersionOrURL() {
        XCTAssertNil(UpdateCheck.evaluate(
            feed: feed(version: nil), installed: "1.4.1", osVersion: os))
        XCTAssertNil(UpdateCheck.evaluate(
            feed: feed(url: nil), installed: "1.4.1", osVersion: os))
    }

    func testHonoursAMacOSFloor() {
        XCTAssertNil(UpdateCheck.evaluate(
            feed: feed(minMacOS: "26.0"), installed: "1.4.1", osVersion: os))
        XCTAssertNotNil(UpdateCheck.evaluate(
            feed: feed(minMacOS: "15.0"), installed: "1.4.1", osVersion: os))
    }

    /// Fails open, unlike every other branch here. An unparseable floor is a
    /// typo in one string; treating it as a block would silently stop this
    /// build ever updating again, which is far worse than offering a build
    /// macOS would refuse to launch anyway.
    func testAnUnparseableMacOSFloorDoesNotBlock() {
        XCTAssertNotNil(UpdateCheck.evaluate(
            feed: feed(minMacOS: "Sequoia"), installed: "1.4.1", osVersion: os))
    }

    // MARK: The shipped feed

    /// docs/latest.json is what every installed copy actually reads, so a
    /// commit that breaks its shape should fail here rather than in the field.
    func testShippedFeedParsesAndIsWellFormed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // repo root
        let data = try Data(contentsOf: root.appendingPathComponent("docs/latest.json"))
        let decoded = try UpdateCheck.decode(data)

        XCTAssertEqual(decoded.schema, 1)
        XCTAssertNotNil(decoded.version)
        XCTAssertTrue(decoded.url?.hasPrefix("https://") ?? false)
        XCTAssertEqual(decoded.sha256?.count, 64)
        XCTAssertGreaterThan(decoded.size ?? 0, 0)
    }
}
