import XCTest
@testable import HeadroomBar

final class ModelsTests: XCTestCase {
    func testDecodesBackendShape() throws {
        let json = """
        {
          "updated": "2026-07-23T10:00:00+0200",
          "plan": "Max",
          "quota_ok": true,
          "session_pct": 22.0,
          "session_pace_pct": 18.0,
          "session_resets_in": "1h",
          "week_pct": 31.0,
          "week_pace_pct": 26.0,
          "week_resets_in": "4d",
          "today": {"total": 1234, "cost_usd": 4.25},
          "codex": {
            "ok": true,
            "plan": "Team",
            "session_pct": 41.0,
            "session_pace_pct": 20.0,
            "session_resets_in": "2h",
            "week_pct": 72.0,
            "week_pace_pct": 55.0,
            "week_resets_in": "3d"
          },
          "cursor": {
            "ok": true,
            "plan": "Pro",
            "total_pct": 4.0,
            "total_pace_pct": 28.0,
            "auto_pct": 0.0,
            "auto_pace_pct": 28.0,
            "api_pct": 34.0,
            "api_pace_pct": 28.0,
            "resets_in": "7d 43m"
          },
          "vercel": {
            "ok": true,
            "team": "ev-io",
            "deployments": [
              {"project": "signals", "status": "ready", "ago": "2m"}
            ]
          },
          "git": {"ok": true, "commits": []},
          "local": {
            "ok": true,
            "host": "mac",
            "servers": [{"name": "web", "port": 3000, "pid": 4242}]
          }
        }
        """.data(using: .utf8)!

        let value = try JSONDecoder().decode(UsageSnapshot.self, from: json)

        XCTAssertEqual(value.codex?.sessionPct, 41)
        XCTAssertEqual(value.codex?.weekPct, 72)
        XCTAssertEqual(value.meter(for: .claude).primary.percent, 22)
        XCTAssertEqual(value.meter(for: .claude).secondary.percent, 31)
        XCTAssertEqual(value.meter(for: .codex).primary.title, "Session")
        XCTAssertEqual(value.meter(for: .cursor).primary.percent, 4)
        XCTAssertEqual(value.meter(for: .cursor).primary.title, "Total")
        XCTAssertEqual(value.meter(for: .cursor).secondary.title, "Auto")
        XCTAssertEqual(value.meter(for: .cursor).tertiary?.title, "API")
        XCTAssertEqual(value.vercel?.deployments?.first?.project, "signals")
        XCTAssertEqual(value.local?.servers?.first?.port, 3000)
        XCTAssertEqual(value.local?.servers?.first?.pid, 4242)
        XCTAssertEqual(value.today?.costUSD, 4.25)
    }
}
