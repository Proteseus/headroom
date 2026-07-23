import os
import signal
import unittest
from unittest.mock import patch

import local_servers


LISTENER = """COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
node 4242 mz 23u IPv4 0x123 0t0 TCP *:3000 (LISTEN)
"""


class StopServerTests(unittest.TestCase):
    @patch("local_servers.os.kill")
    @patch("local_servers._pid_uid", return_value=os.getuid())
    @patch("local_servers._lsof_listen", return_value=LISTENER)
    def test_stops_exact_current_listener(self, _listen, _uid, kill):
        result = local_servers.stop_server(4242, 3000)

        self.assertTrue(result["ok"])
        kill.assert_called_once_with(4242, signal.SIGTERM)

    @patch("local_servers.os.kill")
    @patch("local_servers._lsof_listen", return_value=LISTENER)
    def test_rejects_stale_pid(self, _listen, kill):
        result = local_servers.stop_server(9999, 3000)

        self.assertFalse(result["ok"])
        kill.assert_not_called()

    @patch("local_servers.os.kill")
    def test_rejects_headroom_port(self, kill):
        result = local_servers.stop_server(4242, local_servers.SELF_PORT)

        self.assertFalse(result["ok"])
        kill.assert_not_called()

    @patch("local_servers.os.kill")
    @patch("local_servers._pid_uid", return_value=os.getuid() + 1)
    @patch("local_servers._lsof_listen", return_value=LISTENER)
    def test_rejects_another_users_process(self, _listen, _uid, kill):
        result = local_servers.stop_server(4242, 3000)

        self.assertFalse(result["ok"])
        kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
