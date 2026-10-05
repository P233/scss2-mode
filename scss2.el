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
Semantic results are exclusive, but modules and paths without local files
decline; Emmet's table yields to later functions when it has no choices."
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

;; INTERIM (since 2026-10-03, until treesit.el reads its redisplay and syntax hooks
;; in Font Lock's view, upstream draft 01): see "Narrowing and the shared parser"
;; in docs/architecture.md.
(defun scss2--pre-redisplay (&rest args)
  "Call `treesit--pre-redisplay' with ARGS in Font Lock's view of the buffer."
  (scss2--with-font-lock-view
    (apply #'treesit--pre-redisplay args)))

(defun scss2--pre-syntax-ppss (start end)
  "Extend START..END like `treesit--pre-syntax-ppss', reading Font Lock's view.
`syntax-propertize' rejects a start before the caller's accessible region."
  (let ((minimum (point-min)))
    (when-let* ((region (scss2--with-font-lock-view
                          (treesit--pre-syntax-ppss start end))))
      (cons (max minimum (car region)) (cdr region)))))

(defconst scss2--widened-tree-hooks
  '((pre-redisplay-functions treesit--pre-redisplay scss2--pre-redisplay)
    (syntax-propertize-extend-region-functions
     treesit--pre-syntax-ppss scss2--pre-syntax-ppss))
  "Private treesit.el hook functions and the wrappers that replace them.
Each entry is (HOOK ORIGINAL WRAPPER).  The wrappers read the tree in Font
Lock's view: the widened buffer unless `font-lock-dont-widen' is non-nil.")

(defun scss2--widen-tree-hooks ()
  "Replace treesit.el's buffer-local tree hooks with Font Lock view wrappers.
A hook whose original function is undefined or absent stays unchanged."
  (pcase-dolist (`(,hook ,original ,wrapper) scss2--widened-tree-hooks)
    (when (and (fboundp original) (memq original (symbol-value hook)))
      (remove-hook hook original t)
      (add-hook hook wrapper 0 t))))

;; INTERIM (since 2026-10-03, until treesit.el commands read the tree in Font Lock's
;; view, upstream draft 01): see "Narrowing and the shared parser" in docs/architecture.md.
(defun scss2--move-in-font-lock-view (motion arg)
  "Call MOTION with ARG in Font Lock's view, keeping point accessible.
Return MOTION's value, or nil when its target lies outside the restriction;
point then stops at the restriction's nearer edge, as regexp motion does."
  (let ((minimum (point-min)) (maximum (point-max)) value target)
    (scss2--with-font-lock-view
      (setq value (funcall motion arg) target (point)))
    (goto-char (max minimum (min maximum target)))
    (and (<= minimum target maximum) value)))

(defun scss2--push-mark-once (command)
  "Push the mark when COMMAND starts a run of invocations, like treesit.el."
  (or (not (eq this-command command))
      (eq last-command command)
      (and transient-mark-mode mark-active)
      (push-mark)))

(defun scss2--beginning-of-defun (&optional arg)
  "Move like `treesit-beginning-of-defun' with ARG, within the restriction."
  (interactive "^p")
  (scss2--push-mark-once 'scss2--beginning-of-defun)
  (scss2--move-in-font-lock-view #'treesit-beginning-of-defun arg))

(defun scss2--end-of-defun (&optional arg _interactive)
  "Move like `treesit-end-of-defun' with ARG, within the restriction."
  (interactive "^p\nd")
  (scss2--push-mark-once 'scss2--end-of-defun)
  (scss2--move-in-font-lock-view #'treesit-end-of-defun arg))

(defun scss2--indent-accessible-lines (start end)
  "Reindent the lines from START to END whose indentation is accessible.
`indent-region' widens to compute indentation, so skip a line that begins
before the restriction or whose indentation crosses its end."
  (let ((minimum (point-min)) (maximum (point-max)))
    (save-excursion
      (save-restriction
        (widen)
        (setq start (max start minimum) end (min end maximum))
        (goto-char start)
        (when (< (line-beginning-position) minimum)
          (setq start (line-beginning-position 2)))
        (when (< start end)
          (goto-char (1- end))
          (forward-line 0)
          (when (> (save-excursion (skip-chars-forward " \t") (point)) maximum)
            (setq end (point)))))
      (when (< start end)
        (indent-region start end)))))

;; INTERIM (since 2026-10-03, until treesit-fill-reindent-defun decides fill or reindent
;; outside the restriction, no upstream report yet): see "Tree-sitter commands" in
;; docs/architecture.md.
(defun scss2--fill-reindent-defun (&optional justify)
  "Refill or reindent like `treesit-fill-reindent-defun' with JUSTIFY.
Decide and find the defun in Font Lock's view, where a restriction cannot
hide the start of a comment or string; reindent only accessible lines.
Fill only when the restriction reads the same comment or string."
  (let ((text (scss2--with-font-lock-view (prog--text-at-point-p))))
    (cond
     ((not text)
      (let ((node (scss2--with-font-lock-view
                    (let ((treesit-defun-tactic 'parent-first))
                      (treesit-defun-at-point)))))
        (unless node
          (user-error "No defun detected at point"))
        (scss2--indent-accessible-lines (treesit-node-start node) (treesit-node-end node))))
     ((eql text (prog--text-at-point-p))
      (treesit-fill-reindent-defun justify))
     (t
      (user-error "Comment or string at point depends on text outside the narrowed region")))))

(defun scss2--transpose-sexps (arg)
  "Return the sexps that `treesit-transpose-sexps' finds for ARG.
Read the whole tree, but reject sexps outside the accessible region."
  (let* ((minimum (point-min)) (maximum (point-max)) (origin (point))
         (positions (scss2--with-font-lock-view (treesit-transpose-sexps arg))))
    (unless (or (null positions)
                (and (<= minimum (car positions) maximum)
                     (<= minimum (cdr positions) maximum)))
      (goto-char origin)
      (user-error "Sexps to transpose extend outside the narrowed region"))
    positions))

(defun scss2--add-log-current-defun ()
  "Return `treesit-add-log-current-defun' read from Font Lock's view."
  (scss2--with-font-lock-view
    (treesit-add-log-current-defun)))

(defun scss2--outline-search (&optional bound move backward looking-at)
  "Search like `treesit-outline-search' in the whole tree.
BOUND, MOVE, BACKWARD and LOOKING-AT are as in `outline-search-function'.
Find only heading lines that begin in the restriction."
  (let ((minimum (point-min)) (maximum (point-max)) (origin (point)) found heading)
    (scss2--with-font-lock-view
      (setq found (treesit-outline-search bound move backward looking-at)
            heading (point)))
    (cond
     (looking-at (and found (<= minimum found) found))
     ((and found (<= minimum heading) (< heading maximum))
      (goto-char heading)
      (set-match-data (list heading (min (match-end 0) maximum)))
      t)
     (t
      (goto-char (cond ((not move) origin)
                       (bound (max minimum (min maximum bound)))
                       (backward minimum)
                       (t maximum)))
      nil))))

(defun scss2--outline-level ()
  "Return `treesit-outline-level' read from Font Lock's view."
  (scss2--with-font-lock-view
    (treesit-outline-level)))

(defconst scss2--widened-tree-functions
  '((beginning-of-defun-function treesit-beginning-of-defun scss2--beginning-of-defun)
    (end-of-defun-function treesit-end-of-defun scss2--end-of-defun)
    (prog-fill-reindent-defun-function
     treesit-fill-reindent-defun scss2--fill-reindent-defun)
    (transpose-sexps-function treesit-transpose-sexps scss2--transpose-sexps)
    (add-log-current-defun-function
     treesit-add-log-current-defun scss2--add-log-current-defun)
    (outline-search-function treesit-outline-search scss2--outline-search)
    (outline-level treesit-outline-level scss2--outline-level))
  "Variables that `treesit-major-mode-setup' sets, with their wrappers.
Each entry is (VARIABLE ORIGINAL WRAPPER).  The wrappers find targets in Font
Lock's view of the tree and act only in the caller's restriction.")

(defconst scss2--widened-tree-remaps
  '((beginning-of-defun treesit-beginning-of-defun scss2--beginning-of-defun)
    (end-of-defun treesit-end-of-defun scss2--end-of-defun))
  "Commands that `treesit-major-mode-setup' remaps in the mode map.
Each entry is (COMMAND ORIGINAL WRAPPER).")

(defun scss2--widen-tree-commands ()
  "Point treesit.el's command variables and remaps at Font Lock view wrappers.
A variable or remap no longer holding its treesit.el original stays unchanged."
  (pcase-dolist (`(,variable ,original ,wrapper) scss2--widened-tree-functions)
    (when (eq (symbol-value variable) original)
      (set (make-local-variable variable) wrapper)))
  (pcase-dolist (`(,command ,original ,wrapper) scss2--widened-tree-remaps)
    (let ((key (format "<remap> <%s>" command)))
      (when (eq (keymap-lookup (current-local-map) key nil t) original)
        (keymap-set (current-local-map) key wrapper)))))

(defun scss2--tree-binding (map key command)
  "Return COMMAND where `treesit-major-mode-setup' ran, else KEY in MAP's parent.
A nil result would shadow the parent keymaps' remaps."
  (if treesit-primary-parser
      command
    (keymap-lookup (keymap-parent map) key nil t)))

;; INTERIM (since 2026-10-04, until treesit-major-mode-setup stops remapping in the
;; shared mode map, upstream draft 10): see "Initialization and lifetime" in
;; docs/architecture.md.
(defun scss2--scope-tree-remaps ()
  "Make the defun motion remaps apply only where `treesit-major-mode-setup' ran.
That function writes them into the keymap that every buffer of the mode
shares, including buffers above `treesit-max-buffer-size'."
  (let ((map (current-local-map)))
    (dolist (command '(beginning-of-defun end-of-defun))
      (let* ((key (format "<remap> <%s>" command))
             (binding (keymap-lookup map key nil t)))
        (when (and binding (symbolp binding))
          (keymap-set map key
                      `(menu-item ,(symbol-name binding) ,binding
                                  :filter ,(apply-partially #'scss2--tree-binding
                                                            map key))))))))

(defun scss2--setup (dialect)
  "Set up shared editing for DIALECT with exactly one SCSS-grammar parser.
As in built-in tree-sitter modes, a buffer larger than
`treesit-max-buffer-size' only warns and keeps its base mode."
  ;; Same check and warning as `treesit-ready-p', which would load the grammar again.
  (if (> (position-bytes (max (point-min) (1- (point-max))))
         treesit-max-buffer-size)
      (display-warning
       'treesit
       "Cannot activate tree-sitter, because buffer larger than `treesit-max-buffer-size'")
    (scss2-syntax-setup dialect)
    (scss2-emmet-setup)
    (add-to-list 'emulation-mode-map-alists 'scss2--tab-map-alist)
    (setq-local treesit-font-lock-settings (scss2--font-lock-settings))
    (setq-local treesit-font-lock-feature-list '((scss)))
    ;; Emacs 31's internal subtree splitting loses contextual parent matches.
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
    (treesit-major-mode-setup)
    (scss2--widen-tree-hooks)
    (scss2--widen-tree-commands)
    (scss2--scope-tree-remaps)))

(provide 'scss2)
;;; scss2.el ends here
