;;; scss2-eldoc-test.el --- Sass signature contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'scss2-mode)
(require 'css2-mode)

(defmacro scss2-eldoc-test--with (dialect source &rest body)
  "Run BODY in DIALECT's SOURCE, using | for point."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (insert ,source)
     (goto-char (point-min))
     (search-forward "|")
     (delete-char -1)
     (let ((position (point)) (scss2-fontify-colors nil))
       (funcall (if (eq ,dialect 'css) #'css2-mode #'scss2-mode))
       (goto-char position)
       ,@body)))

(defun scss2-eldoc-test--documentation ()
  "Request the signature through the registered provider."
  (when (eq scss2-dialect 'scss)
    (should (memq #'scss2-eldoc-function eldoc-documentation-functions)))
  (let (documentation)
    (scss2-eldoc-function (lambda (&rest result) (setq documentation result)))
    documentation))

(defun scss2-eldoc-test--expect (thing signature highlighted)
  "Assert THING, SIGNATURE and HIGHLIGHTED parameter text from eldoc."
  (let* ((documentation (scss2-eldoc-test--documentation))
         (text (car documentation))
         (properties (cdr documentation))
         (position 0) marked)
    (should (equal (plist-get properties :thing) thing))
    (should (eq (plist-get properties :face) 'font-lock-function-name-face))
    (should (equal (substring-no-properties text) signature))
    (while (< position (length text))
      (let ((end (next-single-property-change position 'face text (length text))))
        (when (eq (get-text-property position 'face text) 'eldoc-highlight-function-argument)
          (push (substring-no-properties text position end) marked))
        (setq position end)))
    (should (equal (nreverse marked) (and highlighted (list highlighted))))))

(ert-deftest scss2-eldoc-positional-and-defaults ()
  (dolist (case '(("|" "$a") ("1, |" "$b: fn(1, 2)") ("1, 2, |" nil)))
    (scss2-eldoc-test--with 'scss
        (concat "@mixin paint($a, $b: fn(1, 2)) {} @include paint(" (car case) ");")
      (scss2-eldoc-test--expect "paint" "($a, $b: fn(1, 2))" (cadr case))))
  (scss2-eldoc-test--with 'scss "@mixin empty {} @include empty(|);"
    (scss2-eldoc-test--expect "empty" "()" nil)))

(ert-deftest scss2-eldoc-keyword-identity-and-rest ()
  (dolist (case '(("$amount: |" "$amount: 10") ("$base_color: |" "$base-color")
                  ("$base\\-color: |" "$base-color") ("$Amount: |" "$args...")
                  ("$unknown: |" "$args...") ("1, 2, 3, |" "$args...")
                  ("$args: |" "$args...")))
    (scss2-eldoc-test--with 'scss
        (concat "@function tint($base-color, $amount: 10, $args...) { @return red; } .a { color: tint("
                (car case) "); }")
      (scss2-eldoc-test--expect "tint" "($base-color, $amount: 10, $args...)" (cadr case))))
  (scss2-eldoc-test--with 'scss
      "@function tint($a) { @return $a; } .a { x: tint($missing: |); }"
    (scss2-eldoc-test--expect "tint" "($a)" nil)))

(ert-deftest scss2-eldoc-innermost-call-and-nested-values ()
  (let ((prefix "@mixin paint($a, $b) {} @function tint($x, $amount: 2) { @return $x; } "))
    (scss2-eldoc-test--with 'scss (concat prefix "@include paint(tint(1, |), 3);")
      (scss2-eldoc-test--expect "tint" "($x, $amount: 2)" "$amount: 2"))
    (dolist (source '("@include paint(tint(1, 2)|, 3);"
                      "@include paint((a: 1, b: 2), |);"
                      "@include paint('a,b', /* , */ |);"))
      (scss2-eldoc-test--with 'scss (concat prefix source)
        (scss2-eldoc-test--expect "paint" "($a, $b)"
                                 (if (string-match-p "2)|" source) "$a" "$b"))))
    (scss2-eldoc-test--with 'scss (concat prefix "@include paint(calc(|), 3);")
      (should-not (scss2-eldoc-test--documentation)))))

(ert-deftest scss2-eldoc-local-lookup-keeps-lexical-precedence ()
  (scss2-eldoc-test--with 'scss
      "@mixin paint($outer) {} .a { @mixin paint($inner) {} @include paint(|); }"
    (scss2-eldoc-test--expect "paint" "($inner)" "$inner"))
  (scss2-eldoc-test--with 'scss
      "@mixin wrapper { @include later(|); } @mixin later($x) {}"
    (scss2-eldoc-test--expect "later" "($x)" "$x")))

(ert-deftest scss2-eldoc-modules-and-aliases ()
  (let* ((directory (make-temp-file "scss2-eldoc-" t))
         (path (expand-file-name "_theme.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "@mixin paint($a, $b: 2) {}\n@function tint($x) { @return $x; }"))
          (dolist (case '(("@use 'theme'; @include theme.paint(1, |);" "theme.paint" "($a, $b: 2)" "$b: 2")
                          ("@use 'theme' as ns; @include ns.paint(1, |);" "ns.paint" "($a, $b: 2)" "$b: 2")
                          ("@use 'theme'; .a { x: theme.tint(|); }" "theme.tint" "($x)" "$x")
                          ("@use 'theme' as ns; .a { x: ns.tint(|); }" "ns.tint" "($x)" "$x")))
            (scss2-eldoc-test--with 'scss (car case)
              (setq buffer-file-name (expand-file-name "main.scss" directory))
              (cl-letf (((symbol-function 'find-file-noselect)
                         (lambda (&rest _) (ert-fail "Eldoc must not visit files"))))
                (apply #'scss2-eldoc-test--expect (cdr case)))
              (should-not (find-buffer-visiting path)))))
      (delete-directory directory t))))

(ert-deftest scss2-eldoc-unsaved-modules-without-file-prompts ()
  (let* ((directory (make-temp-file "scss2-eldoc-open-" t))
         (path (expand-file-name "_theme.scss" directory))
         (module (generate-new-buffer " *scss2 eldoc module*")))
    (unwind-protect
        (progn
          (with-temp-file path (insert "@mixin paint($disk) {}"))
          (dolist (parsed '(nil t))
            (with-current-buffer module
              (fundamental-mode)
              (erase-buffer)
              (insert "@mixin paint($unsaved: (a: 1, b: 2)) {}")
              (setq buffer-file-name path)
              (when parsed (scss2-mode))
              (goto-char (point-max))
              (narrow-to-region (point) (point)))
            (set-file-times path (time-add (current-time) 10))
            (scss2-eldoc-test--with 'scss "@use 'theme'; @include theme.paint(|);"
              (setq buffer-file-name (expand-file-name "main.scss" directory))
              (cl-letf (((symbol-function 'find-file-noselect) (lambda (&rest _) (ert-fail "File visit")))
                        ((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "File prompt")))
                        ((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "File prompt"))))
                (scss2-eldoc-test--expect "theme.paint" "($unsaved: (a: 1, b: 2))" "$unsaved: (a: 1, b: 2)")))
            (with-current-buffer module
              (should (buffer-narrowed-p))
              (should (= (point) (point-max)))
              (should (buffer-modified-p)))))
      (kill-buffer module)
      (delete-directory directory t))))

(ert-deftest scss2-eldoc-unresolved-css-and-content-decline ()
  (dolist (dialect '(scss css))
    (dolist (source '("@include missing(|);" ".a { x: missing(|); }" ".a { x: calc(|); }"
                      "@include paint() using ($x|) {}" "@mixin paint($x) { @content(|); }"))
      (scss2-eldoc-test--with dialect (concat "@mixin paint($a) {} " source)
        (let ((called nil))
          (should-not (scss2-eldoc-function (lambda (&rest _) (setq called t))))
          (should-not called))))))

(ert-deftest scss2-eldoc-outside-arguments-skips-lookup ()
  (dolist (dialect '(scss css))
    (dolist (source '("|" "@mixin paint($a|) {}" "@include paint|();"
                      "@include paint(|);" "@include paint()|;" ".a { color: |red; }"
                      "@include paint() using ($x|) {}"))
      (unless (and (eq dialect 'scss) (equal source "@include paint(|);"))
        (scss2-eldoc-test--with dialect source
          (cl-letf (((symbol-function 'scss2-completion-reference-at-point) (lambda () (ert-fail "Reference lookup")))
                    ((symbol-function 'scss2-completion-definitions) (lambda (&rest _) (ert-fail "Definition lookup")))
                    ((symbol-function 'treesit-query-capture) (lambda (&rest _) (ert-fail "Tree-wide query"))))
            (should-not (scss2-eldoc-test--documentation))))))))

(ert-deftest scss2-eldoc-damaged-input-does-not-signal ()
  (dolist (dialect '(scss css))
    (dolist (source '("|" "@include |(" "@include paint(|" "@include paint($x: |);"
                      "@mixin paint($x: fn(,) {} @include paint(|);" ".a { x: tint((|; }"))
      (scss2-eldoc-test--with dialect source
        (let ((text (buffer-string)) (position (point)))
          (scss2-eldoc-test--documentation)
          (should (equal text (buffer-string)))
          (should (= position (point))))))))

(ert-deftest scss2-eldoc-narrowing-preserves-point-and-restriction ()
  (dolist (dialect '(scss css))
    (scss2-eldoc-test--with dialect "@mixin paint($a, $b) {}\n@include paint(1, |);"
      (let ((origin (point)))
        (narrow-to-region (1- origin) origin)
        (if (eq dialect 'scss)
            (scss2-eldoc-test--expect "paint" "($a, $b)" "$b")
          (should-not (scss2-eldoc-test--documentation)))
        (should (= (point-min) (1- origin)))
        (should (= (point-max) origin))
        (should (= (point) origin))))))

(ert-deftest scss2-eldoc-registration-and-provider-fallback ()
  (let ((global (default-value 'eldoc-documentation-functions)))
    (dolist (dialect '(scss css))
      (scss2-eldoc-test--with dialect ".a { color: |red; }"
        (if (eq dialect 'scss)
            (should (memq #'scss2-eldoc-function eldoc-documentation-functions))
          (should-not (memq #'scss2-eldoc-function eldoc-documentation-functions))
          (should-not eldoc-mode)
          (should-not (memq #'eldoc-schedule-timer post-command-hook))
          (should-not (memq #'eldoc-pre-command-refresh-echo-area pre-command-hook)))
        (let ((fallback (lambda (_callback &rest _) "Other provider")))
          (add-hook 'eldoc-documentation-functions fallback t t)
          (should (equal (run-hook-with-args-until-success 'eldoc-documentation-functions #'ignore)
                         "Other provider")))))
    (should (equal global (default-value 'eldoc-documentation-functions)))))

(ert-deftest scss2-eldoc-unopened-module-uses-one-guarded-read ()
  (let* ((directory (make-temp-file "scss2-eldoc-read-" t))
         (path (expand-file-name "_theme.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "@mixin paint($a, $b: 2) {}"))
          (scss2-eldoc-test--with 'scss "@use 'theme'; @include theme.paint(1, |);"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (let ((read (symbol-function 'insert-file-contents))
                  (release (symbol-function 'treesit-parser-set-included-ranges))
                  (reads 0) (releases 0))
              (cl-letf (((symbol-function 'insert-file-contents)
                         (lambda (file &rest args)
                           (when (equal file path) (cl-incf reads))
                           (apply read file args)))
                        ((symbol-function 'treesit-parser-set-included-ranges)
                         (lambda (parser ranges)
                           (when (equal ranges '((1 . 1))) (cl-incf releases))
                           (funcall release parser ranges))))
                (scss2-eldoc-test--expect "theme.paint" "($a, $b: 2)" "$b: 2"))
              (should (= reads 1))
              (should (= releases 1)))
            (cl-letf (((symbol-function 'insert-file-contents)
                       (lambda (&rest _) (signal 'file-missing '("Module disappeared")))))
              (should-not (scss2-eldoc-test--documentation)))
            (should-not (find-buffer-visiting path))))
      (delete-directory directory t))))

(ert-deftest scss2-eldoc-dont-widen-ignores-host-comment ()
  (with-temp-buffer
    (insert "host /* opens a comment\n")
    (let ((begin (point)) end)
      (insert "@mixin paint($a, $b) {}\n.a { @include paint(1, ); }\n")
      (setq end (point))
      (insert "host closes */\n")
      (narrow-to-region begin end)
      (let ((scss2-fontify-colors nil)) (scss2-mode))
      (setq-local font-lock-dont-widen t)
      (goto-char begin)
      (search-forward "paint(1, ")
      (let ((origin (point)))
        (scss2-eldoc-test--expect "paint" "($a, $b)" "$b")
        (should (= origin (point)))
        (should (= begin (point-min)))
        (should (= end (point-max)))))))

(ert-deftest scss2-eldoc-display-sees-original-point-and-restriction ()
  (dolist (strategy '(eldoc-documentation-default eldoc-documentation-compose))
    (scss2-eldoc-test--with 'scss "@mixin paint($a, $b) {}\n@include paint(1, |);"
      (save-window-excursion
        (set-window-buffer (selected-window) (current-buffer))
        (let* ((origin (point)) (begin (1- origin)) (end (1+ origin))
               (eldoc-documentation-strategy strategy)
               (eldoc-documentation-functions '(scss2-eldoc-function))
               is-displayed
               (eldoc-display-functions
                (list (lambda (docs _interactive)
                        (should (= (point) origin))
                        (should (= (window-point) origin))
                        (should (= (point-min) begin))
                        (should (= (point-max) end))
                        (should (equal (caar docs) "($a, $b)"))
                        (should (equal (plist-get (cdar docs) :thing) "paint"))
                        (setq is-displayed t)))))
          (narrow-to-region begin end)
          (eldoc-print-current-symbol-info t)
          (should is-displayed))))))

(ert-deftest scss2-eldoc-normalizes-multiline-parameters ()
  (scss2-eldoc-test--with 'scss "@mixin m(\n  $a,\n  $b: 2 // c\n) {} @include m(1, |);"
    (scss2-eldoc-test--expect "m" "($a, $b: 2)" "$b: 2"))
  (scss2-eldoc-test--with 'scss
      "@mixin m($a /* name */: fn(1, /* value */ 2), $b: 'http://x') {} @include m(1, |);"
    (scss2-eldoc-test--expect "m" "($a : fn(1, 2), $b: 'http://x')" "$b: 'http://x'")))

(ert-deftest scss2-eldoc-content-block-and-opaque-arguments ()
  (dolist (source '("@include paint(1, |) using ($x) { color: $x; }"
                    "@include paint(1, |) { color: red; }"
                    "@include paint('first', 'sec|ond');"
                    "@include paint(1, /* sec|ond */ 2);"
                    "@include paint(1, // sec|ond\n 2);"))
    (scss2-eldoc-test--with 'scss (concat "@mixin paint($a, $b) { @content; } " source)
      (scss2-eldoc-test--expect "paint" "($a, $b)" "$b")))
  (scss2-eldoc-test--with 'scss "@mixin paint($a) {} @include paint|;"
    (should-not (scss2-eldoc-test--documentation))))

(ert-deftest scss2-eldoc-star-use-remains-unresolved ()
  (let* ((directory (make-temp-file "scss2-eldoc-star-" t))
         (path (expand-file-name "_theme.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "@mixin paint($a) {}"))
          (scss2-eldoc-test--with 'scss "@use 'theme' as *; @include paint(|);"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (should-not (scss2-eldoc-test--documentation))))
      (delete-directory directory t))))

(provide 'scss2-eldoc-test)
;;; scss2-eldoc-test.el ends here
