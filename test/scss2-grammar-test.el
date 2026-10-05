;;; scss2-grammar-test.el --- Bundled grammar installation contracts -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'scss2-grammar)
(require 'scss2-context)
(require 'scss2-edit)
(require 'scss2-test-support)

(defun scss2-grammar-test--first-candidate (language)
  "Return the first file Emacs tries to load for LANGUAGE."
  ;; Emacs searches extra paths, then the user directory, and tries the last suffix first.
  (expand-file-name (concat (cadr (assq language treesit-load-name-override-list))
                            (car (last dynamic-library-suffixes)))
                    (or (car treesit-extra-load-path)
                        (expand-file-name "tree-sitter/" user-emacs-directory))))

(ert-deftest scss2-grammar-language-identities-are-private-and-dialect-specific ()
  (let ((treesit-load-name-override-list nil))
    (let ((css (scss2-grammar-language 'css))
          (scss (scss2-grammar-language 'scss)))
      (should-not (eq css scss))
      (should-not (memq scss '(scss css)))
      (should (equal (cadr (assq css treesit-load-name-override-list))
                     (cadr (assq scss treesit-load-name-override-list))))
      (should (equal (scss2-grammar-test--first-candidate css)
                     (scss2-grammar--library-file)))
      (should (equal (nth 2 (assq css treesit-load-name-override-list))
                     "tree_sitter_stylesheet_css"))
      (should (equal (nth 2 (assq scss treesit-load-name-override-list))
                     "tree_sitter_scss"))
      (let ((scss2-grammar-cache-directory temporary-file-directory))
        (scss2-grammar-language 'scss)
        (should (= (length treesit-load-name-override-list) 2))
        (should (equal (scss2-grammar-test--first-candidate scss)
                       (scss2-grammar--library-file))))
      (let* ((user-emacs-directory (expand-file-name "scss2-user/" temporary-file-directory))
             (scss2-grammar-cache-directory
              (expand-file-name "tree-sitter/scss2-mode/" user-emacs-directory)))
        (scss2-grammar-language 'scss)
        (should (equal (scss2-grammar-test--first-candidate scss)
                       (scss2-grammar--library-file)))
        (let ((treesit-extra-load-path (list temporary-file-directory)))
          (scss2-grammar-language 'scss)
          (should (equal (scss2-grammar-test--first-candidate scss)
                         (scss2-grammar--library-file)))))
      (let ((scss2-grammar--content-id (make-string 64 ?a)))
        (should-not (eq scss (scss2-grammar-language 'scss)))))
    (should-error (scss2-grammar-language 'sass))))

(ert-deftest scss2-grammar-missing-runtime-does-not-build ()
  (let ((scss2-grammar-cache-directory (make-temp-file "scss2-no-runtime-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'treesit-available-p) (lambda () nil))
                  ((symbol-function 'call-process)
                   (lambda (&rest _) (ert-fail "Compiler must not run"))))
          (let ((failure (should-error (scss2-grammar-ensure 'scss) :type 'user-error)))
            (should (string-match-p "Tree-sitter support" (error-message-string failure))))
          (should-not (directory-files scss2-grammar-cache-directory nil "\\`[^.]")))
      (delete-directory scss2-grammar-cache-directory t))))

(ert-deftest scss2-grammar-compiler-failure-publishes-no-library ()
  (let ((scss2-grammar-cache-directory (make-temp-file "scss2-build-error-" t))
        ;; The real language must not stay registered under this directory.
        (treesit-load-name-override-list (copy-tree treesit-load-name-override-list)))
    (unwind-protect
        (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
                  ((symbol-function 'executable-find) (lambda (_) "/test/compiler"))
                  ((symbol-function 'call-process)
                   (lambda (&rest _)
                     (insert "fixture compiler diagnostic")
                     1)))
          (let ((failure (should-error (scss2-grammar-ensure 'scss) :type 'user-error)))
            (should (string-match-p "fixture compiler diagnostic"
                                    (error-message-string failure))))
          (should-not (file-exists-p (scss2-grammar--library-file)))
          (should-not (directory-files-recursively scss2-grammar-cache-directory ".")))
      (delete-directory scss2-grammar-cache-directory t))))

(ert-deftest scss2-grammar-success-without-output-publishes-nothing-and-retries ()
  (dolist (missing '(nil t))
    (let ((scss2-grammar-cache-directory (make-temp-file "scss2-empty-build-" t))
          (treesit-load-name-override-list (copy-tree treesit-load-name-override-list))
          (builds 0))
      (unwind-protect
          (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
                    ((symbol-function 'executable-find) (lambda (_) "/test/compiler"))
                    ((symbol-function 'call-process)
                     (lambda (&rest arguments)
                       (cl-incf builds)
                       (when missing (delete-file (car (last arguments))))
                       (insert "fixture empty-output diagnostic")
                       0)))
            (dotimes (_ 2)
              (let ((failure (should-error (scss2-grammar-ensure 'scss) :type 'user-error)))
                (should (string-match-p "produced no native library"
                                        (error-message-string failure)))
                (should (string-match-p "fixture empty-output diagnostic"
                                        (error-message-string failure))))
              (should-not (file-exists-p (scss2-grammar--library-file)))
              (should-not (directory-files-recursively scss2-grammar-cache-directory ".")))
            (should (= builds 2)))
        (delete-directory scss2-grammar-cache-directory t)))))

(ert-deftest scss2-grammar-build-announces-itself-before-compiling ()
  (let* ((directory (make-temp-file "scss2-build-progress-" t))
         (library (expand-file-name "libscss2-test.so" directory))
         messages before-build)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_) "/test/compiler"))
                  ((symbol-function 'message)
                   (lambda (format &rest arguments)
                     (when format (push (apply #'format-message format arguments) messages))))
                  ((symbol-function 'call-process)
                   (lambda (&rest arguments)
                     (setq before-build messages)
                     (write-region "fixture native output" nil (car (last arguments)) nil 'silent)
                     0)))
          (scss2-grammar--compile library)
          (should (equal (car before-build) "Compiling the bundled scss2-mode grammar..."))
          (should (equal (car messages) "Compiling the bundled scss2-mode grammar...done"))
          (should (file-exists-p library)))
      (delete-directory directory t))))

(ert-deftest scss2-grammar-missing-compiler-has-actionable-error ()
  (let ((scss2-grammar-cache-directory (make-temp-file "scss2-no-compiler-" t))
        (treesit-load-name-override-list (copy-tree treesit-load-name-override-list)))
    (unwind-protect
        (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
                  ((symbol-function 'executable-find) (lambda (_) nil)))
          (let ((failure (should-error (scss2-grammar-ensure 'css) :type 'user-error)))
            (should (string-match-p "install cc or set CC" (error-message-string failure))))
          (let ((process-environment (cons "CC=missing-cc -m64" process-environment)))
            (let ((failure (should-error (scss2-grammar-ensure 'css) :type 'user-error)))
              (should (string-match-p "\"missing-cc -m64\"" (error-message-string failure)))))
          (should-not (file-exists-p (scss2-grammar--library-file))))
      (delete-directory scss2-grammar-cache-directory t))))

(ert-deftest scss2-grammar-compiler-command-runs-outside-the-buffer-directory ()
  ;; CC is a shell-style command, and a new file's directory may not exist yet.
  (let* ((directory (make-temp-file "scss2-compiler-command-" t))
         (compiler (expand-file-name "fixture cc" directory))
         (library (expand-file-name "cache/libscss2-test.so" directory))
         (default-directory (expand-file-name "missing/" directory))
         (process-environment
          (cons (concat "CC=" (shell-quote-argument compiler) " -m64") process-environment)))
    (unwind-protect
        (progn
          (write-region (concat "#!/bin/sh\n"
                                "printf '%s\\n' \"$1\" > \"$(dirname \"$0\")/first-argument\"\n"
                                "while [ \"$1\" != -o ]; do shift; done\n"
                                "printf native > \"$2\"\n")
                        nil compiler nil 'silent)
          (set-file-modes compiler #o755)
          (scss2-grammar--compile library)
          (should (scss2-grammar--library-present-p library))
          (should (equal (with-temp-buffer
                           (insert-file-contents (expand-file-name "first-argument" directory))
                           (buffer-string))
                         "-m64\n")))
      (delete-directory directory t))))

(ert-deftest scss2-grammar-verifies-the-library-on-each-request ()
  (let ((scss2-grammar-cache-directory (make-temp-file "scss2-verify-" t))
        (treesit-load-name-override-list (copy-tree treesit-load-name-override-list))
        (loadable nil) (checks 0))
    (unwind-protect
        (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
                  ((symbol-function 'scss2-grammar--library-present-p) #'always)
                  ((symbol-function 'treesit-language-available-p)
                   (lambda (_language _detail)
                     (cl-incf checks)
                     (if loadable '(t) '(nil fixture-load-error)))))
          (let ((failure (should-error (scss2-grammar-ensure 'scss) :type 'user-error)))
            (should (string-match-p "fixture-load-error" (error-message-string failure))))
          (setq loadable t)
          (dolist (dialect '(scss css))
            (scss2-grammar-ensure dialect))
          (should (= checks 3)))
      (delete-directory scss2-grammar-cache-directory t))))

(ert-deftest scss2-grammar-loads-beside-other-search-directories ()
  (let ((treesit-load-name-override-list (copy-tree treesit-load-name-override-list))
        (user-emacs-directory (file-name-as-directory (make-temp-file "scss2-user-" t))))
    (unwind-protect
        (dolist (treesit-extra-load-path (list nil (list user-emacs-directory)))
          (with-temp-buffer
            (should (treesit-parser-create (scss2-grammar-ensure 'scss)))))
      (delete-directory user-emacs-directory t))))

(defconst scss2-grammar-test--single-word-node-types
  '("arguments" "combinator" "configuration" "important" "interpolation" "list" "map"
    "number" "operator" "parameter" "parameters" "selectors" "spread" "string" "url")
  "Single-word node types named in Lisp; a scan cannot tell them from keywords.")

(ert-deftest scss2-grammar-libraries-name-only-existing-node-types-and-fields ()
  ;; A renamed node must fail here instead of silently matching nothing.
  (let ((language (scss2-grammar-ensure 'scss))
        (patterns (mapcar (lambda (type) (format "(%s)" type))
                          scss2-grammar-test--single-word-node-types))
        (case-fold-search nil))
    (dolist (file (directory-files (expand-file-name "../.." scss2-grammar-directory) t
                                   "\\`scss2.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (while (re-search-forward "\"\\([a-z]+\\(?:_[a-z]+\\)+\\)\"" nil t)
          (unless (string-prefix-p "tree_sitter_" (match-string 1))
            (push (format "(%s)" (match-string 1)) patterns)))
        (goto-char (point-min))
        (while (re-search-forward "field-name[^\"\n]*\"\\([a-z_]+\\)\"" nil t)
          (push (format "(_ %s: (_))" (match-string 1)) patterns))))
    (should (member "(rule_set)" patterns))
    (should (member "(_ name: (_))" patterns))
    (should-not (cl-remove-if (lambda (pattern)
                                (ignore-errors
                                  (treesit-query-compile language (concat pattern " @node") t)))
                              (delete-dups patterns)))))

(ert-deftest scss2-grammar-closed-sass-blocks-remain-statements ()
  ;; Statement and body tables name these types; no compiled query checks them.
  (dolist (source '("@f│or $i from 1 through 2 { .a { width: $i; } }"
                    "@wh│ile $i > 0 { .a { width: $i; } }"
                    "@at-r│oot { .a { width: 1px; } }"
                    "@key│frames spin { from { opacity: 0; } }"))
    (scss2-test-with-buffer 'scss2-mode source
      (let ((statement (buffer-string)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (scss2-duplicate)
        (should (equal (buffer-string) (concat statement "\n" statement))))))
  (scss2-test-with-buffer 'scss2-mode ".a { @keyframes spin { op│ } }"
    (should-not (eq (plist-get (scss2-context-at-point) :role) 'property))))

(ert-deftest scss2-grammar-cold-build-loads-both-dialects-and-warm-cache-reuses ()
  ;; A new Emacs process cannot pass by reusing a language loaded by the suite.
  (let ((cache (make-temp-file "scss2-cold-build-" t))
        (root (file-name-directory (directory-file-name
                                   (file-name-directory (directory-file-name
                                                         scss2-grammar-directory))))))
    (unwind-protect
        (with-temp-buffer
          (let* ((program
                  `(progn
                     (require 'cl-lib)
                     (setq native-comp-enable-subr-trampolines nil)
                     (require 'scss2-grammar)
                     (setq scss2-grammar-cache-directory ,cache)
                     ;; A failed older compiler may have left an empty cache.
                     (let ((library (scss2-grammar--library-file)))
                       (make-directory (file-name-directory library) t)
                       (write-region "" nil library nil 'silent))
                     (let ((builds 0)
                           (original (symbol-function 'call-process)))
                       (cl-letf (((symbol-function 'call-process)
                                  (lambda (&rest arguments)
                                    (setq builds (1+ builds))
                                    (apply original arguments))))
                         (dolist (dialect '(css scss css scss))
                           (let ((language (scss2-grammar-ensure dialect)))
                             (with-temp-buffer
                               (insert ".a { content: \"#{$tone}\"; }")
                               (treesit-parser-create language)
                               (let ((node (treesit-buffer-root-node language)))
                                 (when (treesit-node-check node 'has-error)
                                   (error "Bundled grammar could not parse %s" dialect))
                                 (unless (eq (not (null (treesit-query-capture
                                                        node '((interpolation) @value))))
                                             (eq dialect 'scss))
                                   (error "Bundled grammar lost dialect identity"))))))
                         (unless (= builds 1)
                           (error "Expected one native build, got %s" builds))))))
                 (status
                  (call-process (expand-file-name invocation-name invocation-directory)
                                nil t nil "-Q" "--batch" "-L" root
                                "--eval" (prin1-to-string program))))
            (ert-info ((buffer-string)) (should (eq status 0)))))
      (delete-directory cache t))))

(provide 'scss2-grammar-test)
;;; scss2-grammar-test.el ends here
