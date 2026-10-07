;;; test-frontends.el --- Optional Company and Orderless protocols -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Put real company-mode, orderless, compat, and Emmet2 checkouts on load-path.
;; Runs real candidate selection and insertion, without popup drawing.

(require 'ert)
(require 'scss2-mode)
(require 'company-capf)
(require 'orderless)
(setq native-comp-enable-subr-trampolines nil)
(defvar scss2-frontends--temporary (make-temp-file "scss2-frontends-" t))
(setq scss2-grammar-cache-directory scss2-frontends--temporary)

(defmacro scss2-frontends--with (mode input &rest body)
  (declare (indent 2) (debug t))
  `(save-window-excursion
     (with-temp-buffer
       (set-window-buffer (selected-window) (current-buffer))
       (let ((scss2-fontify-colors nil)) (funcall ,mode))
       (insert ".a { " ,input "; }") (backward-char 3)
       (buffer-enable-undo)
       (let ((completion-styles '(orderless basic))
             (completion-category-defaults '((scss2 (styles scss2))))
             (completion-category-overrides nil)
             (company-frontends nil) (company-idle-delay nil)
             (company-minimum-prefix-length 0))
         (company-mode 1)
         (unwind-protect (progn ,@body)
           (company-abort))))))

(ert-deftest scss2-frontends-company-semantic-selection-and-undo ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-frontends--with mode "display: ib"
      (company-begin-backend 'company-capf)
      (setq company-selection (cl-position "inline-block" company-candidates :test #'equal))
      (should company-selection)
      (company-complete-selection) (undo-boundary)
      (should (equal (buffer-string) ".a { display: inline-block; }"))
      (should (eq (char-after) ?\;))
      (undo-only 1)
      (should (equal (buffer-string) ".a { display: ib; }")))))

(ert-deftest scss2-frontends-company-function-insertion-stays-after-the-call ()
  ;; Company reports `exact' on acceptance; emmet2 enters a call only for `finished'.
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-frontends--with mode "width: cal"
      (company-begin-backend 'company-capf)
      (setq company-selection (cl-position "calc()" company-candidates :test #'equal))
      (should company-selection)
      (company-complete-selection)
      (should (equal (buffer-string) ".a { width: calc(); }"))
      (should (looking-at ";")))))

(ert-deftest scss2-frontends-company-emmet-declaration-insertion ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-frontends--with mode "m10"
      (company-begin-backend 'company-capf)
      (should company-candidates)
      (setq company-selection 0)
      (company-complete-selection)
      (should (equal (buffer-string) ".a { margin: 10px; }")))))

(ert-deftest scss2-frontends-company-value-tab-skips-without-accepting ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (key '("TAB" "<tab>"))
      (scss2-frontends--with mode "display: ib"
        (company-begin-backend 'company-capf)
        (company-install-map)
        (should company-candidates)
        (execute-kbd-macro (kbd key))
        (should-not company-candidates)
        (should (eq (char-before) ?\;))
        (should (equal (buffer-string) ".a { display: ib; }"))))))

(ert-deftest scss2-frontends-company-keeps-non-tab-bindings ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-frontends--with mode "display: ib"
      (use-local-map (copy-keymap (current-local-map)))
      (local-set-key (kbd "C-c n") #'company-complete-common-or-cycle)
      (company-begin-backend 'company-capf)
      (company-install-map)
      (should company-candidates)
      (should (eq (key-binding (kbd "C-c n")) #'company-complete-common-or-cycle))
      (let ((selection company-selection))
        (call-interactively (key-binding (kbd "C-c n")))
        (should company-candidates)
        (should-not (equal company-selection selection)))
      (should (eq (char-after) ?\;))
      (should (equal (buffer-string) ".a { display: ib; }")))))

(ert-deftest scss2-frontends-company-tab-keeps-completion-without-semicolon ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-frontends--with mode "display: ib"
      (save-excursion (search-forward ";") (delete-char -1))
      (company-begin-backend 'company-capf)
      (company-install-map)
      (should company-candidates)
      (should (eq (key-binding (kbd "TAB")) #'company-complete-common-or-cycle))
      (let ((selection company-selection))
        (call-interactively (key-binding (kbd "TAB")))
        (should company-candidates)
        (should-not (equal company-selection selection)))
      (should (equal (buffer-string) ".a { display: ib }")))))

(ert-deftest scss2-frontends-orderless-preserves-the-scss2-category ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-frontends--with mode "display: ib"
      (pcase-let ((`(,begin ,end ,table . ,_) (scss2-completion-at-point)))
        (should (eq (completion-metadata-get
                     (completion-metadata "ib" table nil) 'category) 'scss2))
        (should (member "inline-block"
                        (completion-all-completions
                         (buffer-substring-no-properties begin end) table nil (- end begin))))))))

(ert-deftest scss2-frontends-orderless-category-override-uses-plain-spellings ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-frontends--with mode "display: block"
      (let* ((completion-category-overrides '((scss2 (styles orderless))))
             (table (nth 2 (scss2-completion-at-point))))
        (should (member "inline-block"
                        (completion-all-completions "block inline" table nil 12)))
        (should-not (completion-all-completions "i\\62" table nil 4))))))

(unwind-protect
    (let ((result (ert-run-tests-batch
                   (or (getenv "SCSS2_TEST_SELECTOR") "^scss2-frontends-"))))
      (delete-directory scss2-frontends--temporary t)
      (kill-emacs (if (zerop (ert-stats-completed-unexpected result)) 0 1)))
  (when (file-directory-p scss2-frontends--temporary)
    (delete-directory scss2-frontends--temporary t)))

;;; test-frontends.el ends here
