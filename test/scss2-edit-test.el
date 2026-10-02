;;; scss2-edit-test.el --- Structural editor behavior -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'scss2-edit)
(require 'scss2-test-support)

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

(ert-deftest scss2-edit-killing-a-comment-keeps-adjacent-values-separate ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (command '(scss2-kill scss2-kill-value-item))
      (scss2-edit-test--buffer mode ".a { margin: 1px/*│*/2px; }"
        (buffer-enable-undo)
        (setq buffer-undo-list nil)
        (let ((original (buffer-string)))
          (funcall command)
          (undo-boundary)
          (should (equal (buffer-string) ".a { margin: 1px 2px; }"))
          (should (equal (car kill-ring) "/**/"))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (undo-only 1)
          (should (equal (buffer-string) original)))))))

(ert-deftest scss2-edit-comment-removal-does-not-add-selector-whitespace ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".a/*│*/.b { color: red; }"
      (scss2-kill)
      (should (equal (buffer-string) ".a.b { color: red; }")))))

(ert-deftest scss2-edit-keeps-the-required-first-css-var-argument ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (name '("var" "VAR" "v\\61r"))
      (dolist (command '(scss2-kill scss2-kill-value-item))
        (scss2-edit-test--buffer mode (format ".a { color: %s(--│x, red); }" name)
          (scss2-edit-test--unchanged command)))))
  (scss2-edit-test--buffer 'css2-mode ".a { color: var(--│x, {a:b}); }"
    (scss2-edit-test--unchanged #'scss2-kill-value-item))
  (scss2-edit-test--buffer 'scss2-mode ".a { color: theme.var($│x, red); }"
    (scss2-kill-value-item)
    (should (equal (buffer-string) ".a { color: theme.var(red); }"))))

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
    (dolist (source '(".a│ {}" ".a { dis│play: block; }"
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

(ert-deftest scss2-edit-selection-separates-owner-from-subject ()
  ;; A named argument owns its value, while the argument list validates the
  ;; selected item and supplies separators.  A compound argument is one subject
  ;; whose entire content is cleared, including any nested calls.
  (dolist (case '((".a { x: fn($tone: r│ed, blue); }" "named_argument" "red"
                   ".a { x: fn($tone: , blue); }")
                  (".a { x: fn(red + │blue, green); }" "argument" "red + blue"
                   ".a { x: fn(, green); }")
                  (".a { x: fn(foo(1) + b│ar(2), green); }" "argument" "foo(1) + bar(2)"
                   ".a { x: fn(, green); }")))
    (scss2-edit-test--buffer 'scss2-mode (nth 0 case)
      (let* ((target (scss2--resolve-target))
             (owner (scss2--target-owner target))
             (subject (scss2--target-subject target))
             (bounds (scss2--content-bounds target)))
        (should (equal (treesit-node-type owner) "arguments"))
        (should (equal (and subject (treesit-node-type subject)) (nth 1 case)))
        (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds)) (nth 2 case))))
      (scss2-empty)
      (should (equal (buffer-string) (nth 3 case)))
      (should (equal (car kill-ring) (nth 2 case))))))

(ert-deftest scss2-edit-scss-crlf-escape-keeps-independent-value-items ()
  (scss2-edit-test--buffer 'scss2-mode ".a { x: foo\\61\r\nb│ar; color: red; }"
    (scss2-kill-value-item)
    (should (equal (buffer-string) ".a { x: foo\\61\r\n; color: red; }"))
    (should (equal (car kill-ring) "bar"))))

(ert-deftest scss2-edit-css-crlf-escape-keeps-one-value-item ()
  (scss2-edit-test--buffer 'css2-mode ".a { x: foo\\61\r\nb│ar; color: red; }"
    (scss2-kill-value-item)
    (should (equal (buffer-string) ".a { x: ; color: red; }"))
    (should (equal (car kill-ring) "foo\\61\r\nbar"))))

