import XCTest
@testable import Headroom

/// Decodes the same fixture the Python side checks, through the real models.
/// A renamed host key shows up here as a nil field rather than as a blank row
/// someone notices weeks later. The Python half is host/test_contract.py.
final class ContractTests: XCTestCase {

    func testProviderIconsCoverEveryQuotaSourceAndNamedAccounts() {
        let expectedAssets = [
            "claude": "ProviderClaude",
            "codex": "ProviderCodex",
            "cursor": "ProviderCursor",
            "copilot": "ProviderCopilot",
            "gemini": "ProviderGemini",
            "windsurf": "ProviderWindsurf",
            "jetbrains": "ProviderJetBrains",
            "zed": "ProviderZed",
        ]

        for (providerID, assetName) in expectedAssets {
            XCTAssertEqual(ProviderIcon.assetName(for: providerID), assetName)
            XCTAssertEqual(
                ProviderIcon.assetName(for: "\(providerID):work"),
                assetName
            )
        }
        XCTAssertNil(ProviderIcon.assetName(for: "unknown"))
    }

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
        XCTAssertGreaterThanOrEqual(snapshot.providers?.count ?? 0, 1)
        XCTAssertEqual(
            Set(snapshot.providers?.map(\.id) ?? []),
            Set(snapshot.activeQuotaProviders.map(\.rawValue)))
        XCTAssertEqual(
            snapshot.activeQuotaProviders.map(\.rawValue),
            ["claude", "codex", "cursor"])
        XCTAssertEqual(
            snapshot.visibleQuotaProviders.map(\.id),
            ["claude", "codex", "cursor"])
        XCTAssertNotNil(snapshot.codex, "codex")
        XCTAssertNotNil(snapshot.cursor, "cursor")
        XCTAssertNotNil(snapshot.vercel, "vercel")
        XCTAssertNotNil(snapshot.git, "git")
        XCTAssertNotNil(snapshot.local, "local")
        XCTAssertNotNil(snapshot.plausible, "plausible")
        XCTAssertEqual(snapshot.plausible?.sites?.count, 2)
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
        XCTAssertEqual(
            snapshot.codex?.resetCreditsExpireAt,
            [1785330000, 1786359600]
        )
        let meter = snapshot.meter(for: .codex)
        XCTAssertEqual(meter.resetCreditsLabel, "2 reset credits")
        XCTAssertEqual(meter.resetCreditsExpiryLabel, "6d 5h · 18d 3h")
    }

    func testSourceRowsCarryTheBrandAccentSettingsPaintsWith() throws {
        let snapshot = try decodeDemo()
        let sources = try XCTUnwrap(snapshot.sources)
        let claude = try XCTUnwrap(sources.first { $0.id == "claude" })
        XCTAssertEqual(claude.accent, "#D97757")
        // Same hex the rings and the firmware palette use — one source.
        XCTAssertEqual(
            claude.accent,
            snapshot.providers?.first { $0.id == "claude" }?.accent)
        // Rows with no brand fall back to the status color, so nil is fine.
        XCTAssertNil(sources.first { $0.id == "git" }?.accent)
    }

    func testFocusPicksTheProvidersTheHostChose() throws {
        var snapshot = try decodeDemo()
        XCTAssertEqual(snapshot.focus, ["claude", "codex", "cursor"])
        XCTAssertEqual(
            snapshot.focusProviders().map(\.id), ["claude", "codex", "cursor"])
        XCTAssertEqual(snapshot.providers?.first?.rank, 0)

        snapshot.focus = ["cursor", "claude"]
        XCTAssertEqual(snapshot.focusProviders().map(\.id), ["cursor", "claude"])

        // Never more than the compact surfaces can draw.
        snapshot.focus = ["cursor", "claude", "codex", "claude"]
        XCTAssertEqual(snapshot.focusProviders().count, 3)
    }

    func testFocusFallsBackWhenTheHostIsOlderOrTheIDsAreStale() throws {
        var snapshot = try decodeDemo()
        snapshot.focus = nil
        XCTAssertEqual(
            snapshot.focusProviders().map(\.id), ["claude", "codex", "cursor"])

        // Every focus id unresolvable between polls — show something.
        snapshot.focus = ["nope", "gone"]
        XCTAssertFalse(snapshot.focusProviders().isEmpty)
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
        let github = try XCTUnwrap(sources.first { $0.id == "github" })
        XCTAssertEqual(github.title, HeadroomCopy.githubActions)
    }

    func testSourcesSplitIntoAIAndDevToolSections() throws {
        let snapshot = try decodeDemo()
        let sources = try XCTUnwrap(snapshot.sources)
        let grouped = sources.groupedBySourceGroup()
        XCTAssertEqual(grouped.map(\.group), [.ai, .devtools])
        XCTAssertEqual(
            grouped.first { $0.group == .ai }?.sources.map(\.id),
            ["claude", "codex", "cursor", "claude-status"])
        let ai = try XCTUnwrap(grouped.first { $0.group == .ai })
        XCTAssertEqual(
            ai.sources.first { $0.id == "claude-status" }?.kind, "activity")
        let devtools = try XCTUnwrap(grouped.first { $0.group == .devtools })
        XCTAssertTrue(devtools.sources.contains { $0.id == "plausible" })
        XCTAssertFalse(devtools.sources.contains { $0.kind == "quota" })
    }

    func testSourceGroupFallsBackToKindOnOlderHosts() {
        // Hosts before the split only sent `kind`; quota meant a coding tool.
        XCTAssertEqual(SourceGroup(group: nil, kind: "quota"), .ai)
        XCTAssertEqual(SourceGroup(group: nil, kind: "activity"), .devtools)
        XCTAssertEqual(SourceGroup(group: "devtools", kind: "quota"), .devtools)
    }

    func testHeadroomCopyMatchesGlossaryTerms() {
        XCTAssertEqual(HeadroomCopy.dailyBurn, "Daily burn")
        XCTAssertEqual(HeadroomCopy.overallBurndown, "Overall burndown")
        XCTAssertEqual(HeadroomCopy.burndown, "Burndown")
        XCTAssertEqual(HeadroomCopy.activity, "Activity")
        XCTAssertEqual(HeadroomCopy.services, "Services")
        XCTAssertEqual(HeadroomCopy.codingQuotas, "Coding quotas")
        XCTAssertEqual(HeadroomCopy.allClear, "All clear")
        XCTAssertEqual(HeadroomCopy.connected, "Connected")
        XCTAssertEqual(HeadroomCopy.macUnavailable, "Mac unavailable")
        XCTAssertEqual(HeadroomCopy.collectingHistory, "Collecting history")
        XCTAssertEqual(HeadroomCopy.overallBurndownSubtitle, "7 days")
        XCTAssertEqual(HeadroomCopy.dailyBurnUnit, "pts / day")
        XCTAssertEqual(HeadroomCopy.noHistoryYet, "No history yet")
        XCTAssertEqual(HeadroomCopy.noCodingSources, "No coding sources")
        XCTAssertEqual(HeadroomCopy.clearAttention, "Clear")
        XCTAssertEqual(HeadroomCopy.githubActions, "GitHub Actions")
        XCTAssertEqual(HeadroomCopy.openAtLogin, "Open at Login")
        XCTAssertEqual(HeadroomCopy.poolBurndown("Weekly"), "Weekly burndown")
        XCTAssertEqual(HeadroomCopy.resets("3d"), "Resets 3d")
    }

    func testDisabledQuotaProviderIsHidden() throws {
        var snapshot = try decodeDemo()
        snapshot.sources = snapshot.sources?.map { source in
            var row = source
            if row.id == "cursor" { row.enabled = false }
            return row
        }
        snapshot.providers = snapshot.providers?.map { row in
            var provider = row
            if provider.id == "cursor" { provider.enabled = false }
            return provider
        }
        XCTAssertEqual(
            snapshot.activeQuotaProviders.map(\.rawValue),
            ["claude", "codex"])
        XCTAssertEqual(
            snapshot.visibleQuotaProviders.map(\.id),
            ["claude", "codex"])
    }

    func testEmptyQuotaSourcesYieldNoActiveProviders() throws {
        var snapshot = try decodeDemo()
        snapshot.sources = snapshot.sources?.map { source in
            var row = source
            if row.kind == "quota" { row.enabled = false }
            return row
        }
        // Even if providers[] still advertise enabled (stale), sources win.
        XCTAssertTrue(snapshot.activeQuotaProviders.isEmpty)
        XCTAssertTrue(snapshot.visibleQuotaProviders.isEmpty)

        snapshot.providers = snapshot.providers?.map { row in
            var provider = row
            provider.enabled = false
            return provider
        }
        XCTAssertTrue(snapshot.visibleQuotaProviders.isEmpty)
    }

    func testProvidersOnlyPayloadUsesEnabledFlags() throws {
        let json = """
        {
          "providers": [
            {"id": "claude", "kind": "quota", "enabled": true},
            {"id": "codex", "kind": "quota", "enabled": false},
            {"id": "gemini", "title": "Gemini", "kind": "quota", "enabled": true,
             "ok": true, "headline": "week",
             "pools": {
               "week": {"title": "Weekly", "pct": 20.0, "ring": true}
             }}
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(
            UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(
            snapshot.visibleQuotaProviders.map(\.id),
            ["claude", "gemini"])
        // Known-enum helper still lists only branded ids.
        XCTAssertEqual(
            snapshot.activeQuotaProviders.map(\.rawValue),
            ["claude"])
        // Mac surfaces use visibleQuotaProviders — unknown ids still meter.
        let gemini = snapshot.meter(forProviderID: "gemini")
        XCTAssertEqual(gemini.title, "Gemini")
        XCTAssertEqual(gemini.primary.percent, 20)
        XCTAssertEqual(
            DashboardSelection.tabs(for: snapshot.visibleQuotaProviders),
            ["overview", "claude", "gemini"])
    }

    func testAReplayedProviderSaysSoDespiteBeingOK() throws {
        // The host keeps ok=true on a replay — the numbers were real once —
        // so `stale` is the only thing standing between a frozen meter and a
        // surface that draws it as live.
        let json = """
        {
          "providers": [
            {"id": "claude", "title": "Claude", "kind": "quota",
             "enabled": true, "ok": true, "stale": true,
             "stale_for_s": 7200, "headline": "week",
             "pools": {
               "week": {"title": "Weekly", "pct": 35.0, "ring": true}
             }},
            {"id": "codex", "title": "Codex", "kind": "quota",
             "enabled": true, "ok": true,
             "pools": {
               "week": {"title": "Weekly", "pct": 12.0, "ring": true}
             }}
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(
            UsageSnapshot.self, from: Data(json.utf8))
        let claude = try XCTUnwrap(
            snapshot.providers?.first { $0.id == "claude" })
        XCTAssertEqual(claude.ok, true)
        XCTAssertTrue(claude.isStale)
        XCTAssertFalse(claude.needsSignIn)
        XCTAssertEqual(claude.statusNote, "Not updating · 2 hours ago")
        XCTAssertEqual(snapshot.meter(for: claude).statusNote, claude.statusNote)

        let codex = try XCTUnwrap(
            snapshot.providers?.first { $0.id == "codex" })
        XCTAssertFalse(codex.isStale)
        XCTAssertNil(codex.statusNote)
        XCTAssertNil(snapshot.meter(for: codex).statusNote)
    }

    func testADeadLoginSaysSignInRatherThanNotUpdating() throws {
        // The failure that sent us here: `ok` true, bars replayed, and the one
        // string naming the fix suppressed because nothing looked wrong. Both
        // flags are set on the wire, and the sign-in wording has to win —
        // "Not updating" reads as a hiccup to wait out, and this one never
        // clears on its own.
        let json = """
        {
          "providers": [
            {"id": "claude", "title": "Claude", "kind": "quota",
             "enabled": true, "ok": true, "stale": true,
             "auth_required": true, "stale_for_s": 41896,
             "error": "keychain has no claudeAiOauth.accessToken",
             "headline": "week",
             "pools": {
               "week": {"title": "Weekly", "pct": 53.0, "ring": true}
             }}
          ],
          "sources": [
            {"id": "claude", "title": "Claude", "kind": "quota",
             "enabled": true, "ok": true, "stale": true,
             "auth_required": true}
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(
            UsageSnapshot.self, from: Data(json.utf8))
        let claude = try XCTUnwrap(snapshot.providers?.first)
        XCTAssertEqual(claude.ok, true)
        XCTAssertTrue(claude.isStale)
        XCTAssertTrue(claude.needsSignIn)
        XCTAssertTrue(claude.readingSuspect)
        XCTAssertEqual(claude.statusNote, "Needs sign-in · 12 hours ago")

        let meter = snapshot.meter(for: claude)
        XCTAssertTrue(meter.needsSignIn)
        XCTAssertEqual(meter.statusNote, claude.statusNote)
        // The card draws this whenever it is non-nil now, so the reason
        // reaches the reader while `ok` is still true.
        XCTAssertEqual(meter.error, "keychain has no claudeAiOauth.accessToken")

        let row = try XCTUnwrap(snapshot.sources?.first)
        XCTAssertTrue(row.needsSignIn)
    }

    func testAProviderThatNeverFetchedStillAsksForSignIn() throws {
        // No snapshot to replay, so nothing is stale and there is no age to
        // report — the card is empty and still owes a reason.
        let json = """
        {"providers": [{"id": "claude", "kind": "quota", "ok": false,
                        "auth_required": true}]}
        """
        let snapshot = try JSONDecoder().decode(
            UsageSnapshot.self, from: Data(json.utf8))
        let claude = try XCTUnwrap(snapshot.providers?.first)
        XCTAssertFalse(claude.isStale)
        XCTAssertTrue(claude.needsSignIn)
        XCTAssertTrue(claude.readingSuspect)
        XCTAssertEqual(claude.statusNote, "Needs sign-in")
    }

    func testAHostWithoutTheStaleFieldReadsAsFetching() throws {
        // Older hosts never send it; absent must not mean frozen.
        let json = """
        {"providers": [{"id": "claude", "kind": "quota", "ok": true}]}
        """
        let snapshot = try JSONDecoder().decode(
            UsageSnapshot.self, from: Data(json.utf8))
        let claude = try XCTUnwrap(snapshot.providers?.first)
        XCTAssertFalse(claude.isStale)
        XCTAssertFalse(claude.needsSignIn)
        XCTAssertNil(claude.statusNote)
    }

    func testMissingProvidersAndSourcesYieldEmptyActiveSet() throws {
        let snapshot = UsageSnapshot.empty
        XCTAssertTrue(snapshot.visibleQuotaProviders.isEmpty)
        XCTAssertTrue(snapshot.activeQuotaProviders.isEmpty)
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
