;;; css2-mode.el --- CSS entry for the scss2-mode package -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; css2-mode uses scss2-mode's modules with the parser's CSS entry, where
;; Sass syntax such as `#{' in strings stays literal.
;;; Code:
(require 'scss2)

;;;###autoload
(define-derived-mode css2-mode prog-mode "CSS[ts]"
  "Edit CSS with semantic completion, structural edits and Emmet."
  :syntax-table nil
  (scss2--setup 'css))

;; Code that asks `derived-mode-p' about the built-in modes treats this one alike.
(derived-mode-add-parents 'css2-mode '(css-mode css-base-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.css\\'" . css2-mode))

(provide 'css2-mode)
;;; css2-mode.el ends here
