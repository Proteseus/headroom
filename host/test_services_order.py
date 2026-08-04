import unittest

import sources_config


class IntegrationsOrderTests(unittest.TestCase):
    def setUp(self):
        sources_config.reset_for_tests()
        # Other tests in this HOME may have pinned integrations_order on disk;
        # reset only drops the cache.
        sources_config.set_integrations_order(
            list(sources_config.INTEGRATION_CATALOG_IDS))

    def test_default_matches_catalog(self):
        self.assertEqual(
            sources_config.integrations_order_ids(),
            list(sources_config.INTEGRATION_CATALOG_IDS),
        )

    def test_pin_and_normalize(self):
        stored = sources_config.set_integrations_order(
            ["builds", "servers", "nope", "builds", "supabase", "git"])
        self.assertEqual(stored[0], "builds")
        self.assertEqual(stored[1], "servers")
        self.assertEqual(stored[2], "supabase")
        self.assertEqual(stored[3], "git")
        self.assertEqual(
            set(stored), set(sources_config.INTEGRATION_CATALOG_IDS))

    def test_activity_blocks_are_a_filter(self):
        sources_config.set_integrations_order(
            ["openrouter", "builds", "git", "supabase"])
        # Missing catalog ids are appended; Activity is a stable filter of
        # the full pin, not a truncated pin.
        self.assertEqual(
            sources_config.services_order_ids()[:4],
            ["openrouter", "builds", "git", "supabase"],
        )
        self.assertEqual(
            set(sources_config.services_order_ids()),
            set(sources_config.ACTIVITY_BLOCK_IDS),
        )

    def test_source_id_for_watch(self):
        self.assertEqual(sources_config.source_id_for_watch("servers"), "local")
        self.assertEqual(sources_config.source_id_for_watch("builds"), "local")
        self.assertEqual(sources_config.source_id_for_watch("git"), "git")

    def test_shared_prefs_round_trip(self):
        import shared_prefs
        sources_config.set_integrations_order(
            ["posthog", "git", "supabase"])
        prefs = shared_prefs.read()
        self.assertEqual(
            prefs[shared_prefs.INTEGRATIONS_ORDER_KEY][0], "posthog")
        shared_prefs.apply({
            shared_prefs.INTEGRATIONS_ORDER_KEY: [
                "servers", "builds", "git", "vercel",
            ],
        })
        self.assertEqual(
            sources_config.integrations_order_ids()[0], "servers")


if __name__ == "__main__":
    unittest.main()
