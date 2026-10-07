;;; scss2-edit-test.el --- Structural editor behavior -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'scss2-edit)
(require 'scss2-test-support)

;; Model Avy's special variables without loading the optional package.
(defvar avy-all-windows nil)
(defvar avy-all-windows-alt nil)

(defmacro scss2-edit-test--buffer (mode source &rest body)
  "Run BODY in MODE with SOURCE, using │ to indicate point."
  (declare (indent 2) (debug t))
  `(scss2-test-with-buffer ,mode ,source
     (let ((kill-ring '("previous kill"))
           (kill-ring-yank-pointer nil)
           (interprogram-cut-function nil)
           (interprogram-paste-function nil))
       (setq kill-ring-yank-pointer kill-ring)
       ,@body)))

(defun scss2-edit-test--unchanged (command)
  "Assert COMMAND fails without changing text, point, mark or the kill ring."
  (set-mark (point-min))
  (setq mark-active t)
  (let ((source (buffer-string)) (position (point))
        (saved-mark (mark)) (ring (copy-sequence kill-ring)))
    (should-error (funcall command))
    (should (equal source (buffer-string)))
    (should (= position (point)))
    (should (= saved-mark (mark)))
    (should mark-active)
    (should (equal ring kill-ring))
    (should (eq kill-ring-yank-pointer kill-ring))))

(defun scss2-edit-test--with-point ()
  "Return the buffer text with │ at point."
  (concat (buffer-substring-no-properties (point-min) (point)) "│"
          (buffer-substring-no-properties (point) (point-max))))

(ert-deftest scss2-edit-commands-ignore-prefix-arguments ()
  (dolist (source '(".a { color: re│d; width: 1px; }"
                    ".a { $m: (one: │1, two: 2); }"
                    ".outer { .a, .│b { color: red; } }"
                    "@if $x │> 0 { x: 1; } @else { x: 2; }"
                    "@include fo│o(1, 2);"
                    "@u│se 'sass:math';"))
    (dolist (command '(scss2-kill scss2-copy scss2-duplicate scss2-mark
                       scss2-empty scss2-comment-uncomment))
      (let (baseline)
        (dolist (prefix '(nil (4) (16) -))
          (scss2-edit-test--buffer 'scss2-mode source
            (let ((current-prefix-arg prefix) (pulse-flag nil) (last-command nil))
              (call-interactively command)
              (let ((result (list (buffer-substring-no-properties (point-min) (point-max))
                                  (point) (mark t) mark-active kill-ring)))
                (if prefix (should (equal result baseline)) (setq baseline result))))))))))

(ert-deftest scss2-edit-duplicate-keeps-literal-crlf-line-endings ()
  (dolist (case '((css2-mode ".a {\r\n  co│lor: red;\r\n}"
                            ".a {\r\n  color: red;\r\n  color: red;\r\n}")
                  (scss2-mode ".a {\r\n  co│lor: red;\r\n}"
                             ".a {\r\n  color: red;\r\n  color: red;\r\n}")
                  (scss2-mode "$x: 1;\r\n$│y: 2;" "$x: 1;\r\n$y: 2;\r\n$y: 2;")))
    (scss2-edit-test--buffer (car case) (cadr case)
      (let ((original (buffer-string)))
        (scss2-copy)
        (should (equal (buffer-string) original))
        (scss2-duplicate)
        (should-not (string-match-p "[^\r]\n" (buffer-string)))
        (should (equal (buffer-string) (nth 2 case)))))))

(ert-deftest scss2-edit-tab-indents-leading-whitespace-before-navigation ()
  (dolist (case '((scss2-mode "$_offset: lib.ensure-valid-offset($offset);"
                             "lib.ensure-valid-offset($offset);")
                  (css2-mode "width: calc(1rem + 2px);" "calc(1rem + 2px);")))
    (dolist (prefix '("│   " " │   " " \t│  "))
      (dolist (ending '("\n" "\r\n"))
        (scss2-edit-test--buffer (car case) (concat ".a {" ending prefix (cadr case) ending "}")
          (let ((scss2-indent-offset 2) (indent-tabs-mode nil))
            (scss2-tab)
            (should (equal (scss2-edit-test--with-point)
                           (concat ".a {" ending "  │" (cadr case) ending "}")))
            (scss2-tab)
            (should (looking-at-p (regexp-quote (nth 2 case))))
            (scss2-tab)
            (should (eq (char-before) ?\;))))))))

(ert-deftest scss2-edit-tab-leading-whitespace-keeps-line-indentation-policy ()
  (dolist (case '((".a {\n│ color: red;\n}" ".a {\n    │color: red;\n}")
                  (".a {\n  width: 1px;\n│     color: red;\n}"
                   ".a {\n  width: 1px;\n  │color: red;\n}")
                  ("│   $color: red;" "│$color: red;")
                  (".a {\n│   .b {}\n}" ".a {\n    │.b {}\n}")
                  (".a { display:\n    │ block; }" ".a { display:\n    │block; }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (let ((scss2-indent-offset 4) (indent-tabs-mode nil))
        (scss2-tab)
        (should (equal (scss2-edit-test--with-point) (cadr case)))))))

(ert-deftest scss2-edit-tab-blank-lines-keep-snippet-navigation ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n│   \n}"
    (let ((calls 0))
      (cl-letf (((symbol-function 'yas-active-snippets) (lambda () '(active)))
                ((symbol-function 'yas-next-field) (lambda () (setq calls (1+ calls)))))
        (should-not (scss2--tab-binding #'scss2-tab))
        (scss2-tab)
        (should (= calls 1))))))

(ert-deftest scss2-edit-tab-jumps-over-the-declaration-semicolon ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".a { display: inline-bl│ock; color: red; }"
                      ".a { display: inline-block│; }"
                      ".a { display: │; }"
                      ".a { width: calc(1rem + 2px)│; }"
                      ".a { content: \"a;b\"│; }"
                      ".a { content: \"a│;b\"; color: red; }"
                      ".a { background: url(im│age.png); color: red; }"
                      ".a { width: calc(1rem + min(│2px, 3px)); color: red; }"
                      ".a { color: var(--co│lor); color: blue; }"
                      ".a { color: red /* │; */ !important; color: blue; }"
                      ".a { color: red│ /* ; */ !important; }"
                      ".a { display:\n  block│\n; }"))
      (scss2-edit-test--buffer mode source
        (let ((text (buffer-string)) (ring (copy-sequence kill-ring)))
          (let ((indent-line-function (lambda () (ert-fail "Unexpected indentation"))))
            (scss2-tab))
          (should (eq (char-before) ?\;))
          (should (equal (buffer-substring-no-properties (point) (point-max))
                         (substring text (1+ (string-match ";\\(?: color:\\| }\\|$\\)" text)))))
          (should-not mark-active)
          (should (equal (buffer-string) text))
          (should (equal kill-ring ring)))))))

(ert-deftest scss2-edit-tab-falls-back-without-a-reliable-value-terminator ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".a│ {}"
                      ".a { display: block│ }"
                      ".a { /* color: r│ed; */ }"
                      ".a { width: calc(│) }"
                      "@supports (display: bl│ock) {}"))
      (scss2-edit-test--buffer mode source
        (let* ((position (point)) (calls 0)
               (indent-line-function (lambda () (setq calls (1+ calls)))))
          (scss2-tab)
          (should (= calls 1))
          (should (= (point) position)))))))

(ert-deftest scss2-edit-tab-moves-from-a-name-to-its-value ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '((".a { │display: block; }" . "block; }")
                    (".a { dis│play: block; }" . "block; }")
                    (".a { display│: block; }" . "block; }")
                    (".a { display │ : block; }" . "block; }")
                    (".a { --x│: 1px 2px; }" . "1px 2px; }")
                    (".a { co│lor: /* c */ red !important; }" . "red !important")
                    (".a { co│lor: red }" . "red }")
                    (".a { fo│nt: bold { family: serif; } }" . "bold {")))
      (scss2-edit-test--buffer mode (car case)
        (let ((text (buffer-string)) (ring (copy-sequence kill-ring)))
          (scss2-tab)
          (should (looking-at-p (cdr case)))
          (should-not mark-active)
          (should (equal (buffer-string) text))
          (should (equal kill-ring ring))))))
  (scss2-edit-test--buffer 'scss2-mode "$gu│tter: 1rem; .a { #{$p}-x: 1px; }"
    (scss2-tab)
    (should (looking-at-p "1rem;"))
    (scss2-tab)
    (should (looking-at-p " \\.a"))
    (search-forward "#{$p}")
    (scss2-tab)
    (should (looking-at-p "1px; }"))))

(ert-deftest scss2-edit-tab-reindents-names-before-the-value ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (ending '("\n" "\r\n"))
      (dolist (case '((".a {\n│color: red;\n}" ".a {\n    color: │red;\n}")
                      (".a {\n co│lor: red;\n}" ".a {\n    color: │red;\n}")
                      (".a {\n      │color: red;\n}" ".a {\n    color: │red;\n}")
                      (".a {\n\tco│lor: red;\n}" ".a {\n    color: │red;\n}")
                      (".a {\n.b { co│lor: red; }\n}" ".a {\n    .b { color: │red; }\n}")
                      (".a {\nco│lor: red;\n}" ".a {\n    color: │red;\n}")
                      (".a {\ncolor│: red;\n}" ".a {\n    color: │red;\n}")
                      (".a {\n--to│ne: red;\n}" ".a {\n    --tone: │red;\n}")
                      (".a {\ncolor│: /* note */ red\n}"
                       ".a {\n    color: /* note */ │red\n}")
                      (".a {\nco│lor:\n    red;\n}" ".a {\n    color:\n    │red;\n}")
                      (".a {\n  width: 1px;\nco│lor: red;\n}"
                       ".a {\n  width: 1px;\n  color: │red;\n}")
                      (".a {\n    .b {\nco│lor: red;\n    }\n}"
                       ".a {\n    .b {\n        color: │red;\n    }\n}")))
        (scss2-edit-test--buffer mode (string-replace "\n" ending (car case))
          (let ((scss2-indent-offset 4) (indent-tabs-mode nil)
                (original (buffer-string)) (ring (copy-sequence kill-ring)))
            (buffer-enable-undo)
            (setq buffer-undo-list nil)
            (scss2-tab)
            (should (equal (scss2-edit-test--with-point)
                           (string-replace "\n" ending (cadr case))))
            (should (equal kill-ring ring))
            (undo-boundary)
            (undo 1)
            (should (equal (buffer-string) original)))))))
  (scss2-edit-test--buffer 'scss2-mode ".a {\n$ga│p: 1rem;\n}"
    (let ((scss2-indent-offset 2) (indent-tabs-mode nil))
      (scss2-tab)
      (should (equal (scss2-edit-test--with-point) ".a {\n  $gap: │1rem;\n}")))))

(ert-deftest scss2-edit-tab-reindents-map-keys-before-the-value ()
  (dolist (ending '("\n" "\r\n"))
    (dolist (case '(("$m: (\n│one: 1,\n);" "$m: (\n  one: │1,\n);")
                    ("$m: (\n o│ne: 1,\n);" "$m: (\n  one: │1,\n);")
                    ("$m: (\n      one│: 1,\n);" "$m: (\n  one: │1,\n);")
                    ("$m: (\n\tone │ : 1,\n);" "$m: (\n  one  : │1,\n);")
                    ("$m: (\n\"on│e\": /* note */ 1,\n);"
                     "$m: (\n  \"one\": /* note */ │1,\n);")
                    ("$m: (\n  outer: (\nin│ner: 1,\n  ),\n);"
                     "$m: (\n  outer: (\n    inner: │1,\n  ),\n);")
                    ("@include use((\non│e: 1,\n));"
                     "@include use((\n  one: │1,\n));")
                    ("$m: (\non│e:\n    1,\n);" "$m: (\n  one:\n    │1,\n);")))
      (scss2-edit-test--buffer 'scss2-mode (string-replace "\n" ending (car case))
        (let ((scss2-indent-offset 2) (indent-tabs-mode nil)
              (original (buffer-string)) (ring (copy-sequence kill-ring)))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (buffer-enable-undo)
          (setq buffer-undo-list nil)
          (scss2-tab)
          (should (equal (scss2-edit-test--with-point)
                         (string-replace "\n" ending (cadr case))))
          (should (equal kill-ring ring))
          (undo-boundary)
          (undo 1)
          (should (equal (buffer-string) original)))))))

(ert-deftest scss2-edit-tab-map-whitespace-precedes-key-navigation ()
  (scss2-edit-test--buffer 'scss2-mode "$m: (\n│ one: 1,\n);"
    (let ((scss2-indent-offset 2) (indent-tabs-mode nil))
      (scss2-tab)
      (should (equal (scss2-edit-test--with-point) "$m: (\n  │one: 1,\n);"))
      (let ((tick (buffer-chars-modified-tick)))
        (scss2-tab)
        (should (equal (scss2-edit-test--with-point) "$m: (\n  one: │1,\n);"))
        (should (= tick (buffer-chars-modified-tick)))))))

(ert-deftest scss2-edit-tab-map-key-respects-region-and-narrowing ()
  (scss2-edit-test--buffer 'scss2-mode "$m: (\non│e: 1,\n);"
    (let ((transient-mark-mode t)
          (indent-line-function (lambda () (ert-fail "Unexpected indentation"))))
      (set-mark (line-beginning-position))
      (activate-mark)
      (scss2-tab)
      (should (equal (scss2-edit-test--with-point) "$m: (\none: │1,\n);"))
      (should-not mark-active)))
  (scss2-edit-test--buffer 'scss2-mode "$m: (on│e: 1);"
    (narrow-to-region (- (point) 2) (point-max))
    (let ((indent-line-function (lambda () (ert-fail "Unexpected indentation"))))
      (scss2-tab)
      (should (equal (scss2-edit-test--with-point) "one: │1);")))))

(ert-deftest scss2-edit-tab-name-indentation-keeps-other-navigation ()
  (dolist (case '((".a {\ncolor: re│d;\n}" ".a {\ncolor: red;│\n}")
                  (".a {\ncolor:\nre│d;\n}" ".a {\ncolor:\nred;│\n}")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (let ((indent-line-function (lambda () (ert-fail "Unexpected indentation"))))
        (scss2-tab))
      (should (equal (scss2-edit-test--with-point) (cadr case))))))

(ert-deftest scss2-edit-tab-correct-indentation-does-not-modify-text ()
  (dolist (source '(".a {\n  co│lor: red;\n}" ".a {\n│  color: red;\n}"))
    (scss2-edit-test--buffer 'scss2-mode source
      (let ((tick (buffer-chars-modified-tick)))
        (scss2-tab)
        (should (= tick (buffer-chars-modified-tick)))))))

(ert-deftest scss2-edit-tab-name-indentation-respects-region-and-narrowing ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\nco│lor: red;\n}"
    (let ((transient-mark-mode t)
          (indent-line-function (lambda () (ert-fail "Unexpected indentation"))))
      (set-mark (line-beginning-position))
      (activate-mark)
      (scss2-tab)
      (should (equal (scss2-edit-test--with-point) ".a {\ncolor: │red;\n}"))
      (should-not mark-active)))
  (scss2-edit-test--buffer 'scss2-mode ".a { co│lor: red; }"
    (narrow-to-region (- (point) 2) (point-max))
    (let ((indent-line-function (lambda () (ert-fail "Unexpected indentation"))))
      (scss2-tab)
      (should (equal (scss2-edit-test--with-point) "color: │red; }")))))

(ert-deftest scss2-edit-tab-from-a-name-falls-back-without-a-value ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".a { col│or:; }" ".a { col│or: ; }" ".a { fo│nt: { family: serif; } }"
                      ".a { dis│play }"))
      (scss2-edit-test--buffer mode source
        (let* ((position (point)) (calls 0)
               (indent-line-function (lambda () (setq calls (1+ calls)))))
          (scss2-tab)
          (should (= calls 1))
          (should (= (point) position)))))))

(ert-deftest scss2-edit-tab-skips-all-value-parentheses-in-one-step ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".a { width: calc(│); }"
                      ".a { width: calc(1rem + │2px); }"
                      ".a { color: var(--co│lor); }"))
      (scss2-edit-test--buffer mode source
        (let ((text (buffer-string)))
          (scss2-tab)
          (should (eq (char-before) ?\;))
          (should-not mark-active)
          (should (equal (buffer-string) text)))))
    (scss2-edit-test--buffer mode ".a { width: calc(1rem + min(│2px, 3px)); }"
      (scss2-tab)
      (should (eq (char-before) ?\;)))))

(ert-deftest scss2-edit-tab-keeps-indentation-in-an-inaccessible-declaration ()
  (scss2-edit-test--buffer 'scss2-mode ".a { display: block│; }"
    (let* ((position (point)) (calls 0)
           (indent-line-function (lambda () (setq calls (1+ calls)))))
      (save-restriction
        (narrow-to-region (- (point) 3) (point-max))
        (scss2-tab)
        (should (= (point) position))
        (should (= calls 1))))))

(ert-deftest scss2-edit-tab-leaves-a-selected-value-without-editing ()
  (scss2-edit-test--buffer 'scss2-mode ".a { display: block│; }"
    (let ((transient-mark-mode t) (calls 0))
      (set-mark (- (point) 3)) (activate-mark)
      (cl-letf (((symbol-function 'indent-for-tab-command)
                 (lambda () (interactive) (setq calls (1+ calls)))))
        (scss2-tab))
      (should (= calls 0))
      (should (eq (char-before) ?\;))
      (should-not mark-active))))

(ert-deftest scss2-edit-incomplete-statement-keeps-following-block-editable ()
  (dolist (prefix '("@mixin paint($tone) { @if true {} @else }"
                    "@mixin paint($tone) { @if true {} @else if $tone }"
                    "@mixin paint($tone) { color: $/*c*/; }"
                    "@mixin paint($tone) { color: $ !important; }"
                    "@mixin paint($tone) { @each $/*c*/in $list {} }"
                    "@mixin paint($tone) { @for $ from 1 through 3 {} }"
                    "@mixin paint($tone) { color: $ //c\n; }"))
    (scss2-edit-test--buffer 'scss2-mode (concat prefix " .af│ter {}")
      (should (treesit-node-check (scss2--root-node) 'has-error))
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((original (buffer-string)) (position (point)))
        (undo-boundary)
        (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
        (undo-boundary)
        (should (equal (buffer-string) (concat prefix " ")))
        (should (equal (car kill-ring) ".after {}"))
        (should (= (point) (1+ (length (concat prefix " ")))))
        (undo 1)
        (should (equal (buffer-string) original))
        (should (= (point) position))
        (undo-redo 1)
        (should (equal (buffer-string) (concat prefix " ")))))
    (scss2-edit-test--buffer 'scss2-mode (concat "│" prefix " .after {}")
      (scss2-edit-test--unchanged (lambda () (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill)))))))

(ert-deftest scss2-edit-repaired-statements-restore-following-block-editing ()
  (dolist (entry '(("@if true {} @else" . "@if true {} @else {}")
                   ("@if true {} @else if $tone" . "@if true {} @else if $tone {}")
                   ("color: $/*c*/;" . "color: $tone/*c*/;")
                   ("color: $ !important;" . "color: $tone !important;")
                   ("@each $/*c*/in $list {}" . "@each $item/*c*/in $list {}")
                   ("@for $ from 1 through 3 {}" . "@for $i from 1 through 3 {}")
                   ("color: $ //c\n;" . "color: $tone //c\n;")))
    (let ((prefix (format "@mixin paint($tone) { %s }" (car entry)))
          (repaired (format "@mixin paint($tone) { %s }" (cdr entry))))
      (scss2-edit-test--buffer 'scss2-mode (concat prefix " .af│ter {}")
        ;; Recovery shape is unspecified; force its tree before replacing the statement.
        (scss2--root-node)
        (save-excursion
          (goto-char (point-min))
          (delete-region (point) (+ (point) (length prefix)))
          (insert repaired))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (buffer-enable-undo)
        (setq buffer-undo-list nil)
        (let ((original (buffer-string)) (position (point)))
          (undo-boundary)
          (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
          (undo-boundary)
          (should (equal (buffer-string) (concat repaired " ")))
          (should (equal (car kill-ring) ".after {}"))
          (should (= (point) (1+ (length (concat repaired " ")))))
          (undo 1)
          (should (equal (buffer-string) original))
          (should (= (point) position))
          (undo-redo 1)
          (should (equal (buffer-string) (concat repaired " ")))))
      (scss2-edit-test--buffer 'scss2-mode (concat "│" prefix " .after {}")
        (scss2-edit-test--unchanged (lambda () (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))))))))

(ert-deftest scss2-edit-repaired-comment-interpolation-restores-following-rule ()
  (dolist (content '("https://example.test" "fix // later" "a /* b"))
    (let ((prefix (concat ".a {\n /* see #{ " content " */\n color: red;\n}\n"))
          (repaired (format ".a {\n /* see #{ %S } */\n color: red;\n}\n" content)))
      (scss2-edit-test--buffer 'scss2-mode (concat prefix ".af│ter { /* tail */ }")
        (scss2--root-node)
        (save-excursion
          (goto-char (point-min))
          (delete-region (point) (+ (point) (length prefix)))
          (insert repaired))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
        (should (equal (buffer-string) repaired))
        (should (equal (car kill-ring) ".after { /* tail */ }"))))))

(ert-deftest scss2-edit-recovered-block-header-does-not-establish-targets ()
  (dolist (command '(scss2-kill scss2-empty scss2-copy scss2-mark
                     scss2-duplicate scss2-comment-uncomment))
    (scss2-edit-test--buffer 'scss2-mode
        ".a { color: var(--x, {a:b│;c:d}); width: 1px; }"
      (should (treesit-node-check (scss2--root-node) 'has-error))
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (scss2-edit-test--unchanged command)
      (should-not buffer-undo-list)))
  (scss2-edit-test--buffer 'scss2-mode
      ".a { color: var(--x, {a:b;c:d}); width: 1│px; }"
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((original (buffer-string)))
      (undo-boundary)
      (scss2-kill)
      (undo-boundary)
      (should (equal (buffer-string) ".a { color: var(--x, {a:b;c:d});  }"))
      (should (equal (car kill-ring) "width: 1px;"))
      (undo 1)
      (should (equal (buffer-string) original)))))

(ert-deftest scss2-edit-property-and-complete-value-both-dialects ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode
        ".a { /* before */ color: r│ed !important; /* after */ x: 1; }"
      (scss2-kill)
      (should (equal (buffer-string) ".a { /* before */  /* after */ x: 1; }"))
      (should (equal (car kill-ring) "color: red !important;")))
    (scss2-edit-test--buffer mode ".a { content: \"a b\" !imp│ortant; }"
      (scss2-empty)
      (should (equal (buffer-string) ".a { content: ; }"))
      (should (equal (car kill-ring) "\"a b\" !important")))
    (scss2-edit-test--buffer mode ".a { con│tent: \"literal\"; }"
      (scss2-empty)
      (should (equal (buffer-string) ".a { content: ; }"))
      (should (equal (car kill-ring) "\"literal\"")))))

(ert-deftest scss2-edit-block-keeps-external-comments-and-empties-body ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode
        "/* before */ @media (width > 10px) {\n.│a { color: red; }\n/* inner */\n} /* after */"
      (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
      (should (equal (buffer-string)
                     "/* before */ @media (width > 10px) {\n/* inner */\n} /* after */"))
      (should (equal (car kill-ring) ".a { color: red; }\n")))
    (scss2-edit-test--buffer mode ".a │{\n  color: red;\n  /* trailing */\n} /* outside */"
      (let ((current-prefix-arg '(4))) (call-interactively #'scss2-empty))
      (should (equal (buffer-string) ".a {} /* outside */"))))
  (scss2-edit-test--buffer 'css2-mode "@m│edia (width > 10px) { .a { x: 1; } }"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-entities-share-rule-boundaries-with-kill ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (scss2-entity-node-types
             (list scss2-entity-node-types '("selectors") '("property_declaration") nil))
      (dolist (case '((".a, .│b { x: 1; }" ".a, .b { x: 1; }")
                      (".a, :is(.b, .│c) { x: 1; }" ".a, :is(.b, .c) { x: 1; }")
                      (".a { x: 1; │}" ".a { x: 1; }")
                      (".a { x: 1;│ y: 2; }" ".a { x: 1; y: 2; }")
                      (".a { .child {}│ .sibling {} }" ".a { .child {} .sibling {} }")))
        (dolist (block '(nil t))
          (dolist (command '(scss2-copy scss2-mark scss2-kill scss2-duplicate scss2-comment-uncomment))
            (scss2-edit-test--buffer mode (concat ".outer { " (car case) " .after {} }")
              (let ((pulse-flag nil) (last-command nil) (entity (cadr case)))
                (let ((current-prefix-arg block)) (call-interactively command))
                (pcase command
                  ('scss2-copy (should (equal (car kill-ring) entity)))
                  ('scss2-mark
                   (should (equal (buffer-substring-no-properties (point) (mark)) entity)))
                  ('scss2-kill (should (equal (buffer-string) ".outer {  .after {} }")))
                  ('scss2-duplicate
                   (should (equal (buffer-string) (concat ".outer { " entity " " entity " .after {} }"))))
                  ('scss2-comment-uncomment
                   (should (equal (buffer-string) (concat ".outer { /* " entity " */ .after {} }")))))))))))))

(ert-deftest scss2-edit-comment-at-end-still-uncomments-before-point ()
  (dolist (block '(nil t))
    (dolist (case '((".a { /* note */│ color: red; }" ".a { note color: red; }")
                    (".a { // note│\n  color: red; }" ".a { note\n  color: red; }")))
      (scss2-edit-test--buffer 'scss2-mode (car case)
        (let ((current-prefix-arg block)) (call-interactively #'scss2-comment-uncomment))
        (should (equal (buffer-string) (cadr case)))))))

(ert-deftest scss2-edit-if-condition-is-a-kill-only-target ()
  (dolist (case '(("@if $a │> 0 { x: 1; } @else { x: 2; }"
                   "@if $a > 0 { x: 1; } @else { x: 2; }" "@if  { x: 1; } @else { x: 2; }")
                  ("@if $a {} @else if $b │> 0 { x: 2; }"
                   "@if $a {} @else if $b > 0 { x: 2; }" "@if $a {} @else if  { x: 2; }")))
    (dolist (command '(scss2-copy scss2-mark scss2-kill scss2-duplicate scss2-comment-uncomment))
      (scss2-edit-test--buffer 'scss2-mode (concat ".outer { " (car case) " .after {} }")
        (let ((pulse-flag nil) (entity (cadr case)))
          (funcall command)
          (pcase command
            ('scss2-copy (should (equal (car kill-ring) entity)))
            ('scss2-mark (should (equal (buffer-substring-no-properties (point) (mark)) entity)))
            ('scss2-kill (should (equal (buffer-string) (concat ".outer { " (nth 2 case) " .after {} }"))))
            ('scss2-duplicate
             (should (equal (buffer-string) (concat ".outer { " entity " " entity " .after {} }"))))
            ('scss2-comment-uncomment
             (should (equal (buffer-string) (concat ".outer { /* " entity " */ .after {} }"))))))))))

(ert-deftest scss2-edit-kill-selector-always-selects-the-complete-rule ()
  (dolist (scss2-entity-node-types
           (list scss2--statement-types (cons "selectors" scss2--statement-types)
                 '("selectors") '("property_declaration") nil))
    (dolist (mode '(css2-mode scss2-mode))
      (dolist (selector '(".a > .│b" ".a, .│b, .c" ".a, │ .b"
                          ".a > .b, .c:is(.d, .│e), .f"
                          ".a, :nth-child(2n of .b, .│c), .d"
                          ".a:lang(\"│en,US\")"))
        (scss2-edit-test--buffer mode
            (concat ".outer { " selector " { color: red; } .after {} }")
          (scss2-kill)
          (should (equal (buffer-string) ".outer {  .after {} }"))
          (should (equal (car kill-ring)
                         (concat (replace-regexp-in-string "│" "" selector)
                                 " { color: red; }"))))))))

(ert-deftest scss2-edit-kill-selector-keeps-only-external-comments ()
  (let ((scss2-entity-node-types (cons "selectors" scss2--statement-types)))
    (dolist (mode '(css2-mode scss2-mode))
      (dolist (selector '(".│a /* inside */, .b" ".a, /* inside */ .│b"))
        (scss2-edit-test--buffer mode
            (concat "/* before */ " selector " { x: 1; } /* after */")
          (scss2-kill)
          (should (equal (buffer-string) "/* before */  /* after */"))
          (should (string-search "/* inside */" (car kill-ring))))))))

(ert-deftest scss2-edit-conditionals-never-orphan-else ()
  (scss2-edit-test--buffer 'scss2-mode
      "@│if $x { x: 1; } @else if $y { x: 2; } @else { x: 3; }"
    (scss2-kill)
    (should (equal (buffer-string) "")))
  (scss2-edit-test--buffer 'scss2-mode "@if $x { x: 1; } @│else { x: 2; }"
    (scss2-kill)
    (should (equal (buffer-string) "")))
  (scss2-edit-test--buffer 'scss2-mode "@if $x { x: 1; } @else │{ x: 2; }"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-duplicate-preserves-inner-text-and-final-semicolon ()
  (let ((scss2-entity-node-types (cons "selectors" scss2--statement-types)))
    (scss2-edit-test--buffer 'css2-mode ".a { col│or: red }"
      (scss2-duplicate)
      (should (equal (buffer-string) ".a { color: red; color: red }"))
      (should (equal kill-ring '("previous kill"))))
    (scss2-edit-test--buffer 'css2-mode ".a, .│b { x: 1; }"
      (scss2-duplicate)
      (should (equal (buffer-string) ".a, .b { x: 1; }\n.a, .b { x: 1; }")))
    ;; A trailing comment does not make an entity share its line.
    (dolist (comment '("// note" "/* note */"))
      (scss2-edit-test--buffer 'scss2-mode (concat ".a {\n  co│lor: red; " comment "\n  x: 1;\n}")
        (scss2-duplicate)
        (should (equal (buffer-string)
                       (concat ".a {\n  color: red;\n  color: red; " comment "\n  x: 1;\n}")))))
    ;; Complete rules retain their selector list's layout.
    (dolist (source '(".a,\n.│b { x: 1; }"
                      "  .│a,\n  .b { x: 1; }"
                      ".│a,.b { x: 1; }"))
      (scss2-edit-test--buffer 'scss2-mode source
        (let ((original (buffer-string)))
          (scss2-duplicate)
          (should (equal (buffer-string) (concat original "\n" original))))))
    (scss2-edit-test--buffer 'scss2-mode
        "@m│ixin paint() {\n  --raw: { literal: \"  value  \"; };\n}"
      (let ((source (buffer-string)))
        (scss2-duplicate)
        (should (equal (buffer-string) (concat source "\n" source)))))))

(ert-deftest scss2-edit-failures-restore-buffer-point-mark-and-kill-ring ()
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: red; }"
    (cl-letf (((symbol-function 'kill-new)
               (lambda (&rest _) (setq kill-ring '("bad partial state"))
                 (error "Simulated clipboard failure"))))
      (scss2-edit-test--unchanged #'scss2-kill)))
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: red; }"
    (setq buffer-read-only t)
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: \"unterminated; }"
    (scss2-edit-test--unchanged #'scss2-kill)))

(ert-deftest scss2-edit-flat-nested-property-keeps-its-block-boundaries ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (body '("" " /* lead { */ size: 12px; /* trail } */ "
                    " family: { name: \"}\"; } "))
      (let ((property (concat "font: bold {" body "}")))
        (scss2-edit-test--buffer mode
            (concat ".a { fo│nt: bold {" body "} color: red; } .after {}")
          (let ((position (point))
                (bounds (scss2--block-bounds
                         (scss2--ancestor (scss2--node-at-point)
                                          '("property_declaration")))))
            (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds)) body))
            (scss2-copy)
            (should (= (point) position))
            (should (equal (car kill-ring) property)))
          (scss2-mark)
          (should (equal (buffer-substring-no-properties (point) (mark)) property))
          (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
          (should (equal (buffer-string) ".a {  color: red; } .after {}"))
          (should (= (point) 6))
          (should (equal (car kill-ring) property)))))))

(ert-deftest scss2-edit-flat-nested-property-empty-undo-and-duplicate ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode
        ".a { font: bold │{ /* lead */ size: 12px; /* trail */ } color: red; }"
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((source (buffer-string)))
        (undo-boundary)
        (let ((current-prefix-arg '(4))) (call-interactively #'scss2-empty))
        (undo-boundary)
        (should (equal (buffer-string) ".a { font: bold {} color: red; }"))
        (should (equal (car kill-ring) " /* lead */ size: 12px; /* trail */ "))
        (let ((position (point)))
          (undo 1)
          (should (equal (buffer-string) source))
          (undo-redo 1)
          (should (equal (buffer-string) ".a { font: bold {} color: red; }"))
          (should (= (point) position)))))
    (scss2-edit-test--buffer mode ".a { fo│nt: { size: 12px; } color: red; }"
      (scss2-duplicate)
      (should (equal (buffer-string)
                     ".a { font: { size: 12px; } font: { size: 12px; } color: red; }"))
      (should (equal kill-ring '("previous kill"))))))

(ert-deftest scss2-edit-kill-pseudo-arguments-selects-the-owning-rule ()
  (let ((scss2-entity-node-types (cons "selectors" scss2--statement-types)))
    (dolist (mode '(css2-mode scss2-mode))
      (dolist (branch '(".a:is(.b, :not(.c, .│d))"
                        ".a:is([data-x=\",\"], /* , */ :has(> .│d))"
                        ".a:nth-child(2n of :is(.b, .│c), .d)"))
        (scss2-edit-test--buffer mode (concat branch ", .other { color: red; } .after {}")
          (scss2-kill)
          (should (equal (buffer-string) " .after {}"))
          (should (= (point) (point-min)))
          (should (equal (car kill-ring)
                         (concat (replace-regexp-in-string "│" "" branch)
                                 ", .other { color: red; }")))))
      (scss2-edit-test--buffer mode ".a:is(:lang(\"│en,US\"), .b) { color: red; }"
        (scss2-kill)
        (should (equal (buffer-string) ""))))))

(ert-deftest scss2-edit-narrowing-and-selector-strings-respect-entities ()
  (scss2-edit-test--buffer 'css2-mode ".a { color: r│ed; }"
    (let ((position (point)))
      (narrow-to-region (point) (point-max))
      (goto-char position)
      (scss2-edit-test--unchanged #'scss2-kill)))
  (scss2-edit-test--buffer 'css2-mode ".a:lang(\"│en\") { color: red; }"
    (scss2-kill)
    (should (equal (buffer-string) "")))
  (scss2-edit-test--buffer 'scss2-mode "@use \"│theme\";"
    (let ((position (point)))
      (narrow-to-region position (point-max))
      (goto-char position)
      (scss2-edit-test--unchanged #'scss2-kill))))

(ert-deftest scss2-edit-narrowed-literals-keep-the-full-syntax-owner ()
  (dolist (case '((".a { content: \".b { color: re│d; }\"; }" . ".b { color: red; }")
                  (".a { /* .b { color: re│d; } */ }")))
    (scss2-edit-test--buffer 'css2-mode (car case)
      (let ((position (point)))
        (goto-char (point-min)) (search-forward ".b")
        (let ((begin (- (point) 2)))
          (search-forward "}")
          (narrow-to-region begin (point)))
        (goto-char position))
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (dolist (command (append '(scss2-kill scss2-copy scss2-mark scss2-duplicate)
                               (unless (cdr case) '(scss2-empty))))
        (scss2-edit-test--unchanged command)
        (should-not buffer-undo-list))
      ;; Empty targets the string's interior, which the restriction spans exactly.
      (when (cdr case)
        (scss2-empty)
        (should (equal (buffer-string) ""))
        (should (equal (car kill-ring) (cdr case))))))
  (scss2-edit-test--buffer 'css2-mode ".a { content: \".b { color: re│d; }\"; }"
    (let ((position (point)))
      (goto-char (point-min)) (search-forward "color")
      (narrow-to-region (- (point) 5) (progn (search-forward ";") (point)))
      (goto-char position))
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'css2-mode ".before {} .a { color: re│d; } .after {}"
    (let ((position (point)))
      (goto-char (point-min)) (search-forward ".a ")
      (let ((begin (- (point) 3)))
        (search-forward "}")
        (narrow-to-region begin (point)))
      (goto-char position))
    (scss2-kill)
    (should (equal (buffer-string) ".a {  }"))
    (should (equal (car kill-ring) "color: red;"))
    (save-restriction
      (widen)
      (should (equal (buffer-string) ".before {} .a {  } .after {}")))))

(ert-deftest scss2-edit-one-command-is-one-undo-step ()
  (scss2-edit-test--buffer 'css2-mode ".a { color: r│ed !important; }"
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((source (buffer-string)))
      (undo-boundary)
      (call-interactively #'scss2-empty)
      (undo-boundary)
      (undo 1)
      (should (equal (buffer-string) source)))))

(ert-deftest scss2-edit-repeated-mark-keeps-a-target-that-begins-with-another ()
  (scss2-edit-test--buffer 'css2-mode ".a │{\n  color: red;\n}"
    (scss2-mark)
    (let ((begin (point)) (end (mark)) (last-command 'scss2-mark))
      (should (equal (buffer-substring-no-properties begin end)
                     ".a {\n  color: red;\n}"))
      (scss2-mark)
      (should (= (point) begin))
      (should (= (mark) end)))))

(ert-deftest scss2-edit-mark-selects-the-nearest-property-or-map-entry ()
  (dolist (scss2-entity-node-types
           (list scss2-entity-node-types (cons "selectors" scss2-entity-node-types)))
    (dolist (case '((".a { co│lor: red !important; }" "color: red !important;")
                    (".a { width: calc(1px + min(2│px, 3px)); }"
                     "width: calc(1px + min(2px, 3px));")
                    (".a { content: \"a│b\"; }" "content: \"ab\";")
                    (".a { font: { si│ze: 12px; } }" "size: 12px;")
                    ("$theme: (sm│all: 1, medium: 2);" "small: 1")
                    ("$theme: (small: │1, medium: 2);" "small: 1")
                    ("$theme: (small│: 1, medium: 2);" "small: 1")
                    ("$theme: (small: calc(1px + │2px), medium: 2);" "small: calc(1px + 2px)")
                    ("$theme: (\"sm│all\": \"x\", medium: 2);" "\"small\": \"x\"")
                    ("$theme: (small: \"x│y\", medium: 2);" "small: \"xy\"")
                    ("$theme: (small: (x: │1, y: 2), medium: 3);" "x: 1")
                    ("$theme: (sm│all: (x: 1, y: 2), medium: 3);" "small: (x: 1, y: 2)")
                    ("$theme: (\r\n  small:\r\n    │1 2,\r\n  medium: 3\r\n);"
                     "small:\r\n    1 2")
                    ("$th│eme: (small: 1, medium: 2) !default;"
                     "$theme: (small: 1, medium: 2) !default;")))
      (scss2-edit-test--buffer 'scss2-mode (car case)
        (let ((original (buffer-string)) (ring (copy-sequence kill-ring))
              (transient-mark-mode t) (buffer-read-only t))
          (scss2-mark)
          (should (region-active-p))
          (should (equal (buffer-substring-no-properties (point) (mark)) (cadr case)))
          (let ((last-command 'scss2-mark) (begin (point)) (end (mark)))
            (scss2-mark)
            (should (= (point) begin))
            (should (= (mark) end)))
          (should (equal (buffer-string) original))
          (should (equal kill-ring ring)))))))

(ert-deftest scss2-edit-mark-ascends-to-the-nearest-complete-block ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (scss2-entity-node-types
             (list scss2-entity-node-types (cons "selectors" scss2-entity-node-types)))
      (dolist (case '((".outer { .a, .│b { x: 1; } .after {} }" ".a, .b { x: 1; }")
                      (".outer { @media scre│en { .a {} } .after {} }" "@media screen { .a {} }")
                      (".outer { @media screen { │ .a {} } .after {} }" "@media screen {  .a {} }")
                      (".outer { .a {│} .after {} }" ".a {}")
                      (".outer { .a { x: 1;│ } .after {} }" ".a { x: 1; }")
                      (".outer { .a {\n  │\n  x: 1;\n} .after {} }" ".a {\n  \n  x: 1;\n}")
                      (".outer { .a { /* note */│ } .after {} }" ".a { /* note */ }")
                      (".outer { .a { font: { │ size: 12px; } } }" "font: {  size: 12px; }")))
        (scss2-edit-test--buffer mode (car case)
          (scss2-mark)
          (should (equal (buffer-substring-no-properties (point) (mark)) (cadr case))))))))

(ert-deftest scss2-edit-mark-shares-at-rule-and-conditional-boundaries ()
  (dolist (case '((".a { @include f│oo(1, 2); }" "@include foo(1, 2);")
                  (".a { @include foo($x: │2); }" "@include foo($x: 2);")
                  (".a { @deb│ug 1; }" "@debug 1;")
                  ("@u│se 'theme';" "@use 'theme';")
                  ("@mixin m($x: │1) { color: red; }" "@mixin m($x: 1) { color: red; }")
                  ("@if $a { x: 1; } @else { │ x: 2; }"
                   "@if $a { x: 1; } @else {  x: 2; }")
                  ("@if $a { x: 1; } @el│se { x: 2; }"
                   "@if $a { x: 1; } @else { x: 2; }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-mark)
      (should (equal (buffer-substring-no-properties (point) (mark)) (cadr case)))))
  (scss2-edit-test--buffer 'scss2-mode ".a {}\n\n│\n.b {}"
    (scss2-edit-test--unchanged #'scss2-mark)))

(ert-deftest scss2-edit-mark-map-entry-prefix-keeps-the-entry ()
  (scss2-edit-test--buffer 'scss2-mode ".a { $theme: (small: │1, medium: 2); } .b {}"
    (let ((transient-mark-mode t))
      (scss2-mark)
      (should (equal (buffer-substring-no-properties (point) (mark)) "small: 1"))
      (let ((last-command 'scss2-mark)) (let ((current-prefix-arg '(4))) (call-interactively #'scss2-mark)))
      (should (equal (buffer-substring-no-properties (point) (mark))
                     "small: 1")))))

(ert-deftest scss2-edit-kill-map-entry-matches-mark-and-repairs-commas ()
  (dolist (scss2-entity-node-types (list scss2-entity-node-types '("map_entry")))
    (dolist (case '(("$m: (a│: 1, b: 2, c: 3);" "a: 1" "$m: (b: 2, c: 3);")
                    ("$m: (a: 1, b: │2, c: 3);" "b: 2" "$m: (a: 1, c: 3);")
                    ("$m: (a: 1, b│: 2);" "b: 2" "$m: (a: 1);")
                    ("$m: (a: 1, b: │2,);" "b: 2" "$m: (a: 1, );")
                    ("$m: (a: │1);" "a: 1" "$m: ();")
                    ("$m: (a: │1,);" "a: 1" "$m: ();")
                    ("$m: (a: 1, b: (x: │2, y: 3)) !default;" "x: 2"
                     "$m: (a: 1, b: (y: 3)) !default;")
                    ("$m: (a: 1, b: (x: │2)) !default;" "x: 2"
                     "$m: (a: 1, b: ()) !default;")
                    ("$m: (a: 1, b│: (x: 2, y: 3));" "b: (x: 2, y: 3)" "$m: (a: 1);")
                    ("$m: (\"a│,b\": rhythm(1, 2), c: 3);" "\"a,b\": rhythm(1, 2)" "$m: (c: 3);")
                    ("$m: (a: min(1px, │2px), b: 3);" "a: min(1px, 2px)" "$m: (b: 3);")
                    ("$m: (a: (\n  1,\n│\n  2\n), b: 3);" "a: (\n  1,\n\n  2\n)" "$m: (b: 3);")
                    ("@at-root (with│out: media) { .a {} }" "without: media" "@at-root  { .a {} }")
                    ("@at-root (without: me│dia,) { .a {} }" "without: media" "@at-root  { .a {} }")))
      (scss2-edit-test--buffer 'scss2-mode (car case)
        (let ((position (point)))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (scss2-mark)
          (should (equal (buffer-substring-no-properties (point) (mark)) (nth 1 case)))
          (goto-char position)
          (deactivate-mark)
          (scss2-kill)
          (should (equal (buffer-string) (nth 2 case)))
          (should-not (treesit-node-check (scss2--root-node) 'has-error)))))))

(ert-deftest scss2-edit-kill-map-entry-keeps-surrounding-comments ()
  (dolist (case '(("$m: (a: │1 /* keep */, b: 2);" "$m: ( /* keep */ b: 2);")
                  ("$m: (a: 1, /* keep */ b: │2);" "$m: (a: 1 /* keep */ );")
                  ("$m: (/* before */ a: │1, /* after */ b: 2);"
                   "$m: (/* before */ /* after */ b: 2);")
                  ("$m: (a: 1, // keep\n  b: │2\n);" "$m: (a: 1 // keep\n  \n);")
                  ("$m: (a│: /* value */ 1, b: 2);" "$m: (b: 2);")
                  ("@at-root (/* before */ with│out: media /* after */) { .a {} }"
                   "@at-root /* before */  /* after */ { .a {} }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-kill)
      (should (equal (buffer-string) (cadr case)))
      (should-not (treesit-node-check (scss2--root-node) 'has-error)))))

(ert-deftest scss2-edit-kill-map-entry-preserves-lines-and-is-one-undo-step ()
  (dolist (ending '("\n" "\r\n"))
    (dolist (case '(("$m: (\n  a: │1,\n  b: 2,\n);\n" "$m: (\n  b: 2,\n);\n" "  a: 1,\n")
                    ("$m: (\n  a: 1,\n  b: │2,\n);\n" "$m: (\n  a: 1,\n);\n" "  b: 2,\n")
                    ("$m: (\n  a: │1,\n);\n" "$m: (\n);\n" "  a: 1,\n")))
      (scss2-edit-test--buffer 'scss2-mode (string-replace "\n" ending (car case))
        (buffer-enable-undo)
        (setq buffer-undo-list nil)
        (let ((original (buffer-string)))
          (call-interactively #'scss2-kill)
          (should (equal (buffer-string) (string-replace "\n" ending (nth 1 case))))
          (should (equal (car kill-ring) (string-replace "\n" ending (nth 2 case))))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (undo-boundary)
          (undo 1)
          (should (equal (buffer-string) original)))))))

(ert-deftest scss2-edit-kill-map-entry-validates-separators-and-rolls-back ()
  (dolist (source '("$m: (a│: 1, b: 2);" "$m: (a: 1, b│: 2);"
                    "@at-root (with│out: media) { .a {} }"))
    (scss2-edit-test--buffer 'scss2-mode source
      ;; Mark's entry is accessible, but the required comma or brackets are not.
      (scss2-mark)
      (narrow-to-region (point) (mark))
      (scss2-edit-test--unchanged #'scss2-kill)))
  (scss2-edit-test--buffer 'scss2-mode "$m: (a: │1, b: \"unterminated);"
    (scss2-edit-test--unchanged #'scss2-kill))
  (scss2-edit-test--buffer 'scss2-mode "$m: (a: │1, b: 2);"
    (let ((buffer-read-only t)) (scss2-edit-test--unchanged #'scss2-kill)))
  (scss2-edit-test--buffer 'scss2-mode "$m: (a: 1, /* keep */ b: │2);"
    (cl-letf (((symbol-function 'kill-new)
               (lambda (&rest _) (setq kill-ring '("partial")) (error "Clipboard failed"))))
      (scss2-edit-test--unchanged #'scss2-kill))))

(ert-deftest scss2-edit-kill-map-entry-ignores-prefix ()
  (scss2-edit-test--buffer 'scss2-mode ".a { $m: (a: │1, b: 2); } .b {}"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
    (should (equal (buffer-string) ".a { $m: (b: 2); } .b {}"))))

(ert-deftest scss2-edit-mark-rejects-inaccessible-or-incomplete-targets ()
  (scss2-edit-test--buffer 'scss2-mode "$theme: (small: │1, medium: 2);"
    (narrow-to-region (point) (point-max))
    (scss2-edit-test--unchanged #'scss2-mark))
  (scss2-edit-test--buffer 'scss2-mode ".a {\n│\n  x: 1;\n}"
    (narrow-to-region (point) (point-max))
    (scss2-edit-test--unchanged #'scss2-mark))
  (scss2-edit-test--buffer 'scss2-mode "$theme: (small: \"│unterminated);"
    (should (treesit-node-check (scss2--root-node) 'has-error))
    (scss2-edit-test--unchanged #'scss2-mark)))

(ert-deftest scss2-edit-entity-commands-preserve-parse-integrity ()
  ;; Whole entities preserve syntax.  Killing a required if condition can
  ;; intentionally leave it incomplete; verify its exact range separately.
  (dolist (case '((css2-mode ".a, .b:is(.c, [d=\"e\"]) {\n  margin: 0 auto !important;\n  font: 1px/2 a, \"b, c\";\n  x: rgba(0, 0, 0, 0.5) url(\"u.png\");\n}\n@media screen and (width > 1px) { .e { color: red; } }\n")
                  (scss2-mode "@use 'x' with ($only: 1);\n$o: (a,);\n$l: [a, b,];\n.f {\n  font: {\n    family: x;\n    size: 12px;\n  }\n  transition:\n    opacity 1s,\n    transform 2s;\n}\n")
                  (scss2-mode "@use 'theme' as t;\n$m: (a: 1, 'b': 2, c: (d e f));\n@mixin f($a: 1, $b: 'x') { @content; }\n.a {\n  @include f($a: 2, $b: t.$tone) using ($s) { x: $s; }\n  &:hover, .b { y: 1px 2px !important; }\n  @if $m { z: 1; } @else { z: 2; }\n  @at-root (without: media) { w: 1; }\n}\n")))
    (dolist (command '(scss2-kill scss2-duplicate scss2-comment-uncomment))
      (with-temp-buffer
        (let ((source (cadr case)) (scss2-fontify-colors nil)
              (interprogram-cut-function nil) (interprogram-paste-function nil)
              (kill-ring nil) (kill-ring-yank-pointer nil))
          (insert source)
          (scss2-test-setup-buffer (car case))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (buffer-disable-undo)
          (dotimes (offset (1+ (length source)))
            (erase-buffer) (insert source) (goto-char (1+ offset))
            (let* ((target (and (eq command 'scss2-kill)
                                (condition-case nil (scss2--resolve-target 'kill)
                                  (user-error nil))))
                   (head (and target (scss2--directive (scss2--target-owner target))
                              (> (scss2--target-beg target)
                                 (treesit-node-start (scss2--target-owner target)))))
                   (expected (and head
                                  (concat (substring source 0 (1- (scss2--target-beg target)))
                                          (substring source (1- (scss2--target-end target)))))))
              (when head
                (should (member (treesit-node-type (scss2--target-owner target))
                                '("if_statement" "else_clause"))))
              (when (condition-case nil (progn (funcall command) t) (user-error nil))
                (ert-info ((format "%s at %d gave %S" command (1+ offset) (buffer-string)))
                  (if head (should (equal (buffer-string) expected))
                    (should-not (treesit-node-check (scss2--root-node) 'has-error))))))))))))

(ert-deftest scss2-edit-long-values-never-look-up-field-names-per-child ()
  ;; A child's own field-name lookup walks all of its previous siblings.
  (let ((items (mapcar (lambda (index) (format "%dpx 0 #000" index)) (number-sequence 1 500))))
    (setf (nth 250 items) (concat "│" (nth 250 items)))
    (dolist (mode '(css2-mode scss2-mode))
      (scss2-edit-test--buffer mode (concat ".a { box-shadow: " (string-join items ", ") "; }")
        (let ((lookup (symbol-function 'treesit-node-field-name)) (calls 0))
          (cl-letf (((symbol-function 'treesit-node-field-name)
                     (lambda (&rest args) (cl-incf calls) (apply lookup args))))
            (scss2-copy))
          (should (equal (car kill-ring)
                         (concat "box-shadow: " (replace-regexp-in-string "│" "" (string-join items ", ")) ";")))
          (should (zerop calls)))))))

(ert-deftest scss2-edit-value-tokens-select-complete-declarations ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (declaration '("color: var(--│x, red) !important;"
                           "--x: {a:b; c:│d};"
                           "margin: 1px\n    2│px;"))
      (scss2-edit-test--buffer mode (concat ".a { " declaration " }")
        (let ((text (replace-regexp-in-string "│" "" declaration)))
          (scss2-copy)
          (should (equal (car kill-ring) text))
          (scss2-mark)
          (should (equal (buffer-substring-no-properties (point) (mark)) text))
          (scss2-kill)
          (should (equal (buffer-string) ".a {  }"))))))
  (scss2-edit-test--buffer 'scss2-mode "$theme: (a: 1, b: (x: │2)) !default;"
    (scss2-copy)
    (should (equal (car kill-ring) "x: 2"))
    (scss2-kill)
    (should (equal (buffer-string) "$theme: (a: 1, b: ()) !default;"))))

(ert-deftest scss2-edit-leaf-statements-are-entities ()
  (dolist (statement '("@include foo(1, 2);" "@debug 1;" "@extend .base;" "@content;"))
    (scss2-edit-test--buffer 'scss2-mode
        (concat ".a {\n  │" statement "\n  color: red;\n}")
      (let ((original (buffer-string)))
        (scss2-copy)
        (should (equal (car kill-ring) statement))
        (scss2-duplicate)
        (should (equal (buffer-string)
                       (concat ".a {\n  " statement "\n  " statement "\n  color: red;\n}")))
        (undo-boundary)
        (erase-buffer) (insert original) (goto-char 8)
        (scss2-comment-uncomment)
        (should (string-search (concat "  // " statement "\n") (buffer-string)))
        (erase-buffer) (insert original) (goto-char 8)
        (scss2-kill)
        (should (equal (scss2-edit-test--with-point) ".a {\n  │color: red;\n}")))))
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode "@import \"a.css\";\n@char│set \"utf-8\";\n.b {}"
      (scss2-kill)
      (should (equal (buffer-string) "@import \"a.css\";\n.b {}")))))

(ert-deftest scss2-edit-unsupported-leaves-do-not-select-parent ()
  (dolist (source '(".a { thi│ng(a:b); }"))
    (dolist (command '(scss2-copy scss2-duplicate))
      (scss2-edit-test--buffer 'scss2-mode source
        (scss2-edit-test--unchanged command))))
  (scss2-edit-test--buffer 'scss2-mode ".a { thi│ng(a:b); }"
    (scss2-edit-test--unchanged #'scss2-kill)
    (scss2-edit-test--unchanged #'scss2-mark))
  (scss2-edit-test--buffer 'scss2-mode ".a { @include fo│o(1, 2); }"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
    (should (equal (buffer-string) ".a {  }"))))

(ert-deftest scss2-edit-kill-body-whitespace-selects-the-nearest-block ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (scss2-entity-node-types (list scss2--statement-types nil))
      (dolist (ending '("\n" "\r\n"))
        (dolist (source '(".a {│}" ".a { │ }" ".a {│ color: red; }"
                          ".a { color: red;│ }" ".a { color: red; │ }"
                          ".a {\n│  color: red;\n}"
                          ".a {\n\t│\t\n  color: red;\n}"
                          ".a {\n  color: red;\n  │\n  width: 1px;\n}"
                          ".a { /* note */│ color: red; }"
                          ".a { /* note */ │ color: red; }"
                          ".a { .child {}│ .sibling {} }"
                          "@media screen {\n  │\n  .child {}\n}"))
          (let ((rule (string-replace "\n" ending source)))
            (scss2-edit-test--buffer mode (concat ".outer { " rule " .after {} }")
              (scss2-kill)
              (should (equal (buffer-string) ".outer {  .after {} }"))
              (should (equal (car kill-ring) (string-replace "│" "" rule))))))))))

(ert-deftest scss2-edit-kill-body-whitespace-respects-sass-blocks ()
  (scss2-edit-test--buffer 'scss2-mode
      ".outer { .a { // note│\n  color: red; } .after {} }"
    (scss2-kill)
    (should (equal (buffer-string) ".outer {  .after {} }")))
  (scss2-edit-test--buffer 'scss2-mode
      ".outer { @if $x { x: 1; } @else {\n  │\n  x: 2;\n} .after {} }"
    (scss2-kill)
    (should (equal (buffer-string) ".outer {  .after {} }"))
    (should (string-prefix-p "@if $x" (car kill-ring))))
  (scss2-edit-test--buffer 'scss2-mode ".outer { font: { │ weight: bold; } color: red; }"
    (scss2-kill)
    (should (equal (buffer-string) ".outer {  color: red; }"))
    (should (equal (car kill-ring) "font: {  weight: bold; }"))))

(ert-deftest scss2-edit-kill-body-whitespace-does-not-promote-value-or-comment-space ()
  (dolist (source '(".a { content: \"a │ b\"; x: 1; }"
                    ".a { margin: 0 │ auto; x: 1; }"
                    ".a { --raw: { a │ b }; x: 1; }"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-kill)
      (should (equal (buffer-string) ".a {  x: 1; }"))))
  (scss2-edit-test--buffer 'scss2-mode ".a { /* a │ b */ x: 1; }"
    (scss2-kill)
    (should (equal (buffer-string) ".a {  x: 1; }"))
    (should (equal (car kill-ring) "/* a  b */")))
  (scss2-edit-test--buffer 'scss2-mode ".a { // a │ b\n  x: 1; }"
    (scss2-kill)
    (should (equal (buffer-string) ".a { \n  x: 1; }"))
    (should (equal (car kill-ring) "// a  b")))
  (dolist (source '("/* outside */\n│\n.a {}"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-edit-test--unchanged #'scss2-kill))))

(ert-deftest scss2-edit-kill-body-whitespace-keeps-accessible-and-complete-boundaries ()
  (scss2-edit-test--buffer 'scss2-mode ".outer { .a {\n │\n x: 1;\n} .after {} }"
    (narrow-to-region (point) (point-max))
    (scss2-edit-test--unchanged #'scss2-kill))
  (scss2-edit-test--buffer 'scss2-mode ".a {\n │\n color: red;"
    (scss2-edit-test--unchanged #'scss2-kill)))

(ert-deftest scss2-edit-kill-between-blank-lines-keeps-one ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  color: red;\n\n  mar│gin: 0;\n\n  padding: 0;\n}"
    (scss2-kill)
    (should (equal (scss2-edit-test--with-point) ".a {\n  color: red;\n\n  │padding: 0;\n}"))
    (should (equal (car kill-ring) "  margin: 0;\n")))
  (dolist (ending '("\n" "\r\n"))
    (scss2-edit-test--buffer 'scss2-mode
        (string-join '(".a {}" "" ".│b { x: 1; }" "" ".c {}") ending)
      (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
      (should (equal (buffer-string) (string-join '(".a {}" "" ".c {}") ending)))
      (should (looking-at-p "\\.c")))))

(ert-deftest scss2-edit-empty-header-content-despite-body-errors ()
  (dolist (case '(("[data-x=\"f│oo\"] { color: red; width }" "[data-x=\"│\"] { color: red; width }")
                  ("@if $a == \"f│oo\" { width }" "@if $a == \"│\" { width }")
                  ("@include bu│ttons($gap: 2) { width }" "@include buttons(│) { width }")
                  ("@mixin bu│ttons($gap: 2) { width }" "@mixin buttons(│) { width }")
                  (".a-#{$b│} { width }" ".a-#{│} { width }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (cadr case)))))
  ;; A recovered header itself remains unreliable.
  (scss2-edit-test--buffer 'scss2-mode "[data-x=\"f│oo\" { color: red; }"
    (scss2-edit-test--unchanged #'scss2-empty)))

(ert-deftest scss2-edit-copy-and-duplicate-highlight-their-text ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  co│lor: red;\n}"
    (let (highlights)
      (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
                 (lambda (beg end &rest _)
                   (push (buffer-substring-no-properties beg end) highlights))))
        (scss2-copy)
        (scss2-duplicate))
      (should (equal highlights '("color: red;" "color: red;")))
      (should (equal (buffer-substring-no-properties (line-beginning-position) (point))
                     "  color: red;")))))

(ert-deftest scss2-edit-prefixed-mark-keeps-the-selection ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  co│lor: red;\n}"
    (let ((transient-mark-mode t))
      (scss2-mark)
      (let ((last-command 'scss2-mark))
        (let ((current-prefix-arg '(4))) (call-interactively #'scss2-mark)))
      (should (equal (buffer-substring-no-properties (point) (mark))
                     "color: red;")))))

(ert-deftest scss2-edit-entity-commands-ascend-through-whitespace ()
  (dolist (case '((".outer { .a {\n│  color: red;\n} .after {} }" ".a {\n  color: red;\n}")
                  (".outer { @media screen { │ .a {} } .after {} }" "@media screen {  .a {} }")
                  (".outer { .a { color: red;│ } .after {} }" ".a { color: red; }")
                  (".outer { .a { /* note */ │ } .after {} }" ".a { /* note */  }")
                  (".outer { .a { .child {}│ .sibling {} } }" ".a { .child {} .sibling {} }")
                  (".outer { font: { │ weight: bold; } }" "font: {  weight: bold; }")
                  ("$map: (\n  a: 1,\n│\n  b: 2,\n);" "$map: (\n  a: 1,\n\n  b: 2,\n);")
                  (".a {\n  margin: 1px\n│\n    2px;\n}" "margin: 1px\n\n    2px;"
                   ".a {\n  margin: 1px\n  \n    2px;\n}")))
    (dolist (command '(scss2-mark scss2-copy scss2-kill scss2-duplicate scss2-comment-uncomment))
      (scss2-edit-test--buffer 'scss2-mode (car case)
        (let* ((original (buffer-string)) (text (cadr case))
               (begin (1+ (string-search text original)))
               (end (+ begin (length text)))
               (pulse-flag nil))
          (funcall command)
          (pcase command
            ('scss2-mark (should (equal (buffer-substring-no-properties (point) (mark)) text)))
            ('scss2-copy (should (equal (car kill-ring) text)))
            ('scss2-kill
             (should (equal (string-trim (car kill-ring)) (string-trim text)))
             (should-not (string-search text (buffer-string))))
            ('scss2-duplicate
             (should (= 2 (how-many (regexp-quote text) (point-min) (point-max)))))
            ('scss2-comment-uncomment
             ;; The entire selected entity, and no neighbor, is commented.
             (goto-char begin)
             (skip-chars-forward " \t\r\n")
             (should (scss2--ancestor (scss2--covering-node (point)) scss2--comment-types))
             (should (string-suffix-p (substring original (1- end)) (buffer-string)))
             (scss2-comment-uncomment)
             ;; Native comment alignment may pad an otherwise empty line.
             (should (equal (buffer-string) (or (nth 2 case) original)))))
          (should-not (treesit-node-check (scss2--root-node) 'has-error)))))))

(ert-deftest scss2-edit-map-entry-copy-duplicate-and-comment-share-targets ()
  (dolist (ending '("\n" "\r\n"))
    (dolist (case '(("$m: (a: │1, b: 2);" "a: 1" "$m: (a: 1, a: 1, b: 2);" "a: 1,")
                    ("$m: (a: 1, b│: 2);" "b: 2" "$m: (a: 1, b: 2, b: 2);" ", b: 2")
                    ("$m: (a: 1, b│: 2,);" "b: 2" "$m: (a: 1, b: 2, b: 2,);" "b: 2,")
                    ("$m: (a: │1);" "a: 1" "$m: (a: 1, a: 1);" "a: 1")
                    ("$m: (a: │1,);" "a: 1" "$m: (a: 1,a: 1,);" "a: 1,")
                    ("$m: (a: (b: │2, c: 3));" "b: 2" "$m: (a: (b: 2, b: 2, c: 3));" "b: 2,")
                    ("$m: (\n  a: │1,\n  b: 2,\n);" "a: 1"
                     "$m: (\n  a: 1,\n  a: 1,\n  b: 2,\n);" "a: 1,")
                    ("@at-root (with│out: media) { .a {} }" "without: media"
                     "@at-root (without: media, without: media) { .a {} }" "(without: media)")
                    ("@at-root (with│out: media,) { .a {} }" "without: media"
                     "@at-root (without: media,without: media,) { .a {} }" "(without: media,)")))
      (scss2-edit-test--buffer 'scss2-mode (string-replace "\n" ending (car case))
        (let ((original (buffer-string)) (position (point)) (pulse-flag nil))
          (scss2-copy)
          (should (equal (car kill-ring) (nth 1 case)))
          (scss2-duplicate)
          (should (equal (buffer-string) (string-replace "\n" ending (nth 2 case))))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (erase-buffer) (insert original) (goto-char position)
          (scss2-comment-uncomment)
          (should (string-search (concat "/* " (nth 3 case) " */") (buffer-string)))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (scss2-comment-uncomment)
          (should (equal (buffer-string) original)))))))

(ert-deftest scss2-edit-map-entry-comments-preserve-surrounding-comments ()
  (dolist (source '("$m: (a│: /* value */ 1, /* after */ b: 2);"
                    "$m: (a: │1 /* before comma */, b: 2);"
                    "$m: (a: 1, /* before */ b: │2);"
                    "@at-root (/* before */ with│out: media /* after */) { .a {} }"))
    (scss2-edit-test--buffer 'scss2-mode source
      (let ((original (buffer-string)))
        (scss2-comment-uncomment)
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (scss2-comment-uncomment)
        (should (equal (buffer-string) original))))))

(ert-deftest scss2-edit-whitespace-inside-an-entity-touches-it ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  margin:\n│    0 auto;\n  color: red;\n}"
    (scss2-kill)
    (should (equal (scss2-edit-test--with-point) ".a {\n  │color: red;\n}")))
  (scss2-edit-test--buffer 'scss2-mode ".a { content: \"a  │  b\"; }"
    (scss2-copy)
    (should (equal (car kill-ring) "content: \"a    b\";")))
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  /* one\n│     two */\n  color: red;\n}"
    (scss2-comment-uncomment)
    (should-not (string-search "/*" (buffer-string)))
    (should (string-search "two" (buffer-string)))))

(ert-deftest scss2-edit-block-selector-shares-one-entity ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".outer { .│a { color: red; } } .after {}"
      (let ((position (point)))
        (let ((current-prefix-arg '(4))) (call-interactively #'scss2-copy))
        (should (= (point) position))
        (should (equal (car kill-ring) ".a { color: red; }")))
      (let ((current-prefix-arg '(4))) (call-interactively #'scss2-mark))
      (should (equal (buffer-substring-no-properties (point) (mark)) ".a { color: red; }"))
      (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
      (should (equal (buffer-string) ".outer {  } .after {}")))))

(ert-deftest scss2-edit-empty-resolves-content-independently ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '((".a { width: calc(1px + min(2│px, 3px)); }"
                     ".a { width: calc(1px + min()); }" "2px, 3px")
                    (".a { width: ca│lc(1px + 2px); }"
                     ".a { width: calc(); }" "1px + 2px")
                    (".a { --x: {a:b; c:│d}; }" ".a { --x: {}; }" "a:b; c:d")
                    (".a { color: re│d !important; }" ".a { color: ; }" "red !important")
                    (".a {\n  │\n  color: red;\n}" ".a {}" "\n  \n  color: red;\n")))
      (scss2-edit-test--buffer mode (car case)
        (scss2-empty)
        (should (equal (buffer-string) (nth 1 case)))
        (should (equal (car kill-ring) (nth 2 case))))))
  (scss2-edit-test--buffer 'scss2-mode ".a { font: 12│px { weight: bold; } }"
    (scss2-empty)
    (should (equal (buffer-string) ".a { font:  { weight: bold; } }")))
  (scss2-edit-test--buffer 'scss2-mode "$m: (a: 1, b: │2);"
    (scss2-empty)
    (should (equal (buffer-string) "$m: (a: 1, b: );"))))

(ert-deftest scss2-edit-empty-body-whitespace-selects-the-nearest-body ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (ending '("\n" "\r\n"))
      (dolist (body '(" color: red;│ width: 1px; "
                      " color: red; │ width: 1px; "
                      " color: red;│\n  width: 1px; "
                      " .child {}│ .after {} "
                      " /* note */│ color: red; "
                      " color: red;│"))
        (let ((content (string-replace "\n" ending body)))
          (scss2-edit-test--buffer mode (concat ".outer { .a {" content "} .after {} }")
            (buffer-enable-undo)
            (setq buffer-undo-list nil)
            (let ((original (buffer-string)))
              (scss2-empty)
              (should (equal (scss2-edit-test--with-point) ".outer { .a {│} .after {} }"))
              (should (equal (car kill-ring) (string-replace "│" "" content)))
              (should-not (treesit-node-check (scss2--root-node) 'has-error))
              (undo-boundary)
              (undo 1)
              (should (equal (buffer-string) original)))))))))

(ert-deftest scss2-edit-empty-body-whitespace-keeps-the-current-branch ()
  (dolist (body '(" x: 2;│ y: 3; " " .child {}│ .after {} "
                  " // note│\n  x: 2; "))
    (dolist (branch '("@else" "@else if $b"))
      (scss2-edit-test--buffer 'scss2-mode
          (concat ".outer { @if $a { x: 1; } " branch " {" body "} .after {} }")
        (scss2-empty)
        (should (equal (scss2-edit-test--with-point)
                       (concat ".outer { @if $a { x: 1; } " branch " {│} .after {} }")))
        (should (equal (car kill-ring) (string-replace "│" "" body)))))))

(ert-deftest scss2-edit-empty-body-whitespace-keeps-validation-boundaries ()
  (scss2-edit-test--buffer 'scss2-mode ".a { color: red;│ width: 1px; }"
    (narrow-to-region (point) (point-max))
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode ".a { color: red;│ width: 1px;"
    (scss2-edit-test--unchanged #'scss2-empty)))

(ert-deftest scss2-edit-empty-stops-at-comments ()
  (dolist (source '(".a { x: 1; /* no│te */ y: 2; }"
                    ".a { x: 1; /* note│ */ y: 2; }"
                    ".a { x: 1; // note│ \n  y: 2;\n}"
                    ".a { x: 1; // no│te\n  y: 2;\n}"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-edit-test--unchanged #'scss2-empty)
      (should (equal (cadr (should-error (scss2-empty) :type 'user-error))
                     "Nothing to empty here")))))

(ert-deftest scss2-edit-kill-if-condition-preserves-directive-and-body ()
  (dolist (case '(("@if $x │> 1 { x: 1; } @else { x: 2; }"
                   "@if │ { x: 1; } @else { x: 2; }" "$x > 1")
                  ("@if (foo($│x) > 1) { x: 1; }"
                   "@if │ { x: 1; }" "(foo($x) > 1)")
                  ("@if $x {} @else if $│y { x: 2; } @else { x: 3; }"
                   "@if $x {} @else if │ { x: 2; } @else { x: 3; }" "$y")
                  ("@if $x {} @elseif $│y { x: 2; }"
                   "@if $x {} @elseif │ { x: 2; }" "$y")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (let ((original (buffer-string)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (scss2-kill)
        (should (equal (scss2-edit-test--with-point) (nth 1 case)))
        (should (equal (car kill-ring) (nth 2 case)))
        (insert (car kill-ring))
        (should (equal (buffer-string) original))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))))))

(ert-deftest scss2-edit-kill-other-at-rule-heads-select-complete-statements ()
  (dolist (case '(((scss2-mode) "@mixin fo│o($x) { x: $x; }")
                  ((scss2-mode) "@mixin foo($│x) { x: $x; }")
                  ((scss2-mode) "@function fo│o($x: 1) { @return $x; }")
                  ((scss2-mode) "@function foo($│x: 1) { @return $x; }")
                  ((scss2-mode) "@while $x > │0 { x: 1; }")
                  ((scss2-mode) "@each $x i│n 1, 2 { x: $x; }")
                  ((scss2-mode) "@for $x from 1 th│rough 3 { x: $x; }")
                  ((scss2-mode) "@include th│eme.foo(1) using ($item) { x: 1; }")
                  ((scss2-mode) "@include foo(rhy│thm(1));")
                  ((scss2-mode) "@include fo│o;")
                  ((scss2-mode) "@use 'theme' a│s t;")
                  ((scss2-mode) "@forward 'theme' show co│lor;")
                  ((scss2-mode) "@extend .ba│se !optional;")
                  ((scss2-mode) "@debug $│x;")
                  ((scss2-mode) "@at-root .│a { x: 1; }")
                  ((css2-mode scss2-mode) "@media scr│een and (width > 1px) { .a {} }")
                  ((css2-mode scss2-mode) "@supports (display: gr│id) { .a {} }")
                  ((css2-mode scss2-mode) "@container ca│rd (width > 1px) { .a {} }")
                  ((css2-mode scss2-mode) "@scope (.│a) to (.b) { .c {} }")
                  ((css2-mode scss2-mode) "@keyframes fa│de { from { opacity: 0; } }")
                  ((css2-mode scss2-mode) "@namespace s│vg url(http://example.org);")
                  ((css2-mode scss2-mode) "@import 'the│me.css' screen;")
                  ((css2-mode scss2-mode) "@charset 'UT│F-8';")
                  ((css2-mode scss2-mode) "@layer ba│se, theme;")
                  ((css2-mode scss2-mode) "@property --to│ne { syntax: '<color>'; }")
                  ((css2-mode scss2-mode) "@custom alpha fn('a;│{b}') { x: 1; }")))
    (dolist (mode (car case))
      (scss2-edit-test--buffer mode (nth 1 case)
        (let ((original (buffer-string)))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (scss2-kill)
          (should (equal (scss2-edit-test--with-point) "│"))
          (should (equal (car kill-ring) original))
          (insert (car kill-ring))
          (should (equal (buffer-string) original))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))))))
  (scss2-edit-test--buffer 'scss2-mode "@function f() { @return /* c */ $│x }"
    (scss2-kill)
    (should (equal (scss2-edit-test--with-point) "@function f() { │ }"))
    (should (equal (car kill-ring) "@return /* c */ $x"))))

(ert-deftest scss2-edit-kill-at-rule-keywords-and-head-ignore-prefix ()
  (dolist (source '("@mi│xin foo($x) { x: $x; }" "@mixin foo($x) │{ x: $x; }"
                    "@in│clude foo(1);" "@fo│nt-face { font-family: test; }"
                    "@if $x { x: 1; } @else i│f $y { x: 2; }"
                    "@if $x { x: 1; } @el│se { x: 2; }"
                    "@if $x {} @else /* one */  │  /* two */ { x: 2; }"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-kill)
      (should (equal (buffer-string) ""))))
  (scss2-edit-test--buffer 'scss2-mode "@mixin fo│o($x) { x: $x; }"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-kill))
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-kill-if-condition-is-atomic-and-accessible ()
  (dolist (ending '("\n" "\r\n"))
    (scss2-edit-test--buffer 'scss2-mode
        (string-replace "\n" ending "/* before */\n@if /* head */ fo│o($x) {\n  x: $x;\n}\n/* after */")
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((original (buffer-string)))
        (call-interactively #'scss2-kill)
        (should (equal (buffer-string)
                       (string-replace "\n" ending "/* before */\n@if  {\n  x: $x;\n}\n/* after */")))
        (should (equal (car kill-ring) "/* head */ foo($x)"))
        (undo-boundary)
        (undo 1)
        (should (equal (buffer-string) original)))))
  (scss2-edit-test--buffer 'scss2-mode "@if fo│o($x) { x: 1; }"
    (narrow-to-region (point) (point-max))
    (scss2-edit-test--unchanged #'scss2-kill))
  (scss2-edit-test--buffer 'scss2-mode "@if fo│o($x { x: 1; }"
    (scss2-edit-test--unchanged #'scss2-kill))
  (scss2-edit-test--buffer 'scss2-mode "@if fo│o($x) { x: 1; }"
    (let ((buffer-read-only t)) (scss2-edit-test--unchanged #'scss2-kill)))
  (scss2-edit-test--buffer 'scss2-mode "@if fo│o($x) { x: 1; }"
    (cl-letf (((symbol-function 'kill-new)
               (lambda (&rest _) (setq kill-ring '("partial")) (error "Clipboard failed"))))
      (scss2-edit-test--unchanged #'scss2-kill))))

(ert-deftest scss2-edit-empty-ascends-to-nearest-header-content ()
  (dolist (case '(("@mixin rhy│thm($n, $offset: 0) { x: $n; }"
                   "@mixin rhythm(│) { x: $n; }" "$n, $offset: 0")
                  ("@mixin rhythm($│n, $offset: 0) { x: $n; }"
                   "@mixin rhythm(│) { x: $n; }" "$n, $offset: 0")
                  ("@function rhythm($n: min(1, │2)) { @return $n; }"
                   "@function rhythm($n: min(│)) { @return $n; }" "1, 2")
                  ("@include th│eme.rhythm(1) using ($n) { x: $n; }"
                   "@include theme.rhythm(│) using ($n) { x: $n; }" "1")
                  ("@include rhythm($label: \"a│b\") { x: 1; }"
                   "@include rhythm($label: \"│\") { x: 1; }" "ab")
                  ("@include rhythm($gap: rhy│thm(2)) { x: 1; }"
                   "@include rhythm($gap: rhythm(│)) { x: 1; }" "2")
                  ("@include rhythm(1) using ($│n) { x: $n; }"
                   "@include rhythm(1) using (│) { x: $n; }" "$n")
                  ("@if ($a │> 0) { x: 1; } @else { x: 2; }"
                   "@if (│) { x: 1; } @else { x: 2; }" "$a > 0")
                  ("@if $a │> 0 { x: 1; } @else { x: 2; }"
                   "@if $a > 0 {│} @else { x: 2; }" " x: 1; ")
                  ("@i│f ($a > 0) { x: 1; } @else { x: 2; }"
                   "@if ($a > 0) {│} @else { x: 2; }" " x: 1; ")
                  ("@if $a {} @else if ($b > │0) { x: 2; } @else { x: 3; }"
                   "@if $a {} @else if (│) { x: 2; } @else { x: 3; }" "$b > 0")
                  ("@if $a {} @else if $b > │0 { x: 2; } @else { x: 3; }"
                   "@if $a {} @else if $b > 0 {│} @else { x: 3; }" " x: 2; ")
                  ("@while ($a │> 0) { x: 1; }" "@while (│) { x: 1; }" "$a > 0")
                  ("@while $a │> 0 { x: 1; }" "@while $a > 0 {│}" " x: 1; ")
                  ("@media screen and (width > │1px) { .a {} }"
                   "@media screen and (│) { .a {} }" "width > 1px")
                  ("@media scr│een { .a {} }" "@media screen {│}" " .a {} ")
                  ("@supports (display: gr│id) { .a {} }"
                   "@supports (│) { .a {} }" "display: grid")
                  ("@scope (.│a) to (.b) { .c {} }"
                   "@scope (│) to (.b) { .c {} }" ".a")
                  ("@scope (.a) to (.│b) { .c {} }"
                   "@scope (.a) to (│) { .c {} }" ".b")
                  ("@scope (.a) t│o (.b) { .c {} }"
                   "@scope (.a) to (.b) {│}" " .c {} ")
                  ("@custom alpha fn('a;│{b}') { x: 1; }"
                   "@custom alpha fn('│') { x: 1; }" "a;{b}")
                  ("@mixin m { @include fo│o; x: 1; }"
                   "@mixin m { @include │; x: 1; }" "foo")
                  ("@mixin m { @con│tent; x: 1; }"
                   "@mixin m {│}" " @content; x: 1; ")
                  ("@mixin m { @con│tent(1, 2); }"
                   "@mixin m { @content(│); }" "1, 2")
                  ("@function f() { @return $│n; }"
                   "@function f() { @return │; }" "$n")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (let ((original (buffer-string)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (scss2-empty)
        (should (equal (scss2-edit-test--with-point) (nth 1 case)))
        (should (equal (car kill-ring) (nth 2 case)))
        (insert (car kill-ring))
        (should (equal (buffer-string) original))))))

(ert-deftest scss2-edit-empty-function-name-selects-parameters ()
  (dolist (source '("@function │rhythm($rhythms, $offset: 0) { @return $rhythms; }"
                    "@function rhy│thm($rhythms, $offset: 0) { @return $rhythms; }"
                    "@function rhythm│($rhythms, $offset: 0) { @return $rhythms; }"))
    (scss2-edit-test--buffer 'scss2-mode source
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((original (buffer-string)))
        (call-interactively #'scss2-empty)
        (should (equal (scss2-edit-test--with-point)
                       "@function rhythm(│) { @return $rhythms; }"))
        (should (equal (car kill-ring) "$rhythms, $offset: 0"))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (undo-boundary)
        (undo 1)
        (should (equal (buffer-string) original)))))
  (scss2-edit-test--buffer 'scss2-mode
      "@function rhy│thm(\r\n  $rhythms,\r\n  $offset: 0\r\n) {\r\n  @return $rhythms;\r\n}"
    (scss2-empty)
    (should (equal (scss2-edit-test--with-point)
                   "@function rhythm(│) {\r\n  @return $rhythms;\r\n}"))
    (should (equal (car kill-ring) "\r\n  $rhythms,\r\n  $offset: 0\r\n")))
  (scss2-edit-test--buffer 'scss2-mode "@function rhy│thm() { @return 0; }"
    (scss2-empty)
    (should (equal (scss2-edit-test--with-point) "@function rhythm(│) { @return 0; }"))
    (should (equal kill-ring '("previous kill"))))
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode
        "@function --│f(--n <length>+) returns <length> { result: 2px; }"
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point)
                     "@function --f(│) returns <length> { result: 2px; }"))
      (should (equal (car kill-ring) "--n <length>+"))
      (should-not (treesit-node-check (scss2--root-node) 'has-error)))))

(ert-deftest scss2-edit-empty-function-keyword-and-name-ignore-prefix ()
  (dolist (source '("│@function rhythm($rhythms, $offset: 0) { @return $rhythms; }"
                    "@fun│ction rhythm($rhythms, $offset: 0) { @return $rhythms; }"
                    "@function│ rhythm($rhythms, $offset: 0) { @return $rhythms; }"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point)
                     "@function rhythm($rhythms, $offset: 0) {│}"))
      (should (equal (car kill-ring) " @return $rhythms; "))))
  (scss2-edit-test--buffer 'scss2-mode
      "@function rhy│thm($rhythms, $offset: 0) { @return $rhythms; }"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-empty))
    (should (equal (buffer-string) "@function rhythm() { @return $rhythms; }"))))

(ert-deftest scss2-edit-empty-function-parameters-keep-validation-boundaries ()
  (scss2-edit-test--buffer 'scss2-mode "@function rhy│thm($rhythms) { width }"
    ;; An unrelated body error does not invalidate the parameter list.
    (scss2-empty)
    (should (equal (buffer-string) "@function rhythm() { width }")))
  (scss2-edit-test--buffer 'scss2-mode "@function rhy│thm($rhythms) { @return 0; }"
    (let ((position (point)))
      (search-forward "$rhythms")
      (narrow-to-region (point-min) (1- (point)))
      (goto-char position))
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@function rhy│thm($rhythms { @return 0; }"
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@function rhy│thm($rhythms) { @return 0; }"
    (cl-letf (((symbol-function 'kill-new)
               (lambda (&rest _) (setq kill-ring '("partial")) (error "Clipboard failed"))))
      (scss2-edit-test--unchanged #'scss2-empty))))

(ert-deftest scss2-edit-empty-at-rule-headers-fall-back-to-their-body ()
  (dolist (case '(((scss2-mode) "@mi│xin button($gap)" " x: $gap; ")
                  ((scss2-mode) "@fun│ction f($x)" " @return $x; ")
                  ((scss2-mode) "@ea│ch $x in 1, 2" " x: $x; ")
                  ((scss2-mode) "@each $x i│n 1, 2" " x: $x; ")
                  ((scss2-mode) "@fo│r $i from 1 through 3" " x: $i; ")
                  ((scss2-mode) "@for $i from 1 th│rough 3" " x: $i; ")
                  ((scss2-mode) "@wh│ile $x > 0" " x: 1; ")
                  ((scss2-mode) "@while $x │> 0" " x: 1; ")
                  ((scss2-mode) "@at-r│oot (without: media)" " .a {} ")
                  ((scss2-mode) "@at-root .│a" " x: 1; ")
                  ((scss2-mode) "@inc│lude buttons($gap: 2) using ($item)" " x: 1; ")
                  ((css2-mode scss2-mode) "@med│ia screen and (width > 1px)" " .a {} ")
                  ((css2-mode scss2-mode) "@media scr│een and (width > 1px)" " .a {} ")
                  ((css2-mode scss2-mode) "@sup│ports (display: grid)" " .a {} ")
                  ((css2-mode scss2-mode) "@con│tainer card (width > 1px)" " .a {} ")
                  ((css2-mode scss2-mode) "@sco│pe (.a) to (.b)" " .c {} ")
                  ((css2-mode scss2-mode) "@key│frames fade" " from { opacity: 0; } ")
                  ((css2-mode scss2-mode) "@keyframes fa│de" " from { opacity: 0; } ")
                  ((css2-mode scss2-mode) "@pa│ge :first" " margin: 1px; ")
                  ((css2-mode scss2-mode) "@layer ba│se" " .a {} ")
                  ((css2-mode scss2-mode) "@prop│erty --tone" " syntax: '<color>'; inherits: false; initial-value: red; ")
                  ((css2-mode scss2-mode) "@cus│tom alpha fn('a;{b}')" " x: 1; ")
                  ((css2-mode scss2-mode) "@font-f│ace" " font-family: test; ")
                  ((css2-mode scss2-mode) "@lay│er" " .a {} ")
                  ((css2-mode scss2-mode) "@sco│pe" " .a {} ")
                  ((scss2-mode) "@at-r│oot" " .a {} ")))
    (dolist (mode (car case))
      (scss2-edit-test--buffer mode (concat (nth 1 case) " {" (nth 2 case) "}")
        (let ((original (buffer-string)))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (scss2-empty)
          (should (equal (scss2-edit-test--with-point)
                         (concat (string-replace "│" "" (nth 1 case)) " {│}")))
          (should (equal (car kill-ring) (nth 2 case)))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (insert (car kill-ring))
          (should (equal (buffer-string) original)))))))

(ert-deftest scss2-edit-empty-leaf-at-rules-fall-back-to-their-head ()
  (dolist (case '(((scss2-mode) "@u│se \"sass:math\";" "@use │;" "\"sass:math\"")
                  ((scss2-mode) "@use 'theme' a│s t;" "@use │;" "'theme' as t")
                  ((scss2-mode) "@u│se 'theme' with ($gap: 2);" "@use │;" "'theme' with ($gap: 2)")
                  ((scss2-mode) "@for│ward 'theme';" "@forward │;" "'theme'")
                  ((scss2-mode) "@forward 'theme' show co│lor;" "@forward │;" "'theme' show color")
                  ((scss2-mode) "@ext│end .base !optional;" "@extend │;" ".base !optional")
                  ((scss2-mode) "@extend .ba│se;" "@extend │;" ".base")
                  ((scss2-mode) "@inc│lude mx;" "@include │;" "mx")
                  ((scss2-mode) "@include m│x;" "@include │;" "mx")
                  ((scss2-mode) "@deb│ug $x;" "@debug │;" "$x")
                  ((scss2-mode) "@warn \"x\" + $fo│o;" "@warn │;" "\"x\" + $foo")
                  ((css2-mode scss2-mode) "@imp│ort 'theme.css' screen;" "@import │;" "'theme.css' screen")
                  ((css2-mode scss2-mode) "@char│set 'UTF-8';" "@charset │;" "'UTF-8'")
                  ((css2-mode scss2-mode) "@name│space svg url(http://www.w3.org/2000/svg);"
                   "@namespace │;" "svg url(http://www.w3.org/2000/svg)")
                  ((css2-mode scss2-mode) "@lay│er base, theme;" "@layer │;" "base, theme")
                  ((css2-mode scss2-mode) "@custom al│pha beta;" "@custom │;" "alpha beta")))
    (dolist (mode (car case))
      (scss2-edit-test--buffer mode (nth 1 case)
        (buffer-enable-undo)
        (setq buffer-undo-list nil)
        (let ((original (buffer-string)))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (scss2-empty)
          (should (equal (scss2-edit-test--with-point) (nth 2 case)))
          (should (equal (car kill-ring) (nth 3 case)))
          (undo-boundary)
          (undo 1)
          (should (equal (buffer-string) original)))))))

(ert-deftest scss2-edit-empty-leaf-at-rules-keep-nearer-interiors ()
  (dolist (case '(("@use 'the│me' as t;" "@use '│' as t;")
                  ("@mixin m() { @content(│1, 2); }" "@mixin m() { @content(│); }")
                  ("@function f() { @return \"a│b\"; }" "@function f() { @return \"│\"; }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (cadr case))))))

(ert-deftest scss2-edit-empty-leaf-at-rule-head-preserves-boundaries ()
  (scss2-edit-test--buffer 'scss2-mode
      "/* before */\r\n@u│se\r\n  /* head */ \"sass:math\" as math\r\n;\r\n/* after */"
    (scss2-empty)
    (should (equal (scss2-edit-test--with-point)
                   "/* before */\r\n@use\r\n  │\r\n;\r\n/* after */"))
    (should (equal (car kill-ring) "/* head */ \"sass:math\" as math")))
  (scss2-edit-test--buffer 'scss2-mode ".a { @ext│end .base; color: red; }"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-empty))
    (should (equal (scss2-edit-test--with-point) ".a { @extend │; color: red; }")))
  (scss2-edit-test--buffer 'scss2-mode "@use /* no│te */ 'theme';"
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@cus│tom;"
    (scss2-edit-test--unchanged #'scss2-empty)))

(ert-deftest scss2-edit-empty-leaf-at-rule-head-keeps-validation-and-rollback ()
  (scss2-edit-test--buffer 'scss2-mode "@u│se \"sass:math\";"
    (narrow-to-region (point-min) (- (point-max) 3))
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@u│se \"sass:math;"
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@u│se \"sass:math\";"
    (cl-letf (((symbol-function 'kill-new)
               (lambda (&rest _) (setq kill-ring '("partial")) (error "Clipboard failed"))))
      (scss2-edit-test--unchanged #'scss2-empty))))

(ert-deftest scss2-edit-empty-at-rule-body-keeps-inner-entities ()
  (dolist (case '(("@media screen │{ .a {} }" "@media screen {│}")
                  ("@media screen { │ .a {} }" "@media screen {│}")
                  ("@include buttons(1) { │ x: 1; }" "@include buttons(1) {│}")
                  ("@font-face { │font-family: test; }" "@font-face { font-family: │; }")
                  ("@mixin f() { $m: (x: │1); }" "@mixin f() { $m: (x: │); }")
                  ("@mixin f() { width: rhy│thm(1); }" "@mixin f() { width: rhythm(│); }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (cadr case)))))
  (scss2-edit-test--buffer 'scss2-mode "@mixin f() { width: rhy│thm(1); }"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-empty))
    (should (equal (buffer-string) "@mixin f() { width: rhythm(); }"))))

(ert-deftest scss2-edit-empty-at-rule-preserves-crlf-comments-and-undo ()
  (scss2-edit-test--buffer 'scss2-mode
      "/* before */\r\n@med│ia\r\n  /* head */ screen and (width > 1px)\r\n{\r\n  /* body */ .a {}\r\n}\r\n/* after */"
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((original (buffer-string)))
      (call-interactively #'scss2-empty)
      (should (equal (scss2-edit-test--with-point)
                     "/* before */\r\n@media\r\n  /* head */ screen and (width > 1px)\r\n{│}\r\n/* after */"))
      (should (equal (car kill-ring) "\r\n  /* body */ .a {}\r\n"))
      (undo-boundary)
      (undo 1)
      (should (equal (buffer-string) original)))))

(ert-deftest scss2-edit-empty-at-rule-rejects-unreliable-bodies ()
  (scss2-edit-test--buffer 'scss2-mode "@med│ia screen and (width > 1px) { .a {} }"
    (narrow-to-region (point-min) (save-excursion (search-forward "screen") (point)))
    (scss2-edit-test--unchanged #'scss2-empty))
  (dolist (source '("@med│ia screen and (width > 1px { .a {} }"
                    "@i│f $a == \"foo\" { width }"
                    "@inc│lude buttons($gap: 2) { width }"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-edit-test--unchanged #'scss2-empty)))
  (scss2-edit-test--buffer 'scss2-mode "@mi│xin f() { x: 1; }"
    (let ((buffer-read-only t))
      (scss2-edit-test--unchanged #'scss2-empty)))
  (scss2-edit-test--buffer 'scss2-mode "@mi│xin f() { x: 1; }"
    (cl-letf (((symbol-function 'kill-new)
               (lambda (&rest _) (setq kill-ring '("partial")) (error "Clipboard failed"))))
      (scss2-edit-test--unchanged #'scss2-empty))))

(ert-deftest scss2-edit-empty-include-keyword-clears-arguments ()
  (dolist (case '(("@inc│lude app-chrome-icon-button-group($gap: rhythm(0.25));"
                   "@include app-chrome-icon-button-group(│);" "$gap: rhythm(0.25)")
                  ("│@include theme.buttons($gap: 2);"
                   "@include theme.buttons(│);" "$gap: 2")
                  ("@inc│lude\r\n  buttons(\r\n    2,\r\n    3\r\n  )\r\n;"
                   "@include\r\n  buttons(│)\r\n;" "\r\n    2,\r\n    3\r\n  ")
                  ("// before\n.a { @inc│lude /* call */ buttons(2); // after\n  x: 1; }"
                   "// before\n.a { @include /* call */ buttons(│); // after\n  x: 1; }" "2")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((original (buffer-string)))
        (call-interactively #'scss2-empty)
        (should (equal (scss2-edit-test--with-point) (nth 1 case)))
        (should (equal (car kill-ring) (nth 2 case)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (undo-boundary)
        (undo 1)
        (should (equal (buffer-string) original))))))

(ert-deftest scss2-edit-empty-include-keyword-rejects-unreliable-ranges ()
  (scss2-edit-test--buffer 'scss2-mode ".a { @inc│lude buttons($gap: 2); x: 1; }"
    (let ((position (point)))
      (search-forward "2")
      (narrow-to-region (point-min) (1- (point)))
      (goto-char position))
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode ".a { @inc│lude buttons($gap: 2; x: 1; }"
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@inc│lude buttons($gap: 2);"
    (let ((buffer-read-only t))
      (scss2-edit-test--unchanged #'scss2-empty))))

(ert-deftest scss2-edit-empty-include-name-clears-its-arguments ()
  (dolist (case '(("@include app-chrome-icon-│button-group($gap: rhythm(0.25));"
                   "@include app-chrome-icon-button-group(│);" "$gap: rhythm(0.25)")
                  ("@include th│eme.buttons($gap: rhythm(0.25));"
                   "@include theme.buttons(│);" "$gap: rhythm(0.25)")
                  ("@include theme.but│tons($gap: rhythm(0.25));"
                   "@include theme.buttons(│);" "$gap: rhythm(0.25)")
                  ("@include app-chrome-icon-button-group($gap: rhy│thm(0.25));"
                   "@include app-chrome-icon-button-group($gap: rhythm(│));" "0.25")
                  ("@include bu│ttons(\r\n  $gap: rhythm(0.25),\r\n  $size: 2\r\n);"
                   "@include buttons(│);" "\r\n  $gap: rhythm(0.25),\r\n  $size: 2\r\n")
                  ("@include bu│ttons();" "@include buttons(│);" "previous kill")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case)))
      (should-not (treesit-node-check (scss2--root-node) 'has-error)))))

(ert-deftest scss2-edit-empty-names-select-only-their-own-parameter-list ()
  (dolist (case '(("@include fo│o using ($item) { x: $item; }"
                   "@include foo using ($item) {│}" " x: $item; ")
                  ("@include th│eme.foo using ($item) { x: $item; }"
                   "@include theme.foo using ($item) {│}" " x: $item; ")
                  ("@include theme.fo│o /* call */ using ($item) { x: $item; }"
                   "@include theme.foo /* call */ using ($item) {│}" " x: $item; ")
                  ("@include fo│o /* call */ (1) using ($item) { x: $item; }"
                   "@include foo /* call */ (│) using ($item) { x: $item; }" "1")
                  ("@include fo│o() using ($item) { x: $item; }"
                   "@include foo(│) using ($item) { x: $item; }" "previous kill")
                  ("@include foo using ($│item) { x: $item; }"
                   "@include foo using (│) { x: $item; }" "$item")
                  ("@mixin fo│o /* signature */ ($item) { x: $item; }"
                   "@mixin foo /* signature */ (│) { x: $item; }" "$item")
                  ("@function fo│o /* signature */ ($item) { @return $item; }"
                   "@function foo /* signature */ (│) { @return $item; }" "$item")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case)))
      (should-not (treesit-node-check (scss2--root-node) 'has-error)))))

(ert-deftest scss2-edit-empty-include-name-rejects-unreliable-arguments ()
  (scss2-edit-test--buffer 'scss2-mode ".a { @include bu│ttons($gap: 2); x: 1; }"
    (let ((position (point)))
      (search-forward "2")
      (narrow-to-region (point-min) (1- (point)))
      (goto-char position))
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode ".a { @include bu│ttons($gap: 2; x: 1; }"
    (scss2-edit-test--unchanged #'scss2-empty)))

(ert-deftest scss2-edit-empty-clears-named-parameter-values ()
  (dolist (case '((scss2-mode "@function func($va│lue: 1, $other: 2) { @return $value; }"
                            "@function func($value: │, $other: 2) { @return $value; }" "1")
                  (scss2-mode "@mixin func($│value: 1, $other: 2) {}"
                              "@mixin func($value: │, $other: 2) {}" "1")
                  (scss2-mode "@include func($value│: 1, $other: 2);"
                              "@include func($value: │, $other: 2);" "1")
                  (scss2-mode ".a { x: func($va│lue: 1 2, $other: 3); }"
                              ".a { x: func($value: │, $other: 3); }" "1 2")
                  (scss2-mode "@include func($va│lue: min(1, 2));"
                              "@include func($value: │);" "min(1, 2)")
                  (scss2-mode "@mixin func($va│lue: (a: 1, b: 2)) {}"
                              "@mixin func($value: │) {}" "(a: 1, b: 2)")
                  (scss2-mode "@include func($va│lue: 'text');"
                              "@include func($value: │);" "'text'")
                  (scss2-mode "@include func($value: 1│0);"
                              "@include func($value: │);" "10")
                  (scss2-mode "@include func($value:│ 1);"
                              "@include func($value: │);" "1")
                  (scss2-mode "@include func using ($va│lue: 1) {}"
                              "@include func using ($value: │) {}" "1")
                  (scss2-mode "@use 'x' with ($va│lue: 1 !default);"
                              "@use 'x' with ($value: │ !default);" "1")
                  (scss2-mode "@mixin func($va│lue: /* before */ 1 /* after */, $other: 2) {}"
                              "@mixin func($value: │ /* after */, $other: 2) {}" "/* before */ 1")
                  (css2-mode "@function --func(--va│lue <number>: 1) { result: var(--value); }"
                             "@function --func(--value <number>: │) { result: var(--value); }" "1")))
    (scss2-edit-test--buffer (car case) (nth 1 case)
      (let ((original (buffer-string)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (scss2-empty)
        (should (equal (scss2-edit-test--with-point) (nth 2 case)))
        (should (equal (car kill-ring) (nth 3 case)))
        (insert (car kill-ring))
        (should (equal (buffer-string) original))))))


(ert-deftest scss2-edit-entry-tail-entity-boundaries ()
  (dolist (value '("1" "(inner: 1)" "f(1)" "\"text\""))
    (dolist (tail '("│" "│ " " │" " \t│\r\n "))
      (dolist (ending '(", b: 2);" ");" ",);"))
        (dolist (command '(scss2-copy scss2-mark scss2-kill
                           scss2-duplicate scss2-comment-uncomment))
          (let* ((source (concat "$m: (a: " value tail ending))
                 (plain (string-replace "│" "" source))
                 expected)
            (scss2-edit-test--buffer 'scss2-mode
                (string-replace "a:" "│a:" plain)
              (let ((pulse-flag nil)) (funcall command))
              (setq expected (list (buffer-string) kill-ring
                                   (and (eq command 'scss2-mark)
                                        (buffer-substring (region-beginning) (region-end))))))
            (scss2-edit-test--buffer 'scss2-mode source
              (let ((pulse-flag nil)) (funcall command))
              (should (equal (list (buffer-string) kill-ring
                                   (and (eq command 'scss2-mark)
                                        (buffer-substring (region-beginning) (region-end))))
                             expected))
              (should-not (treesit-node-check (scss2--root-node) 'has-error)))))))))

(ert-deftest scss2-edit-entry-tail-empty-boundaries ()
  (dolist (frame '(("$m: (a: " . ", b: 2);")
                   ("$m: (a: " . ");")
                   ("@include f($x: " . ", $y: 2);")
                   ("@mixin f($x: " . ") {}")
                   ("@use 'x' with ($x: " . ");")))
    (dolist (value '("1" "(inner: 1)" "f(1)" "\"text\""))
      (dolist (tail '("│" "│ " " │" " \t│\r\n "))
        (scss2-edit-test--buffer 'scss2-mode
            (concat (car frame) value tail (cdr frame))
          (scss2-empty)
          (should (equal (car kill-ring) value))
          (should (equal (buffer-string)
                         (concat (car frame) (string-replace "│" "" tail) (cdr frame)))))))))

(ert-deftest scss2-edit-entry-tail-keeps-container-and-comment-boundaries ()
  (dolist (case '(("$m: (a: 1,│ b: 2);" "a: 1, b: 2")
                  ("$m: (a: 1, │);" "a: 1, ")
                  ("$m: (a: 1 /* keep */ │, b: 2);" "a: 1 /* keep */ , b: 2")
                  ("$m: (a: f(1 │), b: 2);" "1 ")
                  ("$m: (a: \"text │\", b: 2);" "text ")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (car kill-ring) (cadr case)))))
  (scss2-edit-test--buffer 'scss2-mode "$m: (a: 1 /* ke│ep */, b: 2);"
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "$m: (a: 1 │, b: 2);"
    (let ((scss2-entity-node-types '("variable_declaration")))
      (scss2-copy)
      (should (equal (car kill-ring) "$m: (a: 1 , b: 2);")))))

(ert-deftest scss2-edit-entry-tail-keeps-validation-and-undo ()
  (dolist (command '(scss2-copy scss2-mark scss2-kill scss2-duplicate
                     scss2-comment-uncomment scss2-empty))
    (scss2-edit-test--buffer 'scss2-mode "$m: (a: 1 │, b: 2);"
      (narrow-to-region (1- (point)) (point-max))
      (scss2-edit-test--unchanged command))
    (scss2-edit-test--buffer 'scss2-mode "$m: (a: 1 │, b: \"unfinished);"
      (scss2-edit-test--unchanged command)))
  (dolist (command '(scss2-kill scss2-duplicate scss2-comment-uncomment scss2-empty))
    (scss2-edit-test--buffer 'scss2-mode "$m: (a: (inner: 1) \t│\n, b: 2);"
      ;; An incremental whitespace edit must resolve the same entry.
      (insert " ")
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((original (buffer-string)) (pulse-flag nil))
        (funcall command)
        (undo-boundary)
        (undo 1)
        (should (equal (buffer-string) original))))))

(ert-deftest scss2-edit-empty-named-parameter-boundaries-and-nearer-content ()
  (dolist (case '(("@mixin f($x: 1│, $y: 2) {}" "@mixin f($x: │, $y: 2) {}" "1")
                  ("@include f($x: 1│);" "@include f($x: │);" "1")
                  ("@use 'x' with ($x: 1│);" "@use 'x' with ($x: │);" "1")
                  ("@include f($x: 1,│ $y: 2);" "@include f(│);" "$x: 1, $y: 2")
                  ("@mixin f│($x: 1) {}" "@mixin f(│) {}" "$x: 1")
                  ("@mixin f($│x, $y: 2) {}" "@mixin f(│) {}" "$x, $y: 2")
                  ("@mixin f($x, $re│st...) {}" "@mixin f(│) {}" "$x, $rest...")
                  ("@include f($x: mi│n(1, 2));" "@include f($x: min(│));" "1, 2")
                  ("@mixin f($x: 'te│xt') {}" "@mixin f($x: '│') {}" "text")
                  ("@include f($x: (a: │1, b: 2));" "@include f($x: (a: │, b: 2));" "1")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case))))))

(ert-deftest scss2-edit-empty-named-parameter-values-keep-validation-and-undo ()
  (dolist (ending '("\n" "\r\n"))
    (scss2-edit-test--buffer 'scss2-mode
        (string-replace "\n" ending "@mixin f(\n  $va│lue:\n    1 2,\n  $other: 3\n) {}")
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((original (buffer-string)))
        (scss2-empty)
        (should (equal (scss2-edit-test--with-point)
                       (string-replace "\n" ending "@mixin f(\n  $value:\n    │,\n  $other: 3\n) {}")))
        (should (equal (car kill-ring) "1 2"))
        (undo-boundary)
        (undo 1)
        (should (equal (buffer-string) original)))))
  (scss2-edit-test--buffer 'scss2-mode "@function f($│x: 1) { width }"
    ;; A body error does not invalidate a complete parameter value.
    (scss2-empty)
    (should (equal (buffer-string) "@function f($x: ) { width }")))
  (scss2-edit-test--buffer 'scss2-mode "@include f($│x: 1);"
    (narrow-to-region (point-min) (save-excursion (search-forward "1") (1- (point))))
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@mixin f($│x: 1 { x: 1; }"
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@include f($x: /* co│mment */ 1);"
    (scss2-edit-test--unchanged #'scss2-empty))
  (scss2-edit-test--buffer 'scss2-mode "@include f($│x: 1);"
    (cl-letf (((symbol-function 'kill-new)
               (lambda (&rest _) (setq kill-ring '("partial")) (error "Clipboard failed"))))
      (scss2-edit-test--unchanged #'scss2-empty))))

(ert-deftest scss2-edit-empty-clears-map-entry-values ()
  (dolist (case '(("$m: (sm│all: 576px, medium: 768px);" "$m: (small: │, medium: 768px);" "576px")
                  ("$m: (small: 57│6px, medium: 768px);" "$m: (small: │, medium: 768px);" "576px")
                  ("$m: (small│: 1 2);" "$m: (small: │);" "1 2")
                  ("$m: (a: (b: │1));" "$m: (a: (b: │));" "1")
                  ("$m: (a│: (b: 1));" "$m: (a: │);" "(b: 1)")
                  ("$bp: (\n  sm│all: 576px,\n  medium: 768px,\n);"
                   "$bp: (\n  small: │,\n  medium: 768px,\n);" "576px")
                  (".a { @at-root (with│out: media) { x: 1; } }"
                   ".a { @at-root (without: │) { x: 1; } }" "media")
                  ;; Strings and interpolation keep their own interiors.
                  ("$m: (\"s│m\": 1);" "$m: (\"│\": 1);" "sm")
                  ("$m: (#{$k│}: 1);" "$m: (#{│}: 1);" "$k")
                  ("$m: (a│: /* c */ 1);" "$m: (a: │);" "/* c */ 1")
                  ;; At the comma or parenthesis after a value, its entry.
                  ("$m: (a: 1│, b: 2);" "$m: (a: │, b: 2);" "1")
                  ("$m: (a: 1, b: 2│);" "$m: (a: 1, b: │);" "2")
                  ("$bp: (\n  small: 576px│,\n  medium: 768px,\n);"
                   "$bp: (\n  small: │,\n  medium: 768px,\n);" "576px")
                  ;; After a comma or at the opening parenthesis, the whole map.
                  ("$m: (a: 1,│ b: 2);" "$m: (│);" "a: 1, b: 2")
                  ("$m: │(a: 1);" "$m: (│);" "a: 1")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case))))))

(ert-deftest scss2-edit-empty-clears-string-and-interpolation-interiors ()
  (dolist (case '(((css2-mode scss2-mode) ".a { content: \"a │b\" !important; }"
                   ".a { content: \"│\" !important; }" "a b")
                  ((css2-mode scss2-mode) ".a { content: '│lit\\'eral'; }"
                   ".a { content: '│'; }" "lit\\'eral")
                  ((css2-mode scss2-mode) ".a { content: \"literal│\"; }"
                   ".a { content: \"│\"; }" "literal")
                  ((css2-mode scss2-mode) ".a { content: │\"foo\"; }"
                   ".a { content: \"│\"; }" "foo")
                  ((css2-mode scss2-mode) ".a { content: \"foo\"│ \"x\"; }"
                   ".a { content: \"│\" \"x\"; }" "foo")
                  ((css2-mode scss2-mode) ".a { content: \"a\\\r\nb│c\"; }"
                   ".a { content: \"│\"; }" "a\\\r\nbc")
                  ((css2-mode scss2-mode) ".a { content: \"│\"; }"
                   ".a { content: \"│\"; }" "previous kill")
                  ((css2-mode scss2-mode) "@import \"fo│o\";" "@import \"│\";" "foo")
                  ((css2-mode scss2-mode) "[data-x=\"f│oo\"] {}" "[data-x=\"│\"] {}" "foo")
                  ((css2-mode scss2-mode) ".a { background: url(\"im│g.png\"); }"
                   ".a { background: url(\"│\"); }" "img.png")
                  ;; CSS has no interpolation, so `#{' is string text there.
                  ((css2-mode) ".a { content: \"a #{b│} c\"; }"
                   ".a { content: \"│\"; }" "a #{b} c")
                  ((scss2-mode) ".a { content: \"a│ #{$b} c\"; }"
                   ".a { content: \"│\"; }" "a #{$b} c")
                  ((scss2-mode) ".a { content: \"a #{$b│} c\"; }"
                   ".a { content: \"a #{│} c\"; }" "$b")
                  ((scss2-mode) ".a { width: #{\"x│y\"}; }" ".a { width: #{\"│\"}; }" "xy")
                  ((scss2-mode) ".a { width: #{ma│th.div($a, 2)}; }"
                   ".a { width: #{│}; }" "math.div($a, 2)")
                  ((scss2-mode) ".a { content: \"#{map-g│et($m, k)}\"; }"
                   ".a { content: \"#{│}\"; }" "map-get($m, k)")
                  ((scss2-mode) ".a { b: #{i│f($c, 1px, 2px)}; }" ".a { b: #{│}; }" "if($c, 1px, 2px)")
                  ;; From its opening parenthesis on, a call selects its arguments.
                  ((scss2-mode) ".a { width: #{math.div│($a, 2)}; }"
                   ".a { width: #{math.div(│)}; }" "$a, 2")
                  ((scss2-mode) ".a { b: #{│#{$a}}; }" ".a { b: #{#{│}}; }" "$a")
                  ;; Sass evaluates interpolation in loud comments.
                  ((scss2-mode) ".a { /* #{f│n(1)} */ }" ".a { /* #{│} */ }" "fn(1)")
                  ((scss2-mode) "@use \"sass:m│ath\" as m;" "@use \"│\" as m;" "sass:math")
                  ((scss2-mode) "@debug \"v│: #{$a}\";" "@debug \"│\";" "v: #{$a}")
                  ((scss2-mode) "@if $a == \"f│oo\" { x: 1; }"
                   "@if $a == \"│\" { x: 1; }" "foo")
                  ((scss2-mode) ".a { width: │#{$a + 1}px; }"
                   ".a { width: #{│}px; }" "$a + 1")
                  ((scss2-mode) ".a-#{$b│} { x: 1; }" ".a-#{│} { x: 1; }" "$b")
                  ((scss2-mode) ".a { #{$p│}-top: 1px; }" ".a { #{│}-top: 1px; }" "$p")
                  ((scss2-mode) "@media #{$q│} { .a { x: 1; } }"
                   "@media #{│} { .a { x: 1; } }" "$q")))
    (dolist (mode (car case))
      (scss2-edit-test--buffer mode (nth 1 case)
        (scss2-empty)
        (should (equal (scss2-edit-test--with-point) (nth 2 case)))
        (should (equal (car kill-ring) (nth 3 case))))))
  ;; Unterminated strings and a lone quote have no reliable interior.
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '((".a { content: \"ab│c\n}" . "This syntax is incomplete; no reliable edit range")
                    ("$x: \"ab│" . "This syntax is incomplete; no reliable edit range")
                    ("@media \"│" . "Nothing to empty here")))
      (scss2-edit-test--buffer mode (car case)
        (scss2-edit-test--unchanged #'scss2-empty)
        (should (equal (cadr (should-error (scss2-empty) :type 'user-error)) (cdr case)))))))

(ert-deftest scss2-edit-empty-if-header-selects-current-branch-body ()
  (dolist (case '(("@if $a │and $b { x: 1; } @else { x: 2; }"
                   "@if $a and $b {} @else { x: 2; }" " x: 1; ")
                  ("@if $a {} @else if $b == │2 { x: 1; }"
                   "@if $a {} @else if $b == 2 {}" " x: 1; ")
                  ("@if $a { x: 1; } @else │{ x: 2; }"
                   "@if $a { x: 1; } @else {}" " x: 2; ")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (buffer-string) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case)))))
  (scss2-edit-test--buffer 'scss2-mode "@if $a { x: 1; } @else if $b │{ x: 2; }"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-empty))
    (should (equal (buffer-string) "@if $a { x: 1; } @else if $b {}"))))

(ert-deftest scss2-edit-conditional-copy-and-duplicate-keep-the-chain ()
  (scss2-edit-test--buffer 'scss2-mode "@if $x {} @│else if $y {} @else {}"
    (let ((source (buffer-string)))
      (scss2-copy)
      (should (equal (car kill-ring) source))
      (scss2-duplicate)
      (should (equal (buffer-string) (concat source "\n" source))))))

(ert-deftest scss2-edit-selector-comments-roundtrip-complete-rules ()
  (let ((scss2-entity-node-types (cons "selectors" scss2--statement-types)))
    (dolist (mode '(css2-mode scss2-mode))
      (dolist (source '(".│a { color: red; }"
                        ".│a, .b { color: red; }"
                        ".a, .│b { color: red; }"
                        ".│a /* retained */, .b { color: red; }"
                        ".a, /* retained */ .│b { color: red; }"
                        ".a, :is(.b, .│c), .d { color: red; }"))
        (scss2-edit-test--buffer mode source
          (let ((original (buffer-string)) (ring (copy-sequence kill-ring)))
            (scss2-comment-uncomment)
            (should-not (treesit-node-check (scss2--root-node) 'has-error))
            (goto-char (point-min)) (re-search-forward "/[/*]")
            (scss2-comment-uncomment)
            (should (equal (buffer-string) original))
            (should (equal kill-ring ring))))))))

(ert-deftest scss2-edit-declaration-and-block-comments-roundtrip ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".a { content: \"hello│\"; color: red; }"
                      ".a {\n  co│lor: red; /* retained */\n  x: 1;\n}"
                      "@m│edia screen {\n  .a { /* inner */ color: red; }\n}"
                      "@m│edia screen {\r\n  .a { /* inner */ color: red; }\r\n}"))
      (scss2-edit-test--buffer mode source
        (let ((original (buffer-string)))
          (scss2-comment-uncomment)
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (goto-char (point-min)) (re-search-forward "/[/*]")
          (let ((current-prefix-arg '(4))) (call-interactively #'scss2-comment-uncomment))
          (should (equal (buffer-string) original))))))
  (scss2-edit-test--buffer 'scss2-mode "// first\n\n// se│cond\n.a {}"
    (scss2-comment-uncomment)
    (should (equal (buffer-string) "// first\n\nsecond\n.a {}"))))

(ert-deftest scss2-edit-comment-keeps-conditional-and-nested-body ()
  (scss2-edit-test--buffer 'scss2-mode
      "@i│f $x {\n  x: 1;\n} @else {\n  x: 2;\n}\n.after {}"
    (let ((original (buffer-string)))
      (let ((current-prefix-arg '(4))) (call-interactively #'scss2-comment-uncomment))
      (goto-char (point-min)) (search-forward "//")
      (let ((current-prefix-arg '(4))) (call-interactively #'scss2-comment-uncomment))
      (should (equal (buffer-string) original)))))

(ert-deftest scss2-edit-comment-and-selector-ranges-stay-accessible ()
  (let ((scss2-entity-node-types (cons "selectors" scss2--statement-types)))
    (dolist (source '(".│a /* retained */, .b {}" ".a, /* retained */ .│b {}"))
      (scss2-edit-test--buffer 'css2-mode source
        (let ((selectors (scss2--selector-owner (scss2--containing-node)))
              (position (point)))
          (narrow-to-region (treesit-node-start selectors) (treesit-node-end selectors))
          (goto-char position))
        (dolist (command '(scss2-kill scss2-copy scss2-mark scss2-duplicate scss2-comment-uncomment))
          (scss2-edit-test--unchanged command))))
    (scss2-edit-test--buffer 'scss2-mode "// first\n// se│cond\n.a {}"
      (let ((position (point)))
        (forward-line 0) (narrow-to-region (point) (point-max)) (goto-char position))
      (scss2-edit-test--unchanged #'scss2-comment-uncomment)
      (scss2-edit-test--unchanged (lambda () (let ((current-prefix-arg '(4))) (call-interactively #'scss2-comment-uncomment))))
      (widen)
      (scss2-comment-uncomment)
      (should (equal (buffer-string) "first\nsecond\n.a {}")))))

(ert-deftest scss2-edit-copy-mark-and-duplicate-preserve-editor-state ()
  (scss2-edit-test--buffer 'css2-mode ".a { content: \"ab│cd\"; }"
    (set-mark (point-min)) (setq mark-active t)
    (let ((position (point)) (saved-mark (mark)))
      (scss2-copy)
      (should (= (point) position)) (should (= (mark) saved-mark)) (should mark-active)
      (should (equal (car kill-ring) "content: \"abcd\";")))
    (let ((ring (copy-sequence kill-ring)))
      (scss2-duplicate)
      (should (equal (buffer-string) ".a { content: \"abcd\"; content: \"abcd\"; }"))
      (should (equal kill-ring ring)))))

(ert-deftest scss2-edit-clipboard-buffer-switch-failure-restores-origin ()
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: red; }"
    (let ((origin (current-buffer)) (other (generate-new-buffer " *scss2-clipboard-test*")))
      (unwind-protect
          (let ((interprogram-cut-function
                 (lambda (&rest _) (set-buffer other) (error "Clipboard failure"))))
            (scss2-edit-test--unchanged #'scss2-kill)
            (should (eq (current-buffer) origin))
            (with-current-buffer other (should (equal (buffer-string) ""))))
        (kill-buffer other)))))

(ert-deftest scss2-edit-mutating-commands-have-one-undo-step ()
  (dolist (command '(scss2-kill scss2-empty scss2-duplicate scss2-comment-uncomment))
    (scss2-edit-test--buffer 'css2-mode ".a {\n  col│or: red;\n}"
      (buffer-enable-undo) (setq buffer-undo-list nil)
      (let ((source (buffer-string)))
        (undo-boundary) (funcall command) (undo-boundary)
        (undo-only 1)
        (should (equal (buffer-string) source))))))

(ert-deftest scss2-edit-avy-rejects-inaccessible-and-incomplete-blocks ()
  (dolist (source '(".a { color: re│d; }" ".a { color: re│d;"))
    (scss2-edit-test--buffer 'css2-mode source
      (when (string-suffix-p "}" (buffer-string)) (narrow-to-region (point) (point-max)))
      (let ((require-function (symbol-function 'require)))
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &optional filename noerror)
                     (if (eq feature 'avy) t (funcall require-function feature filename noerror))))
                  ((symbol-function 'avy-goto-word-0)
                   (lambda (&rest _) (ert-fail "Avy received an invalid scope"))))
          (scss2-edit-test--unchanged #'scss2-avy-word))))))

(ert-deftest scss2-edit-empty-opening-brace-selects-the-body ()
  (dolist (case '(("@if $x │{ color: red; } @else { color: blue; }"
                   "@if $x {} @else { color: blue; }")
                  ("@if $x {} @else if $y │{ color: red; }"
                   "@if $x {} @else if $y {}")
                  (".a { font: bold │{ size: 12px; } }"
                   ".a { font: bold {} }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (buffer-string) (cadr case)))
      (should-not (treesit-node-check (scss2--root-node) 'has-error)))))

(ert-deftest scss2-edit-comment-block-with-blank-lines-roundtrips ()
  (dolist (ending '("\n" "\r\n"))
    (dolist (blank '("" "  " "\t"))
      (scss2-edit-test--buffer 'scss2-mode
          (string-join (list "@m│ixin f() {" blank "  color: red;" blank "}" ".after {}") ending)
        (let ((original (buffer-string)))
          (buffer-enable-undo) (setq buffer-undo-list nil)
          (scss2-comment-uncomment)
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (goto-char (point-min)) (search-forward "//")
          (undo-boundary)
          (let ((current-prefix-arg '(4))) (call-interactively #'scss2-comment-uncomment))
          (undo-boundary)
          (should (equal (buffer-string) original))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (should (equal kill-ring '("previous kill")))
          (undo-only 1)
          (should (string-prefix-p "// @mixin" (buffer-string)))
          (let ((last-command 'undo)) (undo-only 1))
          (should (equal (buffer-string) original)))))))

(ert-deftest scss2-edit-uncomment-groups-adjacent-lines ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  // TODO: tweak\n\n  co│lor: red;\n}"
    (let ((original (buffer-string)))
      (scss2-comment-uncomment)
      (should (equal (buffer-string) ".a {\n  // TODO: tweak\n\n  // color: red;\n}"))
      (goto-char (point-min)) (search-forward "// color")
      (scss2-comment-uncomment)
      (should (equal (buffer-string) original))))
  (dolist (prefix '(nil t))
    (scss2-edit-test--buffer 'scss2-mode ".a {\n  // one\n  // t│wo\n  color: red;\n}"
      (let ((current-prefix-arg prefix)) (call-interactively #'scss2-comment-uncomment))
      (should (equal (buffer-string) ".a {\n  one\n  two\n  color: red;\n}")))))

(ert-deftest scss2-edit-multiline-line-comment-aligns-its-markers ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  .in│ner {\n    x: 1;\n  }\n  color: red;\n}"
    (let ((current-prefix-arg '(4))) (call-interactively #'scss2-comment-uncomment))
    (should (equal (buffer-string)
                   ".a {\n  // .inner {\n  //   x: 1;\n  // }\n  color: red;\n}"))
    (search-forward "color")
    (scss2-comment-uncomment)
    (should (string-search "\n  // color: red;\n" (buffer-string)))))

(ert-deftest scss2-edit-line-comment-aligns-conditional-markers ()
  (scss2-edit-test--buffer 'scss2-mode
      ".a {\n  @│if lib.is-present($baseline-ratio) {\n    @error \"Invalid configuration\";\n  }\n}"
    (let ((original (buffer-string)))
      (scss2-comment-uncomment)
      (should (equal (buffer-string)
                     ".a {\n  // @if lib.is-present($baseline-ratio) {\n  //   @error \"Invalid configuration\";\n  // }\n}"))
      (scss2-comment-uncomment)
      (should (equal (buffer-string) original)))))

(ert-deftest scss2-edit-comment-indented-block-uses-native-blank-line-indentation ()
  (dolist (ending '("\n" "\r\n"))
    (scss2-edit-test--buffer 'scss2-mode
        (string-join '(".outer {" "  .inner │{" "" "    color: red;" "\t" "  }  " "}") ending)
      (let ((original (buffer-string)))
        (buffer-enable-undo) (setq buffer-undo-list nil)
        (let ((current-prefix-arg '(4))) (call-interactively #'scss2-comment-uncomment))
        (should (equal (buffer-string)
                       (string-join (if (equal ending "\n")
                                        '(".outer {" "  // .inner {" "  // "
                                          "  //   color: red;" "  // \t" "  // }  " "}")
                                      '(".outer {" "//   .inner {" "// "
                                        "//     color: red;" "// \t" "//   }  " "}"))
                                    ending)))
        (undo-boundary)
        (goto-char (point-min)) (search-forward "//")
        (let ((current-prefix-arg '(4))) (call-interactively #'scss2-comment-uncomment))
        ;; Native indentation pads a short blank LF line to the common column.
        (should (equal (buffer-string)
                       (if (equal ending "\n")
                           (string-replace "{\n\n" "{\n  \n" original)
                         original)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (undo-boundary)
        (undo-only 2)
        (should (equal (buffer-string) original))))))

(ert-deftest scss2-edit-line-comment-preserves-mixed-indentation-and-existing-comments ()
  (dolist (ending '("\n" "\r\n"))
    (scss2-edit-test--buffer 'scss2-mode
        (string-join '(".outer {" " \t.inner │{" " \t  // note" " \t  color: red;"
                       " \t}" "}") ending)
      (let ((original (buffer-string)))
        (scss2-comment-uncomment)
        (should (equal (buffer-string)
                       (string-join '(".outer {" " \t// .inner {" " \t//   // note"
                                      " \t//   color: red;" " \t// }" "}") ending)))
        (goto-char (point-min)) (search-forward "//")
        (scss2-comment-uncomment)
        (should (equal (buffer-string) original))))))

(ert-deftest scss2-edit-comment-entities-share-copy-and-mark-boundaries ()
  (dolist (case '((scss2-mode "// one\n// t│wo\n.a {}" "// one\n// two")
                  (scss2-mode ".a {} // trailing\n// hea│der\n.b {}" "// header")
                  (scss2-mode ".a {} // trai│ling\n// header\n.b {}" "// trailing")
                  (scss2-mode "// one\n\n// t│wo\n.a {}" "// two")
                  (scss2-mode "/* doc */\n// o│ne\n// two\n.a {}" "// one\n// two")
                  (scss2-mode "// one\n/* d│oc */\n// two\n.a {}" "/* doc */")
                  (scss2-mode ".a {\n  // o│ne\n  // two\n  x: 1;\n}" "// one\n  // two")
                  (scss2-mode "// one  \r\n// t│wo\t\r\n.a {}" "// one  \r\n// two\t")
                  (css2-mode ".a { /* no│te */ color: red; }" "/* note */")
                  (css2-mode "/* one\n   t│wo */\n.a {}" "/* one\n   two */")))
    (scss2-edit-test--buffer (car case) (cadr case)
      (let ((original (buffer-string)) (position (point))
            (transient-mark-mode t) (pulse-flag nil))
        (set-mark (point-max)) (setq mark-active t)
        (scss2-copy)
        (should (equal (buffer-string) original))
        (should (= (point) position))
        (should (= (mark) (point-max)))
        (should mark-active)
        (should (equal (car kill-ring) (nth 2 case)))
        (scss2-mark)
        (should (equal (buffer-substring-no-properties (point) (mark)) (nth 2 case)))
        (let ((last-command 'scss2-mark) (begin (point)) (end (mark)))
          (scss2-mark)
          (should (= (point) begin))
          (should (= (mark) end)))))))

(ert-deftest scss2-edit-comment-kill-preserves-surrounding-code ()
  (dolist (case '((scss2-mode ".a {} // trailing\n// hea│der\n// second\n.b {}"
                              ".a {} // trailing\n.b {}")
                  (scss2-mode ".a {} // trai│ling\n// header\n.b {}"
                              ".a {} \n// header\n.b {}")
                  (scss2-mode ".a {\r\n  // one\r\n  // t│wo\r\n  x: 1;\r\n}"
                              ".a {\r\n  x: 1;\r\n}")
                  (css2-mode ".a { /* no│te */ color: red; }"
                             ".a {  color: red; }")
                  (css2-mode "/* one\n   t│wo */\n.a {}" ".a {}")))
    (scss2-edit-test--buffer (car case) (cadr case)
      (scss2-kill)
      (should (equal (buffer-string) (nth 2 case)))
      (should-not (treesit-node-check (scss2--root-node) 'has-error)))))

(ert-deftest scss2-edit-comment-duplicates-use-comment-separators ()
  (dolist (case '((scss2-mode "// one\n// t│wo\n.a {}"
                              "// one\n// two\n// one\n// two\n.a {}")
                  (scss2-mode ".a {\n  // o│ne\n  // two\n  x: 1;\n}"
                              ".a {\n  // one\n  // two\n  // one\n  // two\n  x: 1;\n}")
                  (scss2-mode ".a {} // trai│ling\n.b {}"
                              ".a {} // trailing\n// trailing\n.b {}")
                  (scss2-mode "// o│ne" "// one\n// one")
                  (scss2-mode "// one\r\n// t│wo\r\n.a {}"
                              "// one\r\n// two\r\n// one\r\n// two\r\n.a {}")
                  (css2-mode ".a { /* no│te */ x: 1; }"
                             ".a { /* note */ /* note */ x: 1; }")
                  (css2-mode ".a {\n  /* no│te */\n  x: 1;\n}"
                             ".a {\n  /* note */\n  /* note */\n  x: 1;\n}")
                  (css2-mode "/* one\r\n   t│wo */\r\n.a {}"
                             "/* one\r\n   two */\r\n/* one\r\n   two */\r\n.a {}")))
    (scss2-edit-test--buffer (car case) (cadr case)
      (let ((ring (copy-sequence kill-ring)) (pulse-flag nil))
        (scss2-duplicate)
        (should (equal kill-ring ring))
        (should (equal (buffer-string) (nth 2 case)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))))))

(ert-deftest scss2-edit-comment-default-double-toggle-restores-complete-blocks ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (ending '("\n" "\r\n"))
      (dolist (header '(".│a, .b {" "@m│edia screen {" "@m│ixin f() {"))
        (unless (and (eq mode 'css2-mode) (string-prefix-p "@m│ixin" header))
          (scss2-edit-test--buffer mode
              (string-join (list header "" "  .inner { /* retained */ x: 1; }" "\t" "}" ".after {}") ending)
            (let ((original (buffer-string)))
              (scss2-comment-uncomment)
              (should-not (treesit-node-check (scss2--root-node) 'has-error))
              (scss2-comment-uncomment)
              (should (equal (buffer-string) original))
              (should (equal kill-ring '("previous kill")))
              (should-not (treesit-node-check (scss2--root-node) 'has-error)))))))))

(ert-deftest scss2-edit-entity-boundaries-match-comment-at-rule-headers ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '((".outer { .│a { x: 1; } .after {} }" ".a { x: 1; }")
                    (".outer { .a, │ .b { x: 1; } .after {} }"
                     ".a,  .b { x: 1; }")
                    (".outer { .a, :is(.b, .│c) { x: 1; } .after {} }"
                     ".a, :is(.b, .c) { x: 1; }")
                    (".outer { @m│edia screen { .a { x: 1; } } .after {} }"
                     "@media screen { .a { x: 1; } }")
                    (".outer { @media scr│een { .a { x: 1; } } .after {} }"
                     "@media screen { .a { x: 1; } }")))
      (scss2-edit-test--buffer mode (car case)
        (let ((position (point)) (original (buffer-string))
              (transient-mark-mode t) (pulse-flag nil))
          (scss2-copy)
          (should (equal (car kill-ring) (cadr case)))
          (scss2-mark)
          (should (equal (buffer-substring-no-properties (point) (mark)) (cadr case)))
          (goto-char position) (deactivate-mark)
          (scss2-comment-uncomment)
          (should (string-search (concat "/* " (cadr case) " */") (buffer-string)))
          (scss2-comment-uncomment)
          (should (equal (buffer-string) original))
          (goto-char position)
          (scss2-duplicate)
          (should (string-search (concat (cadr case) " " (cadr case)) (buffer-string)))
          (erase-buffer) (insert original) (goto-char position)
          (scss2-kill)
          (should (equal (buffer-string) ".outer {  .after {} }")))))))

(ert-deftest scss2-edit-entity-boundaries-share-configured-types ()
  (let ((scss2-entity-node-types '("rule_set")))
    (dolist (command '(scss2-copy scss2-mark scss2-kill scss2-duplicate scss2-comment-uncomment))
      (scss2-edit-test--buffer 'scss2-mode ".a { x: │1; }"
        (let ((pulse-flag nil)) (funcall command))
        (pcase command
          ('scss2-copy (should (equal (car kill-ring) ".a { x: 1; }")))
          ('scss2-mark (should (equal (buffer-substring-no-properties (point) (mark)) ".a { x: 1; }")))
          ('scss2-kill (should (equal (buffer-string) "")))
          ('scss2-duplicate (should (equal (buffer-string) ".a { x: 1; }\n.a { x: 1; }")))
          ('scss2-comment-uncomment (should (equal (buffer-string) "// .a { x: 1; }")))))))
  ;; Map entries are part of the shared option, not command-specific additions.
  (let ((scss2-entity-node-types '("variable_declaration")))
    (dolist (command '(scss2-copy scss2-mark scss2-kill scss2-duplicate scss2-comment-uncomment))
      (scss2-edit-test--buffer 'scss2-mode "$m: (a: │1);"
        (let ((pulse-flag nil)) (funcall command))
        (pcase command
          ('scss2-copy (should (equal (car kill-ring) "$m: (a: 1);")))
          ('scss2-mark (should (equal (buffer-substring-no-properties (point) (mark)) "$m: (a: 1);")))
          ('scss2-kill (should (equal (buffer-string) "")))
          ('scss2-duplicate (should (equal (buffer-string) "$m: (a: 1);\n$m: (a: 1);")))
          ('scss2-comment-uncomment (should (equal (buffer-string) "// $m: (a: 1);")))))))
  (let ((scss2-entity-node-types nil))
    (dolist (command '(scss2-copy scss2-mark scss2-kill scss2-duplicate scss2-comment-uncomment))
      (scss2-edit-test--buffer 'scss2-mode "$m: (a: │1);"
        (scss2-edit-test--unchanged command)))))

(ert-deftest scss2-edit-entity-boundaries-keep-comments-with-a-prefix ()
  (let ((scss2-entity-node-types nil))
    (dolist (command '(scss2-copy scss2-mark scss2-kill scss2-duplicate scss2-comment-uncomment))
      (scss2-edit-test--buffer 'scss2-mode ".a {\n  // one\n  // t│wo\n  x: 1;\n}"
        (let ((pulse-flag nil)) (let ((current-prefix-arg '(4))) (call-interactively command)))
        (pcase command
          ('scss2-copy (should (equal (car kill-ring) "// one\n  // two")))
          ('scss2-mark (should (equal (buffer-substring-no-properties (point) (mark)) "// one\n  // two")))
          ('scss2-kill (should (equal (buffer-string) ".a {\n  x: 1;\n}")))
          ('scss2-duplicate (should (equal (buffer-string) ".a {\n  // one\n  // two\n  // one\n  // two\n  x: 1;\n}")))
          ('scss2-comment-uncomment (should (equal (buffer-string) ".a {\n  one\n  two\n  x: 1;\n}"))))))))

(ert-deftest scss2-edit-comment-entities-stay-within-accessible-buffer ()
  (dolist (command '(scss2-copy scss2-mark scss2-kill scss2-duplicate scss2-comment-uncomment))
    (scss2-edit-test--buffer 'scss2-mode "// first\n// se│cond\n.a {}"
      (let ((position (point)))
        (forward-line 0) (narrow-to-region (point) (point-max)) (goto-char position))
      (scss2-edit-test--unchanged command)))
  (scss2-edit-test--buffer 'scss2-mode "// first\n// se│cond\n.a {}"
    (let ((position (point)) (font-lock-dont-widen t))
      (forward-line 0) (narrow-to-region (point) (point-max)) (goto-char position)
      (scss2-copy)
      (should (equal (car kill-ring) "// second")))))

(ert-deftest scss2-edit-comment-failed-uncomment-restores-selection ()
  (scss2-edit-test--buffer 'scss2-mode "// first\n// se│cond\n.a {}"
    (save-excursion
      (goto-char (point-min)) (forward-line 1)
      (put-text-property (point) (+ (point) 2) 'read-only t))
    (scss2-edit-test--unchanged #'scss2-comment-uncomment)))

(ert-deftest scss2-edit-comment-command-loop-undo-redo ()
  (dolist (mode '(css2-mode scss2-mode))
    (save-window-excursion
      (scss2-edit-test--buffer mode ".│a {\n  x: 1;\n}\n.after {}"
        (switch-to-buffer (current-buffer))
        (let ((original (buffer-string))
              (last-command nil) (real-last-command nil)
              (this-command nil) (real-this-command nil))
          (buffer-enable-undo) (setq buffer-undo-list nil)
          (use-local-map (make-sparse-keymap))
          (local-set-key (kbd "<f5>") #'scss2-comment-uncomment)
          (local-set-key (kbd "<f6>") #'undo-only)
          (local-set-key (kbd "<f7>") #'undo-redo)
          (execute-kbd-macro (kbd "<f5>"))
          (let ((commented (buffer-string)))
            (execute-kbd-macro (kbd "<f5>"))
            (should (equal (buffer-string) original))
            (execute-kbd-macro (kbd "<f6>"))
            (should (equal (buffer-string) commented))
            (execute-kbd-macro (kbd "<f6>"))
            (should (equal (buffer-string) original))
            (execute-kbd-macro (kbd "<f7> <f7>"))
            (should (equal (buffer-string) original))))))))

(ert-deftest scss2-edit-avy-fixes-full-block-scope-at-invocation ()
  (dolist (case '((".outer { .inner { color: re│d; } .sibling {} }"
                   ".inner { color: red; }")
                  (".outer { font: { size: │12px; } .inner {} }"
                   ".outer { font: { size: 12px; } .inner {} }")
                  (".outer { --raw: { nested: │word }; }"
                   ".outer { --raw: { nested: word }; }")
                  ("@if $x {} @else { x: │2; }" "@if $x {} @else { x: 2; }")
                  ;; Navigation tolerates an unfinished declaration in the block.
                  (".outer { .a { color: red; wi│ } .b {} }" ".a { color: red; wi }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (let ((require-function (symbol-function 'require)) (avy-all-windows 'all-frames)
            (avy-all-windows-alt t) (current-prefix-arg '(4)) (called nil))
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &optional filename noerror)
                     (if (eq feature 'avy) t (funcall require-function feature filename noerror))))
                  ((symbol-function 'avy-goto-word-0)
                   (lambda (arg beg end)
                     (setq called t)
                     (should-not arg) (should-not avy-all-windows)
                     (should-not avy-all-windows-alt) (should-not current-prefix-arg)
                     (should (equal (buffer-substring-no-properties beg end) (nth 1 case))))))
          (scss2-avy-word)
          (should called))
        (should (eq avy-all-windows 'all-frames))
        (should avy-all-windows-alt)
        (should (equal current-prefix-arg '(4)))))))

(provide 'scss2-edit-test)
;;; scss2-edit-test.el ends here
