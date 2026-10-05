;;; scss2-mode.el --- Complete CSS and SCSS structural editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: Peiwen Lu <hi@peiwen.lu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1") (emmet2-mode "2.0.0"))
;; Keywords: languages
;; URL: https://github.com/P233/scss2-mode

;;; Commentary:
;; One package supplies scss2-mode and css2-mode, semantic completion,
;; structural editing and default Emmet2 abbreviation expansion.  The matching
;; CSS/SCSS parser is bundled as source and compiled locally on first use.
;; Requires Emacs with tree-sitter and a C compiler; no grammar download occurs.

;;; Code:
(require 'scss2)
(require 'css2-mode)

;;;###autoload
(define-derived-mode scss2-mode scss-mode "SCSS[ts]"
  "Edit SCSS with semantic completion, structural edits and Emmet2."
  (scss2--setup 'scss))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.scss\\'" . scss2-mode))

(provide 'scss2-mode)
;;; scss2-mode.el ends here
