"""Test macOS bootstrap and scheduling with launchd isolated behind a mock."""

import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from test_update import MANIFEST

if sys.platform == "darwin":
    import install as mac_install


@unittest.skipUnless(sys.platform == "darwin", "macOS installer only")
class MacInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / "state"
        self.target = self.state / "extension"
        self.plist = Path(self.temp.name) / "LaunchAgents/updater.plist"
        for name, value in [("STATE", self.state), ("TARGET", self.target), ("PLIST", self.plist)]:
            patch = mock.patch.object(mac_install, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(sys, "argv", ["install.py"])
        patch.start()
        self.addCleanup(patch.stop)

    def test_fresh_install_bootstraps_from_upstream_and_uses_local_paths(self):
        with mock.patch.object(mac_install.subprocess, "run") as run:
            run.return_value.returncode = 1  # No previously loaded job.
            mac_install.main()
        commands = [call.args[0] for call in run.call_args_list]
        bootstrap = next(command for command in commands if "--initialize" in command)
        self.assertIn(str(self.target), bootstrap)
        self.assertIn(str(self.state), bootstrap)
        config = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(config["ProgramArguments"][1], str(self.state / "update.py"))
        self.assertTrue(config["RunAtLoad"])
        self.assertEqual(config["StartInterval"], 86400)

    def test_failed_bootstrap_keeps_existing_schedule_loaded(self):
        def run(command, **kwargs):
            if "--initialize" in command:
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(mac_install.subprocess, "run", side_effect=run) as process:
            with self.assertRaises(subprocess.CalledProcessError):
                mac_install.main()
        self.assertFalse(any("bootout" in call.args[0] for call in process.call_args_list))
        self.assertFalse(self.plist.exists())

    def test_reinstall_preserves_existing_extension(self):
        self.target.mkdir(parents=True)
        original = json.dumps(MANIFEST)
        (self.target / "manifest.json").write_text(original)
        with mock.patch.object(mac_install.subprocess, "run") as run:
            run.return_value.returncode = 0
            mac_install.main()
        commands = [call.args[0] for call in run.call_args_list]
        self.assertFalse(any("--initialize" in command for command in commands))
        self.assertTrue(any("bootout" in command for command in commands))
        self.assertEqual((self.target / "manifest.json").read_text(), original)


if __name__ == "__main__":
    unittest.main()