(ert-deftest scss2-edit-parser-recovery-keeps-following-block-editable ()
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
        (scss2-kill-block)
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
      (scss2-edit-test--unchanged #'scss2-kill-block))))

(ert-deftest scss2-edit-unpaired-comment-interpolation-keeps-following-rule-independent ()
  (dolist (content '("https://example.test" "fix // later" "a /* b"))
    (let ((prefix (concat ".a {\n /* see #{ " content " */\n color: red;\n}\n")))
      (scss2-edit-test--buffer 'scss2-mode (concat prefix ".af│ter { /* tail */ }")
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (scss2-kill-block)
        (should (equal (buffer-string) prefix))
        (should (equal (car kill-ring) ".after { /* tail */ }"))))))

(ert-deftest scss2-edit-recovered-block-header-does-not-establish-targets ()
  (dolist (command '(scss2-kill-value-item scss2-kill-property
                     scss2-empty scss2-empty-value))
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
      (scss2-kill-property)
      (undo-boundary)
      (should (equal (buffer-string) ".a { color: var(--x, {a:b;c:d});  }"))
      (should (equal (car kill-ring) "width: 1px;"))
      (undo 1)
      (should (equal (buffer-string) original)))))

(ert-deftest scss2-edit-unknown-statements-keep-their-block-owner ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode "@future { thing(a:│b); .a {} } .after {}"
      (scss2-kill)
      (should (equal (buffer-string) "@future {  .a {} } .after {}"))
      (should (equal (car kill-ring) "thing(a:b);")))
    (dolist (source '("@future { thi│ng(a:b; .a {} } .after {}"
                      "@future { thi│ng(a:b);"
                      "@future { thi│ng(a:b) }"))
      (scss2-edit-test--buffer mode source
        (scss2-edit-test--unchanged #'scss2-kill-block)))))

(ert-deftest scss2-edit-property-and-complete-value-both-dialects ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode
        ".a { /* before */ color: r│ed !important; /* after */ x: 1; }"
      (scss2-kill-property)
      (should (equal (buffer-string) ".a { /* before */  /* after */ x: 1; }"))
      (should (equal (car kill-ring) "color: red !important;")))
    (scss2-edit-test--buffer mode ".a { content: \"a │b\" !important; }"
      (scss2-empty-value)
      (should (equal (buffer-string) ".a { content: ; }"))
      (should (equal (car kill-ring) "\"a b\" !important")))
    (scss2-edit-test--buffer mode ".a { content: \"│literal\"; }"
      (scss2-empty-value)
      (should (equal (buffer-string) ".a { content: ; }"))
      (should (equal (car kill-ring) "\"literal\"")))))

(ert-deftest scss2-edit-block-keeps-external-comments-and-empties-body ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode
        "/* before */ @media (width > 10px) {\n.a { color: r│ed; }\n/* inner */\n} /* after */"
      (scss2-kill-block)
      (should (equal (buffer-string)
                     "/* before */ @media (width > 10px) {\n/* inner */\n} /* after */"))
      (should (equal (car kill-ring) ".a { color: red; }\n")))
    (scss2-edit-test--buffer mode ".a {\n  │color: red;\n  /* trailing */\n} /* outside */"
      (scss2-empty-block)
      (should (equal (buffer-string) ".a {} /* outside */"))))
  (scss2-edit-test--buffer 'css2-mode "@m│edia (width > 10px) { .a { x: 1; } }"
    (scss2-kill-block)
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-selector-is-a-complete-top-level-branch ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".a > .b, .c:is(.d, .│e), .f { color: red; }"
      (scss2-kill-selector)
      (should (equal (buffer-string) ".a > .b, .f { color: red; }")))
    (scss2-edit-test--buffer mode ".a, :nth-child(2n of .b, .│c), .d { color: red; }"
      (scss2-kill-selector)
      (should (equal (buffer-string) ".a, .d { color: red; }")))
    (scss2-edit-test--buffer mode ".a > .│b { color: red; }"
      (scss2-edit-test--unchanged #'scss2-kill-selector))))

(ert-deftest scss2-edit-selector-separators-do-not-eat-comments ()
  (scss2-edit-test--buffer 'css2-mode ".│a /* retained */, .b { x: 1; }"
    (scss2-kill-selector)
    (should (equal (buffer-string) " /* retained */ .b { x: 1; }")))
  (scss2-edit-test--buffer 'css2-mode ".a, /* retained */ .│b { x: 1; }"
    (scss2-kill-selector)
    (should (equal (buffer-string) ".a /* retained */  { x: 1; }"))))

(ert-deftest scss2-edit-comments-stay-independent-in-sequences ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '((".a { color: red /* co│mment */; width: 1px; }"
                     ".a { color: red ; width: 1px; }")
                    (".a { color: /* co│mment */ red; }" ".a { color:  red; }")
                    (".a { margin: 1px /* co│mment */ 2px; }" ".a { margin: 1px  2px; }")
                    (".a { x: foo(red, /* co│mment */ blue); }" ".a { x: foo(red,  blue); }")
                    (".a { x: foo(red /* co│mment */, blue); }" ".a { x: foo(red , blue); }")))
      (scss2-edit-test--buffer mode (car case)
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (let ((position (point)))
          (scss2-copy)
          (should (= (point) position))
          (should (equal (car kill-ring) "/* comment */")))
        (scss2-mark)
        (should (equal (buffer-substring-no-properties (point) (mark)) "/* comment */"))
        (let ((begin (point)))
          (scss2-kill)
          (should (= (point) begin)))
        (should (equal (buffer-string) (cadr case)))
        (should (equal (car kill-ring) "/* comment */")))))
  (dolist (case '(("@include paint(/* co│mment */ red, blue);" "@include paint( red, blue);" "/* comment */")
                  ("@mixin paint($x, /* co│mment */ $y) {}" "@mixin paint($x,  $y) {}" "/* comment */")
                  ("$map: (a: 1, /* co│mment */ b: 2);" "$map: (a: 1,  b: 2);" "/* comment */")
                  (".a { margin: 1px // co│mment\n2px; }" ".a { margin: 1px \n2px; }" "// comment")
                  ("@use \"theme\" with ($x: 1, /* co│mment */ $y: 2);"
                   "@use \"theme\" with ($x: 1,  $y: 2);" "/* comment */")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (scss2-kill)
      (should (equal (buffer-string) (cadr case)))
      (should (equal (car kill-ring) (nth 2 case))))))

