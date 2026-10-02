;;; scss2-performance-test.el --- Wide-tree font-lock contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'scss2-mode)

(ert-deftest scss2-performance-wide-query-retains-context-after-edits ()
  (dolist (mode '(css2-mode scss2-mode))
    (with-temp-buffer
      ;; Batch mode and hidden buffers otherwise disable real JIT hooks.
      (rename-buffer "scss2-wide-query-test" t)
      (insert "@media (width " (apply #'concat (make-list 4096 "/**/ "))
              "> 1px) { .a { color: red; } }")
      (let ((css-fontify-colors nil))
        (funcall mode)
        (let ((noninteractive nil)) (font-lock-mode 1))
        (should (eq font-lock-ensure-function #'jit-lock-fontify-now))
        (font-lock-ensure)
        (should-not (treesit-node-check (scss2--root-node) 'has-error))
        (goto-char (point-min))
        (search-forward "width")
        (let ((start (match-beginning 0)))
          (should (eq (get-text-property start 'face) 'css-property))
          (replace-match "height" t t)
          (run-hook-with-args 'pre-redisplay-functions nil)
          (font-lock-ensure start (point))
          (should-not (treesit-node-check (scss2--root-node) 'has-error))
          (should (eq (get-text-property start 'face) 'css-property)))
        (search-forward "/**/")
        (should (eq (get-text-property (match-beginning 0) 'face)
                    'font-lock-comment-face))
        (search-forward "1px")
        (should (eq (get-text-property (match-beginning 0) 'face)
                    'font-lock-number-face))))))

;;; scss2-performance-test.el ends here
