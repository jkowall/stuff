"""Exercise archive rejection and replacement/rollback without touching Chrome."""

import copy
import errno
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import zipfile

import update


PUBLIC_KEY = (
    "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvLxf4oOeSoz8qKVzKGQWW5zW44hWCoOoQRGXTrObUpyoGfGzhFO8aZHQmBcLrAZMA4O6EA7GaXnHkOPCLKM11seZ4J2azb1gSswApfAlaoeOLnhDnp/Jpzz7Bt6o4HL+nhKRJUOZ9z+GXAyOkOps5O38TwJN5R6z8tLkleRgfYscp19YU/vq1x9PrbXIHJTRB7qtb/iJmiKATKisXGmFY3Nbs5m379TGqcJFBM9bI+8bSJtS4e7t0LHOwSLDq3IVRaWVsFd9P19WEDNTxuzr9+rczOrw1vgmiisNOcElse8cyVIoq4bjepvfHM/9nzDgKwQsNG5OTzujwHu2UUN4cwIDAQAB"
)
MANIFEST = {
    "name": "Bypass Paywalls Clean", "manifest_version": 3,
    "version": "1.0", "key": PUBLIC_KEY,
    "background": {"service_worker": "background.js"},
    "options_ui": {"page": "options/options.html"},
}


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "installed"
        self.target.mkdir()
        (self.target / "manifest.json").write_text(json.dumps(MANIFEST))
        (self.target / "local-edit.txt").write_text("preserve in backup")
        self.archive = self.root / "package.zip"
        self.state = self.root / "state"

    def make_archive(self, version="2.0", key=PUBLIC_KEY, extra=None, missing=False):
        manifest = copy.deepcopy(MANIFEST)
        manifest.update(version=version, key=key)
        with zipfile.ZipFile(self.archive, "w") as package:
            package.writestr(update.ROOT + "/manifest.json", json.dumps(manifest))
            for name in ["background.js", "sites.js", "options/options.html"]:
                if not (missing and name == "background.js"):
                    package.writestr(update.ROOT + "/" + name, "fixture")
            if extra:
                package.writestr(*extra)

    def run_update(self, check=False, initialize=False):
        def download(destination):
            destination.write_bytes(self.archive.read_bytes())
        with mock.patch.object(update, "download", side_effect=download):
            update.run(self.target, self.state, check, initialize)

    def test_install_preserves_path_and_backs_up_all_old_files(self):
        self.make_archive()
        self.run_update()
        self.assertEqual(update.read_manifest(self.target)["version"], "2.0")
        record = json.loads((self.state / "last-update.json").read_text())
        backup = Path(record["backup"])
        self.assertEqual((backup / "local-edit.txt").read_text(), "preserve in backup")
        self.assertEqual(update.read_manifest(backup)["version"], "1.0")
        self.assertFalse(list(self.root.glob(".bpc-update-*")))

    def test_check_does_not_change_installation(self):
        self.make_archive()
        self.run_update(check=True)
        self.assertEqual(update.read_manifest(self.target)["version"], "1.0")
        self.assertFalse((self.state / "backups").exists())

    def test_same_version_does_not_replace_local_files(self):
        self.make_archive(version="1.0.0.0")
        self.run_update()
        self.assertTrue((self.target / "local-edit.txt").is_file())
        self.assertFalse((self.state / "backups").exists())

    def test_downgrade_rejected(self):
        self.make_archive(version="0.9")
        with self.assertRaisesRegex(ValueError, "downgrade"):
            self.run_update()
        self.assertTrue((self.target / "local-edit.txt").is_file())

    def test_changed_key_rejected(self):
        self.make_archive(key="b3RoZXI=")
        with self.assertRaisesRegex(ValueError, "public key"):
            self.run_update()
        self.assertTrue((self.target / "local-edit.txt").is_file())

    def test_missing_resource_rejected(self):
        self.make_archive(missing=True)
        with self.assertRaisesRegex(ValueError, "resource"):
            self.run_update()

    def test_traversal_rejected(self):
        self.make_archive(extra=(update.ROOT + "/../../escaped", "bad"))
        with self.assertRaisesRegex(ValueError, "Unsafe ZIP path"):
            self.run_update()
        self.assertFalse((self.root / "escaped").exists())

    def test_symlink_rejected(self):
        entry = zipfile.ZipInfo(update.ROOT + "/link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.make_archive(extra=(entry, "/tmp/elsewhere"))
        with self.assertRaisesRegex(ValueError, "Special file"):
            self.run_update()

    def test_failed_replacement_restores_original(self):
        self.make_archive()
        rename = Path.rename

        def fail_replacement(path, destination):
            if path.name == update.ROOT:
                raise OSError("simulated rename failure")
            return rename(path, destination)

        with mock.patch.object(Path, "rename", fail_replacement):
            with self.assertRaisesRegex(OSError, "simulated"):
                self.run_update()
        self.assertEqual(update.read_manifest(self.target)["version"], "1.0")
        self.assertEqual((self.target / "local-edit.txt").read_text(), "preserve in backup")

    def test_bootstrap_fresh_machine(self):
        self.target = self.state / "extension"
        self.make_archive()
        self.run_update(initialize=True)
        self.assertEqual(update.read_manifest(self.target)["version"], "2.0")
        record = json.loads((self.state / "last-update.json").read_text())
        self.assertIsNone(record["previous_version"])
        self.assertIsNone(record["backup"])

    def test_missing_folder_requires_explicit_bootstrap(self):
        self.target = self.state / "extension"
        with self.assertRaisesRegex(ValueError, "missing"):
            self.run_update()

    def test_failed_bootstrap_leaves_no_extension(self):
        self.target = self.state / "extension"
        self.make_archive(key="b3RoZXI=")
        with self.assertRaisesRegex(ValueError, "public key"):
            self.run_update(initialize=True)
        self.assertFalse(self.target.exists())

    def test_windows_unsafe_names_rejected_on_both_platforms(self):
        for filename in ['C:drive', 'file:stream', 'CON', 'nul.txt', 'COM1.js',
                         'trailing.', 'trailing ', 'bad\\path', 'wild*card', 'bad\x01name']:
            with self.subTest(filename=filename):
                self.make_archive(extra=(update.ROOT + "/" + filename, "bad"))
                with self.assertRaisesRegex(ValueError, "Unsafe ZIP path"):
                    self.run_update()

    def test_windows_lock_covers_same_byte_and_unlocks_on_exception(self):
        fake = mock.Mock(LK_NBLCK=1, LK_UNLCK=2)

        def locking(fd, mode, length):
            self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), 0)
            self.assertEqual(length, 1)

        fake.locking.side_effect = locking
        with mock.patch.object(update, 'WINDOWS', True), \
                mock.patch.object(update, 'msvcrt', fake, create=True):
            with self.assertRaisesRegex(ValueError, 'body failed'):
                with update.locked(self.state) as acquired:
                    self.assertTrue(acquired)
                    raise ValueError('body failed')
        self.assertEqual([call.args[1] for call in fake.locking.call_args_list], [1, 2])

    def test_windows_lock_contention_skips_but_other_errors_propagate(self):
        fake = mock.Mock(LK_NBLCK=1, LK_UNLCK=2)
        with mock.patch.object(update, 'WINDOWS', True), \
                mock.patch.object(update, 'msvcrt', fake, create=True):
            fake.locking.side_effect = OSError(errno.EACCES, 'locked')
            with update.locked(self.state) as acquired:
                self.assertFalse(acquired)
            fake.locking.side_effect = OSError(errno.EIO, 'disk error')
            with self.assertRaises(OSError):
                with update.locked(self.state):
                    self.fail('An I/O error must not be treated as contention')


if __name__ == "__main__":
    unittest.main()