(ert-deftest scss2-edit-comment-content-retains-shell-and-state ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case (append
                   '((".a { /* he│llo */ color: red; }" " hello "
                      ".a { /**/ color: red; }"
                      ".a { /*  replacement  */ color: red; }"
                      ".a { /* he*/ color: red; }")
                     (".a { color: red /* he│llo */; }" " hello "
                      ".a { color: red /**/; }"
                      ".a { color: red /*  replacement  */; }"
                      ".a { color: red /* he*/; }"))
                   (when (eq mode 'scss2-mode)
                     '((".a { // he│llo\ncolor: red; }" " hello"
                        ".a { //\ncolor: red; }"
                        ".a { //  replacement  \ncolor: red; }"
                        ".a { // he\ncolor: red; }")))))
      (cl-loop for command in '(scss2-empty scss2-substitute scss2-zap)
               for expected in (cddr case)
               do
               (scss2-edit-test--buffer mode (car case)
                 (buffer-enable-undo)
                 (setq buffer-undo-list nil)
                 (let ((source (buffer-string)) (position (point))
                       (content-begin (save-excursion
                                        (re-search-backward "/[/*]") (+ (point) 2))))
                   (setq kill-ring '("  replacement  ") kill-ring-yank-pointer kill-ring)
                   (undo-boundary)
                   (call-interactively command)
                   (undo-boundary)
                   (should (equal (buffer-string) expected))
                   (should-not (treesit-node-check (scss2--root-node) 'has-error))
                   (should (= (point) (pcase command
                                        ('scss2-zap position)
                                        ('scss2-substitute (+ content-begin (length "  replacement  ")))
                                        (_ content-begin))))
                   (should (equal (car kill-ring)
                                  (if (eq command 'scss2-zap) "  replacement  " (cadr case))))
                   (undo 1)
                   (should (equal (buffer-string) source))))))))

(ert-deftest scss2-edit-comment-delimiters-and-incomplete-content-reject-safely ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".a { /│* hello */ color: red; }"
                      ".a { /* hello *│/ color: red; }"
                      ".a { /* hello */│ color: red; }"))
      (scss2-edit-test--buffer mode source
        (scss2-edit-test--unchanged #'scss2-zap)))
    (scss2-edit-test--buffer mode ".a { /* he│llo"
      (scss2-edit-test--unchanged #'scss2-empty)
      (scss2-edit-test--unchanged #'scss2-zap))))

(ert-deftest scss2-edit-values-respect-spaces-commas-and-nested-literals ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".a { margin: 1px │2px 3px; }"
      (scss2-kill-value-item)
      (should (equal (buffer-string) ".a { margin: 1px 3px; }")))
    (scss2-edit-test--buffer mode
        ".a { font-family: system-ui, \"Family, │With Comma\", serif; }"
      (scss2-kill-value-item)
      (should (equal (buffer-string) ".a { font-family: system-ui, serif; }")))
    (scss2-edit-test--buffer mode ".a { --raw: literal, │a,b; }"
      (scss2-kill-value-item)
      (should (equal (buffer-string) ".a { --raw: ; }")))
    (scss2-edit-test--buffer mode ".a { x: calc(10px │+ 2px); }"
      (scss2-kill-value-item)
      (should (equal (buffer-string) ".a { x: calc(); }")))))

(ert-deftest scss2-edit-last-space-item-takes-its-leading-separator ()
  ;; Only same-line blanks separate items; comments and indentation remain.
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '((".a { margin: 1px 2px │3px; }" ".a { margin: 1px 2px; }" " 3px")
                    (".a { margin: 1px /* c */ │2px; }" ".a { margin: 1px /* c */; }" " 2px")
                    (".a {\n  margin: 1px\n    │2px;\n}" ".a {\n  margin: 1px\n    ;\n}" "2px")
                    (".a { margin: │0 ; }" ".a { margin: ; }" "0 ")))
      (scss2-edit-test--buffer mode (car case)
        (scss2-kill-value-item)
        (should (equal (buffer-string) (nth 1 case)))
        (should (equal (car kill-ring) (nth 2 case))))))
  (dolist (case '(("$list: (1px 2px │3px);" "$list: (1px 2px);" " 3px")
                  (".a { margin: 1px // c\n  │2px; }" ".a { margin: 1px // c\n  ; }" "2px")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-kill-value-item)
      (should (equal (buffer-string) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case))))))

(ert-deftest scss2-edit-scss-arguments-parameters-and-map-entries ()
  (dolist (case '(("@include paint(red, $tone: │blue, 2px);" "@include paint(red, 2px);")
                  ("@mixin paint($x, $y: │2, $rest...) { x: 1; }" "@mixin paint($x, $rest...) { x: 1; }")
                  ("$map: (a: 1, b: │2, c: 3);" "$map: (a: 1, c: 3);")
                  ("@include paint($x │+ $y, blue);" "@include paint(blue);")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-kill-value-item)
      (should (equal (buffer-string) (cadr case)))))
  (scss2-edit-test--buffer 'scss2-mode "$value: $a │+ $b;"
    (scss2-edit-test--unchanged #'scss2-kill-value-item)))

(ert-deftest scss2-edit-query-headers-remain-complete-statements ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '("@supports ((display: grid) a│nd (color: red)) { .a { color: red; } }"
                      "@supports (width: calc(1│0px + 1px)) { .a { color: red; } }"
                      "@supports selector(.a, .│b) { .a { color: red; } }"
                      "@media scr│een, print { .a { color: red; } }"
                      "@supports /* co│mment */ (display: grid) { .a {} }"
                      "@import \"the│me.css\" screen;"))
      (scss2-edit-test--buffer mode source
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (scss2-edit-test--unchanged #'scss2-kill-value-item)
        (scss2-kill)
        (should (equal (buffer-string) "")))
      (scss2-edit-test--buffer mode source
        (let ((original (buffer-string)))
          (scss2-duplicate)
          (should (equal (buffer-string) (concat original "\n" original))))))
    (scss2-edit-test--buffer mode
        "@media screen { /* out│side */ .a { color: red; } }"
      (scss2-kill)
      (should (equal (buffer-string) "@media screen {  .a { color: red; } }")))
    (scss2-edit-test--buffer mode
        "@media screen { .a { color: r│ed; } }"
      (scss2-kill-value-item)
      (should (equal (buffer-string) "@media screen { .a { color: ; } }")))))

(ert-deftest scss2-edit-outer-literals-own-nested-values-and-undo ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".a { --raw: before \"in│ner\" after; color: red; }"
                      ".a { --raw: before /* co│mment */ after; color: red; }"
                      ".a { --raw: before { [\"in│ner\"] } after; color: red; }"
                      ".a { --raw: before #{foo(\"in│ner\")} after; color: red; }"))
      (scss2-edit-test--buffer mode source
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (buffer-enable-undo)
        (setq buffer-undo-list nil)
        (let ((original (buffer-string)))
          (undo-boundary)
          (call-interactively #'scss2-kill-value-item)
          (undo-boundary)
          (should (equal (buffer-string) ".a { --raw: ; color: red; }"))
          (undo 1)
          (should (equal (buffer-string) original)))))
    (scss2-edit-test--buffer mode
        ".a { background: url(\"in│ner.png\"); color: red; }"
      (scss2-kill-value-item)
      (should (equal (buffer-string) ".a { background: ; color: red; }"))))
  (scss2-edit-test--buffer 'scss2-mode
      ".a { content: \"before #{foo(\"in│ner\")} after\"; color: red; }"
    (scss2-kill-value-item)
    (should (equal (buffer-string) ".a { content: ; color: red; }")))
  (scss2-edit-test--buffer 'scss2-mode
      ".a { content: \"before #{foo(\"in│ner\")} after\"; color: red; }"
    (scss2-empty)
    (should (equal (buffer-string) ".a { content: \"\"; color: red; }")))
  (scss2-edit-test--buffer 'scss2-mode
      ".a { /* before #{foo(\"in│ner\")} after */ color: red; }"
    (scss2-kill)
    (should (equal (buffer-string) ".a {  color: red; }"))))

