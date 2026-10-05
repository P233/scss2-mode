#!/usr/bin/env python3
"""Import or verify the fixed parser snapshot shipped with scss2-mode."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "tree-sitter-scss"
FILES = (
    "LICENSE",
    "src/parser.c",
    "src/scanner.c",
    "src/node-types.json",
    "src/tree_sitter/alloc.h",
    "src/tree_sitter/array.h",
    "src/tree_sitter/parser.h",
    "queries/highlights.scm",
    "examples/highlight-stress.scss",
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def content_id(files):
    # The native build reads only src/; queries and fixtures load from the package.
    native = sorted((name, value) for name, value in files.items() if name.startswith("src/"))
    return digest("".join(f"{name}\0{value}\n" for name, value in native).encode())


def verify(release=False):
    manifest = json.loads((VENDOR / "manifest.json").read_text())
    actual = {name: digest((VENDOR / name).read_bytes()) for name in FILES}
    if actual != manifest["files"] or content_id(actual) != manifest["contentId"]:
        raise SystemExit("Bundled parser differs from its manifest; import a complete snapshot")
    paths = {path.relative_to(VENDOR).as_posix() for path in VENDOR.rglob("*") if path.is_file()}
    unexpected = sorted(paths - set(FILES) - {"manifest.json"})
    if unexpected:
        raise SystemExit("Unexpected files in the bundled parser: " + ", ".join(unexpected))
    if release and manifest.get("source", {}).get("dirty") is not False:
        raise SystemExit("Cannot release a dirty or unverified parser snapshot; import a clean committed source")
    print(f"Bundled tree-sitter-scss {manifest['version']}: {manifest['contentId']}")


def update(source):
    source = source.resolve()
    # Read everything before replacing any file. The manifest identifies actual
    # bytes, including authorized source changes not yet represented by a commit.
    contents = {name: (source / name).read_bytes() for name in FILES}
    hashes = {name: digest(data) for name, data in contents.items()}
    metadata = json.loads((source / "package.json").read_text())
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    dirty = bool(subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--", *FILES]))
    manifest = {
        "version": metadata["version"],
        "source": {"repository": "https://github.com/P233/tree-sitter-scss", "commit": revision, "dirty": dirty},
        "files": hashes,
        "contentId": content_id(hashes),
    }
    VENDOR.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="parser-import-", dir=VENDOR.parent) as temporary:
        incoming = Path(temporary) / "snapshot"
        incoming.mkdir()
        for name, data in contents.items():
            destination = incoming / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        (incoming / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        previous = Path(temporary) / "previous"
        try:
            if VENDOR.exists():
                VENDOR.rename(previous)
            incoming.rename(VENDOR)
        finally:
            # Cancellation must restore the previous snapshot before the
            # temporary directory is cleaned, just like a filesystem error.
            if previous.exists() and not VENDOR.exists():
                previous.rename(VENDOR)
    verify()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--source", type=Path, help="Import from a tree-sitter-scss Git checkout")
    action.add_argument("--check", action="store_true", help="Verify the snapshot offline")
    action.add_argument("--check-release", action="store_true",
                        help="Verify the snapshot and require a clean source for release")
    options = parser.parse_args()
    if options.check or options.check_release:
        verify(release=options.check_release)
    else:
        update(options.source)


if __name__ == "__main__":
    main()
