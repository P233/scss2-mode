;;; scss2-xref-test.el --- Definition navigation contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'xref)
(require 'project)
(require 'scss2-mode)
(require 'css2-mode)

(defmacro scss2-xref-test--with (dialect source &rest body)
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

(defun scss2-xref-test--definitions ()
  "Request definitions through the registered backend."
  (let ((backend (xref-find-backend)))
    (should (eq backend 'scss2))
    (when-let* ((identifier (xref-backend-identifier-at-point backend)))
      (xref-backend-definitions backend identifier))))

(defun scss2-xref-test--target (text)
  "Assert a single definition whose location starts with TEXT."
  (let ((definitions (scss2-xref-test--definitions)))
    (should (= (length definitions) 1))
    (let ((marker (xref-location-marker (xref-item-location (car definitions)))))
      (unwind-protect
          (with-current-buffer (marker-buffer marker)
            (save-excursion
              (goto-char marker)
              (should (looking-at-p (regexp-quote text)))))
        (set-marker marker nil)))))

(ert-deftest scss2-xref-variable-lexical-scopes ()
  (dolist (case '(("$x: module; .a { $x: local; color: $x|; }" "$x: local")
                  ("$x: module; .a { $x: local; } .b { color: $x|; }" "$x: module")
                  ("$x: module; .a { color: $x|; $x: later; }" "$x: module")
                  ("$x: first; $x: second; .a { color: $x|; }" "$x: second")
                  ("$x: module; .a { $x: outer; .b { $x: inner; color: $x|; } }" "$x: inner")
                  ("$x: module; .a { $x: $x|; }" "$x: module")))
    (scss2-xref-test--with 'scss (car case)
      (scss2-xref-test--target (cadr case)))))

(ert-deftest scss2-xref-global-assignments ()
  (dolist (case '(("$x: module; .a { $x: changed !global; } .b { color: $x|; }" "$x: changed")
                  (".a { $x: created !global; } .b { color: $x|; }" "$x: created")
                  ("$x: module; .a { $x: local; .b { $x: changed !global; } color: $x|; }" "$x: local")
                  ("$x: module; .a { color: $x|; $x: later !global; }" "$x: module")))
    (scss2-xref-test--with 'scss (car case)
      (scss2-xref-test--target (cadr case)))))

(ert-deftest scss2-xref-lexical-binders ()
  (dolist (case '(("@mixin m($x) { color: $x|; }" "$x)")
                  ("$x: module; @mixin m($x) { color: $x|; }" "$x)")
                  ("@function f($x, $y: $x|) { @return $y; }" "$x,")
                  ("@each $x in red { color: $x|; }" "$x in")
                  ("@for $i from 1 through 3 { width: $i|; }" "$i from")
                  ("@include m using ($x) { color: $x|; }" "$x)")))
    (scss2-xref-test--with 'scss (car case)
      (scss2-xref-test--target (cadr case)))))

(ert-deftest scss2-xref-callable-and-placeholder-kinds ()
  (dolist (case '(("@mixin paint() {} @include pa|int;" "paint()")
                  ("@function tint() { @return red; } .a { color: ti|nt(); }" "tint()")
                  ("%shared { color: red; } .a { @extend %sha|red; }" "%shared {")
                  (".a %shared { color: red; } .b { @extend %shared|; }" "%shared {")))
    (scss2-xref-test--with 'scss (car case)
      (scss2-xref-test--target (cadr case)))))

(ert-deftest scss2-xref-identifiers-are-stable-and-kind-specific ()
  (dolist (case '((".a { color: ns.$to|ne; }" (variable "ns" "$tone"))
                  ("@include ns.pa|int;" (mixin "ns" "paint"))
                  (".a { color: ns.ti|nt(); }" (function "ns" "tint"))
                  (".a { @extend %sha|red; }" (placeholder nil "%shared"))))
    (scss2-xref-test--with 'scss (car case)
      (let ((identifier (xref-backend-identifier-at-point 'scss2)))
        (should (equal (get-text-property 0 'scss2-reference identifier) (cadr case)))
        (should (equal (substring-no-properties identifier)
                       (concat (and (nth 1 (cadr case)) (concat (nth 1 (cadr case)) "."))
                               (nth 2 (cadr case)))))
        (forward-char 1)
        (should (equal identifier (xref-backend-identifier-at-point 'scss2)))))))

(ert-deftest scss2-xref-sass-identity-preserves-case ()
  (scss2-xref-test--with 'scss "$tone_name: red; .a { color: $tone-name|; }"
    (scss2-xref-test--target "$tone_name:"))
  (scss2-xref-test--with 'scss "@mixin p\\61 int() {} @include paint|;"
    (scss2-xref-test--target "p\\61 int()"))
  (scss2-xref-test--with 'scss "$Tone: red; .a { color: $tone|; }"
    (should-not (scss2-xref-test--definitions))))

(ert-deftest scss2-xref-modules-use-completion-resolution ()
  (let* ((directory (make-temp-file "scss2-xref-" t))
         (path (expand-file-name "_theme.scss" directory))
         (module-buffer nil))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "$tone: red;\n@mixin paint() {}\n@function tint() { @return red; }\n"))
          (dolist (alias '(nil "ui"))
            (dolist (case '(("$tone|" "$tone:") ("paint|" "paint()") ("tint|()" "tint()")))
              (let* ((namespace (or alias "theme"))
                     (member (car case))
                     (source (concat "@use 'theme'" (and alias (concat " as " alias)) ";\n"
                                     (if (equal member "paint|") "@include " ".a { color: ")
                                     namespace "." member ";" (unless (equal member "paint|") " }"))))
                (scss2-xref-test--with 'scss source
                  (setq buffer-file-name (expand-file-name "main.scss" directory))
                  (let* ((definitions (scss2-xref-test--definitions))
                         (location (xref-item-location (car definitions))))
                    (should (= (length definitions) 1))
                    (should (equal (xref-file-location-file location) path)))
                  (scss2-xref-test--target (cadr case))
                  (setq module-buffer (find-buffer-visiting path))
                  (when module-buffer (kill-buffer module-buffer) (setq module-buffer nil)))))))
      (when module-buffer (kill-buffer module-buffer))
      (delete-directory directory t))))

(ert-deftest scss2-xref-unsaved-module-buffers-are-authoritative ()
  (let* ((directory (make-temp-file "scss2-xref-open-" t))
         (path (expand-file-name "_theme.scss" directory))
         (module (generate-new-buffer " *scss2 xref module*")))
    (unwind-protect
        (progn
          (with-temp-file path (insert "$saved: red;"))
          (dolist (parsed '(nil t))
            (with-current-buffer module
              (fundamental-mode)
              (erase-buffer)
              (setq buffer-file-name path)
              (insert "// unsaved\n$tone: blue;\n")
              (when parsed (scss2-mode))
              (narrow-to-region (point-max) (point-max)))
            (scss2-xref-test--with 'scss "@use 'theme'; .a { color: theme.$tone|; }"
              (setq buffer-file-name (expand-file-name "main.scss" directory))
              (let* ((definition (car (scss2-completion-definitions (scss2-completion-reference-at-point))))
                     (results (scss2-xref-test--definitions)))
                (should (= (plist-get definition :line) 2))
                (should (= (plist-get definition :position) 12))
                (should (eq (plist-get definition :buffer) module))
                (should (= (length results) 1))
                (with-current-buffer module
                  (should (buffer-narrowed-p)))))))
      (kill-buffer module)
      (delete-directory directory t))))

(ert-deftest scss2-xref-unresolved-modules-and-private-exports ()
  (let* ((directory (make-temp-file "scss2-xref-missing-" t))
         (path (expand-file-name "_theme.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "@forward 'other'; $-private: red; .a { $nested: red; }"))
          (dolist (source '("@use 'sass:math'; .a { x: math.abs|(); }"
                            "@use 'pkg:theme'; .a { x: theme.$tone|; }"
                            "@use 'load-path-only'; .a { x: load-path-only.$tone|; }"
                            "@use 'theme'; .a { x: theme.$forwarded|; }"
                            "@use 'theme'; .a { x: theme.$-private|; }"
                            "@use 'theme'; .a { x: theme.$nested|; }"))
            (scss2-xref-test--with 'scss source
              (setq buffer-file-name (expand-file-name "main.scss" directory))
              (should-not (scss2-xref-test--definitions)))))
      (delete-directory directory t))))

(ert-deftest scss2-xref-custom-properties-use-all-declarations ()
  (dolist (dialect '(css scss))
    (scss2-xref-test--with dialect ":root { --tone: red; } .a { --tone: blue; color: var(--to|ne); }"
      (should (= (length (scss2-xref-test--definitions)) 2)))
    (scss2-xref-test--with dialect ":root { --Tone: red; } .a { color: var(--tone|); }"
      (should-not (scss2-xref-test--definitions)))
    (scss2-xref-test--with dialect ":root { --tone: red; } .a { color: fn(--tone|); }"
      (should-not (xref-backend-identifier-at-point 'scss2)))))

(ert-deftest scss2-xref-css-has-no-sass-definitions ()
  (dolist (source '("$x: red; .a { color: $x|; }" "@mixin m() {} @include m|;"
                    "@function f() { @return red; } .a { color: f|(); }"
                    "%p {} .a { @extend %p|; }"))
    (scss2-xref-test--with 'css source
      (should-not (xref-backend-identifier-at-point 'scss2))
      (should-not (scss2-completion-definitions (scss2-completion-reference-at-point))))))

(ert-deftest scss2-xref-unresolved-uses-the-standard-message ()
  (scss2-xref-test--with 'scss ".a { color: $unknown|; }"
    (let* ((identifier (xref-backend-identifier-at-point 'scss2))
           (error (should-error (xref-find-definitions identifier) :type 'user-error)))
      (should (equal "No definitions found for: $unknown" (error-message-string error))))))

(ert-deftest scss2-xref-damaged-input-does-not-signal ()
  (dolist (dialect '(css scss))
    (dolist (source '("|" "$|" "@include |" ".a { color: ns.$x|" ".a { @extend %x|"
                      "@function f($x { @return $x|" ".a { color: var(--x|"))
      (scss2-xref-test--with dialect source
        (let ((text (buffer-string)) (position (point)))
          (scss2-xref-test--definitions)
          (should (equal text (buffer-string)))
          (should (= position (point))))
        (should-not (scss2-completion-definitions nil)))))
  (scss2-xref-test--with 'scss "$x: red; .a { color: $x|"
    (scss2-xref-test--target "$x:")))

(ert-deftest scss2-xref-narrowing-reads-wide-and-preserves-restriction ()
  (dolist (dialect '(css scss))
    (scss2-xref-test--with dialect
        (if (eq dialect 'scss) "$x: red;\n.a { color: $x|; }"
          ":root { --x: red; }\n.a { color: var(--x|); }")
      (let ((position (point)))
        (goto-char (point-min))
        (forward-line 1)
        (narrow-to-region (point) (point-max))
        (goto-char position)
        (let ((minimum (point-min))
              (definition (car (scss2-completion-definitions (scss2-completion-reference-at-point)))))
          (should (< (plist-get definition :position) minimum))
          (should (= (length (scss2-xref-test--definitions)) 1))
          (should (= minimum (point-min)))
          (should (= position (point)))))))
  (scss2-xref-test--with 'scss ".a { $x: red; color: $x|; }"
    (narrow-to-region 5 (point-max))
    (scss2-xref-test--target "$x:")))

(ert-deftest scss2-xref-registration-is-buffer-local ()
  (let ((global (default-value 'xref-backend-functions)))
    (scss2-xref-test--with 'scss "$x: red; color: $x|;"
      (should (local-variable-p 'xref-backend-functions))
      (should (memq #'scss2--xref-backend xref-backend-functions)))
    (should (equal global (default-value 'xref-backend-functions)))))

(ert-deftest scss2-xref-interpolation-token-endpoints ()
  (dolist (value '("-#{math.div($s|, 2)}" "a#{$s|}b" "#{$s|}-x" "foo-#{bar($s|)}"))
    (scss2-xref-test--with 'scss (concat "$s: 1; .a { margin-top: " value "; }")
      (should (equal (xref-backend-identifier-at-point 'scss2) "$s"))
      (scss2-xref-test--target "$s:")))
  (scss2-xref-test--with 'scss "@function f($x) { @return $x; } .a { x: -#{f|(1)}; }"
    (should (equal (xref-backend-identifier-at-point 'scss2) "f"))
    (scss2-xref-test--target "f($x)")))

(ert-deftest scss2-xref-module-qualifier-is-the-same-identifier ()
  (dolist (source '(".a { color: ns.$tone; }" ".a { color: ns.tint(); }" "@include ns.paint;"))
    (with-temp-buffer
      (insert source)
      (scss2-mode)
      (goto-char (point-min))
      (search-forward "ns.")
      (let* ((start (- (point) 3))
             (end (save-excursion (skip-syntax-forward "w_") (point)))
             (identifier (xref-backend-identifier-at-point 'scss2)))
        (should identifier)
        (dolist (position (number-sequence start end))
          (goto-char position)
          (should (equal-including-properties identifier (xref-backend-identifier-at-point 'scss2))))))))

(ert-deftest scss2-xref-callable-bodies-see-first-later-module-binding ()
  (dolist (case '(("@mixin m { color: $x|; } $x: first; $x: second;" "$x: first")
                  ("@function f() { @return $x|; } $x: first;" "$x: first")
                  ("@mixin m { @include later|; } @mixin later() {}" "later()")
                  ("@function f() { @return later|(); } @function later() { @return 1; }" "later()")
                  ("@mixin m { .a { color: $x|; } } $x: first;" "$x: first")
                  ("$x: before; @mixin m { color: $x|; } $x: after;" "$x: before")))
    (scss2-xref-test--with 'scss (car case)
      (scss2-xref-test--target (cadr case))))
  (dolist (source '(".a { color: $x|; } $x: later;" "@include later|; @mixin later() {}"
                    ".a { color: later|(); } @function later() { @return 1; }"))
    (scss2-xref-test--with 'scss source
      (should-not (scss2-xref-test--definitions)))))

(ert-deftest scss2-xref-keyword-arguments-resolve-only-callee-parameters ()
  (dolist (case '(("$size: global; @mixin m($size) {} @include m($size|: 2);" "$size)")
                  ("$size: global; @function f($size) { @return $size; } .a { x: f($size|: 2); }" "$size)")))
    (scss2-xref-test--with 'scss (car case)
      (scss2-xref-test--target (cadr case))))
  (dolist (source '("$size: global; @include missing($size|: 2);"
                    "$size: global; .a { x: missing($size|: 2); }"
                    "$size: global; @mixin m($other) {} @include m($size|: 2);"))
    (scss2-xref-test--with 'scss source
      (should-not (scss2-xref-test--definitions))))
  (let* ((directory (make-temp-file "scss2-xref-keyword-" t))
         (path (expand-file-name "_theme.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "@mixin m($size) {}\n@function f($size) { @return $size; }"))
          (dolist (call '("@include theme.m($size|: 2);" ".a { x: theme.f($size|: 2); }"))
            (scss2-xref-test--with 'scss (concat "@use 'theme'; $size: global; " call)
              (setq buffer-file-name (expand-file-name "main.scss" directory))
              (let ((definition (car (scss2-completion-definitions
                                      (scss2-completion-reference-at-point)))))
                (should (equal (plist-get definition :file) path))
                (should (= (plist-get definition :column) (if (string-prefix-p "@include" call) 9 12)))))))
      (when-let* ((buffer (find-buffer-visiting path))) (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest scss2-xref-typed-identifiers-fall-back-by-kind ()
  (scss2-xref-test--with 'scss
      "$tone: red; @mixin paint() {} @function tint() { @return 1; } %shared {} :root { --x: red; } .a { color: |; }"
    (dolist (identifier '("$tone" "paint" "tint" "%shared" "--x"))
      (should (= (length (xref-backend-definitions 'scss2 identifier)) 1)))))

(ert-deftest scss2-xref-prompt-default-is-plain-symbol-text ()
  (scss2-xref-test--with 'scss "$local: red; .a { color: $local|; }"
    (let ((current-prefix-arg '(4)) prompt default)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (text _table &rest args)
                   (setq prompt text default (nth 4 args))
                   default)))
        (should (equal (xref--read-identifier "Find definitions of: ") "$local")))
      (should (equal (substring-no-properties default) "$local"))
      (should (string-match-p (regexp-quote "$local") prompt)))))

(ert-deftest scss2-xref-stock-references-fallback-uses-plain-text ()
  (let* ((directory (make-temp-file "scss2-xref-references-" t))
         (path (expand-file-name "main.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "$local: red;\n.a { color: $local; }\n.b { color: $local; }\n"))
          (scss2-xref-test--with 'scss "$local: red;\n.a { color: $local|; }\n.b { color: $local; }\n"
            (setq buffer-file-name path default-directory directory)
            (let ((xref-search-program 'grep) results
                  (identifier (xref-backend-identifier-at-point 'scss2)))
              (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (cons 'transient directory))))
                (let ((xref-show-xrefs-function (lambda (fetcher _alist) (setq results (funcall fetcher)))))
                  (xref-find-references identifier)))
              (should (>= (length results) 2))
              (dolist (result results)
                (should (string-match-p (regexp-quote "$local") (xref-item-summary result)))))))
      (delete-directory directory t))))

(ert-deftest scss2-xref-indirect-clone-has-no-backend ()
  (scss2-xref-test--with 'scss "$x: red; .a { color: $x|; }"
    (let ((clone (clone-indirect-buffer " *scss2 xref clone*" nil)))
      (unwind-protect
          (with-current-buffer clone
            (should-not (treesit-parser-list))
            (should-not (scss2--xref-backend))
            (should-not (xref-find-backend))
            (let* ((this-command 'xref-find-definitions)
                   (error (should-error (call-interactively #'xref-find-definitions) :type 'user-error)))
              (should (string-match-p "No Xref backend" (error-message-string error)))))
        (kill-buffer clone)))))

(ert-deftest scss2-xref-narrowed-result-set-straddles-restriction ()
  (scss2-xref-test--with 'css ":root { --x: red; }\n.a { --x: blue; color: var(--x|); }"
    (let ((origin (point)))
      (goto-char (point-min)) (forward-line 1)
      (narrow-to-region (point) (point-max))
      (goto-char origin)
      (let* ((minimum (point-min)) (maximum (point-max))
             (results (scss2-xref-test--definitions))
             (positions (mapcar (lambda (result)
                                  (marker-position (xref-location-marker (xref-item-location result)))) results)))
        (should (= (length results) 2))
        (should (< (car positions) minimum))
        (should (<= minimum (cadr positions) maximum))
        (should (= origin (point)))
        (should (= minimum (point-min)))
        (should (= maximum (point-max)))))))

(ert-deftest scss2-xref-jump-obeys-widen-automatically ()
  (dolist (allow '(nil t))
    (scss2-xref-test--with 'scss "$x: red;\n.a { color: $x|; }"
      (save-window-excursion
        (set-window-buffer (selected-window) (current-buffer))
        (let ((origin (point)) (widen-automatically allow))
          (goto-char (point-min)) (forward-line 1)
          (narrow-to-region (point) (point-max)) (goto-char origin)
          (let ((identifier (xref-backend-identifier-at-point 'scss2)))
            (if allow
                (progn
                  (xref-find-definitions identifier)
                  (should-not (buffer-narrowed-p))
                  (should (= (point) 1))
                  (xref-go-back)
                  (should (= (point) origin)))
              (should-error (xref-find-definitions identifier))
              (should (buffer-narrowed-p))
              (should (= (point) origin)))))))))

(ert-deftest scss2-xref-open-buffer-results-have-bounded-summaries ()
  (scss2-xref-test--with 'css
      (concat "  :root { --x: " (make-string 200 ?r) "; }\n  .a { --x: blue; color: var(--x|); }")
    (setq buffer-file-name (expand-file-name "scss2-xref-summary.css" temporary-file-directory))
    (let ((results (scss2-xref-test--definitions)))
      (should (= (length results) 2))
      (dolist (result results)
        (should (xref-buffer-location-p (xref-item-location result)))
        (should (<= (length (xref-item-summary result)) 160))
        (should-not (string-match-p "\\`[ \t]" (xref-item-summary result)))))))

(ert-deftest scss2-xref-unopened-module-results-use-file-lines ()
  (let* ((directory (make-temp-file "scss2-xref-" t))
         (path (expand-file-name "_theme.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "// palette\n$tone: red;\n"))
          (scss2-xref-test--with 'scss "@use 'theme';\n.a { color: theme.$tone|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (let ((definition (car (scss2-completion-definitions (scss2-completion-reference-at-point))))
                  (location (xref-item-location (car (scss2-xref-test--definitions)))))
              (should-not (plist-get definition :buffer))
              (should (xref-file-location-p location))
              (should (= (xref-location-line location) 2)))
            (should-not (find-buffer-visiting path))))
      (delete-directory directory t))))

(ert-deftest scss2-xref-open-buffer-jumps-skip-file-checks ()
  (let* ((directory (make-temp-file "scss2-xref-" t))
         (path (expand-file-name "main.scss" directory))
         (buffer nil) (prompts 0))
    (unwind-protect
        (progn
          (with-temp-file path (insert "$local: blue;\n.a { color: $local; }\n"))
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer (scss2-mode))
          ;; Another program rewrites the file while its buffer is open.
          (with-temp-buffer
            (insert "// regenerated\n")
            (write-region nil nil path nil 'silent))
          (set-file-times path (time-add (current-time) 10))
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "color: $loc")
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf prompts) nil))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf prompts) nil)))
              (scss2-xref-test--target "$local: blue")))
          (should (= prompts 0)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest scss2-xref-parameter-defaults-see-later-module-bindings ()
  (dolist (case '(("@mixin m($a: $later|) { color: $a; } $later: 1;" "$later: 1")
                  ("@function f($p: later|()) { @return $p; } @function later() { @return 1; }" "later()")))
    (scss2-xref-test--with 'scss (car case)
      (scss2-xref-test--target (cadr case))))
  (scss2-xref-test--with 'scss "@mixin m($a|: 1) { color: $a; } $a: 2;"
    (let ((later (save-excursion (goto-char (point-min)) (search-forward "$a: 2") (match-beginning 0))))
      (should-not (cl-find later (scss2-completion-definitions (scss2-completion-reference-at-point))
                           :key (lambda (definition) (plist-get definition :position)))))))

(ert-deftest scss2-xref-module-resolution-is-read-once ()
  (let* ((directory (make-temp-file "scss2-xref-once-" t))
         (path (expand-file-name "_theme.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "$tone: red;"))
          (scss2-xref-test--with 'scss "@use 'theme'; .a { color: theme.$tone|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (let ((resolve (symbol-function 'scss2-completion--module-path))
                  (visiting (symbol-function 'find-buffer-visiting)) (paths 0) (buffers 0))
              (cl-letf (((symbol-function 'scss2-completion--module-path)
                         (lambda (&rest args) (cl-incf paths) (apply resolve args)))
                        ((symbol-function 'find-buffer-visiting)
                         (lambda (&rest args) (cl-incf buffers) (apply visiting args))))
                (should (= (length (scss2-xref-test--definitions)) 1)))
              (should (= paths 1))
              (should (= buffers 1)))))
      (delete-directory directory t))))

(ert-deftest scss2-xref-definition-jump-back-and-other-window ()
  (dolist (command '(xref-find-definitions xref-find-definitions-other-window))
    (scss2-xref-test--with 'scss "$local: red;\n.a { color: $local|; }"
      (save-window-excursion
        (delete-other-windows)
        (set-window-buffer (selected-window) (current-buffer))
        (let ((origin (point)) (window (selected-window)))
          (funcall command (xref-backend-identifier-at-point 'scss2))
          (should (= (point) 1))
          (when (eq command 'xref-find-definitions-other-window)
            (should-not (eq window (selected-window))))
          (xref-go-back)
          (should (= (point) origin)))))))

(provide 'scss2-xref-test)
;;; scss2-xref-test.el ends here
