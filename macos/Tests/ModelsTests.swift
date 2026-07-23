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
          "by_day": [
            {"date": "2026-07-22", "claude": 2.0, "codex": 1.5, "cursor": 0.5, "total": 4.0},
            {"date": "2026-07-23", "claude": 3.5, "codex": 2.0, "cursor": 0.25, "total": 5.75}
          ],
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
          "activity": [{
            "id": "dpl_1",
            "kind": "deployment",
            "status": "error",
            "subject": "Fix checkout",
            "repo": "store",
            "project": "store-web",
            "branch": "main",
            "short_sha": "abc1234",
            "ago": "2m",
            "error_message": "Build failed",
            "inspector_url": "https://vercel.com/example"
          }],
          "supabase": {
            "ok": true,
            "configured": true,
            "project_count": 2,
            "healthy_count": 1,
            "alert_count": 1,
            "projects": [{
              "ref": "project-ref",
              "name": "Production DB",
              "region": "eu-west-1",
              "status": "ACTIVE_HEALTHY",
              "healthy": false,
              "unhealthy_services": ["storage"],
              "services": [{
                "name": "storage",
                "status": "unhealthy",
                "healthy": false
              }],
              "dashboard_url": "https://supabase.com/dashboard/project/project-ref"
            }]
          },
          "local": {
            "ok": true,
            "host": "mac",
            "servers": [{
              "name": "web",
              "port": 3000,
              "pid": 4242,
              "reachable": true,
              "latency_ms": 2
            }]
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
        XCTAssertEqual(value.local?.servers?.first?.latencyMS, 2)
        XCTAssertEqual(value.activity?.first?.status, "error")
        XCTAssertEqual(value.activity?.first?.shortSHA, "abc1234")
        XCTAssertEqual(value.supabase?.alertCount, 1)
        XCTAssertEqual(value.supabase?.projects?.first?.ref, "project-ref")
        XCTAssertEqual(
            value.supabase?.projects?.first?.unhealthyServices,
            ["storage"]
        )
        XCTAssertEqual(value.today?.costUSD, 4.25)
        XCTAssertEqual(value.byDay?.count, 2)
        XCTAssertEqual(value.byDay?.last?.total, 5.75)
        XCTAssertEqual(value.byDay?.last?.burn(for: .claude), 3.5)
    }
}
