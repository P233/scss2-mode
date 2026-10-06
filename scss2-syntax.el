;;; scss2-syntax.el --- Shared CSS and SCSS syntax model -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The reading of the bundled grammar that context, completion and structural
;; editing share: parser access, identities, statements, blocks, values and
;; recovered scopes.  A rule needed by two features lives here; a feature
;; keeps only the type tables that it alone uses.  Lexical setup owns the
;; dialect's syntax table, comments and indentation, which need no parser;
;; syntax setup owns the buffer's dialect and parser identity; each command
;; owns its transient derived ranges.

;;; Code:

(require 'cl-lib)
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
  ;; A `clone-indirect-buffer' clone copies this hook but has no parser.
  (when (treesit-parser-list nil (scss2--language))
    (scss2--with-font-lock-view (scss2--root-node)))
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

(defvar editorconfig-indent-size-vars)

(defcustom scss2-indent-offset 2
  "Columns of indentation for each nesting level or continued statement."
  :type 'integer :safe #'integerp :group 'scss2)

(defconst scss2--css-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?/ ". 14" table)
    (modify-syntax-entry ?* ". 23b" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\' "\"" table)
    (pcase-dolist (`(,open . ,close) '((?{ . ?}) (?\( . ?\)) (?\[ . ?\])))
      (modify-syntax-entry open (string ?\( close) table)
      (modify-syntax-entry close (string ?\) open) table))
    ;; Name prefixes and hyphens belong to symbols, so `.a-b' and `#x' move as one.
    (dolist (char '(?@ ?# ?. ?-))
      (modify-syntax-entry char "_" table))
    (dolist (char '(?! ?$ ?% ?& ?+ ?, ?< ?> ?= ??))
      (modify-syntax-entry char "." table))
    table)
  "Syntax table of CSS buffers.")

(defconst scss2--scss-syntax-table
  (let ((table (make-syntax-table scss2--css-syntax-table)))
    (modify-syntax-entry ?/ ". 124" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?$ "_" table)
    (modify-syntax-entry ?% "_" table)
    table)
  "Syntax table of SCSS buffers, which add silent `//' comments.")

