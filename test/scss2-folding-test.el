;;; scss2-folding-test.el --- Syntax-based hideshow contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'hideshow)
(require 'scss2-mode)

(defun scss2-folding-test--visible-text ()
  "Return accessible text that is not hidden by an overlay."
  (apply #'string
         (cl-loop for position from (point-min) below (point-max)
                  unless (invisible-p position) collect (char-after position))))

(ert-deftest scss2-folding-nested-rules ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (insert ".outer {\n  color: red;\n  .inner {\n    margin: 0;\n  }\n}\n.after {\n  display: block;\n}\n")
      (funcall mode)
      (hs-minor-mode 1)
      (hs-hide-all)
      (should (equal (scss2-folding-test--visible-text) ".outer {}\n.after {}\n"))
      (hs-show-all)
      (goto-char (point-min))
      (hs-hide-block)
      (should (equal (scss2-folding-test--visible-text)
                     ".outer {}\n.after {\n  display: block;\n}\n"))
      (hs-show-all)
      (goto-char (point-min)) (search-forward ".inner")
      (hs-hide-block)
      (should (equal (scss2-folding-test--visible-text)
                     ".outer {\n  color: red;\n  .inner {}\n}\n.after {\n  display: block;\n}\n")))))

(ert-deftest scss2-folding-keeps-multiline-selector-header ()
  (dolist (mode '(scss2-mode css2-mode))
    (dolist (command '(hs-hide-all hs-hide-block))
      (with-temp-buffer
        (insert ".label,\n.toggle {\n  color: red;\n}\n")
        (funcall mode)
        (hs-minor-mode 1)
        (goto-char (point-min)) (forward-line 1)
        (funcall command)
        (should (equal (scss2-folding-test--visible-text) ".label,\n.toggle {}\n"))))))

(ert-deftest scss2-folding-block-from-selector-first-line-stays-visible ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (insert ".label,\n.toggle {\n  color: red;\n}\n")
      (funcall mode)
      (hs-minor-mode 1)
      (goto-char (point-min))
      (hs-hide-block)
      (should (equal (scss2-folding-test--visible-text) (buffer-string))))))

(ert-deftest scss2-folding-scss-map ()
  (dolist (command '(hs-hide-all hs-hide-block))
    (with-temp-buffer
      (insert "$m: (\n  a: 1,\n  b: 2\n);\n")
      (scss2-mode)
      (hs-minor-mode 1)
      (goto-char (point-min))
      (funcall command)
      (should (equal (scss2-folding-test--visible-text) "$m: ();\n")))))

(ert-deftest scss2-folding-media-block ()
  (dolist (mode '(scss2-mode css2-mode))
    (dolist (command '(hs-hide-all hs-hide-block))
      (with-temp-buffer
        (insert "@media (width > 10px) {\n  .a {\n    color: red;\n  }\n}\n")
        (funcall mode)
        (hs-minor-mode 1)
        (goto-char (point-min))
        (funcall command)
        (should (equal (scss2-folding-test--visible-text)
                       "@media (width > 10px) {}\n"))))))

(ert-deftest scss2-folding-scss-line-comment-run ()
  (dolist (command '(hs-hide-all hs-hide-block))
    (with-temp-buffer
      (insert "// first\n// second\n// third\n.a { color: red; }\n")
      (scss2-mode)
      (hs-minor-mode 1)
      (goto-char (point-min))
      (funcall command)
      (should (equal (scss2-folding-test--visible-text)
                     "// first\n.a { color: red; }\n")))))

(ert-deftest scss2-folding-block-comments-follow-dialect-defaults ()
  (dolist (mode '(scss2-mode css2-mode))
    (dolist (command '(hs-hide-all hs-hide-block))
      (with-temp-buffer
        (insert "/* first\n * second\n * third\n */\n.a { color: red; }\n")
        (funcall mode)
        (hs-minor-mode 1)
        (goto-char (point-min))
        (funcall command)
        (should (equal (scss2-folding-test--visible-text)
                       (if (eq mode 'css2-mode)
                           "/* first\n.a { color: red; }\n"
                         (buffer-string))))))))

(ert-deftest scss2-folding-hide-all-through-middle-of-block ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (insert ".outer {\n  color: red;\n  .inner {\n    margin: 0;\n  }\n  padding: 0;\n}\n.after {}\n")
      (funcall mode)
      (hs-minor-mode 1)
      (goto-char (point-min)) (forward-line 1)
      (let ((start (point)))
        (search-forward "  padding: 0;")
        (narrow-to-region start (point)))
      (let ((minimum (point-min)) (maximum (point-max)) (text (buffer-string)))
        (hs-hide-all)
        (should (= (point-min) minimum))
        (should (= (point-max) maximum))
        (should (equal (buffer-string) text))
        (should (equal (scss2-folding-test--visible-text)
                       "  color: red;\n  .inner {}\n  padding: 0;"))))))

(ert-deftest scss2-folding-damaged-buffers-complete-without-errors ()
  (dolist (mode '(scss2-mode css2-mode))
    (dolist (command '(hs-hide-all hs-hide-block))
      (pcase-dolist (`(,source ,visible)
                     '(("}\n.a {\n  color: red;\n}\n" "}\n.a {}\n")
                       (".a {\n  color: red;\n" ".a {\n  color: red;\n")))
        (with-temp-buffer
          (insert source)
          (funcall mode)
          (hs-minor-mode 1)
          (goto-char (point-min))
          (when (eq (char-after) ?\}) (forward-line 1))
          (funcall command)
          (should (equal (scss2-folding-test--visible-text) visible)))))))

(ert-deftest scss2-folding-keeps-default-forward-sexp ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (insert ".a { color: red; }")
      (funcall mode)
      (hs-minor-mode 1)
      (should (eq forward-sexp-function (default-value 'forward-sexp-function))))))

(ert-deftest scss2-folding-backward-sexp-from-interpolation-closer ()
  (with-temp-buffer
    (insert ".a-#{$b} { color: red; }")
    (scss2-mode)
    (hs-minor-mode 1)
    (goto-char (point-min)) (search-forward "}")
    (forward-sexp -1)
    (should (= (point) 5))
    (should (looking-at-p "{\\$b}"))))

(ert-deftest scss2-folding-sexp-motion-signals-scan-error-at-the-restriction ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (insert ".a {\n  color: red;\n}\n")
      (funcall mode)
      (narrow-to-region (1+ (string-match "color" (buffer-string))) (point-max))
      (goto-char (point-max))
      (skip-chars-backward "\n")
      (should-error (backward-sexp) :type 'scan-error))))

(ert-deftest scss2-folding-nested-selector-first-line-folds-the-enclosing-block ()
  (dolist (mode '(scss2-mode css2-mode))
    (dolist (command '(hs-hide-block hs-toggle-hiding))
      (with-temp-buffer
        (insert ".a {\n  &:hover,\n  &:focus {\n    color: red;\n  }\n}\n")
        (funcall mode)
        (hs-minor-mode 1)
        (goto-char (point-min))
        (forward-line 1)
        (funcall command)
        (should (equal (scss2-folding-test--visible-text) ".a {}\n"))))))

(provide 'scss2-folding-test)
;;; scss2-folding-test.el ends here
