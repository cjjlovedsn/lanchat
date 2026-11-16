"""Exercise real replacement/rollback commands against disposable fake bundles."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'assets/install-macos-update.sh'

class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lanchat-updater-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'space & 中文'
        self.root.mkdir()
        self.target = self.root / 'LanChat.app'
        self.staged = self.root / '.new.app'
        self.backup = self.root / '.previous.app'
        self.log = self.root / 'install.log'
        for folder, value in [(self.target, 'old'), (self.staged, 'new')]:
            folder.mkdir()
            (folder / 'version').write_text(value)
        tools = self.root / 'bin'
        tools.mkdir()
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])
        (tools / 'open').write_text('#!/bin/sh\nexit 0\n')
        (tools / 'open').chmod(0o755)
        (tools / 'sleep').write_text('#!/bin/sh\nexit 0\n')
        (tools / 'sleep').chmod(0o755)
        self.tools = tools

    def run_helper(self, pid='99999999'):
        return subprocess.run(['/bin/sh', str(HELPER), str(pid), str(self.staged),
            str(self.target), str(self.backup), str(self.log)], env=self.env, timeout=5)

    def test_replacement_preserves_previous_bundle(self):
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'new')
        self.assertEqual((self.backup / 'version').read_text(), 'old')

    def test_cannot_replace_live_application(self):
        self.assertNotEqual(self.run_helper(os.getpid()).returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'old')
        self.assertFalse(self.backup.exists())

    def test_failed_move_restores_old_application(self):
        (self.tools / 'mv').write_text('#!/bin/sh\ncase "$1" in */.new.app) exit 1;; esac\nexec /bin/mv "$@"\n')
        (self.tools / 'mv').chmod(0o755)
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'old')
        self.assertFalse(self.backup.exists())

    def test_failed_launch_rolls_back(self):
        (self.tools / 'open').write_text('#!/bin/sh\n[ "$(cat "$1/version")" = old ]\n')
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'old')
        self.assertEqual((self.staged / 'version').read_text(), 'new')

    def test_existing_backup_is_not_overwritten(self):
        self.backup.mkdir()
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'old')

if __name__ == '__main__':
    unittest.main()
