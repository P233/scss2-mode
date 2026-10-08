#!/usr/bin/env python3
"""Build the installable package; Lisp headers own version and dependencies."""

import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parent.parent
METADATA = r"""
(progn
  (require 'package)
  (require 'json)
  (with-temp-buffer
    (insert-file-contents (getenv "SCSS2_PACKAGE_MAIN"))
    (let* ((desc (package-buffer-info))
           (name (symbol-name (package-desc-name desc)))
           (version (package-version-join (package-desc-version desc)))
           (summary (package-desc-summary desc))
           (reqs (mapcar (lambda (req)
                          (list (car req) (package-version-join (cadr req))))
                        (package-desc-reqs desc)))
           (extras (package-desc-extras desc))
           (keywords (alist-get :keywords extras))
           (url (alist-get :url extras))
           ;; package.el reads these keywords back into the descriptor.
           (details (append (when url (list :url url))
                            (when keywords (list :keywords `',keywords)))))
      (princ (json-encode
              `((name . ,name) (version . ,version)
                (descriptor . ,(concat
                                ";; -*- no-byte-compile: t; lexical-binding: t; -*-\n"
                                (prin1-to-string
                                 `(define-package ,name ,version ,summary ',reqs
                                    ,@details))
                                "\n"))
                (archive . ,(prin1-to-string
                             (cons (package-desc-name desc)
                                   (vector (package-desc-version desc)
                                           (package-desc-reqs desc) summary 'tar
                                           extras))))))))))))
"""


def metadata(root, name, emacs):
    env = dict(os.environ, SCSS2_PACKAGE_MAIN=str(root / f"{name}.el"))
    result = subprocess.run(
        [emacs, "--batch", "-Q", "--eval", METADATA],
        env=env, text=True, capture_output=True,
    )
    if result.returncode:
        raise ValueError(f"Cannot read package metadata from {env['SCSS2_PACKAGE_MAIN']}:\n"
                         f"{result.stderr.strip()}")
    info = json.loads(result.stdout)
    if info["name"] != name or info["version"] == "0":
        raise ValueError(f"Missing or invalid package metadata in {root / (name + '.el')}")
    return info


def tracked_files(root):
    """Return existing tracked paths under ROOT, retaining symlinks for rejection."""
    listing = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                             check=True, stdout=subprocess.PIPE).stdout
    paths = {root / os.fsdecode(name) for name in listing.split(b"\0") if name}
    return {path for path in paths if path.exists() or path.is_symlink()}


def build(root, name, output, emacs):
    info = metadata(root, name, emacs)
    prefix = f"{name}-{info['version']}"
    tracked = tracked_files(root)
    files = [p for p in tracked if p.parent == root and p.suffix == ".el"
             and not p.name.endswith(("-pkg.el", "-autoloads.el"))]
    resources = ("vendor",) if name == "scss2-mode" else ("data",)
    for resource in resources:
        directory = root / resource
        if not directory.is_dir():
            raise ValueError(f"Missing package resource: {directory}")
        files.extend(p for p in tracked if directory in p.parents)
    files.extend(p for p in (root / "README.md", root / "LICENSE", root / "COPYING")
                 if p in tracked)
    if name == "scss2-mode":
        for required in ("scss2-grammar.el", "css2-mode.el", "LICENSE",
                         "vendor/tree-sitter-scss/manifest.json"):
            if root / required not in tracked:
                raise ValueError(f"Missing tracked release file: {required}")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{prefix}.tar"
    partial = output / f".{prefix}.tar.partial"
    # Sorted paths and normalized headers make identical sources reproducible.
    # A failed build must leave neither a truncated archive nor a replaced one.
    try:
        write_archive(partial, files, root, prefix, name, info)
        partial.replace(archive)
    finally:
        partial.unlink(missing_ok=True)
    return archive, info


def write_archive(archive, files, root, prefix, name, info):
    with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as tar:
        for path in sorted(files):
            if path.is_symlink():
                raise ValueError(f"Package resource must not be a symlink: {path}")
            entry = tarfile.TarInfo(f"{prefix}/{path.relative_to(root).as_posix()}")
            data = path.read_bytes()
            entry.size, entry.mode = len(data), 0o644
            tar.addfile(entry, io.BytesIO(data))
        data = info["descriptor"].encode()
        entry = tarfile.TarInfo(f"{prefix}/{name}-pkg.el")
        entry.size, entry.mode = len(data), 0o644
        tar.addfile(entry, io.BytesIO(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--emacs", default=os.environ.get("EMACS", "emacs"))
    parser.add_argument("--release", action="store_true",
                        help="Require a clean parser snapshot before building a release")
    parser.add_argument("--emmet-source", type=Path,
                        help="Also build emmet2-mode and archive-contents for a local package archive")
    args = parser.parse_args()
    subprocess.run([os.environ.get("PYTHON", "python3"),
                    str(ROOT / "scripts/vendor-parser.py"),
                    "--check-release" if args.release else "--check"],
                   check=True, stdout=subprocess.DEVNULL)
    archive, info = build(ROOT, "scss2-mode", args.output_dir, args.emacs)
    if args.emmet_source:
        _, dependency = build(args.emmet_source.resolve(), "emmet2-mode",
                              args.output_dir, args.emacs)
        (args.output_dir / "archive-contents").write_text(
            f"(1\n {info['archive']}\n {dependency['archive']})\n", encoding="utf-8")
    print(archive)


if __name__ == "__main__":
    main()
