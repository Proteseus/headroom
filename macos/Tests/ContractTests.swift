import XCTest
@testable import HeadroomBar

/// Decodes the same fixture the Python side checks, through the real models.
/// A renamed host key shows up here as a nil field rather than as a blank row
/// someone notices weeks later. The Python half is host/test_contract.py.
final class ContractTests: XCTestCase {

    /// docs/demo_usage.json, located relative to this source file so the
    /// fixture doesn't have to be copied into the test bundle.
    private func demoFixtureURL() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repo root
        let url = repoRoot
            .appendingPathComponent("docs")
            .appendingPathComponent("demo_usage.json")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "docs/demo_usage.json not found at \(url.path)")
        return url
    }

    private func decodeDemo() throws -> UsageSnapshot {
        let data = try Data(contentsOf: try demoFixtureURL())
        return try JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func testDemoFixtureDecodesEveryTopLevelSection() throws {
        let snapshot = try decodeDemo()

        XCTAssertNotNil(snapshot.updated, "updated")
        XCTAssertNotNil(snapshot.plan, "plan")
        XCTAssertEqual(snapshot.quotaOK, true)
        XCTAssertNotNil(snapshot.sessionPct, "session_pct")
        XCTAssertNotNil(snapshot.weekPct, "week_pct")
        XCTAssertNotNil(snapshot.today, "today")
        XCTAssertNotNil(snapshot.byDay, "by_day")
        XCTAssertNotNil(snapshot.providers, "providers")
        XCTAssertEqual(snapshot.providers?.count, 3)
        XCTAssertEqual(
            snapshot.activeQuotaProviders.map(\.rawValue),
            ["claude", "codex", "cursor"])
        XCTAssertNotNil(snapshot.codex, "codex")
        XCTAssertNotNil(snapshot.cursor, "cursor")
        XCTAssertNotNil(snapshot.vercel, "vercel")
        XCTAssertNotNil(snapshot.git, "git")
        XCTAssertNotNil(snapshot.local, "local")
        XCTAssertNotNil(snapshot.sources, "sources")
        XCTAssertNotNil(snapshot.attention, "attention")
    }

    func testEveryProviderMeterResolves() throws {
        let snapshot = try decodeDemo()
        for provider in snapshot.activeQuotaProviders {
            let meter = snapshot.meter(for: provider)
            XCTAssertTrue(meter.ok, "\(provider.title) should be ok in the fixture")
            XCTAssertNotNil(
                meter.headline.percent,
                "\(provider.title) headline percent decoded as nil — the host "
                + "key it reads was probably renamed")
        }
    }

    func testCodexResetCreditsSurfaceOnTheMeter() throws {
        let snapshot = try decodeDemo()
        XCTAssertEqual(snapshot.codex?.resetCreditsAvailable, 2)
        XCTAssertEqual(
            snapshot.codex?.resetCreditsExpiries,
            ["6d 5h", "18d 3h"]
        )
        let meter = snapshot.meter(for: .codex)
        XCTAssertEqual(meter.resetCreditsLabel, "2 reset credits")
        XCTAssertEqual(meter.resetCreditsExpiryLabel, "6d 5h · 18d 3h")
    }

    func testSourcesCarryTheFieldsSettingsRenders() throws {
        let snapshot = try decodeDemo()
        let sources = try XCTUnwrap(snapshot.sources)
        XCTAssertFalse(sources.isEmpty)
        for source in sources {
            XCTAssertFalse(source.id.isEmpty)
            XCTAssertNotNil(source.title, "\(source.id) title")
            XCTAssertNotNil(source.kind, "\(source.id) kind")
        }
        XCTAssertEqual(
            sources.filter { $0.kind == "quota" }.map(\.id),
            ["claude", "codex", "cursor"])
    }

    func testDisabledQuotaProviderIsHidden() throws {
        var snapshot = try decodeDemo()
        snapshot.sources = snapshot.sources?.map { source in
            var row = source
            if row.id == "cursor" { row.enabled = false }
            return row
        }
        XCTAssertEqual(
            snapshot.activeQuotaProviders.map(\.rawValue),
            ["claude", "codex"])
    }

    func testHealthReportDecodesTheHostShape() throws {
        let json = """
        {
          "ok": true,
          "uptime_s": 128,
          "updated": "2026-07-25T14:32:00+0200",
          "built_age_s": 3,
          "sources": {
            "claude": {"ok": true, "stale": false, "enabled": true,
                       "age_s": 2, "error": null, "detail": "Max 5x · week 63%"},
            "github": {"ok": false, "stale": false, "enabled": true,
                       "age_s": null, "error": "not connected", "detail": null}
          }
        }
        """
        let report = try JSONDecoder().decode(
            HealthReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.ok, true)
        XCTAssertEqual(report.uptimeS, 128)
        XCTAssertEqual(report.sources["claude"]?.ageS, 2)
        XCTAssertEqual(report.sources["github"]?.error, "not connected")
        XCTAssertNil(report.sources["github"]?.ageS)
    }

    func testClientDerivesEndpointsFromTheUsageURL() {
        let client = HeadroomClient(
            endpoint: "http://mz-mbp.local:8737/usage", token: "abc")
        XCTAssertEqual(client.token, "abc")
        XCTAssertEqual(client.endpoint, "http://mz-mbp.local:8737/usage")
    }

    func testLoopbackSkipsHostKeychain() {
        XCTAssertTrue(HeadroomClient.isLoopback("http://127.0.0.1:8737/usage"))
        XCTAssertTrue(HeadroomClient.isLoopback("http://localhost:8737/usage"))
        XCTAssertFalse(HeadroomClient.isLoopback("http://mz-mbp.local:8737/usage"))
        // Must not call TokenStore.host.read() — a wedged keychain freezes UI.
        let client = HeadroomClient(endpoint: "http://127.0.0.1:8737/usage")
        XCTAssertNil(client.token)
    }
}
