;;; scss2.el --- CSS and SCSS editing with one tree-sitter grammar -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: Peiwen Lu <hi@peiwen.lu>
;; Keywords: languages
;; URL: https://github.com/P233/scss2-mode

;;; Commentary:

;; Shared setup for the scss2-mode package.  The bundled parser and query
;; are installed together; scss2-grammar owns native compilation and loading.
;; Modes retain built-in indentation and comments for their dialect.

;;; Code:

(require 'css-mode)
(require 'treesit)
(require 'scss2-grammar)
(require 'scss2-context)
(require 'scss2-edit)
(require 'scss2-completion)
(require 'scss2-emmet)

(defcustom scss2-fontify-details t
  "Whether to highlight numbers, operators and punctuation.
Numbers use the number face and units use the type face.
Expression operators use the value face.
When nil, retain names, keywords, strings, comments and escapes, using
fewer text-property intervals in large buffers.  Parsing, completion and
structural editing are unchanged.
Set this before entering `scss2-mode' or `css2-mode'.  Reopen existing
buffers after changing it so their old fontification intervals are freed."
  :type 'boolean
  :group 'scss2)

(defconst scss2--faces
  '(("comment" . font-lock-comment-face)
    ("tag" . css-selector)
    ("attribute" . css-selector)
    ("property" . css-property)
    ("variable" . font-lock-variable-name-face)
    ("variable.parameter" . font-lock-variable-name-face)
    ("module" . font-lock-type-face)
    ("function" . font-lock-function-name-face)
    ("constant" . font-lock-constant-face)
    ("constant.builtin" . font-lock-builtin-face)
    ("number" . font-lock-number-face)
    ("type" . font-lock-type-face)
    ("type.unit" . font-lock-type-face)
    ("keyword" . font-lock-keyword-face)
    ("keyword.import" . font-lock-keyword-face)
    ("keyword.return" . font-lock-keyword-face)
    ("keyword.conditional" . font-lock-keyword-face)
    ("keyword.repeat" . font-lock-keyword-face)
    ("keyword.debug" . font-lock-keyword-face)
    ("keyword.exception" . font-lock-keyword-face)
    ("keyword.directive" . font-lock-keyword-face)
    ("keyword.modifier" . font-lock-keyword-face)
    ("operator" . font-lock-operator-face)
    ("operator.expression" . font-lock-constant-face)
    ("string" . font-lock-string-face)
    ("string.escape" . font-lock-escape-face)
    ("punctuation.bracket" . font-lock-bracket-face)
    ("punctuation.delimiter" . font-lock-delimiter-face)
    ("punctuation.special" . font-lock-escape-face))
  "Emacs faces for the shared semantic capture names.")

(defun scss2--highlight-query ()
  "Read the shared query and map semantic captures to Emacs faces."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "queries/highlights.scm" scss2-grammar-directory))
    (goto-char (point-min))
    (while (re-search-forward
            "\"\\(?:[^\"\\\\]\\|\\\\.\\)*\"\\|\\(@[[:alnum:]_.-]+\\)" nil t)
      (when (match-string 1)
        (let* ((capture (substring (match-string 1) 1))
               (face (cdr (assoc capture scss2--faces))))
          (unless face
            (error "Unmapped SCSS highlight capture: %s" capture))
          (replace-match
           (if (and (not scss2-fontify-details)
                    (member capture '("number" "operator" "operator.expression"
                                      "punctuation.bracket" "punctuation.delimiter")))
               ""
             (concat "@" (symbol-name face)))
           t t))))
    (buffer-string)))

(defun scss2--font-lock-settings ()
  "Build font-lock settings with contextual matches applied last.
Emacs orders captures by the start of the entire match.  A contextual
parent match can otherwise be overwritten by a generic child capture."
  (let ((sections (split-string (scss2--highlight-query)
                                "^; Context overrides\n")))
    (unless (= (length sections) 2)
      (error "SCSS query must contain one Context overrides section"))
    ;; Contextual names can contain interpolation and comments with their own faces.
    (dolist (mapping '((css-property . scss2--fontify-property)
                       (font-lock-keyword-face . scss2--fontify-keyword)))
      (setcar (cdr sections)
              (replace-regexp-in-string
               (concat "@" (symbol-name (car mapping)) "\\_>")
               (concat "@" (symbol-name (cdr mapping))) (cadr sections) t t)))
    (append
     (treesit-font-lock-rules
      :language (scss2--language) :feature 'scss :override t (car sections)
      :language (scss2--language) :feature 'scss :override t (cadr sections))
     (when (eq scss2-dialect 'css)
       (treesit-font-lock-rules
        :language (scss2--language) :feature 'scss :override t
        '((inline_comment) @font-lock-warning-face))))))

(defun scss2--fontify-context (node face override start end)
  "Apply FACE with OVERRIDE to NODE in START..END, keeping nested faces.
Interpolation and comments inside NODE are left untouched."
  (let ((position (max start (treesit-node-start node)))
        (limit (min end (treesit-node-end node))))
    ;; Most contextual names are leaves, so cannot contain protected spans.
    (dolist (protected (when (> (treesit-node-child-count node) 0)
                        (treesit-query-capture
                         node (scss2--query '([(interpolation) (block_comment) (inline_comment)] @protected))
                         start end t)))
      (let ((boundary (min limit (treesit-node-start protected))))
        (when (< position boundary)
          (treesit-fontify-with-override position boundary face override))
        (setq position (max position (treesit-node-end protected)))))
    (when (< position limit)
      (treesit-fontify-with-override position limit face override))))

(defun scss2--fontify-property (node override start end &rest _)
  "Apply the contextual property face to NODE within START..END with OVERRIDE."
  (scss2--fontify-context node 'css-property override start end))

(defun scss2--fontify-keyword (node override start end &rest _)
  "Apply the contextual keyword face to NODE within START..END with OVERRIDE."
  (scss2--fontify-context node 'font-lock-keyword-face override start end))

(defun scss2--defun-name (node)
  "Return the name of the rule or definition NODE."
  (let ((name (or (treesit-node-child-by-field-name node "name")
                  (treesit-node-child node 0 t))))
    (when name (treesit-node-text name t))))

;;;###autoload
(defun scss2-completion-at-point ()
  "Dispatch completion using the single context at point.
Emmet owns declaration abbreviations; semantic completion owns other roles.
An exclusive result keeps unrelated providers out of an owned context."
  (when-let* ((context (scss2-context-at-point)))
    (if (eq (plist-get context :role) 'property)
        (scss2-emmet-completion-at-point context)
      (scss2-completion-for-context context))))

(defun scss2--own-completion ()
  "Keep the stylesheet dispatcher as the local completion entry point.
Emmet's minor-mode hook can run after the major mode.  Keep its explicit
commands while removing its overlapping automatic completion provider."
  (remove-hook 'completion-at-point-functions #'css-completion-at-point t)
  (remove-hook 'completion-at-point-functions 'emmet2-capf t)
  (remove-hook 'completion-at-point-functions 'emmet2-css-value-capf t)
  (add-hook 'completion-at-point-functions #'scss2-completion-at-point -90 t))

(defun scss2--setup (dialect)
  "Set up shared editing for DIALECT with exactly one SCSS-grammar parser."
  (scss2-syntax-setup dialect)
  (scss2-emmet-setup)
  (add-to-list 'emulation-mode-map-alists 'scss2--tab-map-alist)
  (setq-local treesit-font-lock-settings (scss2--font-lock-settings))
  (setq-local treesit-font-lock-feature-list '((scss)))
  ;; Emacs 29-31's internal subtree splitting loses contextual parent matches.
  (setq-local treesit--font-lock-fast-mode nil)
  (setq-local treesit-defun-type-regexp
              (regexp-opt '("rule_set" "mixin_definition" "function_definition") t))
  (setq-local treesit-defun-name-function #'scss2--defun-name)
  (setq-local treesit-simple-imenu-settings
              '(("Mixins" "\\`mixin_definition\\'" nil scss2--defun-name)
                ("Functions" "\\`function_definition\\'" nil scss2--defun-name)
                ("Rules" "\\`rule_set\\'" nil scss2--defun-name)))
  (scss2--own-completion)
  (add-hook 'emmet2-mode-hook #'scss2--own-completion nil t)
  (treesit-major-mode-setup))

(provide 'scss2)
;;; scss2.el ends here
