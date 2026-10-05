"""Preserve the complete bundled parser when a maintainer import is interrupted."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parent.parent / "scripts/vendor-parser.py"
SPEC = importlib.util.spec_from_file_location("vendor_parser", SCRIPT)
VENDOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VENDOR)


class VendorImportTest(unittest.TestCase):
    def test_interrupted_publish_restores_existing_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "vendor/tree-sitter-scss"
            destination.mkdir(parents=True)
            (destination / "existing").write_text("previous snapshot")
            for name in VENDOR.FILES:
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("new snapshot")
            (source / "package.json").write_text(json.dumps({"version": "1.0.0"}))
            rename = Path.rename

            def interrupted(path, target):
                if path.name == "snapshot":
                    raise KeyboardInterrupt
                return rename(path, target)

            with patch.object(VENDOR, "VENDOR", destination), \
                    patch.object(VENDOR.subprocess, "check_output", side_effect=["abc\n", b""]), \
                    patch.object(Path, "rename", interrupted):
                with self.assertRaises(KeyboardInterrupt):
                    VENDOR.update(source)
            self.assertEqual((destination / "existing").read_text(), "previous snapshot")
            self.assertEqual(list(destination.iterdir()), [destination / "existing"])
            self.assertEqual(list(destination.parent.iterdir()), [destination])

    def test_content_id_changes_only_with_native_build_inputs(self):
        hashes = {name: "previous" for name in VENDOR.FILES}
        for name in VENDOR.FILES:
            changed = VENDOR.content_id({**hashes, name: "changed"}) != VENDOR.content_id(hashes)
            self.assertEqual(changed, name.startswith("src/"), name)


if __name__ == "__main__":
    unittest.main()
