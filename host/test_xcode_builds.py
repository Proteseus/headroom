import unittest
from unittest.mock import patch

import xcode_builds


class EtimeTests(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(xcode_builds._parse_etime("42"), 42)
        self.assertEqual(xcode_builds._parse_etime("01:02"), 62)
        self.assertEqual(xcode_builds._parse_etime("1:02:03"), 3723)
        self.assertEqual(xcode_builds._parse_etime("2-01:02:03"), 176523)


class ArgvTests(unittest.TestCase):
    def test_scheme_and_action(self):
        args = (
            "/usr/bin/xcodebuild -project Headroom.xcodeproj "
            "-scheme Headroom -configuration Debug test"
        )
        self.assertEqual(xcode_builds._argv_flag(args, "-scheme"), "Headroom")
        self.assertEqual(
            xcode_builds._argv_flag(args, "-project"), "Headroom.xcodeproj")
        self.assertEqual(xcode_builds._xcodebuild_action(args), "test")

    def test_default_action_is_build(self):
        self.assertEqual(
            xcode_builds._xcodebuild_action("xcodebuild -scheme Foo"), "build")


class FetchBuildsTests(unittest.TestCase):
    def setUp(self):
        xcode_builds.invalidate()

    @patch("xcode_builds._cwds_for_pids", return_value={4242: "/Users/mz/Dev/headroom/macos"})
    @patch("xcode_builds._list_procs")
    def test_cli_xcodebuild_row(self, list_procs, _cwds):
        list_procs.return_value = [{
            "pid": 4242,
            "ppid": 1,
            "age_s": 38,
            "args": (
                "/usr/bin/xcodebuild -project Headroom.xcodeproj "
                "-scheme Headroom test"
            ),
        }]
        out = xcode_builds.fetch_builds(force=True)
        self.assertTrue(out["ok"])
        self.assertEqual(len(out["builds"]), 1)
        row = out["builds"][0]
        self.assertEqual(row["name"], "Headroom")
        self.assertEqual(row["kind"], "xcodebuild")
        self.assertEqual(row["action"], "test")
        self.assertEqual(row["scheme"], "Headroom")
        self.assertEqual(row["target"], "Headroom.xcodeproj")
        self.assertEqual(row["pid"], 4242)
        self.assertEqual(row["age_s"], 38)
        self.assertEqual(row["cwd"], "/Users/mz/Dev/headroom/macos")

    @patch("xcode_builds._cwds_for_pids", return_value={99: "/tmp/pkg"})
    @patch("xcode_builds._list_procs")
    def test_swift_build_row(self, list_procs, _cwds):
        list_procs.return_value = [{
            "pid": 99,
            "ppid": 1,
            "age_s": 5,
            "args": "/usr/bin/swift build -c release",
        }]
        out = xcode_builds.fetch_builds(force=True)
        row = out["builds"][0]
        self.assertEqual(row["kind"], "spm")
        self.assertEqual(row["action"], "build")
        self.assertEqual(row["name"], "pkg")

    @patch("xcode_builds._workspace_for_derived",
           return_value="/Users/mz/Dev/headroom/macos/Headroom.xcodeproj")
    @patch("xcode_builds._cwds_for_pids", return_value={})
    @patch("xcode_builds._list_procs")
    def test_ide_build_from_compiler_children(self, list_procs, _cwds, _ws):
        list_procs.return_value = [
            {
                "pid": 100,
                "ppid": 1,
                "age_s": 3600,
                "args": (
                    "/Applications/Xcode.app/Contents/SharedFrameworks/"
                    "SwiftBuild.framework/.../SWBBuildService"
                ),
            },
            {
                "pid": 200,
                "ppid": 100,
                "age_s": 12,
                "args": (
                    "/Applications/Xcode.app/.../swift-frontend -frontend "
                    "-c /Users/mz/Library/Developer/Xcode/DerivedData/"
                    "Headroom-bmrdpgceqosxxifozfnepxzmcaqb/Build/Intermediates/"
                    "Foo.swift"
                ),
            },
        ]
        out = xcode_builds.fetch_builds(force=True)
        self.assertEqual(len(out["builds"]), 1)
        row = out["builds"][0]
        self.assertEqual(row["kind"], "xcode")
        self.assertEqual(row["name"], "Headroom")
        self.assertEqual(row["pid"], 100)
        self.assertEqual(row["age_s"], 12)
        self.assertEqual(row["target"], "Headroom.xcodeproj")

    @patch("xcode_builds._cwds_for_pids", return_value={})
    @patch("xcode_builds._list_procs")
    def test_idle_build_service_is_ignored(self, list_procs, _cwds):
        list_procs.return_value = [{
            "pid": 100,
            "ppid": 1,
            "age_s": 3600,
            "args": "/.../SWBBuildService",
        }]
        out = xcode_builds.fetch_builds(force=True)
        self.assertTrue(out["ok"])
        self.assertEqual(out["builds"], [])

    @patch("xcode_builds._cwds_for_pids", return_value={})
    @patch("xcode_builds._list_procs")
    def test_cli_descendants_are_not_double_counted(self, list_procs, _cwds):
        list_procs.return_value = [
            {
                "pid": 50,
                "ppid": 1,
                "age_s": 20,
                "args": "/usr/bin/xcodebuild -scheme Headroom build",
            },
            {
                "pid": 51,
                "ppid": 50,
                "age_s": 5,
                "args": (
                    "/.../swift-frontend -c /DerivedData/"
                    "Headroom-abc/Build/Intermediates/Foo.swift"
                ),
            },
        ]
        out = xcode_builds.fetch_builds(force=True)
        self.assertEqual(len(out["builds"]), 1)
        self.assertEqual(out["builds"][0]["kind"], "xcodebuild")


if __name__ == "__main__":
    unittest.main()