(ert-deftest scss2-edit-unknown-at-rules-and-known-statements ()
  (dolist (source '("@│unknown token(a,b) { .a { x: 1; } }"
                    "@│layer components;" "@│include paint(red);"
                    "@│use \"theme\";" "@│return $x + 1;"
                    "@│each $x in red, blue { .a { color: $x; } }"
                    "@│function twice($x) { @return $x * 2; }"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-kill)
      (should (equal (buffer-string) "")))))

(ert-deftest scss2-edit-conditionals-never-orphan-else ()
  (scss2-edit-test--buffer 'scss2-mode
      "@│if $x { x: 1; } @else if $y { x: 2; } @else { x: 3; }"
    (scss2-kill)
    (should (equal (buffer-string) "")))
  (scss2-edit-test--buffer 'scss2-mode "@if $x { x: 1; } @│else { x: 2; }"
    (scss2-kill)
    (should (equal (buffer-string) "@if $x { x: 1; } ")))
  (scss2-edit-test--buffer 'scss2-mode "@if $x { x: 1; } @else { x: │2; }"
    (scss2-kill-block)
    (should (equal (buffer-string) ""))))

(ert-deftest scss2-edit-empty-and-substitute-retain-literal-delimiters ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".a { content: \"a │b\"; }"
      (scss2-empty)
      (should (equal (buffer-string) ".a { content: \"\"; }"))
      (should (equal (car kill-ring) "a b")))
    (scss2-edit-test--buffer mode ".a { content: \"a │b\"; }"
      (setq kill-ring '("  replacement  ") kill-ring-yank-pointer kill-ring)
      (scss2-substitute)
      (should (equal (buffer-string) ".a { content: \"  replacement  \"; }"))
      (should (equal (car kill-ring) "a b")))))

(ert-deftest scss2-edit-copy-mark-zap-have-independent-state-contracts ()
  (scss2-edit-test--buffer 'css2-mode ".a { content: \"ab│cd\"; }"
    (let ((position (point)))
      (set-mark (point-min))
      (scss2-copy)
      (should (= (point) position))
      (should (= (mark) (point-min)))
      (should (equal (car kill-ring) "\"abcd\""))
      (scss2-zap)
      (should (equal (buffer-string) ".a { content: \"ab\"; }"))
      (should (= (point) position))
      (should (equal (car kill-ring) "\"abcd\""))))
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: red; }"
    (set-mark (point-min))
    (scss2-mark)
    (should (equal (buffer-substring-no-properties (point) (mark)) "color: red;"))
    (should (= (marker-position (car mark-ring)) (point-min)))
    (let ((begin (point)) (end (mark)))
      (scss2-mark)
      (should (= (point) begin))
      (should (= (mark) end)))))

