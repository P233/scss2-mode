;;; check-package.el --- Verify first installation in isolation -*- lexical-binding: t; -*-

;; Run with SCSS2_EMMET2_DIR=/path/to/emmet2-mode emacs -Q --batch
;; -l scripts/check-package.el.  No user package directory is read or written.

(require 'cl-lib)
(require 'package)
(require 'treesit)
(load (expand-file-name "scss2-test-runner.el" (file-name-directory load-file-name)) nil t)

(defun scss2-package--check-installed (temporary tests)
  "Check installed autoloads and TESTS in a fresh process under TEMPORARY."
  (let* ((user-emacs-directory (file-name-as-directory temporary))
         (package-user-dir (expand-file-name "elpa" temporary))
         (package-directory-list nil)
         (native-comp-enable-subr-trampolines nil))
    (package-initialize)
    (let* ((descriptor (cadr (assq 'scss2-mode package-alist)))
           (installed (package-desc-dir descriptor))
           (emmet (package-desc-dir (cadr (assq 'emmet2-mode package-alist)))))
      (dolist (library '("scss2-mode" "css2-mode" "scss2-grammar" "scss2-syntax" "scss2"))
        (unless (file-in-directory-p (or (locate-library library) "") installed)
          (error "Library %s was not loaded from the installed package" library)))
      (dolist (library '("emmet2-mode" "emmet2-context" "emmet2-capf" "emmet2-extract"
                         "emmet2-extensions" "emmet2-insert" "emmet2-css-data"
                         "emmet2-css-search" "emmet2-fuzzy"))
        (unless (file-in-directory-p (or (locate-library library) "") emmet)
          (error "Dependency library %s is outside its installed package" library)))
      (unless (file-readable-p (expand-file-name "data/css-data.json" emmet))
        (error "Installed dependency lacks shared CSS metadata"))
      (dolist (resource '("vendor/tree-sitter-scss/manifest.json"))
        (unless (file-readable-p (expand-file-name resource installed))
          (error "Installed package lacks resource: %s" resource)))
      (dolist (mode '(css2-mode scss2-mode))
        (unless (autoloadp (symbol-function mode))
          (error "Package installation did not generate %s autoload" mode)))
      (dolist (spec '(("sample.css" css2-mode) ("sample.scss" scss2-mode)))
        (with-temp-buffer
          (setq buffer-file-name (expand-file-name (car spec) temporary))
          (insert ".demo { m10 }")
          (set-auto-mode)
          (unless (eq major-mode (cadr spec))
            (error "File association did not select %s" (cadr spec)))
          (unless (= 1 (length (treesit-parser-list)))
            (error "Expected exactly one parser in %s" major-mode))
          (unless (and (assoc "inset" (emmet2-css-data-query 'property :query "ins"))
                       (assoc "inline-block" (emmet2-css-data-query 'value :property "display" :query "ib")))
            (error "Installed dependency cannot query shared CSS names and values"))
          (goto-char (point-min))
          (search-forward "m10")
          (call-interactively #'scss2-expand)
          (unless (equal (buffer-string) ".demo { margin: 10px; }")
            (error "Installed Emmet adapter produced %S" (buffer-string)))
          (font-lock-ensure)
          (goto-char (point-min))
          (search-forward "margin")
          (unless (get-text-property (1- (point)) 'face)
            (error "Installed highlighting query did not fontify a property"))
          (scss2-empty-value)
          (unless (equal (buffer-string) ".demo { margin: ; }")
            (error "Installed structural edit produced %S" (buffer-string)))
          (unless (local-variable-p 'emmet2-context-provider)
            (error "Installed mode did not register its Emmet host provider"))
          (erase-buffer)
          (insert ".demo { m1 }")
          (search-backward " }")
          (let* ((capf (scss2-completion-at-point))
                 (table (nth 2 capf))
                 (exit (plist-get (nthcdr 3 capf) :exit-function))
                 (previous (car (all-completions "m1" table))))
            (unless (and previous
                         (eq (completion-metadata-get (completion-metadata "m1" table nil) 'category) 'emmet2))
              (error "Installed mode did not delegate to native Emmet choices"))
            (insert "0")
            (let ((current (car (all-completions "m10" table))))
              (unless current (error "Installed Emmet table did not follow typed input"))
              (funcall exit previous 'finished)
              (unless (equal (buffer-string) ".demo { m10 }")
                (error "Installed Emmet table accepted an old candidate"))
              (funcall exit current 'finished)
              (unless (equal (buffer-string) ".demo { margin: 10px; }")
                (error "Installed Emmet table failed to accept its current candidate"))))
          (when (eq major-mode 'scss2-mode)
            (erase-buffer)
            (insert ".demo { p$gutter }")
            (search-backward " }")
            (scss2-expand)
            (unless (equal (buffer-string) ".demo { padding: $gutter; }")
              (error "Installed Emmet integration lost the SCSS dialect")))
          (when (bound-and-true-p emmet2-mode)
            (error "Host integration unexpectedly enabled emmet2-mode"))))
      (unless (file-in-directory-p scss2-grammar-cache-directory temporary)
        (error "Parser installation escaped the isolated user directory"))
      ;; Keep the autoload smoke above before tests require the runtime libraries.
      (dolist (function '(scss2-context-at-point scss2-completion-at-point
                          scss2-duplicate scss2-expand))
        (unless (and (byte-code-function-p (symbol-function function))
                     (file-in-directory-p (or (symbol-file function 'defun) "") installed))
          (error "%s did not load from installed bytecode" function)))
      (unless (scss2-test-run tests)
        (error "Installed bytecode failed ERT")))))

(if-let* ((installed-root (getenv "SCSS2_INSTALLED_CHECK")))
    (progn
      (scss2-package--check-installed
       installed-root (expand-file-name "../test" (file-name-directory load-file-name)))
      (kill-emacs 0))
  (let* ((root (file-name-directory
                (directory-file-name (file-name-directory load-file-name))))
         ;; The package is built from a temporary default directory.
         (dependency (expand-file-name
                      (or (getenv "SCSS2_EMMET2_DIR")
                          (error "Set SCSS2_EMMET2_DIR to a compatible native Emmet2 source"))
                      root))
         (temporary (make-temp-file "scss2-install-test-" t))
         (archive (expand-file-name "archive" temporary))
         (user-emacs-directory (file-name-as-directory temporary))
         (package-user-dir (expand-file-name "elpa" temporary))
         (package-directory-list nil)
         (package-archives `(("local" . ,(file-name-as-directory archive))))
         (package-check-signature nil)
         (package-alist nil)
         (package-archive-contents nil)
         (package-activated-list nil)
         (package-selected-packages nil)
         (package-native-compile nil)
         (native-comp-enable-subr-trampolines nil)
         (custom-file (expand-file-name "custom.el" temporary))
         (load-path (cl-remove-if
                     (lambda (path)
                       (and path
                            (or (file-in-directory-p path root)
                                (file-in-directory-p path dependency))))
                     load-path))
         (default-directory temporary)
         (exit-code 1))
    (unwind-protect
        (condition-case failure
            (progn
              (unless (and (not (version< emacs-version "31.1")) (treesit-available-p))
                (error "Package test requires Emacs 31.1+ with tree-sitter"))
              (with-temp-buffer
                (unless (equal 0 (call-process
                                  (or (getenv "PYTHON") "python3") nil t nil
                                  (expand-file-name "scripts/package.py" root)
                                  "--output-dir" archive "--emmet-source" dependency
                                  "--emacs" (expand-file-name invocation-name invocation-directory)))
                  (error "Package construction failed:\n%s" (buffer-string))))
              (package-initialize)
              (package-refresh-contents)
              (when (or (package-installed-p 'scss2-mode) (package-installed-p 'emmet2-mode))
                (error "Installation test must start with neither package installed"))
              ;; This resolves and installs Emmet through the real package manager.
              (package-install 'scss2-mode)
              (unless (package-installed-p 'scss2-mode)
                (error "The package was not installed"))
              (dolist (requirement (package-desc-reqs (cadr (assq 'scss2-mode package-alist))))
                (unless (package-installed-p (car requirement) (cadr requirement))
                  (error "The declared dependency was not installed: %S" requirement)))
              ;; Byte compilation may load mode definitions.  A fresh process proves
              ;; the generated autoloads work on the user's next Emacs startup.
              (let ((process-environment (copy-sequence process-environment)))
                (setenv "SCSS2_INSTALLED_CHECK" temporary)
                (with-temp-buffer
                  (unless (equal 0 (call-process
                                    (expand-file-name invocation-name invocation-directory)
                                    nil t nil "--batch" "-Q" "-l"
                                    (expand-file-name "scripts/check-package.el" root)))
                    (error "Installed runtime failed:\n%s" (buffer-string)))
                  (message "%s" (buffer-string))))
              (message "Package installation passed: dependency, autoloads, bundled grammar, CSS/SCSS, live Emmet choices, expansion, editing and installed ERT")
              (setq exit-code 0))
          (error (message "Package installation failed: %s" (error-message-string failure))))
      (delete-directory temporary t))
    (kill-emacs exit-code)))

;;; check-package.el ends here
