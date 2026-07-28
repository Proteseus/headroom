import XCTest
@testable import HeadroomMobile

final class MobileContractTests: XCTestCase {
    func testDecodesRegistryDrivenQuotaPayload() throws {
        let data = Data(
            """
            {
              "updated": "2026-07-28T12:00:00Z",
              "providers": [{
                "id": "codex",
                "title": "Codex",
                "enabled": true,
                "ok": true,
                "accent": "#00aaff",
                "pools": {
                  "session": {
                    "title": "Session",
                    "pct": 42,
                    "pace_pct": 35,
                    "resets_in": "2h",
                    "ring": true
                  }
                }
              }],
              "attention": {"level": "ok", "reasons": []}
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(snapshot.providers?.first?.id, "codex")
        XCTAssertEqual(snapshot.providers?.first?.visiblePools.first?.pool.pct, 42)
        XCTAssertEqual(snapshot.attention?.isWarning, false)
    }

    func testNormalizesBareMacHost() {
        XCTAssertEqual(
            MobileConnection.normalize("studio-mac.local"),
            "http://studio-mac.local:8737/usage"
        )
    }

    func testHeadroomCopyMatchesGlossaryTerms() {
        XCTAssertEqual(HeadroomCopy.dailyBurn, "Daily burn")
        XCTAssertEqual(HeadroomCopy.overallBurndown, "Overall burndown")
        XCTAssertEqual(HeadroomCopy.activity, "Activity")
        XCTAssertEqual(HeadroomCopy.services, "Services")
        XCTAssertEqual(HeadroomCopy.allClear, "All clear")
        XCTAssertEqual(HeadroomCopy.connected, "Connected")
        XCTAssertEqual(HeadroomCopy.macUnavailable, "Mac unavailable")
        XCTAssertEqual(HeadroomCopy.noHistoryYet, "No history yet")
        XCTAssertEqual(HeadroomCopy.clearAttention, "Clear")
        XCTAssertEqual(HeadroomCopy.githubActions, "GitHub Actions")
    }
}
