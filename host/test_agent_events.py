"""Durability and concurrency tests for coding-agent attention events."""

import os
import sqlite3
import tempfile
import threading
import time
import unittest

import agent_events
import agent_gateway


ACTIONS = [
    {"id": "approve_once", "label": "Allow once", "risk": "privileged"},
    {"id": "decline", "label": "Deny", "risk": "safe"},
]


class FakeAdapter:
    def __init__(self):
        self.responses = []

    def respond(self, event, action, text=None):
        self.responses.append((event["id"], action, text))


class EventStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = agent_events.EventStore(
            os.path.join(self.tmp.name, "attention.sqlite3"))

    def tearDown(self):
        self.tmp.cleanup()

    def create(self, request_id="req-1", **values):
        fields = {
            "provider": "codex",
            "adapter": "test",
            "provider_request_id": request_id,
            "session_id": "thread-1",
            "turn_id": "turn-1",
            "item_id": "item-1",
            "kind": "command_approval",
            "title": "Approval needed",
            "summary": "Run tests",
            "actions": ACTIONS,
            "detail": {"command": "make test"},
        }
        fields.update(values)
        return self.store.create(**fields)

    def test_create_is_durable_and_provider_request_is_idempotent(self):
        first = self.create()
        second = self.create(title="A duplicate callback")
        self.assertEqual(second["id"], first["id"])
        self.assertEqual(second["title"], "Approval needed")
        reopened = agent_events.EventStore(self.store.path)
        self.assertEqual(reopened.get(first["id"])["detail"]["command"], "make test")

    def test_claim_is_compare_and_swap_guarded(self):
        event = self.create()
        claimed, duplicate = self.store.claim(
            event["id"], event["revision"], "approve_once", "tap-1")
        self.assertFalse(duplicate)
        self.assertEqual(claimed["state"], "responding")
        self.assertEqual(claimed["revision"], event["revision"] + 1)
        with self.assertRaises(agent_events.EventConflict):
            self.store.claim(
                event["id"], event["revision"], "decline", "tap-2")

    def test_idempotency_key_must_keep_the_same_action(self):
        event = self.create()
        self.store.claim(
            event["id"], event["revision"], "approve_once", "tap-1")
        _, duplicate = self.store.claim(
            event["id"], event["revision"], "approve_once", "tap-1")
        self.assertTrue(duplicate)
        with self.assertRaises(agent_events.EventConflict):
            self.store.claim(
                event["id"], event["revision"], "decline", "tap-1")

    def test_expired_claim_persists_terminal_state(self):
        event = self.create(expires_at_ms=int(time.time() * 1000) - 1)
        with self.assertRaises(agent_events.EventConflict):
            self.store.claim(
                event["id"], event["revision"], "decline", "tap-1")
        self.assertEqual(self.store.get(event["id"])["state"], "expired")

    def test_decline_becomes_terminal_after_dispatch(self):
        event = self.create()
        self.store.claim(event["id"], event["revision"], "decline", "tap-1")
        self.store.mark_dispatched(event["id"], "tap-1")
        self.assertEqual(self.store.get(event["id"])["state"], "declined")
        self.assertEqual(
            self.store.get(event["id"])["resolution"], {"action": "decline"})

    def test_open_listing_and_adapter_orphaning(self):
        event = self.create()
        self.assertEqual([event["id"]], [
            row["id"] for row in self.store.list(state="open")
        ])
        self.store.orphan_adapter("codex", "test", "connection lost")
        self.assertEqual(self.store.list(state="open"), [])
        self.assertEqual(self.store.get(event["id"])["state"], "orphaned")

    def test_gateway_dispatches_to_provider_adapter(self):
        event = self.create()
        adapter = FakeAdapter()
        gateway = agent_gateway.AgentGateway.__new__(agent_gateway.AgentGateway)
        gateway._adapter_lock = threading.Lock()
        gateway.store = self.store
        gateway.machine = {"id": "mac-studio-1", "name": "Studio"}
        gateway.codex = adapter
        gateway.adapters = {"codex": adapter}
        result = gateway.respond(
            event["id"],
            revision=event["revision"],
            action="approve_once",
            idempotency_key="phone-tap-1",
        )
        self.assertEqual(
            adapter.responses, [(event["id"], "approve_once", None)])
        self.assertEqual(result["event"]["state"], "responding")
        self.assertEqual(result["event"]["machine_id"], "mac-studio-1")
        self.assertEqual(result["event"]["machine_name"], "Studio")

    def test_events_are_owned_by_the_serving_machine(self):
        first = self.create("same-provider-request")
        first_gateway = agent_gateway.AgentGateway(
            store=self.store,
            codex=FakeAdapter(),
            claude=FakeAdapter(),
            machine={"id": "mac-studio-1", "name": "Studio"},
        )
        first_payload = first_gateway.events()["events"]
        self.assertEqual(first_payload[0]["id"], first["id"])
        self.assertEqual(first_payload[0]["machine_id"], "mac-studio-1")
        self.assertEqual(first_payload[0]["machine_name"], "Studio")

        other_tmp = tempfile.TemporaryDirectory()
        self.addCleanup(other_tmp.cleanup)
        other_store = agent_events.EventStore(
            os.path.join(other_tmp.name, "attention.sqlite3"))
        other = other_store.create(
            provider="codex", adapter="test",
            provider_request_id="same-provider-request",
            session_id="thread-1", kind="command_approval",
            title="Approval needed", summary="Run tests", actions=ACTIONS,
        )
        other_gateway = agent_gateway.AgentGateway(
            store=other_store,
            codex=FakeAdapter(),
            claude=FakeAdapter(),
            machine={"id": "mac-laptop-2", "name": "Laptop"},
        )
        other_payload = other_gateway.events()["events"]
        self.assertEqual(other_payload[0]["id"], other["id"])
        self.assertEqual(other_payload[0]["machine_id"], "mac-laptop-2")
        self.assertEqual(other_payload[0]["machine_name"], "Laptop")
        self.assertEqual(first_payload[0]["session_id"],
                         other_payload[0]["session_id"])