(ert-deftest scss2-edit-duplicate-preserves-inner-text-and-final-semicolon ()
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: red }"
    (scss2-duplicate)
    (should (equal (buffer-string) ".a { color: red;\ncolor: red }"))
    (should (equal kill-ring '("previous kill"))))
  (scss2-edit-test--buffer 'css2-mode ".a, .│b { x: 1; }"
    (scss2-duplicate)
    (should (equal (buffer-string) ".a, .b, .b { x: 1; }")))
  (scss2-edit-test--buffer 'scss2-mode
      "@m│ixin paint() {\n  --raw: { literal: \"  value  \"; };\n}"
    (let ((source (buffer-string)))
      (scss2-duplicate)
      (should (equal (buffer-string) (concat source "\n" source))))))

(ert-deftest scss2-edit-duplicate-separates-final-sass-statements ()
  (dolist (case '((".a { @include pa│int }" ".a { @include paint;\n@include paint }")
                  (".a { @debug │1 }" ".a { @debug 1;\n@debug 1 }")
                  ("@function f() { @return │1 }"
                   "@function f() { @return 1;\n@return 1 }")
                  ("@mixin paint { @con│tent }"
                   "@mixin paint { @content;\n@content }")
                  (".a { @ext│end .base }" ".a { @extend .base;\n@extend .base }")
                  (".a { @include pa│int; }" ".a { @include paint;\n@include paint; }")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (buffer-enable-undo)
      (let ((source (buffer-string)) (position (point)))
        (undo-boundary)
        (scss2-duplicate)
        (undo-boundary)
        (should (equal (buffer-string) (cadr case)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (should (equal kill-ring '("previous kill")))
        (undo-only 1)
        (should (equal (buffer-string) source))
        (should (= (point) position))))))

(ert-deftest scss2-edit-failures-restore-buffer-point-mark-and-kill-ring ()
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: red; }"
    (cl-letf (((symbol-function 'kill-new)
               (lambda (&rest _) (setq kill-ring '("bad partial state"))
                 (error "Simulated clipboard failure"))))
      (scss2-edit-test--unchanged #'scss2-kill-property)))
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: red; }"
    (setq buffer-read-only t)
    (scss2-edit-test--unchanged #'scss2-empty-value))
  (scss2-edit-test--buffer 'css2-mode ".a { col│or: \"unterminated; }"
    (scss2-edit-test--unchanged #'scss2-kill-property)))

(ert-deftest scss2-edit-substitute-rejects-source-changes-during-clipboard-read ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".a { content: \"hel│lo\"; color: red; }"
      (let ((interprogram-paste-function
             (lambda ()
               (save-excursion (goto-char (point-min)) (insert "/* event */"))
               "replacement")))
        (scss2-edit-test--unchanged #'scss2-substitute)))
    (scss2-edit-test--buffer mode ".a { content: \"hel│lo\"; color: red; }"
      (let ((interprogram-paste-function
             (lambda () (goto-char (point-min)) "replacement")))
        (scss2-edit-test--unchanged #'scss2-substitute)))))

(ert-deftest scss2-edit-empty-and-zap-preserve-unsupported-statement-shells ()
  (dolist (source '("@│include foo;" "@│use \"theme\";" "@return 1│ + 2;"
                    "@│layer components;" "@│extend .button;"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-edit-test--unchanged #'scss2-empty)
      (scss2-edit-test--unchanged #'scss2-zap))))

(ert-deftest scss2-edit-clipboard-buffer-switches-stay-owned-by-origin ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".a { content: \"hel│lo\"; color: red; }"
      (let ((origin (current-buffer)) (position (point))
            (other (generate-new-buffer " *scss2-clipboard-test*")))
        (unwind-protect
            (progn
              (with-current-buffer other
                (insert ".b { content: \"world\"; color: red; }")
                (scss2-test-setup-buffer mode) (goto-char position) (set-mark 3))
              (let ((interprogram-paste-function
                     (lambda () (set-buffer other) "replacement")))
                (scss2-substitute))
              (should (eq (current-buffer) origin))
              (should (equal (buffer-string) ".a { content: \"replacement\"; color: red; }"))
              (let ((interprogram-cut-function
                     (lambda (&rest _) (set-buffer other) (error "Clipboard failure"))))
                (scss2-edit-test--unchanged #'scss2-kill-property))
              (should (eq (current-buffer) origin))
              (with-current-buffer other
                (should (equal (buffer-string) ".b { content: \"world\"; color: red; }"))
                (should (= (point) position))
                (should (= (mark) 3))))
          (set-buffer origin)
          (kill-buffer other))))))

(ert-deftest scss2-edit-nested-properties-and-css-identifier-values ()
  (scss2-edit-test--buffer 'scss2-mode ".a { font: 12│px { weight: bold; } }"
    (scss2-empty-value)
    (should (equal (buffer-string) ".a { font:  { weight: bold; } }")))
  (scss2-edit-test--buffer 'scss2-mode ".a { fo│nt: 12px { weight: bold; } }"
    (scss2-kill-property)
    (should (equal (buffer-string) ".a {  }")))
  (scss2-edit-test--buffer 'css2-mode ".a { animation-name: │not; }"
    (scss2-kill-value-item)
    (should (equal (buffer-string) ".a { animation-name: ; }"))))

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
          (scss2-kill-block)
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
        (scss2-empty-block)
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
                     ".a { font: { size: 12px; }\nfont: { size: 12px; } color: red; }"))
      (should (equal kill-ring '("previous kill"))))))

(ert-deftest scss2-edit-flat-pseudo-arguments-keep-outer-selector-branches ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (branch '(".a:is(.b, :not(.c, .│d))"
                      ".a:is([data-x=\",\"], /* , */ :has(> .│d))"
                      ".a:nth-child(2n of :is(.b, .│c), .d)"))
      (scss2-edit-test--buffer mode (concat branch ", .after { color: red; }")
        (scss2-kill-selector)
        (should (equal (buffer-string) ".after { color: red; }"))
        (should (= (point) (point-min)))
        (should (equal (car kill-ring)
                       (concat (replace-regexp-in-string "│" "" branch) ", ")))))
    (scss2-edit-test--buffer mode ".a:is(:lang(\"│en,US\"), .b) { color: red; }"
      (scss2-edit-test--unchanged #'scss2-kill-value-item))))

(ert-deftest scss2-edit-narrowing-and-nonvalue-strings-reject-safely ()
  (scss2-edit-test--buffer 'css2-mode ".a { color: r│ed; }"
    (let ((position (point)))
      (narrow-to-region (point) (point-max))
      (goto-char position)
      (scss2-edit-test--unchanged #'scss2-kill-property)))
  (scss2-edit-test--buffer 'css2-mode ".a:lang(\"│en\") { color: red; }"
    (scss2-edit-test--unchanged #'scss2-kill-value-item))
  (scss2-edit-test--buffer 'scss2-mode "@use \"│theme\";"
    (scss2-edit-test--unchanged #'scss2-kill-value-item)))

(ert-deftest scss2-edit-narrowed-literals-keep-the-full-syntax-owner ()
  (dolist (source '(".a { content: \".b { color: re│d; }\"; }"
                    ".a { /* .b { color: re│d; } */ }"))
    (scss2-edit-test--buffer 'css2-mode source
      (let ((position (point)))
        (goto-char (point-min)) (search-forward ".b")
        (let ((begin (- (point) 2)))
          (search-forward "}")
          (narrow-to-region begin (point)))
        (goto-char position))
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (dolist (command '(scss2-kill-property scss2-empty-value
                         scss2-kill-value-item scss2-empty scss2-zap))
        (scss2-edit-test--unchanged command)
        (should-not buffer-undo-list))))
  (scss2-edit-test--buffer 'css2-mode ".before {} .a { color: re│d; } .after {}"
    (let ((position (point)))
      (goto-char (point-min)) (search-forward ".a ")
      (let ((begin (- (point) 3)))
        (search-forward "}")
        (narrow-to-region begin (point)))
      (goto-char position))
    (scss2-kill-property)
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
      (call-interactively #'scss2-empty-value)
      (undo-boundary)
      (undo 1)
      (should (equal (buffer-string) source)))))

(ert-deftest scss2-edit-css-function-result-spellings-stay-opaque ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (name '("result" "RESULT"))
      (dolist (case `((scss2-kill-property "@function --foo() {  }"
                      ,(concat name ": {payload:value};"))
                     (scss2-empty-value ,(format "@function --foo() { %s: ; }" name)
                      "{payload:value}")
                     (scss2-kill-block "" ,(format "@function --foo() { %s: {payload:value}; }" name))))
        (scss2-edit-test--buffer mode
            (format "@function --foo() { %s: {payload:v│alue}; }" name)
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (buffer-enable-undo)
          (setq buffer-undo-list nil)
          (let ((source (buffer-string)))
            (undo-boundary)
            (call-interactively (car case))
            (undo-boundary)
            (should (equal (buffer-string) (nth 1 case)))
            (should (equal (car kill-ring) (nth 2 case)))
            (undo 1)
            (should (equal (buffer-string) source))))))))

(ert-deftest scss2-edit-escaped-result-remains-a-nested-property ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode "@function --foo() { r\\65 sult: {payload:v│alue}; }"
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (scss2-kill-property)
      (should (equal (buffer-string) "@function --foo() { r\\65 sult: {}; }"))
      (should (equal (car kill-ring) "payload:value")))))

(ert-deftest scss2-edit-result-is-literal-only-in-css-function-bodies ()
  (scss2-edit-test--buffer 'scss2-mode ".a { result: 1px 2│px; }"
    (should-not (treesit-node-check (scss2--root-node) 'has-error))
    (scss2-kill-value-item)
    (should (equal (buffer-string) ".a { result: 1px; }"))
    (should (equal (car kill-ring) " 2px")))
  (scss2-edit-test--buffer 'scss2-mode ".a { result: $x + 1│px; }"
    (scss2-edit-test--unchanged #'scss2-kill-value-item))
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode
        "@function --foo() { @media (width > 1px) { result: 1px 2│px; } }"
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (scss2-kill-value-item)
      (should (equal (buffer-string)
                     "@function --foo() { @media (width > 1px) { result: ; } }"))
      (should (equal (car kill-ring) "1px 2px")))))

(ert-deftest scss2-edit-css-var-balanced-fallback-keeps-one-target ()
  (dolist (group '("[a;\"b│\";/*c*/]" "{a:b;/*c│*/}" "[a;{b:\"c│\"}]"
                   "(a;\"b│\")" "#{a:b;/*c│*/}"))
    (let* ((plain (replace-regexp-in-string "│" "" group))
           (opening (if (string-prefix-p "#{" plain) 2 1))
           (shell (concat (substring plain 0 opening) "│" (substring plain -1)))
           (content (substring plain opening -1)))
      (dolist (case `((scss2-kill-value-item ".a { value: var(--x│); color: red; }"
                      ,(concat ", " plain))
                     (scss2-empty ,(format ".a { value: var(--x, %s); color: red; }" shell)
                      ,content)
                     (scss2-empty-value ".a { value: │; color: red; }"
                      ,(format "var(--x, %s)" plain))))
        (scss2-edit-test--buffer 'css2-mode
            (format ".a { value: var(--x, %s); color: red; }" group)
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (buffer-enable-undo)
          (setq buffer-undo-list nil)
          (let ((original (buffer-string)) (expected (nth 1 case)))
            (undo-boundary)
            (funcall (car case))
            (undo-boundary)
            (should (equal (buffer-string) (replace-regexp-in-string "│" "" expected)))
            (should (= (point) (1+ (string-match "│" expected))))
            (should (equal kill-ring (list (nth 2 case) "previous kill")))
            (should (eq kill-ring-yank-pointer kill-ring))
            (undo 1)
            (should (equal (buffer-string) original)))))))
  (dolist (source '(".a { value: var(--x, [a│;b]; color: red; }"
                    ".a { value: var(--x, {a:b│;c:d}; color: red; }"))
    (scss2-edit-test--buffer 'css2-mode source
      (dolist (command '(scss2-kill-value-item scss2-empty scss2-empty-value))
        (scss2-edit-test--unchanged command)))))

(ert-deftest scss2-edit-dimensions-and-hashes-remain-complete-value-items ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (token '("1foo│2" "1foo-│bar" "1\\65 │m" "1😀│" "#😀│" "#á│" "#foo\\+b│ar"))
      (let ((plain (replace-regexp-in-string "│" "" token)))
        (dolist (case `((scss2-kill-value-item ".a { value: │3px; color: red; }" ,(concat plain " "))
                       (scss2-empty ".a { value: │ 3px; color: red; }" ,plain)
                       (scss2-empty-value ".a { value: │; color: red; }" ,(concat plain " 3px"))))
          (scss2-edit-test--buffer mode
              (format ".a { value: %s 3px; color: red; }" token)
            (should-not (treesit-node-check (scss2--root-node) 'has-error))
            (buffer-enable-undo)
            (setq buffer-undo-list nil)
            (let ((original (buffer-string)) (expected (nth 1 case)))
              (undo-boundary)
              (funcall (car case))
              (undo-boundary)
              (should (equal (buffer-string) (replace-regexp-in-string "│" "" expected)))
              (should (= (point) (1+ (string-match "│" expected))))
              (should (equal kill-ring (list (nth 2 case) "previous kill")))
              (undo 1)
              (should (equal (buffer-string) original))))))))
  (scss2-edit-test--buffer 'css2-mode ".a { value: 1px-2│px 3px; }"
    (scss2-kill-value-item)
    (should (equal (buffer-string) ".a { value: 3px; }"))
    (should (equal (car kill-ring) "1px-2px ")))
  (scss2-edit-test--buffer 'scss2-mode ".a { value: 1px-2│px 3px; }"
    (scss2-edit-test--unchanged #'scss2-kill-value-item)))

(ert-deftest scss2-edit-narrowing-must-include-adjacent-separator ()
  (dolist (source '(".a { value: red, bl│ue; }" ".a { value: bl│ue, red; }"))
    (scss2-edit-test--buffer 'css2-mode source
      (let ((position (point)))
        (goto-char (point-min)) (search-forward "blue")
        (narrow-to-region (- (point) 4) (point))
        (goto-char position))
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (scss2-edit-test--unchanged #'scss2-kill-value-item)
      (should-not buffer-undo-list))))

(ert-deftest scss2-edit-literals-select-their-enclosing-item ()
  ;; A quoted key or value is part of its entry, exactly like a bare one.
  (dolist (case '(("$m: (a: 1, 'b│': 2, c: 3);" "$m: (a: 1, c: 3);" "'b': 2, ")
                  ("@include f($a: 1, $b: 'x│', $c: 3);" "@include f($a: 1, $c: 3);" "$b: 'x', ")
                  ("@mixin f($a: 1, $b: 'x│', $c: 3) {}" "@mixin f($a: 1, $c: 3) {}" "$b: 'x', ")
                  ("$m: (a: 1, b: url(x│.png), c: 3);" "$m: (a: 1, c: 3);" "b: url(x.png), ")
                  ("@use 'x' with ($a: 1, $b: 'y│');" "@use 'x' with ($a: 1);" ", $b: 'y'")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (scss2-kill-value-item)
      (should (equal (buffer-string) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case)))
      (should-not (treesit-node-check (scss2--root-node) 'has-error))))
  ;; Outside a sequence the literal belongs to its statement or selector.
  (scss2-edit-test--buffer 'scss2-mode "@use 'th│eme' as t; .a { x: 1; }"
    (scss2-kill)
    (should (equal (buffer-string) " .a { x: 1; }")))
  (scss2-edit-test--buffer 'css2-mode "[data-x=\"e│n\"], .b { x: 1; }"
    (scss2-kill)
    (should (equal (buffer-string) ".b { x: 1; }")))
  (scss2-edit-test--buffer 'css2-mode "[data-x=\"e│n\"] { x: 1; }"
    (scss2-edit-test--unchanged #'scss2-kill))
  ;; Its content stays editable wherever it is.
  (scss2-edit-test--buffer 'scss2-mode "@use 'th│eme' as t;"
    (scss2-empty)
    (should (equal (buffer-string) "@use '' as t;"))))

(ert-deftest scss2-edit-flags-are-not-value-items ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '((scss2-kill-value-item ".a { font-family: a, │b !important; }"
                                           ".a { font-family: a !important; }")
                    (scss2-duplicate ".a { font-family: a, │b !important; }"
                                     ".a { font-family: a, b, b !important; }")
                    (scss2-kill-value-item ".a { margin: 0 │auto !important; }"
                                           ".a { margin: 0 !important; }")))
      (scss2-edit-test--buffer mode (nth 1 case)
        (funcall (car case))
        (should (equal (buffer-string) (nth 2 case)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))))
    (scss2-edit-test--buffer mode ".a { color: red !imp│ortant; }"
      (scss2-edit-test--unchanged #'scss2-kill-value-item)))
  (scss2-edit-test--buffer 'scss2-mode "$x: a, │b !default;"
    (scss2-kill-value-item)
    (should (equal (buffer-string) "$x: a !default;"))))

(ert-deftest scss2-edit-point-must-touch-its-target ()
  ;; Blank space, a separator or a flag never widens to an enclosing
  ;; value, statement or rule.
  (dolist (source '(".a { x: rgba(0, 0, 0,│ 0.5); }"
                    ".a { x: rgba(0, 0, 0 │ ); }"
                    ".a { margin: 0 │ auto; }"
                    ".a { margin: 0 auto │ ; }"
                    ".a {\n│  color: red;\n}"
                    ".a { color: red; │ }"
                    ".a, │ .b { x: 1; }"
                    ".a, .b │ { x: 1; }"
                    ".a {\n  transition:\n│    opacity 1s,\n    transform 2s;\n}"))
    (dolist (command '(scss2-kill scss2-copy scss2-mark scss2-duplicate
                       scss2-empty scss2-kill-value-item))
      (scss2-edit-test--buffer 'css2-mode source
        (scss2-edit-test--unchanged command))))
  (dolist (source '("$m: (a: 1,│ b: 2);"
                    ".a {\n  font: {\n│    family: x;\n  }\n}"
                    "@if $a { x: 1; }\n│\n@else { x: 2; }"))
    (scss2-edit-test--buffer 'scss2-mode source
      (scss2-edit-test--unchanged #'scss2-kill)))
  ;; A name or delimiter stands for its owner, on either side of a brace
  ;; or parenthesis alike.
  (dolist (case '((".a { x: rgba│(0, 0, 0); }" ".a { x: ; }")
                  (".a { x: rgba(│ 0, 0, 0); }" ".a { x: ; }")
                  (".a { y: 1; .b {│ color: red; } }" ".a { y: 1;  }")))
    (scss2-edit-test--buffer 'css2-mode (car case)
      (scss2-kill)
      (should (equal (buffer-string) (cadr case)))))
  ;; A unit is part of its number even though only the unit is a leaf.
  (scss2-edit-test--buffer 'css2-mode ".a { margin: 1│2px 3px; }"
    (scss2-kill-value-item)
    (should (equal (buffer-string) ".a { margin: 3px; }")))
  ;; An empty container still offers its interior.
  (scss2-edit-test--buffer 'css2-mode ".a { x: fn(│); }"
    (setq kill-ring '("1px") kill-ring-yank-pointer kill-ring)
    (scss2-substitute)
    (should (equal (buffer-string) ".a { x: fn(1px); }"))))

(ert-deftest scss2-edit-any-comma-makes-commas-the-separator ()
  (dolist (case '((scss2-kill "$o: (│a,);" "$o: ();")
                  (scss2-kill "$l: [│a,];" "$l: [];")
                  (scss2-duplicate "$o: (│a,);" "$o: (a, a,);")
                  (scss2-kill ".a { x: fn((│a,), b); }" ".a { x: fn((), b); }")))
    (scss2-edit-test--buffer 'scss2-mode (nth 1 case)
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (funcall (car case))
      (should (equal (buffer-string) (nth 2 case)))
      (should-not (treesit-node-check (scss2--root-node) 'has-error)))))

(ert-deftest scss2-edit-last-item-takes-its-separator-across-lines ()
  (dolist (case '(("$map: (\n  a: 1,\n  b│: 2\n);" "$map: (\n  a: 1\n);" ",\n  b: 2")
                  ("@include foo(\n    $x,\n    $│y\n  );" "@include foo(\n    $x\n  );" ",\n    $y")
                  (".a,\n.│b { x: 1; }" ".a { x: 1; }" ",\n.b")
                  (".a {\n  transition:\n    opacity 1s,\n    trans│form 2s;\n}"
                   ".a {\n  transition:\n    opacity 1s;\n}" ",\n    transform 2s")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-kill)
      (should (equal (buffer-string) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case)))
      (should-not (treesit-node-check (scss2--root-node) 'has-error))))
  ;; A comment between the item and its comma stays.
  (scss2-edit-test--buffer 'scss2-mode "$map: (\n  a: 1, // keep\n  b│: 2\n);"
    (scss2-kill)
    (should (string-search "a: 1 // keep\n" (buffer-string)))
    (should-not (string-search "b: 2" (buffer-string)))
    (should-not (treesit-node-check (scss2--root-node) 'has-error))))

(ert-deftest scss2-edit-literal-content-ignores-surrounding-operators ()
  (dolist (case '(("$path: $base + \"/im│g\";" "$path: $base + \"\";" "/img")
                  (".a { font: 12px/1.5 \"Helvetica │Neue\"; }" ".a { font: 12px/1.5 \"\"; }"
                   "Helvetica Neue")))
    (scss2-edit-test--buffer 'scss2-mode (car case)
      (scss2-empty)
      (should (equal (buffer-string) (nth 1 case)))
      (should (equal (car kill-ring) (nth 2 case)))))
  ;; The operands themselves still stay together.
  (scss2-edit-test--buffer 'scss2-mode "$path: $ba│se + \"/img\";"
    (scss2-edit-test--unchanged #'scss2-empty)))

(ert-deftest scss2-edit-required-sequences-keep-their-last-item ()
  (dolist (command '(scss2-empty scss2-substitute scss2-zap scss2-kill-selector))
    (dolist (source '(".│a { x: 1; }" ".a, .│b { x: 1; }"))
      (scss2-edit-test--buffer 'css2-mode source
        (if (and (eq command 'scss2-kill-selector) (string-search "," source))
            (progn (scss2-kill-selector)
                   (should (equal (buffer-string) ".a { x: 1; }")))
          (scss2-edit-test--unchanged command)))))
  (dolist (command '(scss2-kill scss2-kill-value-item))
    (dolist (source '("$tone: r│ed;" "@use 'x' with ($on│ly: 1);"
                      "@forward 'x' with ($│a: 1 !default);" ".x { @extend .│a; }"))
      (scss2-edit-test--buffer 'scss2-mode source
        (scss2-edit-test--unchanged command))))
  (scss2-edit-test--buffer 'scss2-mode "@use 'x' with ($a: 1, $on│ly: 2);"
    (scss2-kill)
    (should (equal (buffer-string) "@use 'x' with ($a: 1);")))
  (scss2-edit-test--buffer 'scss2-mode "$tone: r│ed;"
    (scss2-empty-value)
    (should (equal (buffer-string) "$tone: ;"))))

(ert-deftest scss2-edit-whole-line-targets-take-their-lines ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-edit-test--buffer mode ".a {\n  col│or: red;\n  margin: 0;\n}\n"
      (scss2-kill)
      (should (equal (buffer-string) ".a {\n  margin: 0;\n}\n"))
      (should (equal (car kill-ring) "  color: red;\n"))
      (should (looking-at-p "margin"))
      ;; Point is on the next statement, so the command repeats.
      (scss2-kill)
      (should (equal (buffer-string) ".a {\n}\n")))
    (scss2-edit-test--buffer mode ".a,\n.│b,\n.c {\n  x: 1;\n}\n"
      (scss2-kill-selector)
      (should (equal (buffer-string) ".a,\n.c {\n  x: 1;\n}\n")))
    ;; Text sharing the line keeps the line.
    (scss2-edit-test--buffer mode ".a {\n  col│or: red; /* note */\n}\n"
      (scss2-kill)
      (should (equal (buffer-string) ".a {\n   /* note */\n}\n"))))
  (scss2-edit-test--buffer 'scss2-mode "$map: (\n  a: 1,\n  b│: 2,\n  c: 3\n);\n"
    (scss2-kill-value-item)
    (should (equal (buffer-string) "$map: (\n  a: 1,\n  c: 3\n);\n"))))

(ert-deftest scss2-edit-substitute-inserts-plain-text ()
  (scss2-edit-test--buffer 'css2-mode ".a { content: \"he│llo\"; }"
    (setq kill-ring (list (propertize "RED" 'read-only t 'invisible t))
          kill-ring-yank-pointer kill-ring)
    (scss2-substitute)
    (should (equal (buffer-string) ".a { content: \"RED\"; }"))
    (should-not (text-properties-at (- (point) 2)))))

(ert-deftest scss2-edit-repeated-mark-keeps-a-target-that-begins-with-another ()
  (scss2-edit-test--buffer 'css2-mode ".a │{\n  color: red;\n}"
    (scss2-mark)
    (let ((begin (point)) (end (mark)) (last-command 'scss2-mark))
      (should (equal (buffer-substring-no-properties begin end)
                     ".a {\n  color: red;\n}"))
      (scss2-mark)
      (should (= (point) begin))
      (should (= (mark) end)))))

(ert-deftest scss2-edit-item-commands-preserve-parse-integrity ()
  ;; Whole-target commands never turn a valid stylesheet into an invalid one.
  (dolist (case '((css2-mode ".a, .b:is(.c, [d=\"e\"]) {\n  margin: 0 auto !important;\n  font: 1px/2 a, \"b, c\";\n  x: rgba(0, 0, 0, 0.5) url(\"u.png\");\n}\n@media screen and (width > 1px) { .e { color: red; } }\n")
                  (scss2-mode "@use 'x' with ($only: 1);\n$o: (a,);\n$l: [a, b,];\n.f {\n  font: {\n    family: x;\n    size: 12px;\n  }\n  transition:\n    opacity 1s,\n    transform 2s;\n}\n")
                  (scss2-mode "@use 'theme' as t;\n$m: (a: 1, 'b': 2, c: (d e f));\n@mixin f($a: 1, $b: 'x') { @content; }\n.a {\n  @include f($a: 2, $b: t.$tone) using ($s) { x: $s; }\n  &:hover, .b { y: 1px 2px !important; }\n  @if $m { z: 1; } @else { z: 2; }\n}\n")))
    (dolist (command '(scss2-kill scss2-kill-value-item scss2-kill-selector
                       scss2-kill-property scss2-kill-block scss2-duplicate))
      (with-temp-buffer
        (let ((source (cadr case)) (css-fontify-colors nil)
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

(provide 'scss2-edit-test)
;;; scss2-edit-test.el ends here
