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

    /// The phone used to decode four fields of a request and drop the rest,
    /// which made an Edit approval read as "Use Edit". Pin the whole shape.
    func testDecodesWholeAgentRequestNotJustTheCommand() throws {
        let data = Data(
            """
            {
              "ok": true,
              "events": [{
                "id": "evt_1",
                "provider": "claude-code",
                "adapter": "claude-http-hooks",
                "session_id": "s1",
                "kind": "permission_approval",
                "state": "pending",
                "revision": 1,
                "title": "Claude needs permission in acme",
                "summary": "Edit /tmp/acme/app.ts",
                "detail": {
                  "tool_name": "Edit",
                  "reasons": ["Destructive operation"],
                  "request": [
                    {"key": "file_path", "label": "File", "kind": "path",
                     "value": "/tmp/acme/app.ts", "truncated": false},
                    {"key": "old_string", "label": "Replacing", "kind": "code",
                     "value": "const port = 3000", "truncated": false},
                    {"key": "new_string", "label": "With", "kind": "code",
                     "value": "const port = 8080", "truncated": true,
                     "full_chars": 9000, "omitted_fields": 2}
                  ]
                },
                "actions": [{"id": "decline", "label": "Deny", "risk": "safe"}],
                "created_at_ms": 1,
                "updated_at_ms": 2
              }]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(
            AgentAttentionEventsResponse.self, from: data)
        let detail = try XCTUnwrap(response.events.first).detail
        XCTAssertEqual(detail.toolName, "Edit")
        XCTAssertEqual(detail.reasons, ["Destructive operation"])
        XCTAssertEqual(detail.requestFields.count, 3)
        XCTAssertEqual(detail.requestFields[1].value, "const port = 3000")
        XCTAssertEqual(detail.requestFields[2].kind, "code")
        XCTAssertTrue(detail.requestFields[2].wasTruncated)
        XCTAssertEqual(detail.requestFields[2].fullChars, 9000)
        XCTAssertEqual(detail.requestFields[2].omittedFields, 2)
    }

    /// The row shows how long the agent has been waiting, in the same words
    /// an activity row uses.
    func testAgentEventAgeReadsFromCreatedAt() throws {
        let sixMinutesAgo = Int64((Date().timeIntervalSince1970 - 360) * 1000)
        let data = Data(
            """
            {"ok": true, "events": [{
              "id": "evt_1", "provider": "claude-code",
              "adapter": "claude-http-hooks", "session_id": "s1",
              "kind": "permission_approval", "state": "pending", "revision": 1,
              "title": "t", "summary": "s", "detail": {}, "actions": [],
              "created_at_ms": \(sixMinutesAgo), "updated_at_ms": \(sixMinutesAgo)
            }]}
            """.utf8
        )
        let event = try XCTUnwrap(
            try JSONDecoder().decode(
                AgentAttentionEventsResponse.self, from: data).events.first)
        XCTAssertEqual(event.age, 360, accuracy: 5)
        XCTAssertEqual(HeadroomCopy.ago(event.age), "6 min ago")
    }

    /// Codex still sends a bare `command`; it must render through the same
    /// accessor so views never branch on provider.
    func testBareCommandDetailStillProducesARequestField() throws {
        let data = Data(#"{"command": "npm test", "cwd": "/tmp"}"#.utf8)
        let detail = try JSONDecoder().decode(
            AgentAttentionDetail.self, from: data)
        XCTAssertEqual(detail.requestFields.count, 1)
        XCTAssertEqual(detail.requestFields.first?.kind, "command")
        XCTAssertEqual(detail.requestFields.first?.value, "npm test")
    }

    func testNormalizesBareMacHost() {
        XCTAssertEqual(
            MobileConnection.normalize("studio-mac.local"),
            "http://studio-mac.local:8737/usage"
        )
    }

    func testIdentityLabelPrefersDistinctMachineName() {
        UserDefaults.standard.set(
            "http://studio-mac.local:8737/usage",
            forKey: MobileConnection.endpointKey
        )
        defer {
            UserDefaults.standard.removeObject(forKey: MobileConnection.endpointKey)
        }
        XCTAssertEqual(
            MobileConnection.identityLabel(machineName: "Studio"),
            "Studio · studio-mac.local"
        )
        XCTAssertEqual(
            MobileConnection.identityLabel(machineName: "studio-mac"),
            "studio-mac.local"
        )
        XCTAssertEqual(
            MobileConnection.identityLabel(machineName: nil),
            "studio-mac.local"
        )
    }

    /// Attention and Activity are a partition of one feed, not two filters
    /// that happen to agree. Every row lands on exactly one tab, and the
    /// failing ones land on Attention — the tab bar's badge counts the same
    /// call, so a disagreement here is a row nobody can reach.
    func testAttentionAndActivitySplitTheFeedExactlyOnce() throws {
        let data = Data(
            """
            {
              "activity": [
                {"id": "a1", "status": "failure", "subject": "Release"},
                {"id": "a2", "status": "ready", "subject": "Deploy"},
                {"id": "a3", "status": "pushed", "subject": "Push"},
                {"id": "a4", "status": "error", "subject": "Tests"}
              ]
            }
            """.utf8
        )
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        let failing = AttentionScreen.failures(in: snapshot)
        let rest = (snapshot.activity ?? []).filter {
            !ActivityStatusStyle.resolve($0.status).needsAttention
        }
        XCTAssertEqual(failing.map(\.id), ["a1", "a4"])
        XCTAssertEqual(failing.count + rest.count, snapshot.activity?.count)
        XCTAssertTrue(Set(failing.map(\.id)).isDisjoint(with: rest.map(\.id)))
    }

    /// Tab order is the reading order the split exists for: what is going on,
    /// what wants you, what happened.
    func testTabsRunSummaryThenQueueThenLog() {
        XCTAssertEqual(
            MobileTab.allCases.map(\.rawValue),
            ["overview", "attention", "activity"]
        )
    }

    func testHeadroomCopyMatchesGlossaryTerms() {
        XCTAssertEqual(HeadroomCopy.dailyBurn, "Daily burn")
        XCTAssertEqual(HeadroomCopy.overallBurndown, "Overall burndown")
        XCTAssertEqual(HeadroomCopy.activity, "Activity")
        XCTAssertEqual(HeadroomCopy.attention, "Attention")
        XCTAssertEqual(HeadroomCopy.recentActivity, "Recent")
        XCTAssertEqual(HeadroomCopy.services, "Services")
        XCTAssertEqual(HeadroomCopy.allClear, "All clear")
        XCTAssertEqual(HeadroomCopy.connected, "Connected")
        XCTAssertEqual(HeadroomCopy.macUnavailable, "Mac unavailable")
        XCTAssertEqual(HeadroomCopy.noHistoryYet, "No history yet")
        XCTAssertEqual(HeadroomCopy.clearAttention, "Clear")
        XCTAssertEqual(HeadroomCopy.githubActions, "GitHub Actions")
    }
}
