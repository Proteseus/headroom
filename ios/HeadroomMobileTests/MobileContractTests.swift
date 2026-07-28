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

        let snapshot = try JSONDecoder().decode(MobileUsageSnapshot.self, from: data)
        XCTAssertEqual(snapshot.providers?.first?.id, "codex")
        XCTAssertEqual(snapshot.providers?.first?.visiblePools.first?.pct, 42)
        XCTAssertEqual(snapshot.attention?.needsAttention, false)
    }

    func testNormalizesBareMacHost() {
        XCTAssertEqual(
            MobileConnection.normalize("studio-mac.local"),
            "http://studio-mac.local:8737/usage"
        )
    }
}
