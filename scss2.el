;;; scss2.el --- CSS and SCSS editing with one Tree-sitter grammar -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: Peiwen Lu <hi@peiwen.lu>
;; Keywords: languages
;; URL: https://github.com/P233/scss2-mode

;;; Commentary:

;; Shared setup for the scss2-mode package.  The bundled parser and query
;; are installed together; scss2-grammar owns native compilation and loading.
;; Indentation and comments come from scss2-syntax and need no parser.

;;; Code:

(require 'treesit)
(require 'scss2-grammar)
(require 'scss2-context)
(require 'scss2-edit)
(require 'scss2-completion)
(require 'scss2-emmet)

(defvar shr-color-html-colors-alist)
(declare-function color-hsl-to-rgb "color" (hue saturation luminance))
(declare-function color-rgb-to-hex "color" (red green blue &optional digits-per-component))

(defcustom scss2-fontify-colors t
  "Whether to show each literal color with that color as background.
Hex colors, CSS color names and rgb(), rgba(), hsl() and hsla() calls with
literal components are shown.  Set this before entering `scss2-mode' or
`css2-mode'."
  :type 'boolean
  :group 'scss2)

(defcustom scss2-fontify-details nil
  "Whether to highlight numbers, type brackets and delimiters such as commas.
They use the number, bracket and delimiter faces, which Emacs's default
theme and many others leave plain, so nil saves text-property intervals
without a visible change.  Either way, units use the type face,
operators keep their faces, and so do names, keywords, strings, comments
and escapes.  Parsing, completion and structural editing are unchanged.
Set this before entering `scss2-mode' or `css2-mode'.  Reopen existing
buffers after changing it so their old fontification intervals are freed."
  :type 'boolean
  :group 'scss2)

(defface scss2-selector '((t :inherit font-lock-function-name-face))
  "Face for selectors."
  :group 'scss2)

(defface scss2-property '((t :inherit font-lock-keyword-face))
  "Face for property names and media feature names."
  :group 'scss2)

(defconst scss2--faces
  '(("comment" . font-lock-comment-face)
    ("tag" . scss2-selector)
    ("attribute" . scss2-selector)
    ("property" . scss2-property)
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
                    (member capture '("number" "punctuation.bracket" "punctuation.delimiter")))
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
    (dolist (mapping '((scss2-property . scss2--fontify-property)
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
        '((inline_comment) @font-lock-warning-face)))
     (when scss2-fontify-colors
       (require 'shr-color)
       (treesit-font-lock-rules
        :language (scss2--language) :feature 'scss :override t
        `(((hex_color) @scss2--fontify-color)
          ((plain_value) @scss2--fontify-color
           (:match ,(scss2--color-name-regexp) @scss2--fontify-color))
          ((call_expression
            name: (function_name) @_name (:match "\\`\\(?:rgba?\\|hsla?\\)\\'" @_name))
           @scss2--fontify-color)))))))

(defvar scss2--color-name-regexp nil
  "Regexp matching a whole CSS color name, built on first use.")

(defun scss2--color-name-regexp ()
  "Return a regexp for CSS color names in their usual lowercase or camel case.
Building it takes about 1 ms, so every buffer reuses one."
  (or scss2--color-name-regexp
      (setq scss2--color-name-regexp
            (concat "\\`" (regexp-opt (mapcan (lambda (entry) (list (car entry) (downcase (car entry))))
                                               shr-color-html-colors-alist))
                    "\\'"))))

(defun scss2--fontify-color (node _override start end &rest _)
  "Show the literal color NODE within START..END on itself as background."
  (when-let* ((color (scss2--literal-color node)))
    (treesit-fontify-with-override
     (max start (treesit-node-start node)) (min end (treesit-node-end node))
     (scss2--color-face color)
     t)))

(defun scss2--color-face (color)
  "Return the preview face of hex COLOR, shared per color and terminal.
On a terminal without 24-bit color, `readable-foreground-color' scans the
terminal's whole color table on every call.  A face stays shared while
some text uses it; once no text does, garbage collection may drop it."
  (let ((faces (or (terminal-parameter nil 'scss2--color-faces)
                   (let ((table (make-hash-table :test #'equal :weakness 'value)))
                     (set-terminal-parameter nil 'scss2--color-faces table)
                     table))))
    (with-memoization (gethash color faces)
      (list :background color :foreground (readable-foreground-color color)
            :box '(:line-width -1)))))

(defun scss2--literal-color (node)
  "Return the hex RGB color that NODE spells, or nil.
Hex alpha digits are dropped, as rgba() and hsla() alpha components are."
  (let ((text (treesit-node-text node t)))
    (pcase (treesit-node-type node)
      ("hex_color" (substring text 0 (if (> (length text) 5) 7 4)))
      ("plain_value" (cdr (assoc-string text shr-color-html-colors-alist t)))
      (_ (scss2--color-call text)))))

(defun scss2--color-call (text)
  "Return the hex RGB color of the rgb() or hsl() family call TEXT, or nil.
Commas, spaces and a slash before alpha may separate the components."
  (when (string-match "\\`\\(rgb\\|hsl\\)a?(\\([^()]*\\))\\'" text)
    (let ((model (match-string 1 text))
          (parts (mapcar (lambda (part)
                           (and (string-match "\\`\\([-+]?[0-9]*\\.?[0-9]+\\)\\([a-z%]*\\)\\'" part)
                                (cons (string-to-number (match-string 1 part)) (match-string 2 part))))
                         (split-string (match-string 2 text) "[ \t\n,/]+" t))))
      (pcase (and (<= 3 (length parts) 4) (not (memq nil parts)) parts)
        ((and `((,red . ,u1) (,green . ,u2) (,blue . ,u3) . ,_)
              (guard (equal model "rgb"))
              (guard (cl-every (lambda (unit) (member unit '("" "%"))) (list u1 u2 u3))))
         (apply #'format "#%02x%02x%02x"
                (cl-mapcar (lambda (number unit)
                             (min 255 (max 0 (round (if (equal unit "%") (* number 2.55) number)))))
                           (list red green blue) (list u1 u2 u3))))
        ((and `((,hue . ,unit) (,saturation . ,u2) (,lightness . ,u3) . ,_)
              (guard (equal model "hsl"))
              (let turn (pcase unit ("" 360.0) ("deg" 360.0) ("grad" 400.0)
                          ("rad" (* 2 float-pi)) ("turn" 1.0)))
              (guard (and turn (member u2 '("" "%")) (member u3 '("" "%")))))
         (apply #'color-rgb-to-hex
                (append (color-hsl-to-rgb (mod (/ hue turn) 1.0)
                                          (min 1.0 (max 0.0 (/ saturation 100.0)))
                                          (min 1.0 (max 0.0 (/ lightness 100.0))))
                        '(2))))))))

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
  (scss2--fontify-context node 'scss2-property override start end))

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
  (remove-hook 'completion-at-point-functions 'emmet2-capf t)
  (add-hook 'completion-at-point-functions #'scss2-completion-at-point -90 t))

;; INTERIM (since 2026-10-03, until treesit.el reads its redisplay and syntax hooks
;; in Font Lock's view): see "Narrowing and the shared parser"
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
;; view): see "Narrowing and the shared parser" in docs/architecture.md.
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

;; Adapted from `css-fill-paragraph' in Emacs's css-mode.el, without its block reformatting.
(defun scss2--fill-paragraph (&optional justify)
  "Fill the block comment paragraph at point with JUSTIFY.
In code, change nothing and return t, so code is never filled as prose.
Return nil in strings and line comments, leaving them to `fill-paragraph'."
  (save-excursion
    ;; Fill a comment that starts later on this line.
    (when (save-excursion
            (beginning-of-line)
            (comment-search-forward (line-end-position) t))
      (goto-char (match-end 0)))
    (let ((state (syntax-ppss))
          (end (line-end-position)))
      (cond
       ((not (nth 8 state)) t)
       ((and (nth 4 state)
             (save-excursion
               (goto-char (nth 8 state))
               (forward-comment 1)
               (prog1 (not (bolp)) (setq end (point)))))
        (save-restriction
          (narrow-to-region (nth 8 state) end)
          (comment-normalize-vars)
          (let* ((fill-paragraph-function nil)
                 (continue (and comment-continue (string-match "[^ \t]" comment-continue)
                                (regexp-quote comment-continue)))
                 (paragraph-separate
                  (if continue
                      (concat "\\(?:[ \t]*\\(?:" continue "\\|" comment-start-skip
                              "\\|" comment-end-skip "\\)\\)?\\(?:" paragraph-separate "\\)")
                    paragraph-separate))
                 (paragraph-start
                  (if continue
                      (concat "\\(?:[ \t]*" continue "\\)?\\(?:" paragraph-start "\\)")
                    paragraph-start)))
            (fill-paragraph justify)
            t)))))))

(defun scss2--adaptive-fill ()
  "Continue a line that opens a block comment with ` *'."
  (when (looking-at "[ \t]*/\\*[ \t]*")
    (let ((prefix (match-string 0)))
      (and (string-match "/\\*" prefix) (replace-match " *" t t prefix)))))

;; INTERIM (since 2026-10-03, until treesit-fill-reindent-defun decides fill or reindent
;; outside the restriction): see "Tree-sitter commands" in
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
;; shared mode map): see "Initialization and lifetime" in
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
As in built-in Tree-sitter modes, a buffer larger than
`treesit-max-buffer-size' or a grammar that cannot be built or loaded only
warns; it keeps the dialect's syntax, comments, indentation and
syntactic highlighting of comments and strings."
  (scss2-syntax-lexical-setup dialect)
  (setq-local fill-paragraph-function #'scss2--fill-paragraph)
  (setq-local adaptive-fill-function #'scss2--adaptive-fill)
  (setq-local font-lock-defaults '(nil))
  (cond
   ;; Same check and warning as `treesit-ready-p', which would load the grammar again.
   ((> (position-bytes (max (point-min) (1- (point-max))))
       treesit-max-buffer-size)
    (display-warning
     'treesit
     "Cannot activate tree-sitter, because buffer larger than `treesit-max-buffer-size'"))
   ((condition-case failure
        (ignore (scss2-grammar-ensure dialect))
      (error (display-warning 'scss2 (error-message-string failure)) t)))
   (t
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
    (scss2--scope-tree-remaps))))

(provide 'scss2)
;;; scss2.el ends here
