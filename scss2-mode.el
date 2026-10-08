;;; scss2-mode.el --- CSS and SCSS modes with completion and structural editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: Peiwen Lu <hi@peiwen.lu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1") (emmet2-mode "2.0.0"))
;; Keywords: languages
;; URL: https://github.com/P233/scss2-mode

;;; Commentary:
;; Major modes for SCSS (scss2-mode) and CSS (css2-mode) with semantic
;; completion, structural editing and emmet2-mode declaration abbreviations
;; (on by default; see `scss2-enable-emmet').  The parser is a bundled
;; snapshot of P233/tree-sitter-scss, which is independent of the official
;; grammar; it ships as C source and is compiled locally on first use.
;; Requires Emacs 31.1 or later built with Tree-sitter, and a C compiler.

;;; Code:
(require 'scss2)
(require 'css2-mode)

;;;###autoload
(define-derived-mode scss2-mode prog-mode "SCSS[ts]"
  "Edit SCSS with semantic completion, structural edits and Emmet."
  :syntax-table nil
  (scss2--setup 'scss))

;; Code that asks `derived-mode-p' about the built-in modes treats this one alike.
(derived-mode-add-parents 'scss2-mode '(scss-mode css-mode css-base-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.scss\\'" . scss2-mode))

(provide 'scss2-mode)
;;; scss2-mode.el ends here