class RetentionTests(unittest.TestCase):
    """The ledger holds commands and code excerpts, so it has to forget."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = agent_events.EventStore(
            os.path.join(self.tmp.name, "attention.sqlite3"))

    def tearDown(self):
        self.tmp.cleanup()

    def create(self, request_id):
        return self.store.create(
            provider="codex", adapter="test",
            provider_request_id=request_id, session_id="thread-1",
            kind="command_approval", title="Approval needed",
            summary="Run tests", actions=ACTIONS,
            detail={"command": "rm -rf ~/secrets"})

    def settle(self, request_id, days_ago):
        """Resolve an event and backdate when it settled."""
        event = self.create(request_id)
        self.store.resolve(event["id"])
        connection = sqlite3.connect(self.store.path)
        try:
            connection.execute(
                "UPDATE attention_events SET updated_at_ms = ? WHERE id = ?",
                (int((time.time() - days_ago * 24 * 3600) * 1000),
                 event["id"]))
            connection.commit()
        finally:
            connection.close()
        return event

    def test_settled_events_past_the_window_are_dropped(self):
        now = time.time()
        old = self.settle("old", days_ago=90)
        recent = self.settle("recent", days_ago=1)

        self.assertEqual(self.store.prune(now=now), 1)
        with self.assertRaises(agent_events.EventNotFound):
            self.store.get(old["id"])
        self.assertIsNotNone(self.store.get(recent["id"]))

    def test_the_clock_runs_from_settlement_not_creation(self):
        # Raised in March, answered today: a record of what you approved
        # today, and it keeps a full window from then.
        now = time.time()
        event = self.store.create(
            provider="codex", adapter="test", provider_request_id="ancient",
            session_id="thread-1", kind="command_approval",
            title="Approval needed", summary="Run tests", actions=ACTIONS,
            created_at_ms=int((now - 200 * 24 * 3600) * 1000))
        self.store.resolve(event["id"])

        self.assertEqual(self.store.prune(now=now), 0)
        self.assertIsNotNone(self.store.get(event["id"]))

    def test_an_open_event_is_never_pruned_however_old(self):
        # Still pending means something is waiting on the answer; age says
        # nothing about whether it is live.
        now = time.time()
        stale = self.create("stale")
        connection = sqlite3.connect(self.store.path)
        try:
            connection.execute(
                "UPDATE attention_events SET updated_at_ms = ?",
                (int((now - 400 * 24 * 3600) * 1000),))
            connection.commit()
        finally:
            connection.close()

        self.assertEqual(self.store.prune(now=now), 0)
        self.assertIsNotNone(self.store.get(stale["id"]))

    def test_responses_go_with_the_event(self):
        now = time.time()
        event = self.create("old")
        self.store.claim(
            event["id"], event["revision"], "approve_once", "key-1")
        self.store.resolve(event["id"])
        connection = sqlite3.connect(self.store.path)
        try:
            connection.execute(
                "UPDATE attention_events SET updated_at_ms = ?",
                (int((now - 90 * 24 * 3600) * 1000),))
            connection.commit()
        finally:
            connection.close()

        self.store.prune(now=now)
        connection = sqlite3.connect(self.store.path)
        try:
            remaining = connection.execute(
                "SELECT COUNT(*) FROM attention_responses").fetchone()[0]
        finally:
            connection.close()
        self.assertEqual(remaining, 0)

    def test_pruning_a_missing_file_is_not_an_error(self):
        store = agent_events.EventStore(
            os.path.join(self.tmp.name, "nested", "gone.sqlite3"))
        self.assertEqual(store.prune(), 0)


if __name__ == "__main__":
    unittest.main()