(defun scss2-syntax-lexical-setup (dialect)
  "Install DIALECT's syntax table, comments and indentation in this buffer.
None of them needs a parser, so a buffer whose parser is unavailable or
missing, such as a `clone-indirect-buffer' clone, still edits as a stylesheet."
  (set-syntax-table (if (eq dialect 'scss) scss2--scss-syntax-table scss2--css-syntax-table))
  (setq-local syntax-propertize-function #'scss2--syntax-propertize)
  (if (eq dialect 'scss)
      (setq-local comment-start "// " comment-end "" comment-continue " *"
                  comment-start-skip "/[*/]+[ \t]*"
                  comment-end-skip "[ \t]*\\(?:\n\\|\\*+/\\)")
    (setq-local comment-start "/*" comment-end "*/"
                comment-start-skip "/\\*+[ \t]*" comment-end-skip "[ \t]*\\*+/"))
  (setq-local indent-line-function #'scss2--indent-line)
  (setq-local editorconfig-indent-size-vars '(scss2-indent-offset))
  (setq-local electric-indent-chars (append '(?\} ?\;) electric-indent-chars)))

(defun scss2-syntax-setup (dialect)
  "Create DIALECT's parser after `scss2-syntax-lexical-setup'.
Own the parser identity shared by all stylesheet features.
Major-mode changes let Emacs discard the previous parser and local settings."
  (setq-local scss2-dialect dialect)
  (setq-local scss2--parser-language (scss2-grammar-ensure dialect))
  (treesit-parser-add-notifier (treesit-parser-create scss2--parser-language)
                               #'scss2--mark-changed-ranges)
  (scss2--query '((raw_text) @raw))
  (add-hook 'syntax-propertize-extend-region-functions
            #'syntax-propertize-wholelines nil t)
  (add-hook 'syntax-propertize-extend-region-functions
            #'scss2--extend-to-changed-start nil t)
  (unless scss2--idle-release-timer
    (scss2--schedule-idle-release)))

(defconst scss2--unquoted-url-rules
  (syntax-propertize-rules
   ("url\\((\\)[[:space:]]*\\(?:\\\\.\\|[^()[:space:]\n'\"]\\)+[[:space:]]*\\()\\)"
    (1 "|") (2 "|")))
  "Make an unquoted URL one string, so `//' or quotes in it start nothing.")

(defun scss2--syntax-propertize (start end)
  "Apply stylesheet syntax properties between START and END.
Raw CSS and unquoted URLs cannot start silent comments.  Correct the
syntax table there so indentation and comment commands see real code."
  (funcall scss2--unquoted-url-rules start end)
  ;; A `clone-indirect-buffer' clone or a buffer without a grammar has no parser.
  (when (and (scss2--language) (treesit-parser-list nil (scss2--language)))
    (dolist (node (scss2--with-font-lock-view
                    (treesit-query-capture
                     (scss2--root-node) (scss2--query '((raw_text) @raw)) start end t)))
      (save-excursion
        (goto-char (max start (treesit-node-start node)))
        (while (search-forward "/" (min end (treesit-node-end node)) t)
          (put-text-property (1- (point)) (point)
                             'syntax-table (string-to-syntax ".")))))))

(defconst scss2--statement-containers '("stylesheet" "declaration_block" "ERROR")
  "Nodes whose children are separate statements.")

(defun scss2--indent-line ()
  "Indent the current line as computed in Font Lock's view.
Inside a comment or string the line keeps its indentation, except that a
leading `*' aligns under the comment opener's star and a blank comment line
takes the previous line's indentation."
  (when-let* ((column (scss2--with-font-lock-view (scss2--line-indentation))))
    (if (<= (current-column) (current-indentation))
        (indent-line-to column)
      (save-excursion (indent-line-to column)))))

(defun scss2--line-indentation ()
  "Return the column for the current line's first character, or nil."
  (save-excursion
    (back-to-indentation)
    (let* ((state (syntax-ppss))
           (opening (nth 1 state))
           (base (if opening (scss2--opening-indentation opening) 0)))
      (cond
       ((nth 3 state) nil)
       ((nth 4 state)
        (cond ((eq (char-after) ?*)
               (save-excursion (goto-char (nth 8 state)) (1+ (current-column))))
              ((eolp) (save-excursion (forward-line -1) (current-indentation)))))
       ((memq (char-after) '(?\} ?\) ?\])) base)
       ((scss2--continued-statement opening))
       (opening (or (scss2--sibling-indentation opening) (+ base scss2-indent-offset)))
       (t 0)))))

(defun scss2--sibling-indentation (opening)
  "Return the indentation of the previous statement line inside OPENING, or nil.
Following it keeps a block's own indentation when it differs from the offset."
  (save-excursion
    (catch 'found
      (while (and (zerop (forward-line -1)) (> (point) opening))
        (back-to-indentation)
        (let* ((state (syntax-ppss))
               (nested (cadr (memq opening (nth 9 state)))))
          ;; Inside a nested bracket, resume at the line that opens it.
          (when nested
            (goto-char nested)
            (back-to-indentation)
            (setq state (syntax-ppss)))
          (when (and (not (eolp)) (eql (nth 1 state) opening) (not (nth 8 state))
                     (not (memq (char-after) '(?\} ?\) ?\])))
                     (not (scss2--continued-statement opening)))
            (throw 'found (current-indentation)))))
      nil)))

(defun scss2--opening-indentation (opening)
  "Return the indentation that the bracket at OPENING nests from.
A `{' nests from the first line of the statement it opens, which can be
an earlier line of a selector list; other brackets nest from their line."
  (save-excursion
    (goto-char opening)
    (when-let* (((eq (char-after) ?{))
                (language (scss2--language))
                ((treesit-parser-list nil language))
                (brace (treesit-node-at opening language))
                ((equal (treesit-node-type brace) "{"))
                (owner (treesit-node-parent brace))
                ((not (member (treesit-node-type owner) scss2--statement-containers))))
      (goto-char (treesit-node-start owner)))
    (current-indentation)))

(defun scss2--continued-statement (opening)
  "Return the column of point's line if it continues an earlier statement.
OPENING is the innermost open bracket.  The next item of a selector list,
an `@else' branch or a lone `{' aligns with the statement's first line;
any other continuation indents once more."
  (when-let* ((language (scss2--language))
              (_ (treesit-parser-list nil language)))
    (let* ((bol (point))
           (previous (save-excursion (skip-chars-backward " \t\n") (point)))
           ;; A blank line has no token: continue a trailing `,' or `:', else take the node around it.
           (trailing (and (eolp) (memq (char-before previous) '(?, ?:))))
           (node (cond (trailing (treesit-node-at (1- previous) language))
                       ((eolp) (treesit-node-on bol bol language))
                       (t (treesit-node-at bol language))))
           statement)
      (while (and node (> (treesit-node-start node) (or opening 0))
                  (not (member (treesit-node-type node) scss2--statement-containers)))
        (setq statement node node (treesit-node-parent node)))
      (when (and statement (< (treesit-node-start statement) bol)
                 (if trailing
                     (member (treesit-node-type statement)
                             '("property_declaration" "variable_declaration"))
                   (< bol (treesit-node-end statement))))
        (let* ((child (treesit-node-first-child-for-pos statement bol t))
               (selectors (cond ((equal (treesit-node-type statement) "selectors") statement)
                                ((and child (equal (treesit-node-type child) "selectors")) child)))
               (item (and selectors (treesit-node-first-child-for-pos selectors bol t)))
               ;; A line inside one selector of a list continues that selector.
               (anchor (if (and item (< (treesit-node-start item) bol)) item statement)))
          (cond
           ;; A line that starts no earlier item's text begins the next one.
           ((or (eq (char-after bol) ?{)
                (and child (>= (treesit-node-start child) bol)
                     (equal (treesit-node-type child) "else_clause"))
                (and selectors (or (null item) (>= (treesit-node-start item) bol))))
            (save-excursion (goto-char (treesit-node-start statement)) (current-indentation)))
           ;; Later continuation lines follow the previous one, as typed.
           ((save-excursion
              (forward-line -1)
              (while (and (looking-at-p "[ \t]*$") (> (point) (treesit-node-start anchor)))
                (forward-line -1))
              (back-to-indentation)
              (and (> (point) (treesit-node-start anchor))
                   (eql (nth 1 (syntax-ppss)) opening)
                   (current-indentation))))
           (t (+ (save-excursion (goto-char (treesit-node-start anchor)) (current-indentation))
                 scss2-indent-offset))))))))

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

(defconst scss2--comment-types '("block_comment" "inline_comment")
  "Comment node types shared by context and structural editing.")

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

(defun scss2--identifier-text (node)
  "Return NODE's static spelling, or nil for a dynamic identifier."
  (when (and node
             (or (zerop (treesit-node-child-count node))
                 (not (treesit-search-subtree node "interpolation"))))
    (buffer-substring-no-properties (treesit-node-start node) (treesit-node-end node))))

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
