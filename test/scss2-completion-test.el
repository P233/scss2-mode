;;; scss2-completion-test.el --- Semantic completion regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'scss2-mode)

(defmacro scss2-completion-test--with (dialect source &rest body)
  "Complete SOURCE, with | denoting point, in DIALECT and evaluate BODY."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (insert ,source)
     (goto-char (point-min))
     (search-forward "|")
     (delete-char -1)
     (let ((position (point)) (css-fontify-colors nil))
       (funcall (if (eq ,dialect 'css) #'css2-mode #'scss2-mode))
       (goto-char position)
       ,@body)))

(defun scss2-completion-test--all (input table &optional predicate)
  "Return TABLE's candidates for INPUT as a completion frontend sees them."
  (let ((all (completion-all-completions input table predicate (length input))))
    (when (consp all) (setcdr (last all) nil))
    all))

(defun scss2-completion-test--names ()
  "Return currently matching completion candidates."
  (when-let* ((capf (scss2-completion-at-point)))
    (scss2-completion-test--all
     (buffer-substring-no-properties (nth 0 capf) (point)) (nth 2 capf))))

(defun scss2-completion-test--expansions ()
  "Return the native Emmet rows displayed for this declaration prefix."
  (when-let* ((capf (scss2-completion-at-point))
              (affix (plist-get (nthcdr 3 capf) :affixation-function)))
    (mapcar #'cadr
            (funcall affix (all-completions
                           (buffer-substring-no-properties (car capf) (point)) (nth 2 capf))))))

(ert-deftest scss2-completion-for-range-keywords-own-their-slot ()
  (dolist (source '("@for $i from 1 t|" ".a { @for $i from 1 t|"
                    "@for $i from max(1, 2) t|"))
    (scss2-completion-test--with 'scss source
      (should (equal (sort (scss2-completion-test--names) #'string<) '("through" "to")))))
  (dolist (source '("@for $i from 1 + t|" "@for $i from max(1, t|"
                    "@for $i from 1 to t|"))
    (scss2-completion-test--with 'scss source
      (should-not (member "through" (scss2-completion-test--names)))))
  (scss2-completion-test--with 'css "@for $i from 1 t|"
    (should-not (member "through" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-empty-variable-value-at-eof ()
  (scss2-completion-test--with 'scss "$known: red; $z: |"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
    (let ((names (scss2-completion-test--names)))
      (should (member "$known" names))
      (should-not (member "$z" names)))))

(ert-deftest scss2-completion-unclosed-loops-keep-their-lexical-bindings ()
  (dolist (case '(("@each $item in red { color: $|" ("$item"))
                  ("@for $i from 1 to 2 { color: $|" ("$i"))
                  ("@mixin m($tone) { @each $key, $value in red { color: $|"
                   ("$key" "$tone" "$value"))
                  ("@each $item in red { color: red; } .a { color: $|" nil)
                  ("@each $item in $|" nil)))
    (scss2-completion-test--with 'scss (car case)
      (should (equal (sort (scss2-completion-test--names) #'string<) (cadr case))))))

(ert-deftest scss2-completion-shared-keyword-sets-cover-common-values ()
  (dolist (dialect '(css scss))
    (dolist (case '(("border-style: sol" "solid") ("border: sol" "solid")
                    ("border-width: thi" "thin") ("color: ora" "orange")
                    ("color: rebe" "rebeccapurple") ("background: rep" "repeat")))
      (scss2-completion-test--with dialect (concat ".a { " (car case) "|; }")
        (should (member (cadr case) (scss2-completion-test--names)))))))

(ert-deftest scss2-completion-bare-at-sign-filters-dialect ()
  (scss2-completion-test--with 'css "@|"
    (should (eq (plist-get (scss2-context-at-point) :role) 'at-rule))
    (should (member "@media" (scss2-completion-test--names)))
    (should-not (member "@mixin" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "@|"
    (should (member "@include" (scss2-completion-test--names)))
    (should (member "@use" (scss2-completion-test--names)))
    (should-not (member "@return" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-at-rule-owner-restrictions ()
  (scss2-completion-test--with 'scss "@mixin x { @| }"
    (should (member "@content" (scss2-completion-test--names)))
    (should-not (member "@use" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "@function x() { @| }"
    (should (member "@return" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css ".a { @| }"
    (should (member "@media" (scss2-completion-test--names)))
    (should-not (member "@charset" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-property-and-value-stay-separate ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect ".a { dis| }"
      (should (member "display: ;" (scss2-completion-test--expansions)))
      (should-not (member "flex" (scss2-completion-test--names))))
    (scss2-completion-test--with dialect ".a { display: |; }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
      (should (member "flex" (scss2-completion-test--names)))
      (should (member "inherit" (scss2-completion-test--names)))
      (should-not (member "color" (scss2-completion-test--names))))
    (scss2-completion-test--with dialect ".a { color: |; }"
      (should (member "red" (scss2-completion-test--names)))
      (should-not (member "flex" (scss2-completion-test--names))))))

(ert-deftest scss2-completion-pseudo-selectors ()
  (dolist (source '(".a:ho| {}" ".a { &:ho| {} }"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'pseudo))
      (should (member ":hover" (scss2-completion-test--names)))))
  (scss2-completion-test--with 'css ".a::be| {}"
    (should (member "::before" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-media-and-supports-prelude ()
  (scss2-completion-test--with 'css "@media (prefers-|) {}"
    (should (member "prefers-color-scheme" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css "@media (prefers-color-scheme: |) {}"
    (should (member "dark" (scss2-completion-test--names)))
    (should-not (member "display" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css "@supports (display: |) {}"
    (should (member "grid" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css "@supports (dis|) {}"
    (should-not (scss2-completion-at-point))))

(ert-deftest scss2-completion-comment-and-string-are-opaque ()
  (dolist (dialect '(css scss))
    (dolist (source '("/* @| */" ".a { content: \"dis|\"; }"))
      (scss2-completion-test--with dialect source
        (should-not (scss2-completion-at-point)))))
  (scss2-completion-test--with 'css ".a { content: \"#{$va|}\"; }"
    (should-not (scss2-completion-at-point))))

(ert-deftest scss2-completion-opaque-text-skips-prefix-backtracking ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect ".a { /* color: red; width: 1px; | */ }"
      (cl-letf (((symbol-function 'scss2--statement-start)
                 (lambda () (ert-fail "Comment requested a statement scan"))))
        (should-not (scss2-completion-at-point))))
    (scss2-completion-test--with dialect ".a { content: \"color: red; width: 1px; |\"; }"
      (let ((quote (nth 8 (syntax-ppss)))
            (scan (symbol-function 'scss2--statement-start)))
        (cl-letf (((symbol-function 'scss2--statement-start)
                   (lambda ()
                     (should (<= (point) quote))
                     (funcall scan))))
          (should-not (scss2-completion-at-point)))))))

(ert-deftest scss2-completion-interpolation-comments-stay-opaque ()
  (dolist (property '("content" "--raw"))
    (scss2-completion-test--with 'scss
        (format "$tone: red; .a { %s: \"#{/* co|mment */ $tone}\"; }" property)
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (should-not (scss2-completion-at-point)))
    (scss2-completion-test--with 'scss
        (format "$tone: red; .a { %s: \"#{/* comment */| $tone}\"; }" property)
      (should (scss2-completion-at-point)))
    (scss2-completion-test--with 'scss
        (format "$tone: red; .a { %s: \"#{/* comment */ $to|}\"; }" property)
      (should (member "$tone" (scss2-completion-test--names))))))

(ert-deftest scss2-completion-scoped-variables-and-mixins ()
  (scss2-completion-test--with 'scss "$global: red; .other { $hidden: blue; } .a { $local: red; color: $|; }"
    (let ((names (scss2-completion-test--names)))
      (should (member "$global" names))
      (should (member "$local" names))
      (should-not (member "$hidden" names))))
  (scss2-completion-test--with 'scss "@mixin paint($tone) { color: $|; }"
    (should (member "$tone" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "@mixin paint($tone: red) {} .a { @include pa|; }"
    (should (member "paint" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "@mixin paint($tone: red) {} .a { @include paint(|); }"
    (should (member "$tone: " (scss2-completion-test--names)))))

(ert-deftest scss2-completion-scss-interpolation-only ()
  (scss2-completion-test--with 'scss "$tone: red; .a { content: \"#{$to|}\"; }"
    (should (member "$tone" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css "$tone: red; .a { content: \"#{$to|}\"; }"
    (should-not (scss2-completion-at-point))))

(ert-deftest scss2-completion-custom-property-reference ()
  (scss2-completion-test--with 'css ":root { --tone: red; } .a { color: var(--|); }"
    (should (member "--tone" (scss2-completion-test--names)))
    (should-not (member "color" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-narrowing-preserves-real-context-and-bounds ()
  (dolist (source '(".a { content: \".b { color: re|d; }\"; }"
                    ".a { /* .b { color: re|d; } */ }"))
    (scss2-completion-test--with 'css source
      (let ((position (point)))
        (goto-char (point-min)) (search-forward ".b")
        (let ((begin (- (point) 2)))
          (search-forward "}")
          (narrow-to-region begin (point)))
        (goto-char position))
      (should-not (scss2-completion-at-point))))
  (scss2-completion-test--with 'css ":root { --tone: red; } .a { color: var(--to|); }"
    (narrow-to-region (- (point) 4) (point))
    (should (equal (scss2-completion-test--names) '("--tone"))))
  (scss2-completion-test--with 'css ".a { width: ca|lc(1px); }"
    (narrow-to-region (- (point) 2) (+ (point) 2))
    (should (equal (plist-get (scss2-context-at-point) :property) "width"))
    (should (member "calc()" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css ".a { wid|th: 1px; }"
    (narrow-to-region (1- (point)) (point-max))
    (should-not (scss2-completion-at-point))))

(ert-deftest scss2-completion-custom-property-reference-uses-call-boundaries ()
  (dolist (dialect '(css scss))
    (dolist (value '("var(\n--to|)" "var(/* first */--to|)" "var(/* first */--to|ne)"
                     "VAR(--to|)" "v\\61 r(--to|)"
                     "var(--to|, red)" "var(--tone, var(/* nested */--to|))"))
      (scss2-completion-test--with dialect
          (format ":root { --tone: red; } .a { color: %s; }" value)
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (should (eq (plist-get (scss2-context-at-point) :role) 'custom-property))
        (should (equal (scss2-completion-test--names) '("--tone")))))
    (dolist (value '("var(--tone, --to|)" "var(, --to|)" "var(other(--to|), red)"
                     "var((--to|), red)" "other(--to|)"))
      (scss2-completion-test--with dialect
          (format ":root { --tone: red; } .a { color: %s; }" value)
        (should-not (eq (plist-get (scss2-context-at-point) :role) 'custom-property))
        (should-not (member "--tone" (scss2-completion-test--names))))))
  (scss2-completion-test--with 'scss
      ":root { --tone: red; } .a { color: theme.var(--to|); }"
    (should-not (treesit-node-check (scss2--root-node) 'has-error))
    (should-not (eq (plist-get (scss2-context-at-point) :role) 'custom-property))
    (should-not (member "--tone" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-custom-property-reference-keeps-incomplete-and-raw-input ()
  (dolist (dialect '(css scss))
    (dolist (source '(":root { --tone: red; } .a { color: var(/* first */--to|"
                      ":root { --tone: red; } .a { --raw: { var(--to|) }; }"))
      (scss2-completion-test--with dialect source
        (should (eq (plist-get (scss2-context-at-point) :role) 'custom-property))
        (should (equal (scss2-completion-test--names) '("--tone")))))
    (dolist (source '(":root { --tone: red; } .a { color: var(--tone, --to|"
                      ":root { --tone: red; } .a { color: theme.var(--to|"
                      ":root { --tone: red; } .a { --raw: { var(--tone, --to|) }; }"
                      ":root { --tone: red; } .a { --raw: { theme.var(--to|) }; }"
                      ":root { --tone: red; } .a { --raw: { \"var(--to|)\" }; }"
                      ":root { --tone: red; } .a { --raw: { /* var(--to|) */ }; }"))
      (scss2-completion-test--with dialect source
        (should-not (eq (plist-get (scss2-context-at-point) :role) 'custom-property))
        (should-not (member "--tone" (scss2-completion-test--names)))))))

(ert-deftest scss2-completion-custom-property-reference-refines-query-values ()
  (dolist (dialect '(css scss))
    (dolist (source '(":root { --tone: red; } @supports (color: var(--to|)) {}"
                      ":root { --tone: red; } .a { color: if(supports(color: var(/* first */--to|)): red; else: blue); }"))
      (scss2-completion-test--with dialect source
        (should (eq (plist-get (scss2-context-at-point) :role) 'custom-property))
        (should (equal (plist-get (scss2-context-at-point) :property) "color"))
        (should (equal (scss2-completion-test--names) '("--tone")))))
    (scss2-completion-test--with dialect
        ":root { --tone: red; } @supports (color: var(--tone, re|)) {}"
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
      (should (member "red" (scss2-completion-test--names)))
      (should-not (member "--tone" (scss2-completion-test--names)))))
  (scss2-completion-test--with 'scss
      ":root { --tone: red; } .a { @include paint(var(--to|)); }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'custom-property))
    (should (equal (scss2-completion-test--names) '("--tone")))))

(ert-deftest scss2-completion-custom-properties-are-case-sensitive ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect
        ":root { --Foo: red; --foo: blue; } .a { color: var(--fo|); }"
      (should (equal (scss2-completion-test--names) '("--foo"))))))

(ert-deftest scss2-completion-unicode-identifiers-keep-complete-bounds ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect
        ":root { --😀tone: red; } .a { color: var(--😀to|); }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'custom-property))
      (should (equal (scss2-completion-test--names) '("--😀tone"))))
    (scss2-completion-test--with dialect ".😀title {} .😀t| {}"
      (should (eq (plist-get (scss2-context-at-point) :role) 'selector))
      (should-not (scss2-completion-at-point))))
  (scss2-completion-test--with 'scss "$😀tone: red; .a { color: $😀to|; }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'variable))
    (should (equal (scss2-completion-test--names) '("$😀tone")))))

(ert-deftest scss2-completion-legacy-property-hack-retains-its-prefix ()
  (scss2-completion-test--with 'css ".a { |*color: red; }"
    (should-not (scss2-completion-at-point)))
  (scss2-completion-test--with 'css ".a { *col|: red; }"
    (should-not (scss2-completion-at-point)))
  (scss2-completion-test--with 'css ".a { *color: re|; }"
    (should (equal (plist-get (scss2-context-at-point) :property) "color"))
    (should (member "red" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-escaped-identifiers-match-with-safe-insertion ()
  (dolist (case '((".a { color: r\\65 |; }" "red" ".a { color: red; }")
                  (".a { width: ca\\6c c|; }" "calc()" ".a { width: calc(); }")
                  (":root { --foo: red; } .a { color: var(--f\\6f|); }" "--foo"
                   ":root { --foo: red; } .a { color: var(--foo); }")
                  ("$f\\6f o: red; .a { color: $fo|; }" "$f\\6f o"
                   "$f\\6f o: red; .a { color: $f\\6f o; }")))
    (scss2-completion-test--with 'scss (car case)
      (let* ((completion (scss2-completion-at-point))
             (candidate (nth 1 case))
             (completion-styles '(basic))
             (completion-cycle-threshold nil)
             (completion-auto-help nil))
        (should (member candidate (scss2-completion-test--names)))
        (completion-in-region
         (nth 0 completion) (nth 1 completion) (nth 2 completion)
         (lambda (name) (equal name candidate)))
        (should (equal (buffer-string) (nth 2 case)))
        (should-not (treesit-node-check (scss2--root-node) 'has-error)))))
  (scss2-completion-test--with 'css
      ":root { --foo\\+bar: red; } .a { color: var(--foo\\+|); }"
    (let* ((completion (scss2-completion-at-point))
           (completion-styles '(basic))
           (completion-auto-help nil))
      (completion-in-region (nth 0 completion) (nth 1 completion) (nth 2 completion))
      (let* ((arguments (treesit-search-subtree (scss2--root-node) "arguments"))
             (children (scss2--children arguments t)))
        (should (= (length children) 1))
        (should (equal (scss2--identifier-name (car children)) "--foo+bar"))
        (should-not (treesit-node-check (scss2--root-node) 'has-error))))))

(ert-deftest scss2-completion-escape-aliases-never-shorten-the-prefix ()
  (scss2-completion-test--with 'scss "$foo: red; $f\\6f o: blue; .a { color: $fo|; }"
    (let* ((completion (scss2-completion-at-point))
           (table (nth 2 completion)))
      (should (equal (sort (scss2-completion-test--names) #'string-lessp)
                     '("$f\\6f o" "$foo")))
      (should (equal (completion-try-completion "$fo" table nil 3) '("$fo" . 3)))
      (should (test-completion "$foo" table))
      (should (equal (completion-boundaries "$fo" table nil "") '(0 . 0))))))

(ert-deftest scss2-completion-custom-properties-decode-static-names ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect
        ":root { \\2d\\2d tone: red; --Tone: blue; --#{$dynamic}: green; } .a { color: var(--to|); }"
      (should (equal (scss2-completion-test--names) '("--tone"))))))

(ert-deftest scss2-completion-custom-property-insertion-preserves-name ()
  (dolist (dialect '(css scss))
    (dolist (spelling '("--foo\\+bar" "--foo\\20 bar" "\\2d\\2d foo\\+bar"))
      (scss2-completion-test--with dialect
          (format ":root { %s: red; } .a { color: var(--fo|); }" spelling)
        (let* ((completion (scss2-completion-at-point))
               (names (scss2-completion-test--names))
               (expected (scss2--decode-identifier spelling)))
          (should (= (length names) 1))
          (delete-region (nth 0 completion) (nth 1 completion))
          (insert (car names))
          (let* ((root (scss2--root-node))
                 (arguments (treesit-search-subtree root "arguments"))
                 (children (scss2--children arguments t)))
            (should-not (treesit-node-check root 'has-error))
            (should (= (length children) 1))
            (should (equal (scss2--identifier-name (car children)) expected))))))))

(ert-deftest scss2-completion-conditional-tests-own-their-context ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect
        ".a { color: if(supports(display: gr|): red; else: blue); }"
      (should (equal (plist-get (scss2-context-at-point) :property) "display"))
      (should (member "grid" (scss2-completion-test--names))))
    (scss2-completion-test--with dialect
        ".a { color: if(media(prefers-color-scheme: da|): red; else: blue); }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'media-value))
      (should (member "dark" (scss2-completion-test--names))))
    (scss2-completion-test--with dialect
        ".a { color: if(media((wi|dth > 10px)): red; else: blue); }"
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (should (eq (plist-get (scss2-context-at-point) :role) 'media-feature))
      (should (member "width" (scss2-completion-test--names))))
    (scss2-completion-test--with dialect
        ".a { color: if(media((width > 1|0px)): red; else: blue); }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'media-value))
      (should (equal (plist-get (scss2-context-at-point) :property) "width")))
    (scss2-completion-test--with dialect
        ".a { color: if(supports(display: grid): re|; else: blue); }"
      (should (equal (plist-get (scss2-context-at-point) :property) "color"))
      (should (member "red" (scss2-completion-test--names))))
    (dolist (value '("ca|" "ca|lc(1px)"))
      (scss2-completion-test--with dialect
          (format "@supports (width: if(media(width > 1px): %s; else: 2px)) {}" value)
        (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
        (should (equal (plist-get (scss2-context-at-point) :property) "width"))
        ;; Existing calls supply their own parentheses and arguments.
        (should (member (if (equal value "ca|") "calc()" "calc")
                        (scss2-completion-test--names)))))))

(ert-deftest scss2-completion-values-share-scan-without-leaking-variable-scope ()
  (scss2-completion-test--with 'scss
      "$before: 1; .hidden { $hidden: 2; } @mixin m($arg) { color: |; $later: 3; } @function future() { @return 1; }"
    (let ((names (scss2-completion-test--names)))
      (should (member "$before" names))
      (should (member "$arg" names))
      (should (member "future()" names))
      (should-not (member "$hidden" names))
      (should-not (member "$later" names)))))

(ert-deftest scss2-completion-module-disappearance-does-not-abort-completion ()
  (let* ((directory (make-temp-file "scss2-module-race-" t))
         (path (expand-file-name "_tokens.scss" directory)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "$color: red;"))
          (scss2-completion-test--with 'scss "@use './tokens'; .a { color: tokens.$|; }"
            (setq-local default-directory directory)
            (let ((resolve (symbol-function 'scss2-completion--module-path)))
              (cl-letf (((symbol-function 'scss2-completion--module-path)
                         (lambda (module)
                           (prog1 (funcall resolve module) (delete-file path)))))
                (should-not (scss2-completion-test--names))))))
      (delete-directory directory t))))

(ert-deftest scss2-completion-value-docs-and-bounds ()
  (scss2-completion-test--with 'css ".a { display: fl|ex; }"
    (let* ((capf (scss2-completion-at-point))
           (doc (funcall (plist-get (nthcdr 3 capf) :company-docsig) "flex")))
      (should (equal "flex" (buffer-substring-no-properties (nth 0 capf) (nth 1 capf))))
      (should (> (length doc) 30)))))

(ert-deftest scss2-completion-css-descriptors-respect-owner ()
  (scss2-completion-test--with 'css ".a { add| }"
    (should-not (member "additive-symbols: ;" (scss2-completion-test--expansions))))
  (scss2-completion-test--with 'css "@counter-style x { add| }"
    (should (member "additive-symbols: ;" (scss2-completion-test--expansions)))))

(ert-deftest scss2-completion-local-modules-read-unsaved-source ()
  (let* ((directory (make-temp-file "scss2-module-" t))
         (module-file (expand-file-name "_theme.scss" directory))
         (module-buffer (generate-new-buffer " *stylesheet test module*")))
    (unwind-protect
        (progn
          (with-temp-file module-file (insert "$old: red;"))
          (with-current-buffer module-buffer
            (setq buffer-file-name module-file)
            (insert "$tone: blue; $-private: red; @mixin paint() {} @function double($n) { @return $n * 2; }"))
          (scss2-completion-test--with 'scss "@use 'theme'; .a { color: theme.$|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (should (member "$tone" (scss2-completion-test--names)))
            (should-not (member "$old" (scss2-completion-test--names)))
            (should-not (member "$-private" (scss2-completion-test--names)))
            (let ((state (with-current-buffer module-buffer
                           (goto-char (point-min)) (search-forward "@mixin")
                           (narrow-to-region (- (point) 6) (point-max))
                           (list (point-min) (point-max) (point) (buffer-chars-modified-tick)))))
              (should (member "$tone" (scss2-completion-test--names)))
              (should-not (member "$old" (scss2-completion-test--names)))
              (should (equal state (with-current-buffer module-buffer
                                     (list (point-min) (point-max) (point) (buffer-chars-modified-tick))))))))
      (kill-buffer module-buffer)
      (delete-directory directory t))))

(ert-deftest scss2-completion-open-module-reuses-parser-and-preserves-buffer ()
  (let* ((directory (make-temp-file "scss2-open-module-" t))
         (path (expand-file-name "_theme.scss" directory))
         (module-buffer (generate-new-buffer " *scss2 open module*")))
    (unwind-protect
        (progn
          (with-temp-file path (insert "$old: red;"))
          (with-current-buffer module-buffer
            (setq buffer-file-name path)
            (insert "$tone: blue; $-private: red; @mixin paint() {} .nested { $hidden: 1; }")
            (scss2-mode)
            (scss2--root-node)
            (goto-char (point-min)) (search-forward "@mixin")
            (narrow-to-region (- (point) 6) (point-max)))
          (scss2-completion-test--with 'scss "@use 'theme'; .a { color: theme.$|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            ;; A reloaded package must not replace either live buffer's language.
            (let ((scss2-grammar--content-id (make-string 64 ?e))
                  (create (symbol-function 'treesit-parser-create))
                  (state (with-current-buffer module-buffer
                           (list (point-min) (point-max) (point) (buffer-chars-modified-tick)
                                 (treesit-parser-list) buffer-undo-list))))
              (cl-letf (((symbol-function 'treesit-parser-create)
                         (lambda (&rest args)
                           ;; Emacs 30's root lookup calls create even to reuse
                           ;; an existing parser; assert identity, not call count.
                           (let* ((before (treesit-parser-list))
                                  (parser (apply create args)))
                             (should (memq parser before))
                             parser))))
                (should (equal (scss2-completion-test--names) '("$tone")))
                (should (equal state (with-current-buffer module-buffer
                                       (list (point-min) (point-max) (point) (buffer-chars-modified-tick)
                                             (treesit-parser-list) buffer-undo-list))))
                (with-current-buffer module-buffer
                  (save-restriction (widen) (goto-char (point-max)) (insert " $fresh: green;")))
                (should (member "$fresh" (scss2-completion-test--names)))))))
      (kill-buffer module-buffer)
      (delete-directory directory t))))

(ert-deftest scss2-completion-modules-follow-host-language-for-temporary-parsers ()
  (dolist (open '(nil t))
    (let* ((directory (make-temp-file "scss2-module-language-" t))
           (path (expand-file-name "_theme.scss" directory))
           (module (and open (generate-new-buffer " *scss2 other language*"))))
      (unwind-protect
          (progn
            (with-temp-file path (insert "$saved: red;"))
            (when module
              (with-current-buffer module
                (setq buffer-file-name path)
                (insert "$unsaved: blue;")
                ;; An incompatible parser must remain owned by this buffer.
                (css2-mode)
                (goto-char (point-max))
                (narrow-to-region (1- (point)) (point))))
            (scss2-completion-test--with 'scss "@use 'theme'; .a { color: theme.$|; }"
              (setq buffer-file-name (expand-file-name "main.scss" directory))
              (let ((scss2-grammar--content-id (make-string 64 ?e))
                    (language (scss2--language))
                    (create (symbol-function 'treesit-parser-create))
                    (state (and module
                                (with-current-buffer module
                                  (list (point-min) (point-max) (point) (buffer-chars-modified-tick)
                                        (treesit-parser-list) buffer-undo-list))))
                    (created 0))
                (cl-letf (((symbol-function 'scss2-grammar--compile)
                           (lambda (&rest _) (ert-fail "Completion must not compile a grammar")))
                          ((symbol-function 'treesit-parser-create)
                           (lambda (&rest args)
                             (should (eq (car args) language))
                             (let* ((before (treesit-parser-list))
                                    (parser (apply create args)))
                               (unless (memq parser before) (cl-incf created))
                               parser))))
                  (should (equal (scss2-completion-test--names)
                                 (if open '("$unsaved") '("$saved"))))
                  (should (= created 1))
                  (when module
                    (should (equal state (with-current-buffer module
                                           (list (point-min) (point-max) (point) (buffer-chars-modified-tick)
                                                 (treesit-parser-list) buffer-undo-list)))))))))
        (when module (kill-buffer module))
        (delete-directory directory t)))))

(ert-deftest scss2-completion-local-import-path ()
  (let ((directory (make-temp-file "scss2-path-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "theme.scss" directory) (insert ""))
          (scss2-completion-test--with 'scss "@use 'the|'"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (should (member "theme.scss" (scss2-completion-test--names)))))
      (delete-directory directory t))))

(ert-deftest scss2-completion-rejects-directives-in-values ()
  (scss2-completion-test--with 'css ".a { color: @|; }"
    (should-not (scss2-completion-at-point))))

(ert-deftest scss2-completion-nested-tag-pseudo-stays-selector ()
  (scss2-completion-test--with 'css ".a { button:ho| {} }"
    (should (member ":hover" (scss2-completion-test--names)))
    (should-not (member "inherit" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-parsed-selectors-own-their-header ()
  (dolist (dialect '(css scss))
    (dolist (source '(".a { m10| {} }" ".a { m10 | {} }"
                      ".a { m10| > .child {} }"))
      (scss2-completion-test--with dialect source
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (should (eq (plist-get (scss2-context-at-point) :role) 'selector))
        (should-not (plist-get (scss2-context-at-point) :start))))))

(ert-deftest scss2-completion-declarations-inherit-body-capability ()
  (dolist (source '("@media screen { dis| }" "@supports (display: grid) { dis| }"
                    "@layer base { dis| }" "@keyframes pulse { dis| }"))
    (scss2-completion-test--with 'css source
      (should-not (member "display" (scss2-completion-test--names)))))
  (dolist (source '(".a { @media screen { dis| } }"
                    ".a { @layer base { dis| } }" "@font-face { dis| }"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'property))))
  (scss2-completion-test--with 'scss "@function f() { @if true { dis| } }"
    (should-not (member "display" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "@mixin m { @if true { dis| } }"
    (should (member "display: ;" (scss2-completion-test--expansions)))))

(ert-deftest scss2-completion-css-functions-retain-declaration-hosts ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect
        "@function --ink(--value <color>: teal) returns <color> { res| }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'property))
      (should (plist-get (scss2-context-at-point) :start)))
    (scss2-completion-test--with dialect
        "@function --ink(--value <color>: teal) returns <color> { result: |; }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
      (should-not (plist-get (scss2-context-at-point) :start))))
  (scss2-completion-test--with 'scss "@function ink($value: teal) { dis| }"
    (should-not (eq (plist-get (scss2-context-at-point) :role) 'property))))

(ert-deftest scss2-completion-font-feature-descriptor-hosts ()
  (dolist (dialect '(css scss))
    (dolist (directive '("styleset" "stylistic" "character-variant" "swash" "ornaments" "annotation"))
      (scss2-completion-test--with dialect
          (format "@font-feature-values Test { @%s { alt| } }" directive)
        (should (eq (plist-get (scss2-context-at-point) :role) 'property))
        (should (plist-get (scss2-context-at-point) :start))))
    (scss2-completion-test--with dialect "@font-feature-values Test { dis| }"
      (should-not (eq (plist-get (scss2-context-at-point) :role) 'property)))))

(ert-deftest scss2-completion-parsed-identifiers-need-no-text-reparse ()
  (dolist (source '(".a { c\\6flor: re|; }" ".a { c\\6f lor: re|; }"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
      (should (member "red" (scss2-completion-test--names)))))
  (scss2-completion-test--with 'scss ".a { c#{$name}: |; }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
    (should-not (plist-get (scss2-context-at-point) :property))
    (should (member "inherit" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css "@m\\65 dia (prefers-|) {}"
    (should-not (member "prefers-color-scheme" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css "@counter-\\73 tyle x { add| }"
    (should (member "additive-symbols: ;" (scss2-completion-test--expansions)))))

(ert-deftest scss2-completion-qualified-includes-do-not-use-local-parameters ()
  (scss2-completion-test--with 'scss
      "@mixin paint($local) {} @include theme.paint(|);"
    (should (eq (plist-get (scss2-context-at-point) :role) 'argument))
    (should-not (member "$local: " (scss2-completion-test--names)))))

(ert-deftest scss2-completion-query-nesting-preserves-role ()
  (dolist (source '("@supports selector(:ho|) {}"
                    ".a { @supports ((display: grid) and selector(:ho|)) {} }"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'pseudo))
      (should (member ":hover" (scss2-completion-test--names)))))
  (dolist (source '("@container card style(color: re|) {}"
                    "@import url(x.css) supports(display: gr|);"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
      (should (cl-intersection '("red" "grid") (scss2-completion-test--names) :test #'equal))))
  (scss2-completion-test--with 'css "@container card style(--theme: |) {}"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
    (should-not (member "width" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-query-ranges-distinguish-operands ()
  (dolist (source '("@media (width >= 4|) {}" "@media (width >= |) {}"
                    "@media (4|00px < width) {}" "@media (unknown >= 4|) {}"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'media-value))
      (should-not (member "width" (scss2-completion-test--names)))))
  (dolist (source '("@media (400px < wi|) {}" "@media (400px < |) {}"
                    "@media ((width > 2px) and (he|)) {}"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'media-feature)))))

(ert-deftest scss2-completion-mixin-identities-decode-escapes ()
  (dolist (source '("@mixin pa\\69 nt($tone) {} @include paint(|);"
                    "@mixin paint($tone) {} @include pa\\69 nt(|);"))
    (scss2-completion-test--with 'scss source
      (should (equal (plist-get (scss2-context-at-point) :mixin) "paint"))
      (should (member "$tone: " (scss2-completion-test--names))))))

(ert-deftest scss2-completion-query-roles-do-not-depend-on-candidates ()
  (dolist (dialect '(css scss))
    (dolist (source '("@media (device-width > |) {}"
                      "@media (device-width > au|to) {}"
                      "@media (400px < device-width < |) {}"
                      "@media (width > |) {}"))
      (scss2-completion-test--with dialect source
        (let ((scss2-completion--media nil))
          (should (eq (plist-get (scss2-context-at-point) :role) 'media-value)))))
    (scss2-completion-test--with dialect "@media (400px < device-wi|dth) {}"
      (let ((scss2-completion--media nil))
        (should (eq (plist-get (scss2-context-at-point) :role) 'media-feature))))))

(ert-deftest scss2-completion-module-identities-decode-escapes ()
  (let ((directory (make-temp-file "scss2-module-identity-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "_tokens.scss" directory)
            (insert "$tone: red; $\\5f private: blue; @mixin paint() {} @function double() { @return 2; }"))
          (dolist (source '("@use 'tokens' as th\\65 me; .a { color: theme.$to|ne; }"
                            "@use 'tokens' as theme; .a { color: th\\65 me.$to|ne; }"
                            "@use 'tokens' as th\\65 me; .a { color: th\\65 me.$to|ne; }"))
            (scss2-completion-test--with 'scss source
              (setq buffer-file-name (expand-file-name "main.scss" directory))
              (should-not (treesit-node-check (scss2--root-node) 'has-error))
              (should (equal (plist-get (scss2-context-at-point) :module) "theme"))
              (should (member "$tone" (scss2-completion-test--names)))))
          (scss2-completion-test--with 'scss "@use 'tokens' as theme; .a { color: theme.$|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (should-not (member "$\\5f private" (scss2-completion-test--names))))
          (dolist (source '("@use 'tokens' as theme; @include th\\65 me.pa|int();"
                            "@use 'tokens' as th\\65 me; .a { value: theme.do|uble(); }"))
            (scss2-completion-test--with 'scss source
              (setq buffer-file-name (expand-file-name "main.scss" directory))
              (should (equal (plist-get (scss2-context-at-point) :module) "theme"))
              (should (cl-intersection '("paint" "double") (scss2-completion-test--names)
                                       :test #'equal)))))
      (delete-directory directory t))))

(ert-deftest scss2-completion-closed-structures-release-point ()
  (dolist (source '(".a {color:red;|}" ".a {font:{size:1px;}|}"
                    ".a {font:{}|}" ".a {font:{/* inner */}|}"))
    (scss2-completion-test--with 'scss source
      (should (eq (plist-get (scss2-context-at-point) :role) 'property))
      (should-not (scss2-completion-at-point))
      ;; A caller can hold the preceding node even when node-at-point happens
      ;; to return the next token at this boundary.
      (dolist (capture (treesit-query-capture (scss2--root-node)
                                              '((property_declaration) @declaration)))
        (when (= (treesit-node-end (cdr capture)) (point))
          (should-not (scss2-context--containing
                       (cdr capture) '("property_declaration")))))))
  (dolist (source '("@supports(display:grid)|{}" "@media(width>=4px)|{}"
                    "@supports selector(:hover)|{}"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'media-keyword))
      (should (member "and" (scss2-completion-test--names)))))
  (dolist (source '(".a {color:red|;}" "@supports(display:grid|){}"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))))
  (scss2-completion-test--with 'css "@supports(width:calc(1px)|){}"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
    (let ((feature (cdar (treesit-query-capture (scss2--root-node)
                                               '((feature_query) @feature)))))
      (should (scss2-context--containing feature '("feature_query"))))))

(ert-deftest scss2-completion-flat-block-and-pseudo-boundaries ()
  (dolist (dialect '(css scss))
    (dolist (case '((".a { font: { | } color: red; }" property)
                    (".a { font: { /* inner */ | } color: red; }" property)
                    (".a { font: bo|ld { size: 12px; } }" property-value)
                    (".a:is(.b, :not(.c, .d|)) {}" selector)
                    (".a:is(.b, :not(.c, .d))| {}" selector)
                    (".a:is(.b, :not(.c, .d)) { | }" property)))
      (scss2-completion-test--with dialect (car case)
        (should (eq (plist-get (scss2-context-at-point) :role) (cadr case)))))))

(ert-deftest scss2-completion-trailing-comments-preserve-current-slot ()
  (dolist (case '((css "@supports(display:grid /*x*/ |){}" property-value "grid")
                  (css "@media(prefers-color-scheme:dark /*x*/ |){}" media-value "dark")
                  (css "@supports selector(:hover /*x*/ |){}" selector ":hover")
                  (scss "@mixin m($tone) {} @include m($tone:red /*x*/ |);" property-value "inherit")
                  (scss "@mixin m($tone) {} @include m($tone: /*x*/ |);" property-value "inherit")))
    (pcase-let ((`(,dialect ,source ,role ,candidate) case))
      (scss2-completion-test--with dialect source
        (let ((position (point)) (text (buffer-string)))
          (should (eq (plist-get (scss2-context-at-point) :role) role))
          (when (not (eq role 'selector))
            (should (member candidate (scss2-completion-test--names))))
          (should (= position (point)))
          (should (equal text (buffer-string)))))))
  (scss2-completion-test--with 'scss
      "@mixin m($tone) {} @include m($tone:red /*x*/, |);"
    (should (eq (plist-get (scss2-context-at-point) :role) 'argument))
    (should (member "$tone: " (scss2-completion-test--names)))))

(ert-deftest scss2-completion-compound-query-expects-logical-keywords ()
  (dolist (source '("@supports ((display:grid) /*x*/ and |) {}"
                    "@media ((width>1px) /*x*/ or |) {}"
                    "@supports (selector(:hover) /*x*/ |) {}"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (scss2-context-at-point) :role) 'media-keyword))
      (should (member "not" (scss2-completion-test--names)))
      (should-not (member "display" (scss2-completion-test--names))))))

(ert-deftest scss2-completion-unfinished-query-keeps-local-fallback ()
  (scss2-completion-test--with 'css "@media (prefers-color-scheme: da|"
    (should (member "dark" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css ".a { @supports (display: |"
    (should (member "grid" (scss2-completion-test--names)))
    (should-not (plist-get (scss2-context-at-point) :start)))
  (scss2-completion-test--with 'css "@supports selector(:ho|)"
    (should (member ":hover" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-include-arguments-follow-the-tree ()
  (dolist (source '("@mixin paint($tone: red) {} .a { @include paint(rgb(1,2,3), $to|); }"
                    "@mixin paint($tone: red) {} .a { @include paint(rgb(1,2,3), |); }"))
    (scss2-completion-test--with 'scss source
      (should (member "$tone: " (scss2-completion-test--names)))))
  (dolist (source '("@mixin paint($tone: red) {} .a { @include paint($tone: |); }"
                    "@mixin paint($tone: red) {} .a { @include paint(rgb(1,2,|)); }"))
    (scss2-completion-test--with 'scss source
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
      (should-not (member "$tone: " (scss2-completion-test--names))))))

(ert-deftest scss2-completion-explicit-trigger-bypasses-auto-prefix ()
  (dolist (source '("@|" ".a:| {}" ".a { color: var(--|); }"))
    (scss2-completion-test--with 'css source
      (should (eq (plist-get (nthcdr 3 (scss2-completion-at-point)) :company-prefix-length) t))))
  (scss2-completion-test--with 'css ".a { co| }"
    (should-not (plist-get (nthcdr 3 (scss2-completion-at-point)) :company-prefix-length))))

(ert-deftest scss2-completion-missing-path-is-empty ()
  (scss2-completion-test--with 'scss "@use './nonexistent-directory-590761/the|'"
    (should-not (scss2-completion-test--names))))

(ert-deftest scss2-completion-does-not-move-point-or-edit ()
  (scss2-completion-test--with 'scss "$tone: red; .a { color: $|; }"
    (let ((position (point)) (text (buffer-string)) (tick (buffer-chars-modified-tick)))
      (should (member "$tone" (scss2-completion-test--names)))
      (should (= position (point)))
      (should (equal text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick))))))

(ert-deftest scss2-completion-parameters-do-not-leak-from-nested-mixin ()
  (scss2-completion-test--with 'scss "@mixin outer($outer) { @mixin inner($inner) {} color: $|; }"
    (should (member "$outer" (scss2-completion-test--names)))
    (should-not (member "$inner" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-parser-recovery-preserves-callable-parameters ()
  (dolist (source '("@mixin paint($tone) { @if true {} @else if $| } .after {}"
                    "@mixin paint($tone) { color: $|/*c*/; } .after {}"
                    "@mixin paint($tone) { color: $| //c\n; } .after {}"
                    "@mixin paint($tone) { color: $| !important; } .after {}"
                    "@mixin paint($tone) { @each $| in $list {} } .after {}"
                    "@mixin paint($tone) { @each $|/*c*/in $list {} } .after {}"
                    "@mixin paint($tone) { @for $| from 1 through 3 {} } .after {}"
                    "@mixin paint($tone) { @if $| { color: red; } } .after {}"
                    "@mixin paint($tone) { @mixin inner($inner) {} color: $| /*c*/; } .after {}"))
    (scss2-completion-test--with 'scss source
      (should (treesit-node-check (scss2--root-node) 'has-error))
      (should (member "$tone" (scss2-completion-test--names)))
      (should-not (member "$inner" (scss2-completion-test--names))))))

(ert-deftest scss2-completion-unclosed-callables-retain-visible-parameters ()
  (dolist (spec '(("@mixin paint($tone) { color: $|" "$tone")
                  ("@function paint($tone) { @return $|;" "$tone")
                  ("@function paint($tone) { @if true { @return $|;" "$tone")
                  ("@mixin outer($outer) { @mixin inner($inner) { color: $|" "$inner" "$outer")
                  ("@mixin outer($outer) { @mixin inner($inner) {} color: $|" "$outer")
                  ("@mixin closed($hidden) {} @mixin active($shown) { color: $|" "$shown")
                  ("@mixin outer($outer) { @include thing() using ($slot) { color: $|" "$outer" "$slot")
                  ("@mixin outer($outer) { @include thing() using ($slot) {} color: $|" "$outer")
                  ("@mixin paint($tone) { .child { color: $|" "$tone")
                  ("@mixin first($hidden) { color: red } .a { color: $|")
                  (".a { color: $| } @mixin later($future) {")))
    (ert-info ((car spec))
      (scss2-completion-test--with 'scss (car spec)
        (let ((position (point)) (text (buffer-string)) (tick (buffer-chars-modified-tick)))
          (should (equal (sort (scss2-completion-test--names) #'string<) (cdr spec)))
          (should (= (point) position))
          (should (equal (buffer-string) text))
          (should (= (buffer-chars-modified-tick) tick)))))))

(ert-deftest scss2-edit-unclosed-callable-completion-does-not-establish-edit-targets ()
  ;; This contract crosses completion and editing, so exercise the complete mode.
  (dolist (command '(scss2-kill-property scss2-empty-value scss2-duplicate))
    (scss2-completion-test--with 'scss "@mixin paint($tone) { color: $to|;"
      (let ((data (scss2-completion-at-point)))
        (should (member "$tone" (all-completions "$to" (nth 2 data)))))
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (set-mark (point-min))
      (setq mark-active t)
      (let* ((source (buffer-string)) (position (point)) (saved-mark (mark))
             (kill-ring '("previous kill")) (kill-ring-yank-pointer kill-ring))
        (should-error (funcall command) :type 'user-error)
        (should (equal source (buffer-string)))
        (should (= position (point)))
        (should (= saved-mark (mark)))
        (should mark-active)
        (should (equal kill-ring '("previous kill")))
        (should (eq kill-ring-yank-pointer kill-ring))
        (should-not buffer-undo-list)))))

(ert-deftest scss2-completion-unclosed-callable-values-include-parameters-only-in-scss ()
  (dolist (dialect '(scss css))
    (scss2-completion-test--with dialect "@mixin paint($tone) { color: |"
      (should (eq (not (null (member "$tone" (scss2-completion-test--names))))
                  (eq dialect 'scss))))))

(ert-deftest scss2-completion-comment-start-belongs-to-the-preceding-prefix ()
  (dolist (dialect '(css scss))
    (dolist (comment '("/* note */" "// note\n"))
      (scss2-completion-test--with dialect (concat ".a { color: r|" comment "; }")
        (should (member "red" (scss2-completion-test--names)))))
    (dolist (source '(".a { color: r/|* note */; }"
                      ".a { color: r/*| note */; }"
                      ".a { color: r/|/ note\n; }"
                      ".a { color: r//| note\n; }"))
      (scss2-completion-test--with dialect source
        (should-not (scss2-completion-at-point))))))

(ert-deftest scss2-completion-unclosed-blocks-still-complete ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect ".a { dis|"
      (should (member "display: ;" (scss2-completion-test--expansions))))
    (scss2-completion-test--with dialect ".a { display: |"
      (should (member "flex" (scss2-completion-test--names))))))

(ert-deftest scss2-completion-include-named-argument-prefix ()
  (scss2-completion-test--with 'scss "@mixin paint($tone: red) {} .a { @include paint($to|); }"
    (should (member "$tone: " (scss2-completion-test--names)))))

(ert-deftest scss2-completion-selectors-do-not-scan-buffer-names ()
  (dolist (source '(".card {} .ca| {}" "#card {} #ca| {}" "button {} bu| {}"))
    (scss2-completion-test--with 'css source
      (cl-letf (((symbol-function 'scss2-completion--candidates)
                 (lambda (_) (ert-fail "Selector completion must not scan candidates"))))
        (should-not (scss2-completion-at-point))))))

(ert-deftest scss2-completion-css-keywords-ignore-case ()
  (scss2-completion-test--with 'css "@MEDIA (prefers-color-scheme: |) {}"
    (should (member "dark" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css "@SUPPORTS (display: |) {}"
    (should (member "grid" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css ".a { DIS| }"
    (should (member "display: ;" (scss2-completion-test--expansions)))))

(ert-deftest scss2-completion-explicit-module-extension-resolves-partial ()
  (let ((directory (make-temp-file "scss2-module-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "_tokens.scss" directory) (insert "$tone: red;"))
          (scss2-completion-test--with 'scss "@use './tokens.scss'; .a { color: tokens.$|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (should (member "$tone" (scss2-completion-test--names)))))
      (delete-directory directory t))))

(ert-deftest scss2-completion-css-uppercase-property-values ()
  (scss2-completion-test--with 'css ".a { COLOR: |; }"
    (should (member "red" (scss2-completion-test--names))))
  (scss2-completion-test--with 'css "@MEDIA (PREFERS-COLOR-SCHEME: |) {}"
    (should (member "dark" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-css-double-slash-does-not-loop ()
  (scss2-completion-test--with 'css ".a { // text\ndis| }"
    (let ((position (point)))
      (scss2-context-at-point)
      (should (= position (point))))))

(ert-deftest scss2-completion-raw-groups-never-offer-declarations ()
  (dolist (dialect '(css scss))
    (dolist (source '(".a { --raw: { display| }; }" ".a { --raw: { m10| }; }"
                      ".a { --raw: { @| }; }" ".a { --raw: { first; m10| }; }"))
      (scss2-completion-test--with dialect source
        (let ((called nil))
          (cl-letf (((symbol-function 'scss2-emmet-completion-at-point)
                     (lambda () (setq called t) nil)))
            (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
            (should-not (member "display" (scss2-completion-test--names)))
            (should-not called)))))))

(ert-deftest scss2-completion-raw-values-preserve-explicit-expressions ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect ".a { --tone: red; --raw: { var(--|) }; }"
      (should (member "--tone" (scss2-completion-test--names)))))
  (scss2-completion-test--with 'scss "$tone: red; .a { --raw: { #{$to|} }; }"
    (should (member "$tone" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "@function tint() { @return red; } .a { --raw: { #{ti|} }; }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
    (should (member "tint()" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "$tone: red; .a { --raw: { $to| }; }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))))

(ert-deftest scss2-completion-explicit-css-module-keeps-its-extension ()
  (let ((directory (make-temp-file "scss2-css-module-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "tokens.css" directory)
            (insert ".a { --tone: red; }"))
          (with-temp-file (expand-file-name "tokens.scss" directory)
            (insert "$sass-only: red;"))
          (scss2-completion-test--with 'scss "@use './tokens.css'; .a { color: tokens.$|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (should (equal (scss2-completion--module-path "tokens")
                           (expand-file-name "tokens.css" directory)))
            (should-not (scss2-completion-test--names))))
      (delete-directory directory t))))

(ert-deftest scss2-completion-explicit-css-partial-has-no-sass-exports ()
  (let ((directory (make-temp-file "scss2-css-module-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "_tokens.css" directory)
            (insert ".a { content: \"#{\"; }"))
          (with-temp-file (expand-file-name "_tokens.scss" directory)
            (insert "$sass-only: red; @mixin paint() {}"))
          (scss2-completion-test--with 'scss "@use './tokens.css'; .a { @include tokens.|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (should (equal (scss2-completion--module-path "tokens")
                           (expand-file-name "_tokens.css" directory)))
            (should-not (scss2-completion-test--names))))
      (delete-directory directory t))))

(ert-deftest scss2-completion-fuzzy-belongs-to-the-category-style ()
  (dolist (dialect '(css scss))
    (dolist (case '((".a { display: ib|; }" "inline-block")
                    ("@font-face { font-display: sw|; }" "swap")))
      (scss2-completion-test--with dialect (car case)
        (let* ((capf (scss2-completion-at-point))
               (input (buffer-substring-no-properties (car capf) (point)))
               (table (nth 2 capf)))
          ;; The category's default style matches under any global styles.
          (dolist (completion-styles '((basic) (partial-completion) (flex)))
            (should (equal (car (scss2-completion-test--all input table)) (cadr case))))
          ;; Without it the user's own styles decide; the table only lists
          ;; candidates that begin with its input.
          (let ((completion-category-defaults nil) (completion-category-overrides nil))
            (let ((completion-styles '(flex)))
              (should (member (cadr case) (scss2-completion-test--all input table))))
            (let ((completion-styles '(basic)))
              (dolist (name (scss2-completion-test--all input table))
                (should (string-prefix-p input name t)))))
          (should-not (bound-and-true-p emmet2-mode)))))))

(ert-deftest scss2-completion-tables-follow-the-table-protocol ()
  ;; Styles may assume every listed candidate begins with the input.
  (dolist (case '((css ".a { display: fl|; }") (css ".a { display: ib|; }")
                  (scss "$gutter-size: 1px; .a { width: $gutter_s|; }")
                  (css ":root { --tone: red; } .a { color: var(--to|); }")))
    (scss2-completion-test--with (car case) (cadr case)
      (let* ((capf (scss2-completion-at-point))
             (input (buffer-substring-no-properties (car capf) (point)))
             (table (nth 2 capf)))
        (dolist (name (all-completions input table))
          (should (string-prefix-p input name t)))
        (dolist (defaults (list completion-category-defaults nil))
          (dolist (styles '((basic) (partial-completion) (flex) (substring) (emacs22)
                            (partial-completion basic)))
            (let ((completion-category-defaults defaults)
                  (completion-category-overrides nil)
                  (completion-styles styles))
              (ert-info ((format "%S styles=%S defaults=%S" (cadr case) styles (and defaults t)))
                (completion-try-completion input table nil (length input))
                (completion-all-completions input table nil (length input))))))))))

(ert-deftest scss2-completion-shared-values-keep-host-scope-and-docs ()
  (scss2-completion-test--with 'scss "$tone: red; .other { $hidden: blue; } .a { color: |; }"
    (let* ((capf (scss2-completion-at-point))
           (names (all-completions "" (nth 2 capf))))
      (should (member "red" names))
      (should (member "$tone" names))
      (should-not (member "$hidden" names))
      (should-not (member "inline-block" names))))
  (scss2-completion-test--with 'css ".a { display: in|; }"
    (let* ((capf (scss2-completion-at-point))
           (table (nth 2 capf))
           (completion-ignore-case t))
      (should (member "inline-block" (all-completions "in" table)))
      (should (equal (try-completion "in" table) "in"))
      (should-not (test-completion "in" table))
      (should (test-completion "inline-block" table))
      (should (equal (all-completions "in" table (lambda (name) (equal name "inline-block"))) '("inline-block")))
      (should (stringp (funcall (plist-get (nthcdr 3 capf) :company-docsig) "inline-block"))))))

(ert-deftest scss2-completion-mixin-signature-follows-visible-binding ()
  (dolist (source '("@mixin paint($outer) {} .a { @mixin paint($inner) {} @include paint(|); }"
                    "@mixin paint($outer) {} @mixin paint($inner) {} .a { @include paint(|); }"
                    "@mixin paint($inner) {} .a { @include paint(|); @mixin paint($later) {} }"
                    "@mixin paint($inner) {} .other { @mixin paint($hidden) {} } .a { @include paint(|); }"))
    (scss2-completion-test--with 'scss source
      (let ((names (scss2-completion-test--names)))
        (should (member "$inner: " names))
        (dolist (name '("$outer: " "$later: " "$hidden: "))
          (should-not (member name names)))))))

(ert-deftest scss2-completion-sass-equivalent-names-preserve-spelling ()
  (dolist (case '(("@mixin paint-box($tone) {} @include paint_box(|);" "$tone: ")
                  ("@mixin paint_box($tone) {} @include paint-box(|);" "$tone: ")
                  ("$gutter-size: 1px; .a { width: $gutter_s|; }" "$gutter-size")
                  ("$gutter_size: 1px; .a { width: $gutter-s|; }" "$gutter_size")
                  ("@mixin paint-box() {} @include paint_b|;" "paint-box")
                  ("@mixin paint($border-width) {} @include paint($border_w|);" "$border-width: ")))
    (scss2-completion-test--with 'scss (car case)
      (let* ((capf (scss2-completion-at-point)) (table (nth 2 capf))
             (input (buffer-substring-no-properties (car capf) (point)))
             (candidate (cadr case)) (completion-styles '(basic)))
        (should (member candidate (scss2-completion-test--all input table)))
        (should (member candidate (all-completions "" table)))
        (should (test-completion candidate table))
        (should (equal (scss2-completion-test--all
                        input table (lambda (name) (equal name candidate)))
                       (list candidate))))))
  (scss2-completion-test--with 'scss
      "$foo-bar: red; $foo_bar: blue; .a { color: $foo_|; }"
    (let* ((capf (scss2-completion-at-point)) (table (nth 2 capf)))
      (should (equal (sort (scss2-completion-test--all "$foo_" table) #'string-lessp)
                     '("$foo-bar" "$foo_bar")))
      (should (equal (completion-try-completion "$foo_" table nil 5) '("$foo_" . 5)))))
  (scss2-completion-test--with 'scss
      ":root { --foo-bar: red; } .a { color: var(--foo_|); }"
    (should-not (scss2-completion-test--names))))

(ert-deftest scss2-completion-escaped-names-retain-css-fuzzy ()
  (dolist (source '("$foo: 1px; .a { display: ib|; }"
                    "$fo\\6f: 1px; .a { display: ib|; }"
                    "$fo\\6f: 1px; .a { display: i\\62|; }"))
    (scss2-completion-test--with 'scss source
      (let* ((capf (scss2-completion-at-point)) (table (nth 2 capf))
             (input (buffer-substring-no-properties (car capf) (point))))
        ;; The category style decodes the query, whatever the global styles.
        (dolist (completion-styles '((basic) (partial-completion) (flex)))
          (ert-info ((format "source=%s style=%s" source completion-styles))
            (should (equal (car (scss2-completion-test--all input table))
                           "inline-block"))))
        (should (equal (scss2-completion-test--all
                        input table (lambda (name) (equal name "inline-block")))
                       '("inline-block")))))))

(ert-deftest scss2-completion-escaped-include-name-uses-syntax-field ()
  (dolist (source '("@mixin paint($tone) {} @include pa\\69|;"
                    "@mixin paint($tone) {} @include pa\\69 nt|;"
                    "@mixin paint($tone) {} @include /* name */ pa\\69|;"))
    (scss2-completion-test--with 'scss source
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (should (eq (plist-get (scss2-context-at-point) :role) 'mixin))
      (should (member "paint" (scss2-completion-test--names))))))

(ert-deftest scss2-completion-module-alias-uses-unsaved-source ()
  (let* ((directory (make-temp-file "scss2-module-alias-" t))
         (path (expand-file-name "_tokens.scss" directory))
         (alias (expand-file-name "_alias.scss" directory)) module)
    (unwind-protect
        (progn
          (with-temp-file path (insert "$saved: red;"))
          (make-symbolic-link path alias)
          (setq module (find-file-noselect path))
          (with-current-buffer module
            (scss2-mode)
            (erase-buffer) (insert "$unsaved: blue;"))
          (scss2-completion-test--with 'scss "@use 'alias'; .a { color: alias.$|; }"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (let ((create (symbol-function 'treesit-parser-create)))
              (cl-letf (((symbol-function 'treesit-parser-create)
                         (lambda (&rest args)
                           ;; Emacs 30 also calls create to retrieve an existing parser.
                           (let* ((before (treesit-parser-list))
                                  (parser (apply create args)))
                             (should (memq parser before))
                             parser))))
                (should (equal (scss2-completion-test--names) '("$unsaved")))))))
      (when (buffer-live-p module)
        (with-current-buffer module (set-buffer-modified-p nil))
        (kill-buffer module))
      (delete-directory directory t))))

(ert-deftest scss2-completion-descriptor-values-share-emmet-membership ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect "@property --x { inherits: |; }"
      (should (equal (scss2-completion-test--names) '("env()" "false" "true"))))
    (scss2-completion-test--with dialect "@property --x { inheritsI| }"
      (should-not (member "inherits: inherit;" (scss2-completion-test--expansions)))
      (should-not (member "inherits: initial;" (scss2-completion-test--expansions))))
    (scss2-completion-test--with dialect "@counter-style x { symbols: |; }"
      (let ((names (scss2-completion-test--names)))
        (should (member "linear-gradient()" names))
        (should (member "env()" names))
        (should-not (member "inherit" names))
        (should-not (member "var()" names))))))

(defmacro scss2-completion-test--with-module (source &rest body)
  "Evaluate BODY at | in SOURCE beside a local `_theme.scss' module."
  (declare (indent 1) (debug t))
  `(let ((directory (make-temp-file "scss2-theme-" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "_theme.scss" directory)
             (insert "$tone: red; @mixin paint() {} @function double($n) { @return $n * 2; }"))
           (scss2-completion-test--with 'scss ,source
             (setq buffer-file-name (expand-file-name "main.scss" directory))
             ,@body))
       (delete-directory directory t))))

(ert-deftest scss2-completion-literal-tokens-are-not-value-names ()
  (dolist (dialect '(css scss))
    (dolist (source '(".a { color: #eee| }" ".a { color: #ac|e; }" ".a { color: #| }"
                      ".a { color: red !imp| }" ".a { color: red !|; }"
                      ".a { color: red !important|; }"))
      (scss2-completion-test--with dialect source
        (should-not (scss2-completion-at-point)))))
  ;; Abbreviations keep their own meaning for the same characters.
  (scss2-completion-test--with 'css ".a { c#f| }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property))))

(ert-deftest scss2-completion-module-members-follow-their-qualifier ()
  (dolist (source '("@use 'theme'; .a { width: theme.|; }"
                    "@use 'theme'; .a { width: theme.d|; }"
                    "@use 'theme'; .a { width: theme.dou|; }"
                    "@use 'theme' as t; .a { width: t.do|; }"
                    "@use 'theme'; @function f() { @return theme.do|; }"))
    (scss2-completion-test--with-module source
      (should (eq (plist-get (scss2-context-at-point) :role) 'module-member))
      (let ((names (scss2-completion-test--names)))
        (should (member "double" names))
        ;; A value reads functions and variables, never mixins or CSS values.
        (should-not (member "paint" names))
        (should-not (member "darkred" names)))))
  (dolist (source '("@use 'theme'; .a { @include theme.|; }"
                    "@use 'theme'; @mixin local() {} .a { @include theme.pa|; }"))
    (scss2-completion-test--with-module source
      (should (eq (plist-get (scss2-context-at-point) :role) 'mixin))
      (should (equal (scss2-completion-test--names) '("paint"))))))

(ert-deftest scss2-completion-sass-expressions-take-values ()
  (dolist (source '("@function tint() { @return 1; } @function f() { @return ti|; }"
                    "@function tint() { @return 1; } @function f() { @return 1 + ti|; }"
                    "@function tint() { @return 1; } @if ti| { .a { x: 1; } }"
                    "@function tint() { @return 1; } @debug ti|;"
                    "@function tint() { @return 1; } @each $x in ti| {}"
                    "@function tint() { @return 1; } @mixin m($a: ti|) {}"))
    (scss2-completion-test--with 'scss source
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
      (should (member "tint()" (scss2-completion-test--names)))))
  (dolist (source '("@mixin m($tone:| red) {}" "@mixin m($tone: |) {}"))
    (scss2-completion-test--with 'scss source
      (should-not (member ":hover" (scss2-completion-test--names)))))
  ;; A plain directive prelude is still not a completion site.
  (dolist (source '("@keyframes sp| {}" "@mixin pa|() {}" "@layer ba|;"))
    (scss2-completion-test--with 'scss source
      (should-not (scss2-completion-at-point)))))

(ert-deftest scss2-completion-declaration-above-a-nested-rule-is-a-value ()
  (dolist (dialect '(css scss))
    (dolist (source '(".a {\n  display: |\n  .b { x: y; }\n}"
                      ".a {\n  display: fl|\n  .b { x: y; }\n}"))
      (scss2-completion-test--with dialect source
        (should (eq (plist-get (scss2-context-at-point) :role) 'property-value))
        (should (equal (plist-get (scss2-context-at-point) :property) "display"))
        (should (member "flex" (scss2-completion-test--names)))))
    ;; A pseudo-class has no blank after its colon.
    (scss2-completion-test--with dialect ".a {\n  a:ho|\n  .b { x: y; }\n}"
      (should (eq (plist-get (scss2-context-at-point) :role) 'pseudo)))))

(ert-deftest scss2-completion-directives-follow-their-surroundings ()
  (scss2-completion-test--with 'scss ".a { @if true { x: 1; } @el| }"
    (should (member "@else" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss ".a { @if true { x: 1; } @else if $y { x: 2; } @el| }"
    (should (member "@else" (scss2-completion-test--names))))
  (dolist (source '(".a { @if true { x: 1; } @else { x: 2; } @el| }" ".a { x: 1; @el| }"))
    (scss2-completion-test--with 'scss source
      (should-not (member "@else" (scss2-completion-test--names)))))
  ;; Unclosed callables still name what their body may contain.
  (scss2-completion-test--with 'scss "@function f() {\n  @if true {\n    @ret|"
    (should (member "@return" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "@mixin m() {\n  @con|"
    (should (member "@content" (scss2-completion-test--names))))
  (scss2-completion-test--with 'scss "@mixin m { @function f() { @| } }"
    (should (member "@return" (scss2-completion-test--names)))
    (should-not (member "@content" (scss2-completion-test--names))))
  ;; A definition is not its own enclosing scope.
  (scss2-completion-test--with 'scss "@mix|in paint() { x: 1; }"
    (should-not (member "@content" (scss2-completion-test--names)))))

(ert-deftest scss2-completion-variables-are-offered-only-where-bound ()
  (dolist (case '(("$list: 1; @each $item in $| {}" ("$list"))
                  ("$list: 1; @each $item in $li| {}" ("$list"))
                  ("$n: 3; @for $i from 1 through $| {}" ("$n"))
                  ;; An argument slot names the mixin's parameters instead.
                  ("@mixin m($a) {} .a { @include m($|) using ($slot) { x: 1; } }" ("$a: "))
                  ("$x: $|;" nil)
                  ("@mixin m($a, $b: $|) {}" ("$a"))
                  ("$list: 1; @each $item in $list { a: $| }" ("$item" "$list"))
                  ("@mixin m($a) {} .a { @include m(1) using ($slot) { x: $| } }" ("$slot"))))
    (scss2-completion-test--with 'scss (car case)
      (ert-info ((car case))
        (should (equal (sort (scss2-completion-test--names) #'string<) (cadr case)))))))

(ert-deftest scss2-completion-media-types-belong-to-media-queries ()
  (dolist (source '("@media |" "@media scr| {}" "@media (width > 1px) |{}"))
    (scss2-completion-test--with 'css source
      (should (equal (plist-get (scss2-context-at-point) :query) "@media"))
      (should (member "screen" (all-completions "" (nth 2 (scss2-completion-at-point)))))))
  (dolist (source '("@supports |" "@container card |" "@supports (display: grid) |{}"))
    (scss2-completion-test--with 'css source
      (let ((names (all-completions "" (nth 2 (scss2-completion-at-point)))))
        (should (member "and" names))
        (should-not (member "screen" names))))))

(ert-deftest scss2-completion-import-paths-offer-sass-load-names ()
  (let ((directory (make-temp-file "scss2-load-name-" t)))
    (unwind-protect
        (progn
          (dolist (file '("_theme.scss" "tokens.scss" "plain.css"))
            (with-temp-file (expand-file-name file directory) (insert "")))
          (scss2-completion-test--with 'scss "@use 'th|'"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (should (equal (scss2-completion-test--names) '("theme"))))
          (scss2-completion-test--with 'scss "@use '|'"
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (let ((names (scss2-completion-test--names)))
              (dolist (name '("theme" "_theme.scss" "tokens" "tokens.scss" "plain.css"))
                (should (member name names)))
              (should-not (member "plain" names))))
          ;; A CSS import names the file itself.
          (scss2-completion-test--with 'css "@import 'to|'"
            (setq buffer-file-name (expand-file-name "main.css" directory))
            (should (equal (scss2-completion-test--names) '("tokens.scss")))))
      (delete-directory directory t))))

(ert-deftest scss2-completion-style-keeps-the-text-after-point ()
  ;; Completing inside a name never repeats what already follows point.
  (dolist (case '((css ".a { font-weight: bol|d; }" ".a { font-weight: bold; }")
                  (css ".a { transform: ro|tate(1deg); }" ".a { transform: rotate(1deg); }")
                  (scss "$size: 1; $sizes: 2; .a { width: |$size; }"
                        "$size: 1; $sizes: 2; .a { width: $size; }")
                  (css ":root { --card-a: 1; --card-b: 2; } .a { gap: var(--|card-a); }"
                       ":root { --card-a: 1; --card-b: 2; } .a { gap: var(--card-a); }")
                  (scss "@mixin btn-a {} @mixin btn-b {} .a { @include b|tn-a; }"
                        "@mixin btn-a {} @mixin btn-b {} .a { @include btn-a; }")
                  (css "@media (pre|fers-color-scheme: dark) {}"
                       "@media (prefers-color-scheme: dark) {}")
                  (scss "$primary: 1; .a { width: $pri|zzz; }"
                        "$primary: 1; .a { width: $primaryzzz; }")))
    (scss2-completion-test--with (car case) (nth 1 case)
      (let ((capf (scss2-completion-at-point))
            (completion-auto-help nil) (completion-cycle-threshold nil))
        (ert-info ((nth 1 case))
          (completion-in-region (nth 0 capf) (nth 1 capf) (nth 2 capf))
          (should (equal (buffer-string) (nth 2 case)))))))
  ;; Text after point narrows the candidates it must still contain.
  (scss2-completion-test--with 'css ".a { display: fl|ex; }"
    (let ((names (scss2-completion-test--all "flex" (nth 2 (scss2-completion-at-point)))))
      (ignore names))
    (let* ((capf (scss2-completion-at-point))
           (all (completion-all-completions "flex" (nth 2 capf) nil 2)))
      (setcdr (last all) nil)
      (should (member "flex" all))
      (should-not (member "flow" all)))))

(ert-deftest scss2-completion-style-marks-its-matches ()
  (scss2-completion-test--with 'css ".a { display: ib|; }"
    (let* ((completion-lazy-hilit nil)
           (name (car (scss2-completion-test--names))))
      (should (equal name "inline-block"))
      (should (eq (get-text-property 0 'face name) 'completions-common-part))
      (should-not (get-text-property 1 'face name)))))

(ert-deftest scss2-completion-tables-never-fold-case-by-themselves ()
  ;; A style that lists through the table must find what it then verifies.
  (dolist (source '(".a { color: b|; }" ".a { display: FL|; }" "@media (MIN|) {}"))
    (scss2-completion-test--with 'css source
      (let* ((capf (scss2-completion-at-point))
             (input (buffer-substring-no-properties (car capf) (point))))
        (dolist (styles '((partial-completion basic) (initials) (basic) (flex)))
          (let ((completion-category-defaults nil) (completion-category-overrides nil)
                (completion-styles styles))
            (ert-info ((format "%S %S" source styles))
              (completion-try-completion input (nth 2 capf) nil (length input))
              (completion-all-completions input (nth 2 capf) nil (length input)))))))))

(ert-deftest scss2-completion-import-conditions-are-media-queries ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect "@import \"a.css\" scr|;"
      (should (equal (scss2-completion-test--names) '("screen"))))))

(ert-deftest scss2-completion-unclosed-blocks-keep-module-and-conditional ()
  (dolist (case '(("@use 'theme';\n.a {\n  @include theme.|" mixin "paint")
                  ("@use 'theme';\n.a {\n  width: 1px;\n  color: theme.|" module-member "double")
                  ("@use 'theme';\n@function f() { @return theme.|" module-member "double")))
    (scss2-completion-test--with-module (car case)
      (should (eq (plist-get (scss2-context-at-point) :role) (nth 1 case)))
      (should (equal (plist-get (scss2-context-at-point) :module) "theme"))
      (should (member (nth 2 case) (scss2-completion-test--names)))))
  ;; Only a declared namespace is read from text the parser dropped.
  (dolist (source '(".a { m1.|" ".a { div.|"))
    (scss2-completion-test--with-module (concat "@use 'theme'; " source)
      (should-not (plist-get (scss2-context-at-point) :module))))
  (dolist (source '(".c {\n  @if a { x: y; } @else|" ".c {\n  @if a { x: y; } @els|"))
    (scss2-completion-test--with 'scss source
      (should (member "@else" (scss2-completion-test--names))))))

(ert-deftest scss2-completion-bindings-being-written-are-not-bound ()
  (dolist (case '(("$a: 1;\n.x { $b: | }" ("$a"))
                  ("$a: 1;\n.x { $b: 1 + | }" ("$a"))
                  ("@mixin m($a, $b: |) { }" ("$a"))
                  ("$a: 1; $b: 2;\n.x { y: | }" ("$a" "$b"))))
    (scss2-completion-test--with 'scss (car case)
      (ert-info ((car case))
        (should (equal (sort (cl-remove-if-not
                              (lambda (name) (string-prefix-p "$" name))
                              (all-completions "" (nth 2 (scss2-completion-at-point))))
                             #'string<)
                       (cadr case)))))))

(ert-deftest scss2-completion-nested-defaults-and-parenthesized-tests-take-values ()
  (dolist (source '("@function tint() { @return 1; } @function f() { @return(ti|); }"
                    "@function tint() { @return 1; } @if(ti|) { .a { x: 1; } }"
                    "@function tint() { @return 1; } @mixin m($c: darken(ti|)) {}"
                    "@function tint() { @return 1; } @mixin m($c: darken(red, ti|)) {}"))
    (scss2-completion-test--with 'scss source
      (should (member "tint()" (scss2-completion-test--names))))))

(ert-deftest scss2-completion-values-share-native-matching-and-function-fields ()
  (dolist (dialect '(css scss))
    (scss2-completion-test--with dialect ".a { display: if|; }"
      (let ((host-names (scss2-completion-test--names)))
        (should (equal (car host-names) "inline-flex"))
        (with-temp-buffer
          (css-mode) (insert ".a { display: if") (emmet2-mode 1)
          (require 'emmet2-css-value)
          (should (equal host-names
                         (scss2-completion-test--all "if" (nth 2 (emmet2-css-value-capf))))))))
    (scss2-completion-test--with dialect ".a { width: cal|; }"
      (let* ((capf (scss2-completion-at-point))
             (exit (plist-get (nthcdr 3 capf) :exit-function)))
        (delete-region (car capf) (cadr capf)) (insert "calc()")
        (funcall exit "calc()" 'finished)
        (should (equal (buffer-string) ".a { width: calc(); }"))
        (should (looking-at ");"))))
    (scss2-completion-test--with dialect ".a { width: cal|c(1rem); }"
      (should (member "calc" (scss2-completion-test--names)))
      (should-not (member "calc()" (scss2-completion-test--names))))))

(provide 'scss2-completion-test)
;;; scss2-completion-test.el ends here
