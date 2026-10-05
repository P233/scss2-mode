;;; scss2-grammar-test.el --- Bundled grammar installation contracts -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'scss2-grammar)

(ert-deftest scss2-grammar-language-identities-are-private-and-dialect-specific ()
  (let ((treesit-load-name-override-list nil))
    (let ((css (scss2-grammar-language 'css))
          (scss (scss2-grammar-language 'scss)))
      (should-not (eq css scss))
      (should-not (memq scss '(scss css)))
      (should (equal (cadr (assq css treesit-load-name-override-list))
                     (cadr (assq scss treesit-load-name-override-list))))
      (should (file-name-absolute-p
               (cadr (assq css treesit-load-name-override-list))))
      (should (equal (nth 2 (assq css treesit-load-name-override-list))
                     "tree_sitter_stylesheet_css"))
      (should (equal (nth 2 (assq scss treesit-load-name-override-list))
                     "tree_sitter_scss"))
      (let ((scss2-grammar-cache-directory temporary-file-directory))
        (scss2-grammar-language 'scss)
        (should (= (length treesit-load-name-override-list) 2)))
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
          (should-not (file-exists-p (scss2-grammar--library-file))))
      (delete-directory scss2-grammar-cache-directory t))))

(ert-deftest scss2-grammar-verifies-each-library-once-until-rebuilt ()
  (let ((scss2-grammar-cache-directory (make-temp-file "scss2-verify-" t))
        (treesit-load-name-override-list (copy-tree treesit-load-name-override-list))
        (scss2-grammar--verified-libraries nil)
        (present nil) (loadable nil) (builds 0) (checks 0))
    (unwind-protect
        (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
                  ((symbol-function 'scss2-grammar--library-present-p) (lambda (_) present))
                  ((symbol-function 'scss2-grammar--compile)
                   (lambda (_) (cl-incf builds) (setq present t)))
                  ((symbol-function 'treesit-language-available-p)
                   (lambda (_language _detail)
                     (cl-incf checks)
                     (if loadable '(t) '(nil fixture-load-error)))))
          ;; A library that cannot load is checked again on the next request.
          (dotimes (_ 2)
            (let ((failure (should-error (scss2-grammar-ensure 'scss) :type 'user-error)))
              (should (string-match-p "fixture-load-error" (error-message-string failure)))))
          (should (equal (list builds checks) '(1 2)))
          (setq loadable t)
          (dolist (dialect '(scss css scss css))
            (scss2-grammar-ensure dialect))
          (should (equal (list builds checks) '(1 3)))
          ;; A rebuilt library must load again before it counts as verified.
          (setq present nil)
          (dotimes (_ 2) (scss2-grammar-ensure 'css))
          (should (equal (list builds checks) '(2 4)))
          ;; Verification is per library path, such as another cache directory's.
          (let ((scss2-grammar-cache-directory
                 (expand-file-name "other/" scss2-grammar-cache-directory)))
            (scss2-grammar-ensure 'scss))
          (should (equal (list builds checks) '(2 5)))
          (scss2-grammar-ensure 'css)
          (should (equal (list builds checks) '(2 5))))
      (delete-directory scss2-grammar-cache-directory t))))

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
