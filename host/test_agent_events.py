"""Durability and concurrency tests for coding-agent attention events."""

import os
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

    def respond(self, event, action):
        self.responses.append((event["id"], action))


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
        gateway.codex = adapter
        gateway.adapters = {"codex": adapter}
        result = gateway.respond(
            event["id"],
            revision=event["revision"],
            action="approve_once",
            idempotency_key="phone-tap-1",
        )
        self.assertEqual(adapter.responses, [(event["id"], "approve_once")])
        self.assertEqual(result["event"]["state"], "responding")


if __name__ == "__main__":
    unittest.main()
