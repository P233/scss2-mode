;;; test-emacs.el --- Test the standalone editor package -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; SCSS2_EMMET2_DIR selects a real emmet2-mode checkout for development.
;; SCSS2_TEST_SELECTOR optionally selects ERT tests by regexp.
;; SCSS2_TEST_SUITE selects all (default), core, or semantic in a fresh process.

(require 'treesit)
(require 'bytecomp)
(load (expand-file-name "scss2-test-runner.el" (file-name-directory load-file-name)) nil t)

(let* ((root (file-name-directory
              (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))
       (suite (or (getenv "SCSS2_TEST_SUITE") "all"))
       (files (pcase suite
                ("core" '("scss2-grammar" "scss2-syntax" "scss2-context" "scss2-edit"))
                ("semantic" '("scss2-grammar" "scss2-syntax" "scss2-completion"))
                ("all" '("scss2-grammar" "scss2-syntax" "scss2-context" "scss2-edit"
                         "scss2-completion" "scss2-emmet" "scss2" "css2-mode"
                         "scss2-mode"))
                (_ (error "Unknown SCSS2_TEST_SUITE: %s" suite))))
       (tests (pcase suite
                ("core" '("scss2-grammar-test.el" "scss2-context-test.el" "scss2-edit-test.el"))
                ("semantic" '("scss2-semantic-test.el"))))
       (temporary (make-temp-file "scss2-tests-" t))
       (default-directory root)
       (load-path (cons root load-path))
       ;; A stale in-place .elc must not stand in for the source under test.
       (load-prefer-newer t)
       (native-comp-enable-subr-trampolines nil)
       (exit-code 1))
  (when-let* ((_ (not (equal suite "core")))
              (emmet-directory (getenv "SCSS2_EMMET2_DIR")))
    (push (expand-file-name emmet-directory) load-path))
  (unwind-protect
      (progn
        (unless (and (not (version< emacs-version "31.1")) (treesit-available-p))
          (error "Tests require Emacs 31.1+ built with tree-sitter"))
        ;; Required integration tests must not silently skip a missing engine.
        (when (equal suite "all")
          (require 'emmet2-mode)
          (require 'emmet2-extract)
          (require 'emmet2-extensions)
          (require 'emmet2-insert))
        (require 'scss2-grammar)
        (setq scss2-grammar-cache-directory (expand-file-name "grammar" temporary))
        (scss2-grammar-ensure 'scss)
        (scss2-grammar-ensure 'css)
        (let ((byte-compile-error-on-warn t)
              (byte-compile-dest-file-function
               (lambda (file)
                 (expand-file-name (concat (file-name-base file) ".elc") temporary))))
          (dolist (file files)
            (unless (byte-compile-file (expand-file-name (concat file ".el") root))
              (error "Byte compilation failed: %s" file))))
        (when (equal suite "all") (require 'scss2-mode))
        (setq exit-code (if (scss2-test-run (expand-file-name "test" root) tests) 0 1))
        ;; Enforce real module boundaries, including indirect runtime loads.
        (unless (equal suite "all")
          (dolist (feature (append '(scss2 scss2-mode css2-mode scss2-emmet emmet2-mode)
                                   (if (equal suite "core")
                                       '(scss2-completion emmet2-css-data emmet2-fuzzy)
                                     '(scss2-context scss2-edit))))
            (when (featurep feature)
              (error "%s suite loaded unrelated subsystem: %s" suite feature)))))
    (delete-directory temporary t))
  (kill-emacs exit-code))

;;; test-emacs.el ends here
