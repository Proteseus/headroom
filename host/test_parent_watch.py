"""Parent-death watch: the orphan guard for the app-owned host lifecycle."""

import os
import subprocess
import unittest

import parent_watch


class ParentAliveTests(unittest.TestCase):
    def test_own_pid_is_alive(self):
        self.assertTrue(parent_watch.parent_alive(os.getpid()))

    def test_reaped_child_is_not_alive(self):
        proc = subprocess.Popen(["/usr/bin/true"])
        proc.wait()
        # wait() reaps it, so the pid is free rather than a zombie. A zombie
        # still answers signal 0, which is why the test reaps before asking.
        self.assertFalse(parent_watch.parent_alive(proc.pid))

    def test_non_positive_pids_are_not_processes(self):
        # os.kill(0, 0) signals our own process group and would report alive
        # forever, which is the one answer that strands the port.
        self.assertFalse(parent_watch.parent_alive(0))
        self.assertFalse(parent_watch.parent_alive(-1))

    def test_permission_error_counts_as_gone(self):
        def denied(_pid, _sig):
            raise PermissionError(1, "Operation not permitted")

        real = os.kill
        os.kill = denied
        try:
            self.assertFalse(parent_watch.parent_alive(4242))
        finally:
            os.kill = real


class WatchTests(unittest.TestCase):
    def test_calls_on_gone_after_parent_disappears(self):
        remaining = [3]
        slept = []
        fired = []

        def alive(pid):
            self.assertEqual(pid, 99)
            remaining[0] -= 1
            return remaining[0] > 0

        parent_watch.watch(
            99, lambda: fired.append(True), interval=7,
            alive=alive, sleep=slept.append)

        self.assertEqual(fired, [True])
        self.assertEqual(slept, [7, 7])

    def test_checks_before_sleeping(self):
        slept = []
        fired = []

        parent_watch.watch(
            99, lambda: fired.append(True),
            alive=lambda _pid: False, sleep=slept.append)

        # A parent that died between spawn and here must not cost an interval.
        self.assertEqual(fired, [True])
        self.assertEqual(slept, [])

    def test_start_returns_a_daemon_thread_that_exits(self):
        done = []
        thread = parent_watch.start(0, lambda: done.append(True), interval=0.01)
        thread.join(timeout=2)
        self.assertTrue(thread.daemon)
        self.assertFalse(thread.is_alive())
        self.assertEqual(done, [True])


if __name__ == "__main__":
    unittest.main()
