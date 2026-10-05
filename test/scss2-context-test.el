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
                  (".a { --raw: { nested: x│ }; }" property-value "--raw")))
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
    (should (eq (plist-get (scss2-context-at-point) :role) 'mixin))))

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
                    "p[1px]" "w[calc(100%-2rem)]" "ct['foo.bar']" "ct['>']"))
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
                    "p[1px]" "w[calc(100%-2rem)]" "ct['foo.bar']" "ct['>']"))
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

(ert-deftest scss2-context-adjacent-rule-recovery-preserves-selector-syntax ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (selector '(".card" "#main" "&" "a[href]" "div.card" "div.éclair"
                        "div.\\61" "svg|path" "div>span" "div~span"))
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
    (dolist (selector '("a[href]" "div.card" "div.éclair" "div.🌟" "div._card"
                        "div.-card" "div.\\61" "svg|path" "div>span" "div~span"))
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
