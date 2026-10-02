;;; css2-mode.el --- CSS entry for the scss2-mode package -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; CSS uses the same editor modules as SCSS with literal CSS semantics.
;;; Code:
(require 'scss2)

;;;###autoload
(define-derived-mode css2-mode css-mode "CSS[ts]"
  "Edit CSS with semantic completion, structural edits and Emmet2."
  (scss2--setup 'css))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.css\\'" . css2-mode))

(provide 'css2-mode)
;;; css2-mode.el ends here
