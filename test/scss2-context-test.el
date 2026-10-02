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

(provide 'scss2-context-test)
;;; scss2-context-test.el ends here
