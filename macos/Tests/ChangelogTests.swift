import XCTest
@testable import Headroom

final class ChangelogTests: XCTestCase {
    func testParseSkipsPreambleAndJoinsSoftWraps() {
        let md = """
        # Changelog

        Marketing versions come from host/VERSION.

        ## 1.9.5 — 2026-08-07

        ### Added

        - **Choose who runs the host** — Settings → General → Host gains *Keep the
          host running when Headroom is closed*. On by default.

        ### Fixed

        - A one-line fix.

        ## 1.9.4 — 2026-08-06

        ### Fixed

        - Earlier fix.
        """

        let doc = Changelog.parse(md)
        XCTAssertEqual(doc.versions.count, 2)
        XCTAssertEqual(doc.versions[0].version, "1.9.5")
        XCTAssertEqual(doc.versions[0].date, "2026-08-07")
        XCTAssertEqual(doc.versions[0].title, "1.9.5 — 2026-08-07")

        let added = doc.versions[0].sections[0]
        XCTAssertEqual(added.title, "Added")
        XCTAssertEqual(added.items.count, 1)
        XCTAssertTrue(
            added.items[0].contains("host running when Headroom is closed"),
            "soft-wrapped bullet should be one item: \(added.items[0])"
        )
        XCTAssertFalse(
            added.items[0].contains("\n"),
            "joined item must not retain the soft newline"
        )

        XCTAssertEqual(doc.versions[0].sections[1].title, "Fixed")
        XCTAssertEqual(doc.versions[0].sections[1].items, ["A one-line fix."])
        XCTAssertEqual(doc.versions[1].version, "1.9.4")
    }

    func testParseHeadingWithoutDate() {
        let doc = Changelog.parse("## 1.0.0\n\n### Added\n\n- First.\n")
        XCTAssertEqual(doc.versions.count, 1)
        XCTAssertEqual(doc.versions[0].version, "1.0.0")
        XCTAssertNil(doc.versions[0].date)
        XCTAssertEqual(doc.versions[0].title, "1.0.0")
    }

    func testBundledChangelogParsesWhenPresent() {
        // Local `xcodebuild test` may or may not copy Resources into the
        // test host the same way a release build does. Prefer the repo file
        // so the gate is about the document shape, not the copy phase.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repo
        let url = root.appendingPathComponent("CHANGELOG.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("CHANGELOG.md missing at \(url.path)")
            return
        }
        let doc = Changelog.parse(text)
        XCTAssertFalse(doc.versions.isEmpty)
        XCTAssertFalse(doc.versions[0].version.isEmpty)
        XCTAssertFalse(doc.versions[0].sections.isEmpty)
    }
}
