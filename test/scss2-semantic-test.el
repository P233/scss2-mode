;;; scss2-semantic-test.el --- Semantic tables without host composition -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'scss2-completion)
(require 'scss2-test-support)

(ert-deftest scss2-semantic-completes-an-explicit-value-context ()
  (scss2-test-with-buffer 'css2-mode ".a { display: ib│; }"
    (let* ((begin (- (point) 2))
           (capf (scss2-completion-for-context
                  (list :role 'property-value :property "display" :beg begin :end (point))))
           (candidates (completion-all-completions "ib" (nth 2 capf) nil 2)))
      (should (= (car capf) begin))
      (should (member "inline-block" (progn (setcdr (last candidates) nil) candidates)))
      (should (plist-get (nthcdr 3 capf) :exclusive))
      (let* ((annotate (plist-get (nthcdr 3 capf) :annotation-function))
             (other (scss2-completion-for-context
                     (list :role 'property-value :property "color" :beg begin :end (point))))
             (other-annotation (plist-get (nthcdr 3 other) :annotation-function)))
        (should (equal (funcall annotate "inline-block") "  display"))
        (should (equal (funcall other-annotation "red") "  color"))
        (should (equal (funcall annotate "block") "  display")))
      (should (equal (buffer-string) ".a { display: ib; }")))))

(ert-deftest scss2-semantic-reads-bindings-from-the-current-parser ()
  (scss2-test-with-buffer 'scss2-mode "$global: red; @mixin m($tone) { color: $│; }"
    (let* ((capf (scss2-completion-for-context
                  (list :role 'variable :beg (1- (point)) :end (point))))
           (names (all-completions "$" (nth 2 capf))))
      (should (member "$global" names))
      (should (member "$tone" names))
      (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function) "$tone")
                     "  variable")))))

(ert-deftest scss2-semantic-leaves-abbreviations-to-composition ()
  (scss2-test-with-buffer 'css2-mode ".a { dis│ }"
    (should-not (scss2-completion-for-context
                 (list :role 'property :beg (- (point) 3) :end (point))))
    (should-not (scss2-completion-for-context nil))))

(ert-deftest scss2-semantic-definition-reader-is-optional ()
  (dolist (case '(("$x: red; .a { color: $x│; }" "$x")
                  ("@mixin m($size) {} @include m│(1);" "m")
                  ("@mixin m($size) {} @include m($size│: 1);" "$size")))
    (scss2-test-with-buffer 'scss2-mode (car case)
      (let* ((reference (scss2-completion-reference-at-point))
             (plain (scss2-completion-definitions reference))
             (calls 0)
             (projected (scss2-completion-definitions
                         reference (lambda (node)
                                     (cl-incf calls)
                                     (treesit-node-text node t)))))
        (should (= calls 1))
        (should (equal (plist-get (car projected) :value) (cadr case)))
        (should-not (plist-member (car plain) :value))
        (should (equal (cl-loop for (key value) on (car projected) by #'cddr
                               unless (eq key :value) append (list key value))
                       (car plain)))))))

(provide 'scss2-semantic-test)
;;; scss2-semantic-test.el ends here
