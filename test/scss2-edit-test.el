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
                    (".a { display:\n    │ block; }" . nil)
                    (".a { --x│: 1px 2px; }" . "1px 2px; }")
                    (".a { co│lor: /* c */ red !important; }" . "red !important")
                    (".a { co│lor: red }" . "red }")
                    (".a { fo│nt: bold { family: serif; } }" . "bold {")))
      (scss2-edit-test--buffer mode (car case)
        (let ((text (buffer-string)) (position (point)) (ring (copy-sequence kill-ring)))
          (let ((indent-line-function (lambda () (ert-fail "Unexpected indentation"))))
            (scss2-tab))
          (if (cdr case)
              (should (looking-at-p (cdr case)))
            ;; Point already in the value moves past the semicolon instead.
            (should (/= (point) position)))
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
        (scss2-kill t)
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
      (scss2-edit-test--unchanged (lambda () (scss2-kill t))))))

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
          (scss2-kill t)
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
        (scss2-edit-test--unchanged (lambda () (scss2-kill t)))))))

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
        (scss2-kill t)
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
        "/* before */ @media (width > 10px) {\n.a { color: r│ed; }\n/* inner */\n} /* after */"
      (scss2-kill t)
      (should (equal (buffer-string)
                     "/* before */ @media (width > 10px) {\n/* inner */\n} /* after */"))
      (should (equal (car kill-ring) ".a { color: red; }\n")))
    (scss2-edit-test--buffer mode ".a {\n  │color: red;\n  /* trailing */\n} /* outside */"
      (scss2-empty t)
      (should (equal (buffer-string) ".a {} /* outside */"))))
  (scss2-edit-test--buffer 'css2-mode "@m│edia (width > 10px) { .a { x: 1; } }"
    (scss2-kill t)
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-selector-is-a-complete-top-level-branch ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".a > .b, .c:is(.d, .│e), .f { color: red; }"
      (scss2-kill)
      (should (equal (buffer-string) ".a > .b, .f { color: red; }")))
    (scss2-edit-test--buffer mode ".a, :nth-child(2n of .b, .│c), .d { color: red; }"
      (scss2-kill)
      (should (equal (buffer-string) ".a, .d { color: red; }")))
    (scss2-edit-test--buffer mode ".a > .│b { color: red; }"
      (scss2-edit-test--unchanged #'scss2-kill))))

(ert-deftest scss2-edit-selector-separators-do-not-eat-comments ()
  (scss2-edit-test--buffer 'css2-mode ".│a /* retained */, .b { x: 1; }"
    (scss2-kill)
    (should (equal (buffer-string) " /* retained */ .b { x: 1; }")))
  (scss2-edit-test--buffer 'css2-mode ".a, /* retained */ .│b { x: 1; }"
    (scss2-kill)
    (should (equal (buffer-string) ".a /* retained */  { x: 1; }"))))

(ert-deftest scss2-edit-conditionals-never-orphan-else ()
  (scss2-edit-test--buffer 'scss2-mode
      "@│if $x { x: 1; } @else if $y { x: 2; } @else { x: 3; }"
    (scss2-kill)
    (should (equal (buffer-string) "")))
  (scss2-edit-test--buffer 'scss2-mode "@if $x { x: 1; } @│else { x: 2; }"
    (scss2-kill)
    (should (equal (buffer-string) "")))
  (scss2-edit-test--buffer 'scss2-mode "@if $x { x: 1; } @else { x: │2; }"
    (scss2-kill t)
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-duplicate-preserves-inner-text-and-final-semicolon ()
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: red }"
    (scss2-duplicate)
    (should (equal (buffer-string) ".a { color: red; color: red }"))
    (should (equal kill-ring '("previous kill"))))
  (scss2-edit-test--buffer 'css2-mode ".a, .│b { x: 1; }"
    (scss2-duplicate)
    (should (equal (buffer-string) ".a, .b, .b { x: 1; }")))
  ;; A trailing comment does not make an entity share its line.
  (dolist (comment '("// note" "/* note */"))
    (scss2-edit-test--buffer 'scss2-mode (concat ".a {\n  co│lor: red; " comment "\n  x: 1;\n}")
      (scss2-duplicate)
      (should (equal (buffer-string)
                     (concat ".a {\n  color: red;\n  color: red; " comment "\n  x: 1;\n}")))))
  ;; Branches keep their list's layout.
  (dolist (case '((".a,\n.│b { x: 1; }" ".a,\n.b,\n.b { x: 1; }")
                  ("  .│a,\n  .b { x: 1; }" "  .a,\n  .a,\n  .b { x: 1; }")
                  (".│a,.b { x: 1; }" ".a,.a,.b { x: 1; }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-duplicate)
      (should (equal (buffer-string) (cadr case)))))
  (scss2-edit-test--buffer 'scss2-mode
      "@m│ixin paint() {\n  --raw: { literal: \"  value  \"; };\n}"
    (let ((source (buffer-string)))
      (scss2-duplicate)
      (should (equal (buffer-string) (concat source "\n" source))))))

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
          (scss2-kill t)
          (should (equal (buffer-string) ".a {  color: red; } .after {}"))
          (should (= (point) 6))
          (should (equal (car kill-ring) property)))))))

(ert-deftest scss2-edit-flat-nested-property-empty-undo-and-duplicate ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode
        ".a { font: bold { /* lead */ │size: 12px; /* trail */ } color: red; }"
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((source (buffer-string)))
        (undo-boundary)
        (scss2-empty t)
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

(ert-deftest scss2-edit-flat-pseudo-arguments-keep-outer-selector-branches ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (branch '(".a:is(.b, :not(.c, .│d))"
                      ".a:is([data-x=\",\"], /* , */ :has(> .│d))"
                      ".a:nth-child(2n of :is(.b, .│c), .d)"))
      (scss2-edit-test--buffer mode (concat branch ", .after { color: red; }")
        (scss2-kill)
        (should (equal (buffer-string) ".after { color: red; }"))
        (should (= (point) (point-min)))
        (should (equal (car kill-ring)
                       (concat (replace-regexp-in-string "│" "" branch) ", ")))))
    (scss2-edit-test--buffer mode ".a:is(:lang(\"│en,US\"), .b) { color: red; }"
      (scss2-edit-test--unchanged #'scss2-kill))))

(ert-deftest scss2-edit-narrowing-and-nonvalue-strings-reject-safely ()
  (scss2-edit-test--buffer 'css2-mode ".a { color: r│ed; }"
    (let ((position (point)))
      (narrow-to-region (point) (point-max))
      (goto-char position)
      (scss2-edit-test--unchanged #'scss2-kill)))
  (scss2-edit-test--buffer 'css2-mode ".a:lang(\"│en\") { color: red; }"
    (scss2-edit-test--unchanged #'scss2-kill))
  (scss2-edit-test--buffer 'scss2-mode "@use \"│theme\";"
    (scss2-edit-test--unchanged #'scss2-kill)))

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

(ert-deftest scss2-edit-entity-commands-preserve-parse-integrity ()
  ;; Whole-target commands never turn a valid stylesheet into an invalid one.
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
            (when (condition-case nil (progn (funcall command) t) (user-error nil))
              (ert-info ((format "%s at %d gave %S" command (1+ offset) (buffer-string)))
                (should-not (treesit-node-check (scss2--root-node) 'has-error))))))))))

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
    (should (equal (car kill-ring) "$theme: (a: 1, b: (x: 2)) !default;"))
    (scss2-kill)
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-unsupported-leaves-and-blank-space-never-select-parent ()
  (dolist (source '(".a { @include fo│o(1, 2); }"
                    ".a { @debug │1; }" ".a { @extend .ba│se; }"
                    ".a { thi│ng(a:b); }" ".a {\n│  color: red;\n}"
                    ".a { color: red; │ }" ".a, │ .b { x: 1; }"
                    ".a { /* no│te */ color: red; }"))
    (dolist (command '(scss2-kill scss2-copy scss2-mark scss2-duplicate))
      (scss2-edit-test--buffer 'scss2-mode source
        (scss2-edit-test--unchanged command))))
  (scss2-edit-test--buffer 'scss2-mode ".a { @include fo│o(1, 2); }"
    (scss2-kill t)
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-kill-between-blank-lines-keeps-one ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  color: red;\n\n  mar│gin: 0;\n\n  padding: 0;\n}"
    (scss2-kill)
    (should (equal (scss2-edit-test--with-point) ".a {\n  color: red;\n\n  │padding: 0;\n}"))
    (should (equal (car kill-ring) "  margin: 0;\n")))
  (dolist (ending '("\n" "\r\n"))
    (scss2-edit-test--buffer 'scss2-mode
        (string-join '(".a {}" "" ".b { x: 1│; }" "" ".c {}") ending)
      (scss2-kill t)
      (should (equal (buffer-string) (string-join '(".a {}" "" ".c {}") ending)))
      (should (looking-at-p "\\.c")))))

(ert-deftest scss2-edit-empty-header-content-despite-body-errors ()
  (dolist (case '(("[data-x=\"f│oo\"] { color: red; width }" "[data-x=\"│\"] { color: red; width }")
                  ("@if $a == \"f│oo\" { width }" "@if $a == \"│\" { width }")
                  (".a-#{$b│} { width }" ".a-#{│} { width }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (cadr case)))))
  ;; A recovered header itself remains unreliable.
  (scss2-edit-test--buffer 'scss2-mode "[data-x=\"f│oo\" { color: red; }"
    (scss2-edit-test--unchanged #'scss2-empty)))

(ert-deftest scss2-edit-prefixed-mark-after-mark-selects-the-block ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  co│lor: red;\n}"
    (let ((transient-mark-mode t))
      (scss2-mark)
      (let ((last-command 'scss2-mark))
        (scss2-mark t))
      (should (equal (buffer-substring-no-properties (point) (mark))
                     ".a {\n  color: red;\n}")))))

(ert-deftest scss2-edit-blank-line-inside-a-value-touches-nothing ()
  (dolist (source '("$map: (\n  a: 1,\n│\n  b: 2,\n);"
                    "@each $k, $v in (\n  a: 1,\n│\n  b: 2,\n) { x: $v; }"))
    (dolist (command '(scss2-kill scss2-copy scss2-duplicate))
      (scss2-edit-test--buffer 'scss2-mode source
        (scss2-edit-test--unchanged command)))))

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

(ert-deftest scss2-edit-block-prefix-shares-one-entity ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".outer { .a { color: re│d; } } .after {}"
      (let ((position (point)))
        (scss2-copy t)
        (should (= (point) position))
        (should (equal (car kill-ring) ".a { color: red; }")))
      (scss2-mark t)
      (should (equal (buffer-substring-no-properties (point) (mark)) ".a { color: red; }"))
      (scss2-kill t)
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

(ert-deftest scss2-edit-empty-stops-at-unsupported-statements ()
  (dolist (source '(".a { @ext│end .b; x: 1; }" ".a { @include m│x; x: 1; }"
                    ".a { @include m│x($a); x: 1; }" "@use \"x\" a│s m;"
                    ".a { x: 1; /* no│te */ y: 2; }" ".a { x: 1; // no│te\n  y: 2;\n}"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-edit-test--unchanged #'scss2-empty)
      (should (equal (cadr (should-error (scss2-empty) :type 'user-error))
                     "Nothing to empty here")))))

(ert-deftest scss2-edit-empty-clears-value-statement-values ()
  (dolist (case '(("@function f() { @return $fo│o + 1; }" "@function f() { @return │; }" "$foo + 1")
                  ("@function f() { @re│turn $foo; }" "@function f() { @return │; }" "$foo")
                  ("@function f() { @return /* c */ $fo│o }" "@function f() { @return │ }" "/* c */ $foo")
                  ("@deb│ug $x;" "@debug │;" "$x")
                  ("@warn \"x\" + $fo│o;" "@warn │;" "\"x\" + $foo")
                  ("@error \"e #{$a}\" fo│o;" "@error │;" "\"e #{$a}\" foo")
                  ;; Nested interiors remain closer targets.
                  ("@function f() { @return \"a│b\"; }" "@function f() { @return \"│\"; }" "ab")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (scss2-edit-test--with-point) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case))))))

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
                  ("$m: │(a: 1);" "$m: (│);" "a: 1")
                  ;; Keyword arguments and module configuration are not maps.
                  (".a { @include m($x│: 1); }" ".a { @include m(│); }" "$x: 1")
                  ("@use \"x\" with ($a│: 1);" "@use \"x\" with (│);" "$a: 1")))
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

(ert-deftest scss2-edit-empty-if-condition-and-branch-body ()
  (dolist (case '(("@if $a │and $b { x: 1; } @else { x: 2; }"
                   "@if  { x: 1; } @else { x: 2; }" "$a and $b")
                  ("@if $a {} @else if $b == │2 { x: 1; }"
                   "@if $a {} @else if  { x: 1; }" "$b == 2")
                  ("@if $a { x: 1; } @else │{ x: 2; }"
                   "@if $a { x: 1; } @else {}" " x: 2; ")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (buffer-string) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case)))))
  (scss2-edit-test--buffer 'scss2-mode "@if $a { x: 1; } @else if $b │{ x: 2; }"
    (scss2-empty t)
    (should (equal (buffer-string) "@if $a { x: 1; } @else if $b {}"))))

(ert-deftest scss2-edit-conditional-copy-and-duplicate-keep-the-chain ()
  (scss2-edit-test--buffer 'scss2-mode "@if $x {} @│else if $y {} @else {}"
    (let ((source (buffer-string)))
      (scss2-copy)
      (should (equal (car kill-ring) source))
      (scss2-duplicate)
      (should (equal (buffer-string) (concat source "\n" source))))))

(ert-deftest scss2-edit-selector-comments-roundtrip-with-their-comma ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".│a, .b { color: red; }"
                      ".a, .│b { color: red; }"
                      ".│a /* retained */, .b { color: red; }"
                      ".a, /* retained */ .│b { color: red; }"
                      ".a, :is(.b, .│c), .d { color: red; }"))
      (scss2-edit-test--buffer mode source
        (let ((original (buffer-string)) (ring (copy-sequence kill-ring)))
          (scss2-comment-uncomment)
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (goto-char (point-min)) (search-forward "/*")
          (scss2-comment-uncomment)
          (should (equal (buffer-string) original))
          (should (equal kill-ring ring)))))
    (scss2-edit-test--buffer mode ".│a { color: red; }"
      (scss2-edit-test--unchanged #'scss2-comment-uncomment)
      (scss2-comment-uncomment t)
      (goto-char (point-min)) (re-search-forward "/[/*]")
      (scss2-comment-uncomment)
      (should (equal (buffer-string) ".a { color: red; }")))))

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
          (scss2-comment-uncomment)
          (should (equal (buffer-string) original))))))
  (scss2-edit-test--buffer 'scss2-mode "// first\n\n// se│cond\n.a {}"
    (scss2-comment-uncomment)
    (should (equal (buffer-string) "// first\n\nsecond\n.a {}"))))

(ert-deftest scss2-edit-comment-prefix-keeps-conditional-and-nested-body ()
  (scss2-edit-test--buffer 'scss2-mode
      "@if $x {\n  x: 1;\n} @else {\n  x: │2;\n}\n.after {}"
    (let ((original (buffer-string)))
      (scss2-comment-uncomment t)
      (goto-char (point-min)) (search-forward "//")
      (scss2-comment-uncomment)
      (should (equal (buffer-string) original)))))

(ert-deftest scss2-edit-comment-and-selector-ranges-stay-accessible ()
  (dolist (source '(".│a /* retained */, .b {}" ".a, /* retained */ .│b {}"))
    (scss2-edit-test--buffer 'css2-mode source
      (let* ((target (scss2--resolve-target)) (position (point)))
        (narrow-to-region (scss2--target-beg target) (scss2--target-end target))
        (goto-char position))
      (dolist (command '(scss2-kill scss2-comment-uncomment))
        (scss2-edit-test--unchanged command))))
  (scss2-edit-test--buffer 'scss2-mode "// first\n// se│cond\n.a {}"
    (let ((position (point)))
      (forward-line 0) (narrow-to-region (point) (point-max)) (goto-char position))
    (scss2-edit-test--unchanged #'scss2-comment-uncomment)))

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

(ert-deftest scss2-edit-avy-fixes-full-block-scope-at-invocation ()
  (dolist (case '((".outer { .inner { color: re│d; } .sibling {} }"
                   ".inner { color: red; }")
                  (".outer { font: { size: │12px; } .inner {} }"
                   ".outer { font: { size: 12px; } .inner {} }")
                  (".outer { --raw: { nested: │word }; }"
                   ".outer { --raw: { nested: word }; }")
                  ("@if $x {} @else { x: │2; }" "@if $x {} @else { x: 2; }")))
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
          (scss2-comment-uncomment)
          (undo-boundary)
          (should (equal (buffer-string) original))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (should (equal kill-ring '("previous kill")))
          (undo-only 1)
          (should (string-prefix-p "// @mixin" (buffer-string)))
          (let ((last-command 'undo)) (undo-only 1))
          (should (equal (buffer-string) original)))))))

(ert-deftest scss2-edit-multiline-line-comment-aligns-its-markers ()
  (scss2-edit-test--buffer 'scss2-mode ".a {\n  .inner {\n    x: 1│;\n  }\n  color: red;\n}"
    (scss2-comment-uncomment t)
    (should (equal (buffer-string)
                   ".a {\n//   .inner {\n//     x: 1;\n//   }\n  color: red;\n}"))
    (search-forward "color")
    (scss2-comment-uncomment)
    (should (string-search "\n  // color: red;\n" (buffer-string)))))

(ert-deftest scss2-edit-comment-indented-block-preserves-blank-line-whitespace ()
  (dolist (ending '("\n" "\r\n"))
    (scss2-edit-test--buffer 'scss2-mode
        (string-join '(".outer {" "  .inner │{" "" "    color: red;" "\t" "  }  " "}") ending)
      (let ((original (buffer-string)))
        (scss2-comment-uncomment t)
        (goto-char (point-min)) (search-forward "//")
        (scss2-comment-uncomment)
        (should (equal (buffer-string) original))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))))))

(provide 'scss2-edit-test)
;;; scss2-edit-test.el ends here
