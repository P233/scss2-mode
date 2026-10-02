"""Build packages from tracked sources, never from stray working-tree files."""

import importlib.util
import os
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import sys
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parent.parent / "scripts/package.py"
SPEC = importlib.util.spec_from_file_location("package_builder", SCRIPT)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class PackageContentsTest(unittest.TestCase):
    def test_release_rejects_dirty_snapshot_before_writing_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            for name in ("package.py", "vendor-parser.py"):
                shutil.copy2(SCRIPT.parent / name, root / "scripts" / name)
            vendor = root / "vendor/tree-sitter-scss"
            shutil.copytree(SCRIPT.parent.parent / "vendor/tree-sitter-scss", vendor)
            manifest = vendor / "manifest.json"
            data = json.loads(manifest.read_text())
            data["source"]["dirty"] = True
            manifest.write_text(json.dumps(data))
            # Development snapshots remain usable for local byte checks.
            check = subprocess.run(
                [sys.executable, str(root / "scripts/vendor-parser.py"), "--check"],
                text=True, capture_output=True,
            )
            self.assertEqual(check.returncode, 0, check.stderr)
            output = root / "dist"
            result = subprocess.run(
                [sys.executable, str(root / "scripts/package.py"), "--release",
                 "--output-dir", str(output)], text=True, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("dirty or unverified parser snapshot", result.stderr)
            self.assertFalse(output.exists())

    def test_only_existing_tracked_files_are_packaged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "data").mkdir()
            (root / "sample-mode.el").write_text(";;; sample-mode.el\n")
            (root / "data" / "table.json").write_text("{}\n")
            obsolete = root / "data" / "obsolete.json"
            obsolete.write_text("{}\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            obsolete.unlink()
            # Emacs lock files are dangling symlinks; Finder adds .DS_Store.
            os.symlink("user@host.1234:1", root / ".#sample-mode.el")
            (root / "data" / ".DS_Store").write_bytes(b"\0")
            (root / "scratch.el").write_text(";;; scratch\n")
            info = {"version": "1.0", "descriptor": ";; descriptor\n"}
            with patch.object(PACKAGE, "metadata", return_value=info):
                archive, _ = PACKAGE.build(root, "sample-mode", root / "dist", "emacs")
            with tarfile.open(archive) as tar:
                self.assertEqual(sorted(tar.getnames()), [
                    "sample-mode-1.0/data/table.json",
                    "sample-mode-1.0/sample-mode-pkg.el",
                    "sample-mode-1.0/sample-mode.el",
                ])


if __name__ == "__main__":
    unittest.main()
