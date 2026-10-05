;;; scss2-context-test.el --- Context contracts without candidate catalogs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'scss2-context)
(require 'scss2-test-support)

(ert-deftest scss2-context-identifies-language-slots ()
  (dolist (case '((".a { dis│ }" property nil)
                  (".a { display: fl│; }" property-value "display")
                  (".a:ho│ {}" pseudo nil)
                  ("@me│" at-rule nil)
                  ("@media (width: au│) {}" media-value "width")
                  ("@media (prefers-co│) {}" media-feature "prefers-co")
                  (".a { color: var(--to│); }" custom-property "color")
                  ("@import 'the│';" path nil)
                  (".a { --raw: { nested: x│ }; }" property-value "--raw")
                  (".a { color /* x */: re│d; }" property-value "color")
                  (".a { p[1px 2px]│ }" property nil)
                  (".a { a[title='x']│ }" selector nil)
                  (".a { a[x='(']│ }" selector nil)
                  (".a { bgi[url(a.png?x=1)]│ }" property nil)
                  (".a { ct['a=b']│ }" property nil)
                  ;; Strings, calls and nested brackets in a bracket value balance their own `]'.
                  (".a { ct[']']│ }" property nil)
                  (".a { gtc[[a] 1fr]│ }" property nil)
                  (".a { ct['x'] b│ }" selector nil)
                  ;; Without auto-pairing, unclosed calls and groups are the typing state.
                  (".a { color: var(--to│; }" custom-property "color")
                  (".a {\n  color: var(--to│\n  top: 0;\n}" custom-property "color")
                  (".a {\n  left: anchor(le│\n  top: 0;\n}" property-value "left")
                  ("@media (max-w│ {\n}" media-feature nil)
                  ("@media screen and (max-w│ {\n}" media-feature nil)
                  ("@media (prefers-color-scheme: │ {\n}" media-value "prefers-color-scheme")
                  ("@supports not (display: │ {\n}" property-value "display")))
    (dolist (mode '(css2-mode scss2-mode))
      (scss2-test-with-buffer mode (car case)
        (let ((context (scss2-context-at-point)))
          (should (eq (plist-get context :role) (cadr case)))
          (should (equal (plist-get context :property) (nth 2 case))))))))

(ert-deftest scss2-context-distinguishes-sass-from-css ()
  (scss2-test-with-buffer 'scss2-mode ".a { color: #{$to│}; }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'variable)))
  (scss2-test-with-buffer 'css2-mode ".a { content: \"#{$to│}\"; }"
    (should-not (scss2-context-at-point)))
  (scss2-test-with-buffer 'scss2-mode "@mixin m($tone) { @include pa│; }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'mixin)))
  ;; A top-level variable declaration needs no block to own its value.
  (dolist (case '(("$t: var(--to│\n.a {}" custom-property "$t")
                  ("$t: rhythm(3│\n.a {}" property-value "$t")
                  ("│\n.a {}" selector nil)
                  ("$│" variable nil)))
    (scss2-test-with-buffer 'scss2-mode (car case)
      (let ((context (scss2-context-at-point)))
        (should (eq (plist-get context :role) (cadr case)))
        (should (equal (plist-get context :property) (nth 2 case)))))))

(ert-deftest scss2-context-unclosed-var-after-a-declaration-expansion ()
  ;; Emmet leaves `prop: ;' with point before the semicolon.
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-test-with-buffer mode ".a {\n  background: │;\n}"
      (dolist (char (string-to-list "var(--x"))
        (insert char)
        (let ((context (scss2-context-at-point)))
          (should (eq (plist-get context :role)
                      (if (looking-back "(--x?" (line-beginning-position))
                          'custom-property 'property-value)))
          (should (equal (plist-get context :property) "background")))))))

(ert-deftest scss2-context-query-groups-without-statement-text-recovery ()
  ;; Only @media, @container and @supports headers have statement-text recovery.
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (case '(("@import url(a.css) screen and (max-width:│;" pseudo)
                    ("@import url(│ {" nil)))
      (scss2-test-with-buffer mode (car case)
        (should (eq (plist-get (scss2-context-at-point) :role) (cadr case))))))
  (scss2-test-with-buffer 'scss2-mode ".a { padding: if(sass(tr│ue): 1px); }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'media-keyword))))

(ert-deftest scss2-context-font-lock-dont-widen-reads-the-restriction ()
  ;; Host text outside a code block's restriction is not stylesheet syntax.
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (host '("<p>see a/*b</p>" "<p>Don't panic</p>"
                    "<template><p>Plain text</p></template>"))
      (scss2-test-with-buffer mode (concat host "\n<style>\n.a { color: r│ }\n</style>\n")
        (setq-local font-lock-dont-widen t)
        (narrow-to-region (save-excursion (search-backward ".a")) (line-end-position))
        (ert-info ((format "%s after %S" mode host))
          (let ((context (scss2-context-at-point)))
            (should (eq (plist-get context :role) 'property-value))
            (should (equal (plist-get context :property) "color"))
            (should-not (plist-get context :at-rule))))))))

