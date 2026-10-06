;;; scss2-emmet-test.el --- Default real Emmet integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'scss2-mode)

(defmacro scss2-emmet-test--buffer (text &rest body)
  "Evaluate BODY at the | marker in TEXT with the real required engine."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min)) (search-forward "|") (delete-char -1)
     (let ((position (point)) (indent-tabs-mode nil) (scss2-indent-offset 2))
       (css2-mode) (goto-char position)
       ,@body)))

(ert-deftest scss2-emmet-expands-without-enabling-emmet-mode ()
  (scss2-emmet-test--buffer ".a { m10| }"
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (scss2-expand)
    (should (equal (buffer-string) ".a { margin: 10px; }"))
    (should-not (bound-and-true-p emmet2-mode))
    (let ((inhibit-message t)) (undo))
    (should (equal (buffer-string) ".a { m10 }"))))

(ert-deftest scss2-emmet-adjacent-nested-rule-keeps-declaration-completion ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (accept '(command capf))
      (with-temp-buffer
        (insert ".a {\n  text-align: center;\n  m10\n  &[data-is-resizing] { cursor: col-resize; }\n}")
        (funcall mode) (goto-char 1) (search-forward "m10")
        (buffer-enable-undo)
        (let ((before (buffer-string)))
          (if (eq accept 'command)
              (scss2-expand)
            (let* ((capf (scss2-completion-at-point))
                   (candidate (car (all-completions "m10" (nth 2 capf)))))
              (should candidate)
              (funcall (plist-get (nthcdr 3 capf) :exit-function) candidate 'finished)))
          (should (equal (buffer-string)
                         (string-replace "m10" "margin: 10px;\n  " before)))
          (should (looking-at "\n  &"))
          (undo-only 1)
          (should (equal (buffer-string) before))
          ;; A second declaration starts on the line that Emmet just created.
          (scss2-expand)
          (insert "p20")
          (should (equal (plist-get (emmet2-context-analyze) :abbr) "p20")))))))

(ert-deftest scss2-emmet-completion-inserts-current-result ()
  (scss2-emmet-test--buffer ".a { p1-2| }"
    (let* ((capf (scss2-completion-at-point))
           (table (nth 2 capf))
           (exit (plist-get (nthcdr 3 capf) :exit-function))
           (candidates (all-completions "p1-2" table)))
      (should candidates)
      (should (cl-every (lambda (candidate) (equal candidate "p1-2")) candidates))
      (funcall exit (car candidates) 'finished)
      (should (equal (buffer-string) ".a { padding: 1px 2px; }")))))

(ert-deftest scss2-emmet-empty-choices-yield-to-later-completion ()
  ;; Only Emmet's own table knows that an admitted word has no choices.
  (dolist (mode '(css2-mode scss2-mode))
    (pcase-dolist (`(,input ,winner) '(("-webkit-app" "-webkit-appearance") ("m10" "m10")))
      (with-temp-buffer
        (insert ".a { " input " }")
        (funcall mode)
        (search-backward " }")
        (add-hook 'completion-at-point-functions
                  (lambda () (list (- (point) (length input)) (point)
                                   '("-webkit-appearance" "m10-later")))
                  0 t)
        (let* (offered
               (completion-in-region-function
                (lambda (begin end table predicate)
                  (setq offered (delete-dups
                                 (all-completions (buffer-substring-no-properties begin end)
                                                  table predicate)))
                  t)))
          (completion-at-point)
          (ert-info ((format "%s %s" mode input))
            (should (equal offered (list winner)))))))))

(ert-deftest scss2-emmet-preserves-native-alternative-identities ()
  (scss2-emmet-test--buffer ".a { p1-2| }"
    (let* ((capf (scss2-emmet-completion-at-point))
           (props (nthcdr 3 capf))
           (candidates (all-completions "p1-2" (nth 2 capf)))
           (rows (funcall (plist-get props :affixation-function) candidates)))
      (should (> (length candidates) 1))
      (should-not (equal (cadar rows) (cadadr rows)))
      (funcall (plist-get props :exit-function) (cadr candidates) 'finished)
      (should (equal (buffer-string) (concat ".a { " (cadadr rows) " }"))))))

(ert-deftest scss2-emmet-completion-rejects-stale-source ()
  (scss2-emmet-test--buffer ".a { m10| }"
    (let* ((capf (scss2-emmet-completion-at-point))
           (exit (plist-get (nthcdr 3 capf) :exit-function)))
      (all-completions "m10" (nth 2 capf))
      (insert "0")
      (funcall exit "m10" 'finished)
      (should (equal (buffer-string) ".a { m100 }")))))

(ert-deftest scss2-emmet-completion-rejects-changed-render-options ()
  (scss2-emmet-test--buffer ".a {\n        m10+p20|\n}"
    (setq indent-tabs-mode nil)
    (let* ((source (buffer-string))
           (capf (scss2-emmet-completion-at-point))
           (exit (plist-get (nthcdr 3 capf) :exit-function)))
      (should (all-completions "m10+p20" (nth 2 capf)))
      (setq indent-tabs-mode t)
      (should-not (all-completions "m10+p20" (nth 2 capf)))
      (funcall exit "m10+p20" 'finished)
      (should (equal (buffer-string) source)))))

(ert-deftest scss2-emmet-property-prefixes-use-the-native-table ()
  (dolist (input '("m" "dis" "DIS" "display"))
    (scss2-emmet-test--buffer (concat ".a { " input "| }")
      (let* ((original (symbol-function 'emmet2-capf)) native
             (data (cl-letf (((symbol-function 'emmet2-capf)
                             (lambda () (setq native (funcall original)))))
                     (scss2-completion-at-point))))
        (should (eq data native))
        (should (eq (completion-metadata-get (completion-metadata input (nth 2 data) nil) 'category) 'emmet2))
        (should (all-completions input (nth 2 data)))))))

(ert-deftest scss2-emmet-declined-properties-have-no-semantic-fallback ()
  (dolist (source '(".a { col|: red; }" ".a { di\\73 p|: block; }"
                    "@supports (dis|: grid) {}" ".a { --brand| }" ".a { | }"))
    (scss2-emmet-test--buffer source
      (should-not (scss2-completion-at-point))))
  (scss2-emmet-test--buffer ".a { dis| }"
    (setq-local scss2-enable-emmet nil)
    (should-not (scss2-completion-at-point))))

(ert-deftest scss2-emmet-preview-reuses-existing-preview-owner ()
  (scss2-emmet-test--buffer ".a { m10+p20| }"
    (let* ((before (buffer-string)) (position (point))
           (capf (scss2-emmet-completion-at-point))
           (candidate (car (all-completions "m10+p20" (nth 2 capf))))
           (preview (funcall (plist-get (nthcdr 3 capf) :company-doc-buffer) candidate)))
      (should (equal (buffer-string) before))
      (should (= (point) position))
      (with-current-buffer preview
        (should buffer-read-only)
        (should (equal (buffer-string) "margin: 10px;\npadding: 20px;"))))))

(ert-deftest scss2-emmet-change-during-expansion-invalidates-candidate ()
  (scss2-emmet-test--buffer ".a { m10| }"
    (let* ((capf (scss2-emmet-completion-at-point))
           (expand (symbol-function 'emmet2-expand-choices))
           (expanded nil))
      (cl-letf (((symbol-function 'emmet2-expand-choices)
                 (lambda (&rest arguments)
                   (prog1 (apply expand arguments)
                     (setq expanded t)
                     (save-excursion (goto-char (point-max)) (insert " "))))))
        (should-not (all-completions "m10" (nth 2 capf)))
        (should expanded)))))

(ert-deftest scss2-emmet-keeps-values-and-css-sass-syntax-out ()
  (dolist (text '(".a { color: m10|; }" ".a { p$size| }" "@include foo|;"
                  ".a { --raw: { m10| }; }"
                  "@supports (\n m10|\n) { .a { color: red; } }"))
    (scss2-emmet-test--buffer text
      (should-not (scss2-emmet-completion-at-point))
      (let ((before (buffer-string)))
        (should-error (scss2-expand) :type 'user-error)
        (should (equal (buffer-string) before))))))

(ert-deftest scss2-emmet-rejects-selectors-and-rule-only-bodies ()
  (dolist (text '(".a { m10| {} }" ".a { m10| > .child {} }"
                  "@media screen { m10| }" "@layer base { m10| }"))
    (scss2-emmet-test--buffer text
      (let ((before (buffer-string)) (position (point)))
        (should-not (scss2-emmet-completion-at-point))
        (should-error (scss2-expand) :type 'user-error)
        (should (equal (buffer-string) before))
        (should (= (point) position)))))
  (scss2-emmet-test--buffer "@function f() { @if true { m10| } }"
    (let ((position (point))) (scss2-mode) (goto-char position))
    (should-error (scss2-expand) :type 'user-error)))

(ert-deftest scss2-emmet-allows-nested-declaration-bodies ()
  (scss2-emmet-test--buffer ".a { @media screen { m10| } }"
    (scss2-expand)
    (should (equal (buffer-string) ".a { @media screen { margin: 10px; } }")))
  (scss2-emmet-test--buffer "@mixin m { @if true { m10| } }"
    (let ((position (point))) (scss2-mode) (goto-char position))
    (scss2-expand)
    (should (equal (buffer-string) "@mixin m { @if true { margin: 10px; } }"))))

(ert-deftest scss2-emmet-host-provider-owns-context-and-lifetime ()
  (scss2-emmet-test--buffer ".a { m10| }"
    (should (local-variable-p 'emmet2-context-provider))
    (cl-letf (((symbol-function 'emmet2-context-js-region)
               (lambda () (error "Built-in Emmet host detection must not run"))))
      (let ((analysis (emmet2-context-analyze t)))
        (should (equal (plist-get analysis :abbr) "m10"))
        (should (eq (plist-get analysis :syntax) 'css))
        (should (= (plist-get analysis :indent-width) 2)))
      (should (= (length (treesit-parser-list)) 1))
      (emmet2-mode 1)
      (should (= (length (treesit-parser-list)) 1))
      (should-not (memq 'emmet2-capf completion-at-point-functions))
      (emmet2-mode -1)
      (should emmet2-context-provider))
    (fundamental-mode)
    (should-not (local-variable-p 'emmet2-context-provider))
    (should-not emmet2-context-provider))
  (scss2-emmet-test--buffer ".a { color: m10|; }"
    (cl-letf (((symbol-function 'emmet2-context-js-region)
               (lambda () (error "Forbidden context must not fall back"))))
      (should-not (emmet2-context-analyze))
      (should-not (emmet2-capf))
      (should-error (emmet2-complete) :type 'user-error))))

(ert-deftest scss2-emmet-requires-the-current-host-api ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'emmet2-expand-analysis) nil))
      (should-error (scss2-emmet-setup) :type 'error)
      (should-not (local-variable-p 'emmet2-context-provider))
      ;; Unlike an unavailable grammar, a mismatched installation never degrades.
      (should-error (scss2-mode) :type 'error))))

(ert-deftest scss2-emmet-declines-without-its-host-provider ()
  (with-temp-buffer
    (insert "div")
    (should-not (scss2-emmet-completion-at-point))
    (should-error (scss2-expand) :type 'user-error)
    (should (equal (buffer-string) "div")))
  (scss2-emmet-test--buffer ".a { m10| }"
    (setq-local emmet2-context-provider nil)
    (should-not (scss2-emmet-completion-at-point))
    (should-error (scss2-expand) :type 'user-error)
    (should (equal (buffer-string) ".a { m10 }"))))

(ert-deftest scss2-emmet-explicit-completion-uses-host-bounds ()
  (scss2-emmet-test--buffer ".a { m| }"
    (should (scss2-emmet-completion-at-point))
    (let ((completion-in-region-function
           (lambda (begin end table predicate)
             (should (equal (buffer-substring-no-properties begin end) "m"))
             (let ((candidate (car (all-completions "m" table predicate))))
               (should candidate)
               (funcall (plist-get completion-extra-properties :exit-function) candidate 'finished))
             t)))
      (call-interactively #'emmet2-complete))
    (should (equal (buffer-string) ".a { margin: ; }"))
    (should-not (bound-and-true-p emmet2-mode))))

(ert-deftest scss2-emmet-scss-variable-abbreviations-use-native-contract ()
  (dolist (variable '("$gutter" "$" "$-"))
    (scss2-emmet-test--buffer (concat ".a { p" variable "| }")
      (let ((position (point))) (scss2-mode) (goto-char position))
      (let* ((input (concat "p" variable))
             (capf (scss2-completion-at-point))
             (candidate (car (all-completions input (nth 2 capf)))))
        (should candidate)
        (should (eq (completion-metadata-get
                     (completion-metadata input (nth 2 capf) nil) 'category)
                    'emmet2))
        (funcall (plist-get (nthcdr 3 capf) :exit-function) candidate 'finished)
        (should (equal (buffer-string) (concat ".a { padding: " variable "; }"))))))
  (dolist (text '(".a { $gutter| }" ".a { $p10| }"))
    (scss2-emmet-test--buffer text
      (let ((position (point))) (scss2-mode) (goto-char position))
      (should-not (scss2-emmet-completion-at-point)))))

(ert-deftest scss2-emmet-recovers-sass-blocks-with-variable-abbreviations ()
  (dolist (source '("@mixin spacing { p$gutter| }"
                    "@mixin spacing($gutter) { p$gutter| }"
                    "@mixin spacing { color: red; p$gutter| }"
                    "@include spacing { p$gutter| }"
                    "@mixin spacing { @if true { p$gutter| } }"
                    "@mixin old { p$gutter } @mixin spacing { p$gutter| }"))
    (dolist (operation '(expand complete))
      (scss2-emmet-test--buffer source
        (let ((position (point))) (scss2-mode) (goto-char position))
        (if (eq operation 'expand)
            (scss2-expand)
          (let* ((capf (scss2-completion-at-point))
                 (candidate (and capf (car (all-completions "p$gutter" (nth 2 capf))))))
            (should candidate)
            (funcall (plist-get (nthcdr 3 capf) :exit-function) candidate 'finished)))
        (should (equal (buffer-string)
                       (string-replace "p$gutter|" "padding: $gutter;" source))))))
  (dolist (source '("@mixin old { p$gutter } @function f() { p$gutter| }"
                    "@mixin m { @function f() { @if true { p$gutter| } } }"
                    "@mixin old { p$gutter } @media screen { p$gutter| }"
                    "@mixin m { p$gutter| {} }"))
    (scss2-emmet-test--buffer source
      (let ((position (point))) (scss2-mode) (goto-char position))
      (let ((before (buffer-string)) (position (point)))
        (should-not (scss2-emmet-completion-at-point))
        (should-error (scss2-expand) :type 'user-error)
        (should (equal (buffer-string) before))
        (should (= (point) position))))))

(ert-deftest scss2-emmet-native-table-updates-and-rejects-old-candidates ()
  (scss2-emmet-test--buffer ".a { m1| }"
    (let* ((capf (scss2-emmet-completion-at-point))
           (table (nth 2 capf))
           (exit (plist-get (nthcdr 3 capf) :exit-function))
           (previous (car (all-completions "m1" table))))
      (should previous)
      (insert "0")
      (let ((current (car (all-completions "m10" table))))
        (should current)
        (funcall exit previous 'finished)
        (should (equal (buffer-string) ".a { m10 }"))
        (funcall exit current 'finished)
        (should (equal (buffer-string) ".a { margin: 10px; }"))))))

(ert-deftest scss2-emmet-host-settings-invalidate-native-candidates ()
  (dolist (setting '(enabled dialect indent provider))
    (scss2-emmet-test--buffer ".a { m10| }"
      (let* ((source (buffer-string))
             (capf (scss2-emmet-completion-at-point))
             (table (nth 2 capf))
             (exit (plist-get (nthcdr 3 capf) :exit-function))
             (candidate (car (all-completions "m10" table))))
        (should candidate)
        (pcase setting
          ('enabled (setq-local scss2-enable-emmet nil))
          ('dialect (setq scss2-dialect 'scss))
          ('indent (setq-local scss2-indent-offset 4))
          ('provider (setq-local emmet2-context-provider (copy-sequence emmet2-context-provider))))
        (should-not (all-completions "m10" table))
        (funcall exit candidate 'finished)
        (should (equal (buffer-string) source))))))

(ert-deftest scss2-emmet-extraction-preserves-leading-multiline-comments ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '((".a { /*\n (*/m10| }" ".a { /*\n (*/margin: 10px; }")
                    (".a { /*\n p[*/m10|] }" ".a { /*\n p[*/margin: 10px;] }")))
      (scss2-emmet-test--buffer (car case)
        (let ((position (point))) (funcall mode) (goto-char position))
        (let ((before (buffer-string)) (analysis (emmet2-context-analyze)))
          (should (equal (plist-get analysis :abbr) "m10"))
          (should (= (plist-get analysis :beg) (plist-get (scss2-context-at-point) :start)))
          (buffer-enable-undo)
          (scss2-expand)
          (should (equal (buffer-string) (cadr case)))
          (let ((inhibit-message t)) (undo))
          (should (equal (buffer-string) before)))))))

(ert-deftest scss2-emmet-narrowing-must-include-the-entire-abbreviation ()
  (dolist (side '(left right))
    (scss2-emmet-test--buffer ".a { m10|+p20 }"
      (if (eq side 'right) (narrow-to-region (point-min) (point))
        (forward-char 4)
        (narrow-to-region (- (point) 3) (point-max)))
      (let ((before (buffer-string)))
        (should-not (emmet2-context-analyze))
        (should-not (scss2-emmet-completion-at-point))
        (should-error (scss2-expand) :type 'user-error)
        (should (equal (buffer-string) before))))))

(ert-deftest scss2-emmet-extraction-reads-font-lock-view ()
  ;; With `font-lock-dont-widen', text past the restriction belongs to the host.
  (scss2-emmet-test--buffer ".a { m10|+p20 }"
    (setq-local font-lock-dont-widen t)
    (narrow-to-region (point-min) (point))
    (should (equal (plist-get (emmet2-context-analyze) :abbr) "m10"))))

(ert-deftest scss2-emmet-font-lock-view-invalidates-native-candidates ()
  (scss2-emmet-test--buffer ".a {\n  m10|\n}"
    (let ((source (buffer-string)))
      ;; Only the widened view sees the rule that makes m10 a declaration.
      (narrow-to-region (line-beginning-position) (point))
      (let* ((queried (nth 2 (scss2-emmet-completion-at-point)))
             (exit (plist-get (nthcdr 3 (scss2-emmet-completion-at-point)) :exit-function)))
        (should (all-completions "m10" queried))
        (setq-local font-lock-dont-widen t)
        (should-not (emmet2-context-analyze))
        (should-not (all-completions "m10" queried))
        ;; Acceptance revalidates a table that no query has invalidated.
        (funcall exit "m10" 'finished)
        (widen)
        (should (equal (buffer-string) source))))))

(ert-deftest scss2-emmet-dispatcher-analyzes-once-without-retaining-context ()
  (dolist (input '("m1" "dis" "ovh,ta"))
    (scss2-emmet-test--buffer (concat ".a { " input "| }")
      (let ((calls 0) (original (symbol-function 'scss2-context-at-point)))
        (cl-letf (((symbol-function 'scss2-context-at-point)
                   (lambda () (cl-incf calls) (funcall original))))
          (let* ((data (scss2-completion-at-point)) (table (nth 2 data)))
            (should (= calls 1))
            (dotimes (_ 3) (all-completions input table))
            (should (= calls 1))
            (when (equal input "m1")
              (insert "0")
              (should (all-completions "m10" table))
              (should (= calls 2)))))))))

(ert-deftest scss2-emmet-descriptors-use-native-choices-and-undo ()
  (dolist (name '("src" "syntax" "inherits" "additive-symbols"))
    (scss2-emmet-test--buffer (concat ".a { " name "| }")
      (when-let* ((capf (scss2-completion-at-point)))
        (let ((rows (funcall (plist-get (nthcdr 3 capf) :affixation-function)
                             (all-completions name (nth 2 capf)))))
          (should-not (member (concat name ": ;") (mapcar #'cadr rows)))))))
  (dolist (case '(("@font-face { sr| }" "src: ;" "@font-face { src: ; }")
                  ("@property --tone { synt| }" "syntax: ;" "@property --tone { syntax: ; }")
                  ("@page { size| }" "size: ;" "@page { size: ; }")))
    (scss2-emmet-test--buffer (car case)
      (buffer-enable-undo)
      (let* ((before (buffer-string))
             (capf (scss2-completion-at-point)) (props (nthcdr 3 capf))
             (input (buffer-substring-no-properties (car capf) (point)))
             (candidates (all-completions input (nth 2 capf)))
             (rows (funcall (plist-get props :affixation-function) candidates))
             (index (cl-position (nth 1 case) (mapcar #'cadr rows) :test #'equal)))
        (should index)
        (funcall (plist-get props :exit-function) (nth index candidates) 'finished)
        (should (equal (buffer-string) (nth 2 case)))
        (should (eq (char-after) ?\;))
        (let ((inhibit-message t)) (undo-only 1))
        (should (equal (buffer-string) before))))))

(ert-deftest scss2-emmet-colon-hands-completion-to-values ()
  (scss2-emmet-test--buffer ".a { display| }"
    (let* ((capf (scss2-completion-at-point))
           (old (car (all-completions "display" (nth 2 capf)))))
      (insert ": fl")
      (should-not (all-completions "display: fl" (nth 2 capf)))
      (funcall (plist-get (nthcdr 3 capf) :exit-function) old 'finished)
      (should (equal (buffer-string) ".a { display: fl }"))
      (let ((values (scss2-completion-at-point)))
        (should (eq (completion-metadata-get (completion-metadata "fl" (nth 2 values) nil) 'category) 'scss2))
        (should (member "flex" (all-completions "fl" (nth 2 values))))))))

(provide 'scss2-emmet-test)
