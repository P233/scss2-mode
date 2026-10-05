;;; scss2-syntax.el --- Shared CSS and SCSS syntax model -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The reading of the bundled grammar that context, completion and structural
;; editing share: parser access, identities, statements, blocks, values and
;; recovered scopes.  A rule needed by two features lives here; a feature
;; keeps only the type tables that it alone uses.  Syntax setup owns the buffer's
;; dialect and parser identity; each command owns its transient derived ranges.

;;; Code:

(require 'cl-lib)
(require 'css-mode)
(require 'seq)
(require 'scss2-grammar)
(require 'treesit)
(require 'subr-x)

(defvar-local scss2-dialect nil
  "Language of the current stylesheet, either `css' or `scss'.")

(defvar-local scss2--parser-language nil
  "Tree-sitter language this buffer's parser was created with.
It stays fixed even when a reloaded package bundles another grammar.")

(defvar scss2--compiled-queries (make-hash-table :test #'equal)
  "Internal queries compiled in this session, keyed by (LANGUAGE . QUERY).
LANGUAGE is a buffer's fixed parser language and QUERY one of the package's
finite query forms, so entries need no eviction.  Syntax nodes and captured
results are never retained.")

(defvar scss2--idle-release-timer nil
  "Idle timer for releasing resources in invisible stylesheet buffers.")

(defcustom scss2-idle-release-delay 30
  "Idle seconds before releasing invisible buffers' trees and highlighting.
The next syntax or fontification request rebuilds them automatically.
Buffers displayed in any frame, active completion sessions, and buffers
sharing text through indirect buffers keep their resources.
Set to nil to disable automatic release.  No garbage collection is forced."
  :type '(choice (const :tag "Keep resources" nil)
                 (number :tag "Idle seconds"))
  :group 'scss2
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'scss2--schedule-idle-release)
           (scss2--schedule-idle-release))))

(defun scss2--schedule-idle-release ()
  "Update the shared idle timer from `scss2-idle-release-delay'."
  (when (timerp scss2--idle-release-timer)
    (cancel-timer scss2--idle-release-timer))
  (setq scss2--idle-release-timer
        (when (and scss2-idle-release-delay
                   (seq-some (lambda (buffer)
                               (buffer-local-value 'scss2--parser-language buffer))
                             (buffer-list)))
          (run-with-idle-timer scss2-idle-release-delay t
                               #'scss2--release-idle-buffers))))

;; See "Narrowing and the shared parser" in docs/architecture.md.
(defmacro scss2--with-font-lock-view (&rest body)
  "Evaluate BODY in the restriction that Font Lock fontifies.
That is the widened buffer unless `font-lock-dont-widen' is non-nil."
  (declare (indent 0) (debug t))
  `(save-restriction
     (unless font-lock-dont-widen (widen))
     ,@body))

(defvar-local scss2--released-tick nil
  "Text modification tick at which idle release last emptied the tree.
Reparses at this tick only empty the tree or rebuild it over unchanged text.")

(defvar-local scss2--changed-start nil
  "Earliest position that a reparse changed since syntax was propertized.")

;; INTERIM (since 2026-10-03, until treesit.el hands every reparse's changed ranges
;; to redisplay, upstream draft 09): see "Changed ranges of early reparses" in
;; docs/architecture.md.
(defun scss2--mark-changed-ranges (ranges parser)
  "Mark RANGES that PARSER's reparse changed for refontification and syntax.
Emacs 31 marks them only when redisplay itself reparses, so a tree read
between an edit and redisplay would leave stale faces and syntax properties."
  (with-current-buffer (treesit-parser-buffer parser)
    (unless (eql scss2--released-tick (buffer-chars-modified-tick))
      (save-restriction
        (widen)
        (with-silent-modifications
          (pcase-dolist (`(,beginning . ,end) ranges)
            ;; A labeled restriction, such as the long-line one, survives `widen'.
            (setq beginning (max beginning (point-min)) end (min end (point-max)))
            (when (< beginning end)
              (put-text-property beginning end 'fontified nil)
              (setq scss2--changed-start
                    (min beginning (or scss2--changed-start beginning))))))))))

(defun scss2--extend-to-changed-start (start end)
  "Extend START..END back to `scss2--changed-start' within the restriction.
Unlike flushing `syntax-ppss', this never asks `syntax-propertize' to start
before a restriction that a reparse in Font Lock's view cannot see."
  ;; Reparse first, so that the notifier records any pending change.
  (scss2--with-font-lock-view (scss2--root-node))
  (let ((changed (and scss2--changed-start (max scss2--changed-start (point-min)))))
    (setq scss2--changed-start nil)
    (when (and changed (< changed start))
      (cons changed end))))

(defun scss2--release-buffer-resources ()
  "Release this buffer's derived data, leaving its parser ready to reparse.
Keep parser identity, text, undo and non-fontification properties.
Return non-nil when the buffer's sole parser belongs to this mode and can
be released.  Custom ranges and other packages' parser notifiers require
their own lifecycle."
  (let* ((parsers (treesit-parser-list))
         (parser (car parsers)))
    (when (and scss2--parser-language parser (null (cdr parsers))
               (eq (treesit-parser-language parser) scss2--parser-language)
               (null (treesit-parser-included-ranges parser))
               (null (remq #'scss2--mark-changed-ranges
                           (treesit-parser-notifiers parser))))
      (save-excursion
        (save-restriction
          (widen)
          (when font-lock-mode
            (with-silent-modifications
              (font-lock-flush)
              (font-lock-unfontify-region (point-min) (point-max))
              (remove-list-of-text-properties (point-min) (point-max) '(fontified))
              ;; Removing faces leaves fragmented interval nodes behind.
              ;; Coalesce equal runs, preserving syntax and third-party properties.
              (let ((position (point-min)))
                (while (< position (point-max))
                  (let ((end (next-property-change position nil (point-max)))
                        (properties (text-properties-at position)))
                    (set-text-properties position end properties)
                    (setq position end))))))
          ;; Deleting a Lisp parser defers native tree disposal until GC.
          ;; An empty parse frees it now.  Restoring the full range only marks
          ;; the same parser dirty: all existing consumers reparse on demand.
          ;; Both reparses report the whole buffer without a text change.
          (setq scss2--released-tick (buffer-chars-modified-tick))
          (let ((inhibit-quit t))
            (unwind-protect
                (progn
                  (treesit-parser-set-included-ranges parser '((1 . 1)))
                  (treesit-parser-root-node parser))
              (treesit-parser-set-included-ranges parser nil)))))
      t)))

(defun scss2--release-idle-buffers ()
  "Release invisible stylesheet buffers until user input is pending."
  (if (null scss2-idle-release-delay)
      (scss2--schedule-idle-release)
    (let* ((buffers (buffer-list))
           (bases (delq nil (mapcar #'buffer-base-buffer buffers)))
           (stylesheets (seq-filter
                         (lambda (buffer)
                           (buffer-local-value 'scss2--parser-language buffer))
                         buffers)))
      (if (null stylesheets)
          (scss2--schedule-idle-release)
        (while (and stylesheets (not (input-pending-p)))
          (let ((buffer (pop stylesheets)))
            (when (and (buffer-live-p buffer)
                       (not (get-buffer-window buffer t))
                       (not (buffer-base-buffer buffer))
                       (not (memq buffer bases)))
              (with-current-buffer buffer
                (unless (bound-and-true-p completion-in-region-mode)
                  (with-demoted-errors "SCSS2 resource release: %S"
                    (scss2--release-buffer-resources)))))))))))

(defun scss2-syntax-unload-function ()
  "Cancel the idle timer before unloading syntax support."
  (when (timerp scss2--idle-release-timer)
    (cancel-timer scss2--idle-release-timer))
  (setq scss2--idle-release-timer nil))

(defun scss2--query (query)
  "Return the compiled form of internal QUERY for this buffer's parser."
  (let ((key (cons (scss2--language) query)))
    (or (gethash key scss2--compiled-queries)
        (puthash key (treesit-query-compile (car key) query t)
                 scss2--compiled-queries))))

(defun scss2-syntax-setup (dialect)
  "Initialize DIALECT after entering the buffer's base CSS/SCSS mode.
Own the parser identity and lexical syntax shared by all stylesheet features.
Major-mode changes let Emacs discard the previous parser and local settings."
  (setq-local scss2-dialect dialect)
  (setq-local scss2--parser-language (scss2-grammar-ensure dialect))
  (treesit-parser-add-notifier (treesit-parser-create scss2--parser-language)
                               #'scss2--mark-changed-ranges)
  (scss2--query '((raw_text) @raw))
  (setq-local syntax-propertize-function #'scss2--syntax-propertize)
  (add-hook 'syntax-propertize-extend-region-functions
            #'syntax-propertize-wholelines nil t)
  (add-hook 'syntax-propertize-extend-region-functions
            #'scss2--extend-to-changed-start nil t)
  (unless scss2--idle-release-timer
    (scss2--schedule-idle-release)))

(defun scss2--syntax-propertize (start end)
  "Apply SCSS syntax properties between START and END.
Raw CSS and unquoted URLs cannot start silent comments.  Correct the
inherited syntax table there so SMIE and comment commands see real code."
  (funcall css-syntax-propertize-function start end)
  (dolist (node (scss2--with-font-lock-view
                  (treesit-query-capture
                   (scss2--root-node) (scss2--query '((raw_text) @raw)) start end t)))
    (save-excursion
      (goto-char (max start (treesit-node-start node)))
      (while (search-forward "/" (min end (treesit-node-end node)) t)
        (put-text-property (1- (point)) (point)
                           'syntax-table (string-to-syntax "."))))))

(defun scss2--language ()
  "Return the language of this buffer's sole parser."
  scss2--parser-language)

(defun scss2--root-node ()
  "Return the current stylesheet's root from its sole parser."
  (treesit-buffer-root-node (scss2--language)))

(defconst scss2--statement-types
  '("rule_set" "property_declaration" "variable_declaration" "raw_statement"
    "use_statement" "forward_statement"
    "function_definition" "mixin_definition" "include_statement"
    "content_statement" "if_statement" "else_clause" "each_statement"
    "for_statement" "while_statement" "value_statement" "extend_statement"
    "at_root_statement" "keyframes_statement" "namespace_statement"
    "css_statement" "page_statement" "query_statement" "scope_statement"
    "at_rule"))

(defconst scss2--declaration-types
  '("property_declaration" "variable_declaration")
  "Declaration owners shared by context and structural editing.")

(defun scss2--node-at-point ()
  "Return the current SCSS-grammar node at point, including anonymous tokens."
  (when (and scss2-dialect (treesit-parser-list))
    (treesit-node-at (min (point) (max (point-min) (1- (point-max))))
                     (scss2--language))))

(defun scss2--ancestor (node types)
  "Return the nearest ancestor of NODE whose type is in TYPES, including NODE."
  (while (and node (not (member (treesit-node-type node) types)))
    (setq node (treesit-node-parent node)))
  node)

(defun scss2--children (node &optional named)
  "Return NODE's direct children, restricted to named children when NAMED."
  (when node
    (cl-loop for index below (treesit-node-child-count node named)
             collect (treesit-node-child node index named))))

(defun scss2--child (node type)
  "Return NODE's first direct child of TYPE, including anonymous tokens."
  (cl-find type (scss2--children node) :key #'treesit-node-type :test #'equal))

(defun scss2--contains-point-p (node)
  "Whether NODE contains point, allowing its end boundary."
  (and node (<= (treesit-node-start node) (point) (treesit-node-end node))))

(defun scss2--decode-identifier (text)
  "Decode CSS escapes in identifier TEXT without changing its case."
  (if (not (string-search "\\" text)) text
    (replace-regexp-in-string
     "\\\\\\([[:xdigit:]]\\{1,6\\}\\)\\(?:\r\n\\|[ \t\r\n\f]\\)?\\|\\\\\\([^\r\n\f]\\)"
     (lambda (escape)
       (if (match-string 1 escape)
           (let ((code (string-to-number (match-string 1 escape) 16)))
             (char-to-string (if (or (= code 0) (> code #x10ffff)
                                     (<= #xd800 code #xdfff)) #xfffd code)))
         (match-string 2 escape)))
     text t t)))

(defun scss2--identifier-start (node)
  "Return NODE's name start, excluding a literal legacy property hack."
  (let ((beginning (treesit-node-start node)))
    (if (and (equal (treesit-node-type node) "property_name")
             (eq (char-after beginning) ?*))
        (1+ beginning)
      beginning)))

(defun scss2--identifier-text (node)
  "Return NODE's static spelling, or nil for a dynamic identifier."
  (when (and node
             (or (zerop (treesit-node-child-count node))
                 (not (treesit-search-subtree node "interpolation"))))
    (buffer-substring-no-properties (scss2--identifier-start node) (treesit-node-end node))))

(defun scss2--identifier-name (node)
  "Return NODE's static decoded name, or nil for a dynamic identifier."
  (when-let* ((text (scss2--identifier-text node)))
    (scss2--decode-identifier text)))

(defun scss2--directive (node)
  "Return NODE's canonical leading directive, or nil."
  (when-let* ((token (treesit-node-child node 0))
              (type (treesit-node-type token)))
    (cond
     ((string-prefix-p "@" type) (downcase type))
     ((equal type "at_keyword")
      (downcase (scss2--decode-identifier (treesit-node-text token t)))))))

(defun scss2--block-bounds (node)
  "Return NODE's first direct block interior as (BEG . END), or nil.
Only direct braces count; nested declarations, strings and else clauses do
not change an owner's boundaries.  Missing braces never establish a range."
  (let (opening closing)
    (dolist (child (and node (member (treesit-node-type node) scss2--statement-types)
                       (scss2--children node)))
      (unless (treesit-node-check child 'missing)
        (cond
         ((and (not opening) (equal (treesit-node-type child) "{"))
          (setq opening (treesit-node-end child)))
         ((and opening (not closing) (equal (treesit-node-type child) "}"))
          (setq closing (treesit-node-start child))))))
    (when (and opening closing) (cons opening closing))))

(defun scss2--in-block-p (node)
  "Whether point is inside NODE's block, even before its closer exists.
Unlike destructive edits, completion accepts a missing closing brace, and
trailing blanks after an unclosed block still belong to it."
  (if-let* ((bounds (scss2--block-bounds node)))
      (<= (car bounds) (point) (cdr bounds))
    (when-let* ((_ (or (member (treesit-node-type node) scss2--statement-types)
                       (equal (treesit-node-type node) "ERROR")))
                (opening (scss2--child node "{")))
      (and (<= (treesit-node-end opening) (point))
           (or (<= (point) (treesit-node-end node))
               (string-blank-p
                (buffer-substring-no-properties (treesit-node-end node) (point))))))))

(defun scss2--value-bounds (node)
  "Return the trimmed right-hand side of NODE's colon as (BEG . END).
NODE is a declaration, feature query, parameter, named argument or map
entry.  Exclude the direct colon, semicolon and nested-property block.
Include flags such as !important.  An empty value has equal beginning and
end."
  (let (begin end)
    (dolist (child (scss2--children node))
      (let ((type (treesit-node-type child)))
        (cond
         ((and (not begin) (equal type ":"))
          (setq begin (treesit-node-end child)))
         ((and begin (not end) (member type '(";" "{")))
          (setq end (treesit-node-start child))))))
    (when begin
      (setq end (or end (treesit-node-end node)))
      (save-excursion
        (goto-char begin)
        (skip-chars-forward " \t\r\n" end)
        (setq begin (point))
        (goto-char end)
        (skip-chars-backward " \t\r\n" begin)
        (cons begin (point))))))

(defun scss2--statement-start ()
  "Find the current statement boundary without crossing literal text.
Scan punctuation at block level, ignoring strings, comments and parentheses.
This also works before the parser can recognize an incomplete declaration."
  (save-excursion
    (let ((end (point)) found)
      (while (and (not found) (re-search-backward "[;{}]" nil t))
        (let* ((position (point)) (state (syntax-ppss position))
               (opening (nth 1 state))
               (raw (scss2--ancestor (treesit-node-at position (scss2--language)) '("raw_value" "interpolation"))))
          (unless (or (nth 3 state) (nth 4 state)
                      (and raw (<= (treesit-node-start raw) position))
                      (and opening (memq (char-after opening) '(?\( ?\[))))
            (setq found (1+ position)))))
      (goto-char (or found (point-min)))
      (skip-chars-forward " \t\r\n" end)
      ;; A standalone leading comment belongs to the preceding whitespace.
      (while (and (< (point) end)
                  (looking-at "/[/*]")
                  (let ((before (point)))
                    (condition-case nil
                        (progn (forward-comment 1) (> (point) before))
                      (scan-error nil))))
        (skip-chars-forward " \t\r\n" end))
      (min (point) end))))

(defun scss2--module-namespaces ()
  "Return (NAMESPACE . SOURCE) for every literal @use in this buffer.
NAMESPACE is decoded.  A later @use of the same namespace comes first."
  (let (modules)
    (dolist (capture (treesit-query-capture (scss2--root-node)
                                          (scss2--query '((use_statement) @use))))
      (let* ((node (cdr capture))
             (string (scss2--child node "string"))
             (alias (treesit-node-child-by-field-name node "alias"))
             (source (and string
                          (string-trim (treesit-node-text string t) "[\"']" "[\"']"))))
        (when source
          (push (cons (if alias
                          (scss2--identifier-name alias)
                        ;; `sass:math' and `lib/_math.scss' are both `math'.
                        (string-remove-prefix
                         "_" (file-name-base (car (last (split-string source "[:/]"))))))
                      source)
                modules))))
    modules))

(defun scss2--recovered-sass-scopes (node)
  "Recover active Sass scopes from NODE's surviving ERROR tokens.
Return (TYPE PARAMETERS . VARIABLES), innermost first.  PARAMETERS is a
callable's parameter node; VARIABLES are a loop's binding nodes.
Only braces still enclosing point count.  The result belongs to this call,
so declaration context and parameter completion share the same recovery."
  (when (and (eq scss2-dialect 'scss) (equal (treesit-node-type node) "ERROR"))
    (let ((position (point)) (count (treesit-node-child-count node)) (index 0)
          child openings openings-scanned type parameters variables bound range scopes)
      ;; Do not allocate every child of a large ERROR or inspect future headers.
      (while (and (< index count)
                  (setq child (treesit-node-child node index))
                  (< (treesit-node-start child) position))
        (let ((token (treesit-node-type child)))
          (cond
           ((string-prefix-p "@" token)
            (setq type (pcase token
                         ("@mixin" "mixin_definition")
                         ("@include" "include_statement")
                         ("@function" "function_definition")
                         ("@each" "each_statement")
                         ("@for" "for_statement"))
                  parameters nil variables nil bound nil range nil))
           ((and type (equal token "parameters")) (setq parameters child))
           ((and (member type '("each_statement" "for_statement"))
                 (not bound) (equal token "variable_name"))
            (push child variables))
           ((member token '("in" "from")) (setq bound t))
           ((member token '("to" "through")) (setq range t))
           ((equal token "{")
            (when (and type
                       (or (not (member type '("each_statement" "for_statement")))
                           (and variables bound
                                (or (equal type "each_statement") range))))
              (unless openings-scanned
                (setq openings-scanned t)
                (save-excursion
                  (let ((opening position))
                    (while (and (setq opening (nth 1 (syntax-ppss opening)))
                                (<= (treesit-node-start node) opening))
                      (push opening openings)))))
              (when (memq (treesit-node-start child) openings)
                (push (cl-list* type parameters (nreverse variables)) scopes)))
            (setq type nil parameters nil variables nil bound nil range nil))
           ((member token '(";" "}"))
            (setq type nil parameters nil variables nil bound nil range nil))))
        (setq index (1+ index)))
      scopes)))

(provide 'scss2-syntax)
;;; scss2-syntax.el ends here