(ert-deftest scss2-context-keeps-literals-opaque ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '("/* co│lor */" ".a { content: \"co│lor\"; }"))
      (scss2-test-with-buffer mode source
        (should-not (scss2-context-at-point))))))

(ert-deftest scss2-context-recovers-incomplete-input-without-changing-source ()
  (dolist (source '(".a { dis│" "@mixin m($tone) { dis│"))
    (scss2-test-with-buffer 'scss2-mode source
      (let ((text (buffer-string)) (position (point))
            (tick (buffer-chars-modified-tick)))
        (dotimes (_ 2)
          (should (eq (plist-get (scss2-context-at-point) :role) 'property)))
        (should (equal text (buffer-string)))
        (should (= position (point)))
        (should (= tick (buffer-chars-modified-tick)))))))

(ert-deftest scss2-context-respects-narrowed-replacement-bounds ()
  (scss2-test-with-buffer 'css2-mode ".a { display: fl│ex; }"
    (let ((context (scss2-context-at-point)))
      (should (equal (buffer-substring-no-properties
                      (plist-get context :beg) (plist-get context :end)) "flex"))
      (narrow-to-region (plist-get context :beg) (point))
      (should-not (scss2-context-at-point)))))

(ert-deftest scss2-context-unclosed-loops-inherit-their-callable-body ()
  (scss2-test-with-buffer 'scss2-mode "@mixin m($tone) { @each $item in red { dis│"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property)))
  (scss2-test-with-buffer 'scss2-mode "@function f($tone) { @each $item in red { dis│"
    (should-not (eq (plist-get (scss2-context-at-point) :role) 'property))))

(ert-deftest scss2-context-declaration-before-a-separated-nested-rule ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (input '("o" "opacity" "o." "o.5" "m-" "m-.5" "c#fff" "m10+p20" "m10,p20"
                    "p[1px]" "p[1px 2px]" "w[calc(100% - 2rem)]" "ff['Open Sans']"
                    "ct['foo.bar']" "ct['>']" "ct['a=b']" "bgi[url(a.png?x=1)]"
                    "ct[']']" "bgi[url(a]b.png)]" "gtc[repeat(2, [a] 1fr)]"))
      (scss2-test-with-buffer mode
          (concat ".appShell { overflow: hidden; " input
                  "│\n\n  &[data-is-resizing] { cursor: col-resize; }\n}")
        (let ((context (scss2-context-at-point)))
          (should (eq (plist-get context :role) 'property))
          (should (equal (buffer-substring-no-properties (plist-get context :start) (point)) input)))))
    (dolist (source '(".a { opa│city  \n  \n .b {} }" ".a { opa│city\r\n\r\n .b {} }"))
      (scss2-test-with-buffer mode source
        (should (eq (plist-get (scss2-context-at-point) :role) 'property))))))

(ert-deftest scss2-context-declaration-before-an-adjacent-nested-rule ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (input '("m" "m10" "display" "o.5" "m-.5" "c#fff" "m10+p20" "m10,p20"
                    "p[1px]" "p[1px 2px]" "w[calc(100% - 2rem)]" "ff['Open Sans']"
                    "ct['foo.bar']" "ct['>']" "ct['a=b']" "bgi[url(a.png?x=1)]"
                    "ct[']']" "bgi[url(a]b.png)]" "gtc[repeat(2, [a] 1fr)]"))
      (dolist (following '("&[data-is-resizing]" ".child" "button:hover"))
        (scss2-test-with-buffer mode
            (concat ".a {\n  text-align: center;\n  " input "│\n  " following " {}\n}")
          (let ((context (scss2-context-at-point)))
            (should (eq (plist-get context :role) 'property))
            (should (equal (buffer-substring-no-properties (plist-get context :start) (point)) input))))))
    (dolist (source '(".a { color: red;\n  opa│city\n  &[x] {} }"
                      ".a { color: red; /* note */\n  m│\n  &[x] {} }"
                      ".a { color: red;\n  /* note */\n  m│\n  &[x] {} }"
                      ".a { color: red;\r\n\tm10│\r\n\t&[x] {} }"))
      (scss2-test-with-buffer mode source
        (should (eq (plist-get (scss2-context-at-point) :role) 'property)))))
  (scss2-test-with-buffer 'scss2-mode ".a { $gap: 1rem;\n  m│\n  &[x] {} }"
    (should (eq (plist-get (scss2-context-at-point) :role) 'property))))

(ert-deftest scss2-context-glued-sass-variables-continue-an-abbreviation ()
  (dolist (source '(".a {\n  p$a$b$c│\n}" ".a { color: red;\n  p$a$b$c│\n}"
                    ".a { color: red;\n  p$a$b$c│\n  &[x] {} }"
                    ".a { color: red; p$a$b$c│\n\n  &[x] {} }"))
    (scss2-test-with-buffer 'scss2-mode source
      (let ((context (scss2-context-at-point)))
        (should (eq (plist-get context :role) 'property))
        (should (equal (buffer-substring-no-properties (plist-get context :start) (point))
                       "p$a$b$c")))))
  (dolist (source '(".a { color: $a│; }" ".a { color: -$a│; }" ".a { color: #{$a│}; }"))
    (scss2-test-with-buffer 'scss2-mode source
      (should (eq (plist-get (scss2-context-at-point) :role) 'variable)))))

(ert-deftest scss2-context-adjacent-rule-recovery-preserves-selector-syntax ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (selector '(".card" "#main" "&" "a[href]" "a[title='x']" "a[x='(']" "div.card"
                        "div.éclair" "div.\\61" "svg|path" "div>span" "div~span"))
      (dolist (position '(1 nil))
        (let ((offset (or position (length selector))))
          (scss2-test-with-buffer mode
              (concat ".a {\n  color: red;\n  " (substring selector 0 offset) "│"
                      (substring selector offset) "\n  &[x] {}\n}")
            (should (eq (plist-get (scss2-context-at-point) :role) 'selector))))))
    (dolist (source '(".a { color: red;\n  div│\n  > .child {} }"
                      ".a { color: red;\n  div│\n  + .child {} }"
                      ".a { color: red;\n  div│\n  ~ .child {} }"
                      ".a { color: red;\n  div│\n  /* continuation */ > .child {} }"
                      ".a { color: red;\n  div│ {} }"
                      ".a { color: red; m10│\n  &[x] {} }"
                      ".a { .previous {}\n  div│\n  .child {} }"
                      ".a { @media screen {}\n  div│\n  .child {} }"
                      ".a { div│\n  .child {} }"))
      (scss2-test-with-buffer mode source
        (should (eq (plist-get (scss2-context-at-point) :role) 'selector))))
    (scss2-test-with-buffer mode ".a { color: red;\n  a:ho│\n  &[x] {} }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'pseudo)))
    (scss2-test-with-buffer mode ".a { color: red\n  m10│\n  &[x] {} }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'property-value)))))

(ert-deftest scss2-context-adjacent-declaration-incremental-matches-fresh ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-test-with-buffer mode ".a {\n  color: red;\n  │\n  &[x] {}\n}"
      (should (eq (plist-get (scss2-context-at-point) :role) 'property))
      (dolist (event '(?m ?1 ?0 delete delete delete ?. ?c delete delete ?m ?1))
        (if (eq event 'delete) (delete-char -1) (insert event))
        (let* ((source (buffer-string)) (position (point))
               (context (scss2-context-at-point)))
          (should (eq (plist-get context :role)
                      (if (string-match-p "\n  \\.c?\n" source) 'selector 'property)))
          (with-temp-buffer
            (insert source) (scss2-test-setup-buffer mode) (goto-char position)
            (should (equal (scss2-context-at-point) context)))))
      (let ((context (scss2-context-at-point)))
        (narrow-to-region (line-beginning-position) (point-max))
        (should (equal (scss2-context-at-point) context))))))

(ert-deftest scss2-context-separated-rule-recovery-preserves-selectors ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (source '(".a { m10│ {} }" ".a { m10│ > .child {} }"
                      ".a { m10│\n  > .child {} }" ".a { div│\n  .child {} }"
                      ".a { div│\n\n  {} }" ".a { .card│\n\n  .child {} }"
                      ".a { #main│\n\n  .child {} }" ".a { &│\n\n  .child {} }"
                      "div│\n\n.child {}" "@media screen { div│\n\n.child {} }"))
      (scss2-test-with-buffer mode source
        (should (eq (plist-get (scss2-context-at-point) :role) 'selector))))
    (scss2-test-with-buffer mode ".a { a:ho│\n\n  .child {} }"
      (should (eq (plist-get (scss2-context-at-point) :role) 'pseudo)))))

(ert-deftest scss2-context-separated-rule-recovery-preserves-compound-selectors ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (selector '("a[href]" "a[title='x']" "a[x='(']" "div.card" "div.éclair" "div.🌟"
                        "div._card" "div.-card" "div.\\61" "svg|path" "div>span" "div~span"))
      (dolist (position '(1 nil))
        (let ((offset (or position (length selector))))
          (scss2-test-with-buffer mode
              (concat ".a { " (substring selector 0 offset) "│"
                      (substring selector offset) "\n\n.child {} }")
            (ert-info ((format "%s: %s at %s" mode selector offset))
              (should-not (treesit-node-check (scss2--root-node) 'has-error))
              (should (eq (plist-get (scss2-context-at-point) :role) 'selector)))))))))

(provide 'scss2-context-test)
;;; scss2-context-test.el ends here
