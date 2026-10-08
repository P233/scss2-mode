;;; scss2-edit.el --- Structural CSS and SCSS editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Entity commands share one selection of declarations, statements, comments,
;; map entries and complete blocks.
;; Empty resolves content independently.  Targets live for one command only.

;;; Code:

(require 'cl-lib)
(require 'newcomment)
(require 'pulse)
(require 'scss2-syntax)
(require 'subr-x)
(declare-function yas-active-snippets "yasnippet" (&optional beg end))
(declare-function yas-next-field "yasnippet" (&optional arg))
(declare-function company-abort "company" ())
(declare-function avy-goto-word-0 "avy" (arg &optional beg end))
(defvar avy-all-windows)
(defvar avy-all-windows-alt)

(defcustom scss2-entity-node-types (cons "map_entry" (copy-sequence scss2--statement-types))
  "Tree-sitter node types shared by kill, copy, duplicate, mark and comment.
By default, a map entry, declaration or leaf statement selects itself.
A rule or at-rule header selects its complete block.  Conditional branches
select the whole conditional.  On a selector or in a block body's
inter-statement whitespace, all entity commands select the complete
enclosing rule or block, regardless of this option.
Existing comments always select their complete comment group.
All entity commands ascend from point to the nearest matching ancestor.
In an `@if' or `@else if' condition, kill selects only the condition.
Empty resolves internal contents and Avy resolves navigation separately."
  :type '(repeat string)
  :group 'scss2)

(cl-defstruct (scss2--target (:constructor scss2--make-target))
  "A transient selection, validated by OWNER, spanning BEG to END.
Map entries carry BEFORE and AFTER commas and their COUNT.
SEPARATOR describes how to duplicate the selected entity."
  owner beg end before after count separator)

(defun scss2--node-target (node &optional separator)
  "Make a target for NODE, with optional duplication SEPARATOR."
  (scss2--make-target :owner node :beg (treesit-node-start node)
                      :end (treesit-node-end node) :separator separator))

(defun scss2--check-target (target &optional navigation)
  "Return TARGET, or reject it when no reliable edit range exists.
A missing target, one outside the accessible buffer and one whose
boundaries depend on parser recovery are all rejected.  For NAVIGATION,
which changes no text, an accessible target suffices."
  (unless target (user-error "No stylesheet target here"))
  (unless (<= (point-min) (scss2--target-beg target)
              (scss2--target-end target) (point-max))
    (user-error "This target extends outside the accessible buffer"))
  (let ((node (and (not navigation) (scss2--target-owner target))))
    (when (and node (or (treesit-node-check node 'has-error)
                        (treesit-node-check node 'missing)))
      (user-error "This syntax is incomplete; no reliable edit range"))
    (while node
      (when (equal (treesit-node-type node) "ERROR")
        (user-error "This syntax is incomplete; no reliable edit range"))
      ;; A recovered block header cannot establish the meaning of its body.
      ;; Errors in unrelated body statements do not invalidate this target.
      (when-let* ((_ (member (treesit-node-type node) scss2--statement-types))
                  (opening (scss2--child node "{")))
        (when (cl-some
               (lambda (child)
                 (and (< (treesit-node-start child) (treesit-node-start opening))
                      (or (treesit-node-check child 'has-error)
                          (treesit-node-check child 'missing))))
               (scss2--children node))
          (user-error "This block header is incomplete; no reliable edit range")))
      (setq node (treesit-node-parent node))))
  target)

(defun scss2--comment-p (node)
  "Whether NODE is a stylesheet comment."
  (member (treesit-node-type node) scss2--comment-types))

(defun scss2--statement-p (node)
  "Whether NODE is a stylesheet statement."
  (member (treesit-node-type node) scss2--statement-types))

(defun scss2--selector-owner (node)
  "Find the outer selector list before NODE's nearest statement.
Nested pseudo-class selector lists belong to the enclosing branch."
  (let (selectors)
    (while (and node (not (scss2--statement-p node)))
      (when (equal (treesit-node-type node) "selectors") (setq selectors node))
      (setq node (treesit-node-parent node)))
    (and node (equal (treesit-node-type node) "rule_set") selectors)))

(defun scss2--map-entry-target (node)
  "Select map entry NODE and record its direct comma neighbors.
The map owns validation because deletion also relies on its separators."
  (let ((map (treesit-node-parent node)) before after seen (count 0))
    (dolist (child (scss2--children map))
      (pcase (treesit-node-type child)
        ("map_entry"
         (cl-incf count)
         (when (treesit-node-eq child node) (setq seen t)))
        ("," (if seen
                 (unless after (setq after child))
               (setq before child)))))
    (scss2--make-target :owner map :beg (treesit-node-start node)
                        :end (treesit-node-end node) :before before :after after
                        :count count :separator 'comma)))

(defun scss2--covering-node (position)
  "Return the smallest token covering POSITION, or nil on whitespace."
  (unless (memq (char-after position) '(nil ?\s ?\t ?\n ?\r ?\f))
    (let ((node (treesit-node-at position (scss2--language))))
      (while (and node (not (and (<= (treesit-node-start node) position)
                                 (< position (treesit-node-end node)))))
        (setq node (treesit-node-parent node)))
      node)))

(defun scss2--touched-node ()
  "Return the token at point or immediately before it.
In whitespace inside a statement, string or comment, return that node;
whitespace between statements touches nothing."
  (or (scss2--covering-node (point))
      (and (> (point) (point-min)) (scss2--covering-node (1- (point))))
      (when-let* ((node (scss2--containing-node)))
        (unless (or (member (treesit-node-type node) scss2--statement-containers)
                    (when-let* ((body (scss2--block-bounds node)))
                      (<= (car body) (point) (cdr body)))
                    ;; A blank line touches no token outside a string or comment.
                    (and (save-excursion (beginning-of-line) (looking-at-p "[ \t]*\r?$"))
                         (not (scss2--ancestor node (cons "string" scss2--comment-types)))))
          node))))

(defun scss2--containing-node ()
  "Return the nearest node whose source bounds contain point."
  (let ((node (scss2--node-at-point)))
    (while (and node (not (scss2--contains-point-p node)))
      (setq node (treesit-node-parent node)))
    node))

(defun scss2--entry-at-point ()
  "Return the entry whose tail before a direct delimiter contains point.
Only whitespace may follow its end, up to a comma or closing parenthesis.
A comma already passed, a comment or a nested delimiter breaks the tail."
  (let* ((end (save-excursion (skip-chars-backward " \t\r\n\f") (point)))
         (node (and (> end (point-min))
                    (treesit-node-at (1- end) (scss2--language))))
         entry)
    (while (and node (not entry) (<= (treesit-node-end node) end))
      (when (and (= (treesit-node-end node) end)
                 (member (treesit-node-type node)
                         '("map_entry" "named_argument" "parameter"))
                 (member (treesit-node-type (treesit-node-parent node))
                         '("map" "arguments" "parameters" "configuration")))
        (when-let* ((next (treesit-node-next-sibling node))
                    (_ (member (treesit-node-type next) '("," ")")))
                    (_ (not (treesit-node-check next 'missing)))
                    (_ (<= (point) (treesit-node-start next))))
          (setq entry node)))
      (setq node (treesit-node-parent node)))
    entry))

(defun scss2--block-node (node &optional branch)
  "Find the nearest structural block around NODE.
Unless BRANCH is non-nil, an else branch selects its entire conditional."
  (while (and node (not (scss2--block-bounds node)))
    (setq node (treesit-node-parent node)))
  (if (and node (not branch) (equal (treesit-node-type node) "else_clause"))
      (treesit-node-parent node)
    node))

(defun scss2--body-whitespace-block (node &optional branch)
  "Return NODE's structural block when point is in its body whitespace.
Whitespace inside a value, string or comment keeps that entity's owner.
An entity's end belongs to the following gap; the closing brace belongs
to its block, including an empty body.  With BRANCH, keep the current
conditional branch instead of selecting the whole conditional."
  (when (memq (char-after) '(?\s ?\t ?\n ?\r ?\f ?}))
    (while (and node (= (point) (treesit-node-end node)))
      (setq node (treesit-node-parent node)))
    (when (member (treesit-node-type node) '("declaration_block" "}"))
      (setq node (treesit-node-parent node)))
    (when-let* ((body (scss2--block-bounds node))
                (_ (<= (car body) (point) (cdr body))))
      (scss2--block-node node branch))))

(defun scss2--resolve-target-1 (kind)
  "Resolve entity KIND in the current tree view.
Entity commands share configured code types and complete comment groups.
KIND may request TAB's map entry or declaration, or allow kill's if-condition
target.  Selectors and body whitespace share block boundaries."
  (let ((node (scss2--containing-node)))
    (pcase kind
      ('property
       ;; Map keys own their values; values keep declaration navigation.
       (when-let* ((owner
                    (or (when-let* ((entry (scss2--ancestor node '("map_entry")))
                                    (colon (scss2--child entry ":"))
                                    (_ (<= (point) (treesit-node-start colon))))
                          entry)
                        (scss2--ancestor node scss2--declaration-types))))
         (scss2--node-target owner)))
      (_
       (let* ((blank-block (scss2--body-whitespace-block node))
              (touched (scss2--touched-node))
              (comment (and (not blank-block)
                            (scss2--ancestor touched scss2--comment-types)))
              (selectors (scss2--selector-owner touched)))
         (cond
          (blank-block (scss2--node-target blank-block 'statement))
          (comment (scss2--comment-target comment))
          (selectors
           (scss2--node-target (treesit-node-parent selectors) 'statement))
          (t
           (when-let* ((selected
                       (scss2--ancestor (or (scss2--entry-at-point) node)
                                        scss2-entity-node-types)))
             (cond
              ((equal (treesit-node-type selected) "map_entry")
               (scss2--map-entry-target selected))
              ((and (eq kind 'kill)
                    (member (treesit-node-type selected) '("if_statement" "else_clause"))
                    (treesit-node-child-by-field-name selected "condition")
                    (when-let* ((head (scss2--value-bounds selected)))
                      (and (<= (car head) (point)) (< (point) (cdr head))
                           (scss2--make-target :owner selected :beg (car head)
                                               :end (cdr head))))))
              (t (scss2--node-target
                  (if (equal (treesit-node-type selected) "else_clause")
                      (treesit-node-parent selected)
                    selected)
                  'statement)))))))))))

(defun scss2--resolve-target (&optional kind)
  "Resolve KIND in Font Lock's view and enforce accessible edit bounds."
  (scss2--check-target
   (scss2--with-font-lock-view (scss2--resolve-target-1 kind))))

(defun scss2--interior (node &optional at-point)
  "Return NODE's delimited interior, using a call's argument container.
With AT-POINT, require the delimiters to surround point.  This also handles
multiple direct pairs, such as the two selector parentheses in @scope."
  (let (openings bounds)
    (dolist (child (scss2--children node))
      (unless (treesit-node-check child 'missing)
        (let* ((type (if (and (equal (treesit-node-type node) "raw_group")
                              (equal (treesit-node-text child t) "#{"))
                         "#{"
                       (treesit-node-type child)))
               (expected (pcase (caar openings)
                           ("(" ")") ("[" "]") ((or "{" "#{") "}")
                           ((and (or "\"" "'") quotation) quotation))))
          (cond
           ((and openings (equal type expected))
            (let ((opening (cdr (pop openings))))
              (when (and (not bounds)
                         (if at-point
                             (<= (treesit-node-start opening) (point) (treesit-node-start child))
                           (null openings)))
                (setq bounds (cons (treesit-node-end opening) (treesit-node-start child))))))
           ((member type '("(" "[" "{" "#{" "\"" "'"))
            (push (cons type child) openings))))))
    (or bounds
        (when-let* ((arguments (scss2--child node "arguments")))
          (scss2--interior arguments at-point)))))

(defun scss2--value-bounds (node)
  "Return NODE's trimmed value or at-rule head as (BEG . END).
Start after a declaration, entry or parameter colon, or an at-rule directive,
preserving the whole @else if prefix.  Stop before the direct
semicolon or block.  Include comments and flags such as !important.
An empty value or head has equal beginning and end."
  (let ((begin (and (scss2--directive node)
                    (treesit-node-end
                     (or (and (equal (treesit-node-type node) "else_clause")
                              (scss2--child node "if"))
                         (treesit-node-child node 0)))))
        end)
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

(defun scss2--entry-value (node)
  "Return NODE's map entry, named argument or parameter value bounds.
A parameter without a default value has no bounds."
  (when (member (treesit-node-type node) '("map_entry" "named_argument" "parameter"))
    (scss2--value-bounds node)))

(defun scss2--content-target ()
  "Resolve the nearest editable content at point."
  (scss2--check-target
   (scss2--with-font-lock-view
    (let* ((at-point (or (scss2--entry-at-point) (scss2--containing-node)))
           (node (or (scss2--body-whitespace-block at-point t) at-point))
           (statement (scss2--ancestor node scss2--statement-types))
           bounds owner)
      (while (and node (not bounds))
        (cond
         ((scss2--statement-p node)
          (let* ((body (scss2--block-bounds node))
                 (name (treesit-node-child-by-field-name node "name"))
                 (parameters
                  (and (or (not body)
                           (scss2--contains-point-p name)
                           (scss2--contains-point-p
                            (treesit-node-child-by-field-name node "module")))
                       (if name
                           ;; A later clause's list does not belong to NAME.
                           (let ((next (treesit-node-next-sibling name)))
                             (while (scss2--comment-p next)
                               (setq next (treesit-node-next-sibling next)))
                             (and (member (treesit-node-type next) '("arguments" "parameters"))
                                  next))
                         (scss2--child node "arguments")))))
            (if (and parameters (setq bounds (scss2--interior parameters)))
                (setq owner (if body parameters node))
              (setq owner node
                    bounds
                    (cond
                     ;; Direct header parentheses can share a statement
                     ;; with its body, without a separate container node.
                     ((scss2--directive node)
                      (or (scss2--interior node t) body
                          (when-let* ((head (scss2--value-bounds node))
                                      (_ (< (car head) (cdr head))))
                            head)))
                     ((and body (>= (point) (1- (car body)))) body)
                     (t (or (scss2--value-bounds node) body))))))
          ;; A leaf without content keeps looking for an enclosing body.
          (unless bounds (setq node (treesit-node-parent node))))
         ((scss2--comment-p node) (setq node nil))
         ;; Inside interpolation, a call's name selects the interpolation.
         ((and (equal (treesit-node-type (treesit-node-parent node)) "interpolation")
               (when-let* ((interior (scss2--interior node)))
                 (and (eq (char-before (car interior)) ?\()
                      (< (point) (1- (car interior))))))
          (setq node (treesit-node-parent node)))
         ((setq bounds (or (scss2--entry-value node) (scss2--interior node)))
          ;; Errors in a block's body leave its header's content reliable.
          (setq owner (if (and statement (not (scss2--block-bounds statement)))
                          statement
                        node)))
         (t (setq node (treesit-node-parent node)))))
      (if bounds
          (scss2--make-target :owner owner :beg (car bounds) :end (cdr bounds))
        (user-error "Nothing to empty here"))))))

(defun scss2--declaration-tab-target (&optional name-only)
  "Return where TAB moves within a declaration or map entry, or nil.
From a name or map key, move to its value, past any comment; from a value,
move past the enclosing declaration's direct semicolon, including inside
strings, URLs, comments, maps and nested calls.  Return nil for an
inaccessible target, one without a direct colon or value, and a value
without `;'.  With NAME-ONLY, only move from a name or map key to its value."
  (when-let* ((target (condition-case nil (scss2--resolve-target 'property)
                       (user-error nil)))
              (owner (scss2--target-owner target))
              (colon (scss2--child owner ":")))
    (if (<= (point) (treesit-node-start colon))
        (when-let* ((value (treesit-node-child-by-field-name owner "value")))
          (treesit-node-start value))
      (when-let* ((_ (not name-only))
                  (semicolon (scss2--child owner ";"))
                  (_ (<= (point) (treesit-node-start semicolon))))
        (treesit-node-end semicolon)))))

(defun scss2--tab-indentation-p ()
  "Whether point precedes the first nonblank character of a nonempty line.
An active region keeps its existing TAB behavior."
  (and (not (use-region-p))
       (let ((position (point)))
         (save-excursion
           (back-to-indentation)
           (and (< position (point)) (not (looking-at-p "\r?$")))))))

(defun scss2--tab-binding (command)
  "Use COMMAND for leading indentation or declaration navigation.
Resolve this during key lookup so frontend pre-command hooks see their own
command when neither action applies."
  (and (or (scss2--tab-indentation-p) (scss2--declaration-tab-target)) command))

(defun scss2--tab-remapping (command)
  "Remap COMMAND only while reading a plain TAB key.
Frontend overlay and overriding maps precede the host's keymap.  Their
commands need remapping for TAB, but keep any other keys the user binds."
  (let ((keys (this-single-command-keys)))
    (and (= (length keys) 1)
         (memq (aref keys 0) '(?\t tab))
         (scss2--tab-binding command))))

(defvar scss2--tab-map-alist
  `((scss2-dialect . ,(let ((map (make-sparse-keymap)))
                      (dolist (key '("TAB" "<tab>"))
                        (define-key map (kbd key)
                                    '(menu-item "Indent or move through declaration" scss2-tab
                                                :filter scss2--tab-binding)))
                      (dolist (command '(yas-next-field yas-next-field-or-maybe-expand
                                         company-complete-common-or-cycle))
                        (define-key map (vector 'remap command)
                                    '(menu-item "Indent or move through declaration" scss2-tab
                                                :filter scss2--tab-remapping)))
                      map)))
  "Leading indentation and declaration navigation precede frontend TAB maps.
The existing buffer-local dialect enables it only in stylesheet buffers.")

;;;###autoload
(defun scss2-tab ()
  "Indent leading whitespace, or move through a declaration or map entry.
Before a nonempty line's first character, indent and move to that character.
From a declaration's name or map key move to its value; from a value, move
past the enclosing declaration's `;'.
Before moving from a name or key, reindent its line unless a region is active
or the line's beginning is outside the accessible buffer.
Dismiss an open completion menu without accepting a candidate.  Elsewhere
move to the next snippet field, or indent with `indent-for-tab-command'."
  (interactive)
  (let ((indent (scss2--tab-indentation-p)))
    (if (or indent (scss2--declaration-tab-target))
        (progn
          (when completion-in-region-mode (completion-in-region-mode -1))
          (when (and (bound-and-true-p company-candidates) (fboundp 'company-abort))
            (company-abort))
          (if indent
              (progn
                (indent-according-to-mode)
                (back-to-indentation)
                (deactivate-mark))
            ;; Resolve after dismissing previews, and again after indentation.
            (when (and (not (use-region-p)) (scss2--declaration-tab-target t)
                       (<= (point-min)
                           (save-restriction (widen) (line-beginning-position))))
              (indent-according-to-mode))
            (when-let* ((destination (scss2--declaration-tab-target)))
              (goto-char destination)
              (deactivate-mark))))
      (if (and (fboundp 'yas-active-snippets) (yas-active-snippets))
          (yas-next-field)
        (call-interactively #'indent-for-tab-command)))))

(defmacro scss2--transaction (&rest body)
  "Evaluate BODY as one edit, restoring editor state on failure."
  (declare (indent 0) (debug t))
  `(let* ((saved-point (point))
          (saved-mark (mark t))
          (saved-active mark-active)
          (saved-deactivate deactivate-mark)
          (saved-ring (copy-sequence kill-ring))
          (saved-yank-index (and kill-ring-yank-pointer
                                 (- (length kill-ring) (length kill-ring-yank-pointer)))))
     (condition-case error-data
         (atomic-change-group
           (save-current-buffer ,@body))
       ((error quit)
        (goto-char saved-point)
        (set-marker (mark-marker) saved-mark)
        (setq mark-active saved-active deactivate-mark saved-deactivate
              kill-ring saved-ring
              kill-ring-yank-pointer (and saved-yank-index (nthcdr saved-yank-index saved-ring)))
        (signal (car error-data) (cdr error-data))))))

(defun scss2--whitespace-p (begin end)
  "Whether the range BEGIN to END contains only whitespace."
  (string-match-p "\\`[ \t\r\n]*\\'" (buffer-substring-no-properties begin end)))

(defun scss2--deletion-ranges (target)
  "Return TARGET's deletion ranges, preserving comments around its comma."
  (let ((begin (scss2--target-beg target)) (end (scss2--target-end target))
        (owner (scss2--target-owner target))
        (after (scss2--target-after target)) (before (scss2--target-before target)))
    (when-let* ((comma (or after before)))
      (unless (<= (point-min) (treesit-node-start comma)
                  (treesit-node-end comma) (point-max))
        (user-error "The adjacent comma is outside the accessible buffer")))
    (cond
     ;; An empty @at-root query is omitted; unlike a value, it cannot be ().
     ((and (equal (treesit-node-type owner) "map")
           (eql (scss2--target-count target) 1)
           (equal (treesit-node-type (treesit-node-parent owner)) "at_root_statement"))
      (cons (cons begin end)
            (mapcar
             (lambda (token)
               (unless (<= (point-min) (treesit-node-start token)
                           (treesit-node-end token) (point-max))
                 (user-error "The map delimiter is outside the accessible buffer"))
               (cons (treesit-node-start token) (treesit-node-end token)))
             (delq nil (list (scss2--child owner "(") after (scss2--child owner ")"))))))
     (after
      (let ((beg (treesit-node-start after)) (finish (treesit-node-end after)))
        (if (scss2--whitespace-p end beg)
            (list (cons begin (save-excursion (goto-char finish)
                                             (skip-chars-forward " \t") (point))))
          (list (cons beg finish) (cons begin end)))))
     (before
      (let ((beg (treesit-node-start before)) (finish (treesit-node-end before)))
        (if (scss2--whitespace-p finish begin)
            (list (cons beg end))
          (list (cons begin end) (cons beg finish)))))
     (t (list (cons begin end))))))

(defun scss2--whole-lines (range)
  "Return RANGE extended over its lines, or nil when other text shares them.
Lines are judged in Font Lock's view; the result stays accessible."
  (let ((accessible-beg (point-min)) (accessible-end (point-max)))
    (save-excursion
      (scss2--with-font-lock-view
        (let ((begin (progn (goto-char (car range)) (skip-chars-backward " \t") (point)))
              (end (progn (goto-char (cdr range)) (skip-chars-forward " \t\r") (point))))
          (when (and (progn (goto-char begin) (bolp))
                     (progn (goto-char end) (eolp)))
            (cons (max begin accessible-beg)
                  (min (if (eobp) end (1+ end)) accessible-end))))))))

(defun scss2--kill-target (target)
  "Kill TARGET and its separator, taking whole lines when possible."
  (let* ((ranges (sort (scss2--deletion-ranges target)
                       (lambda (a b) (> (car a) (car b)))))
         (lines (and (null (cdr ranges)) (scss2--whole-lines (car ranges))))
         (ranges (if lines (list lines) ranges))
         (begin (caar (last ranges)))
         (text (mapconcat (lambda (range)
                           (buffer-substring-no-properties (car range) (cdr range)))
                         (reverse ranges) "")))
    (scss2--transaction
      (dolist (range ranges) (delete-region (car range) (cdr range)))
      (goto-char begin)
      (when lines
        ;; Lines killed between blank lines leave one blank line behind.
        (when (and (looking-at-p "[ \t]*\r?\n")
                   (save-excursion
                     (and (zerop (forward-line -1)) (looking-at-p "[ \t]*\r?\n"))))
          (delete-region (point) (line-beginning-position 2)))
        (back-to-indentation))
      (unless (string-empty-p text) (kill-new text)))))

;;;###autoload
(defun scss2-kill ()
  "Kill the code entity selected by `scss2-entity-node-types', or a comment.
On a selector, always kill its complete rule, including the selector
list and block body.  In a block body's inter-statement whitespace,
kill that complete block.  Both ignore the configured node types.
Consecutive standalone // comment lines are killed together.
Inside a map entry, kill the key/value pair and an adjacent comma, keeping
surrounding comments.  An empty map retains (); an empty @at-root query
also loses its parentheses.
In an @if or @else if condition, kill that condition, keeping the directive
and body.  The @else if prefix stays together.  A map entry remains a nearer
entity.  Other at-rule headers, directives and opening braces select the
complete statement or block."
  (interactive)
  (scss2--kill-target (scss2--resolve-target 'kill)))

;;;###autoload
(defun scss2-empty ()
  "Kill the nearest delimited interior, named value or block body.
Brackets, interpolation and string quotes delimit interiors.  A map entry
or named argument empties its value as a declaration does.  A parameter
with a default empties that value.  Function names select their associated
argument or parameter list; a blockless directive can also select that list.
Otherwise, walk upward until an editable interior, value or body is found.
An at-rule keyword selects its body.  A parenthesized condition selects the
parentheses; a condition without a nearer content target selects the body.
A leaf without content continues to its enclosing block.  Comments stop
the search.  A blockless at-rule with no nearer content target clears its
nonempty head, keeping the directive and semicolon."
  (interactive)
  (let ((target (scss2--content-target)))
    (scss2--transaction
      (let ((text (buffer-substring-no-properties
                   (scss2--target-beg target) (scss2--target-end target))))
        (delete-region (scss2--target-beg target) (scss2--target-end target))
        (goto-char (scss2--target-beg target))
        (unless (string-empty-p text) (kill-new text))))))

;;;###autoload
(defun scss2-copy ()
  "Copy the configured entity, preserving point and mark.
Copy consecutive standalone // lines together and highlight what was copied."
  (interactive)
  (let ((target (scss2--resolve-target)))
    (scss2--transaction
      (kill-new (buffer-substring-no-properties
                 (scss2--target-beg target) (scss2--target-end target))))
    (pulse-momentary-highlight-region (scss2--target-beg target) (scss2--target-end target))))

(defun scss2--end-of-trailing-comment (position)
  "Return the end of a comment that follows POSITION on its line, or POSITION."
  (save-excursion
    (goto-char position)
    (skip-chars-forward " \t")
    (if-let* ((comment (scss2--ancestor (scss2--covering-node (point)) scss2--comment-types)))
        (treesit-node-end comment)
      position)))

(defun scss2--comma-separator (target)
  "Return the comma and following whitespace that join TARGET's map entries."
  (if-let* ((comma (or (scss2--target-before target) (scss2--target-after target))))
      (save-excursion
        (scss2--with-font-lock-view
          (goto-char (treesit-node-end comma))
          (concat "," (buffer-substring-no-properties
                       (point) (progn (skip-chars-forward " \t\r\n") (point))))))
    ", "))

;;;###autoload
(defun scss2-duplicate ()
  "Duplicate the entity, preserving its body text and the kill ring.
Consecutive standalone // comment lines are duplicated together; line
comments get a new line rather than a statement separator.
Briefly highlight the copy."
  (interactive)
  (let* ((target (scss2--resolve-target))
         (text (buffer-substring-no-properties
                (scss2--target-beg target) (scss2--target-end target))))
    (scss2--transaction
      (goto-char (scss2--target-end target))
      (insert
       (if (eq (scss2--target-separator target) 'comma)
           (scss2--comma-separator target)
         (concat
          (when (and (eq (scss2--target-separator target) 'statement)
                     (not (string-suffix-p ";" text))
                     (not (scss2--block-bounds (scss2--target-owner target)))) ";")
          (if (or (equal (treesit-node-type (scss2--target-owner target)) "inline_comment")
                  (scss2--whole-lines (cons (scss2--target-beg target)
                                            (scss2--end-of-trailing-comment
                                             (scss2--target-end target)))))
              (concat
               (save-excursion
                 (end-of-line)
                 (when (eobp) (search-backward "\n" nil t))
                 (if (eq (char-before) ?\r) "\r\n" "\n"))
               (save-excursion
                 (goto-char (scss2--target-beg target))
                 (buffer-substring-no-properties
                  (line-beginning-position) (progn (back-to-indentation) (point)))))
            " "))))
      (insert text)
      (pulse-momentary-highlight-region (- (point) (length text)) (point)))))

;;;###autoload
(defun scss2-mark ()
  "Select the nearest map entry or entity using the shared code boundaries.
On a selector or in body whitespace, select the complete rule or block.
Repeated calls keep the same selection.
Consecutive standalone // comment lines are selected together."
  (interactive)
  (unless (and (eq last-command 'scss2-mark) (region-active-p))
    (let ((target (scss2--resolve-target)))
      (goto-char (scss2--target-beg target))
      (push-mark (scss2--target-end target) t)
      (activate-mark))))

(defun scss2--comment-target (node)
  "Select NODE, grouping adjacent standalone // comment lines."
  (let ((first node) (last node))
    (when (equal (treesit-node-type node) "inline_comment")
      (cl-labels ((standalone (comment)
                    (and comment (equal (treesit-node-type comment) "inline_comment")
                         (save-excursion
                           (goto-char (treesit-node-start comment))
                           (skip-chars-backward " \t") (bolp))))
                  (adjacent (left right)
                    (and (standalone left) (standalone right)
                         (string-match-p
                          "\\`[ \t]*\r?\n[ \t]*\\'"
                          (buffer-substring-no-properties
                           (treesit-node-end left) (treesit-node-start right))))))
        (while (adjacent (treesit-node-prev-sibling first) first)
          (setq first (treesit-node-prev-sibling first)))
        (while (adjacent last (treesit-node-next-sibling last))
          (setq last (treesit-node-next-sibling last)))))
    (scss2--make-target :owner node :beg (treesit-node-start first)
                        :end (treesit-node-end last))))

;; Uncommenting removes padding at a range's edge along with its markers.
(defun scss2--comment-range ()
  "Return (BEGIN END LINE-COMMENT) for commenting the entity at point.
Separator whitespace stays outside the range; LINE-COMMENT selects // markers."
  (let* ((target (scss2--resolve-target))
         (ranges (scss2--deletion-ranges target))
         (begin (apply #'min (mapcar #'car ranges)))
         (end (save-excursion
                (goto-char (apply #'max (mapcar #'cdr ranges)))
                (skip-chars-backward " \t" begin)
                (point)))
         ;; Inline // would also hide code after the target.
         (line-comment (and (eq scss2-dialect 'scss)
                            (not (eq (scss2--target-separator target) 'comma))
                            (scss2--whole-lines (cons begin end))
                            t)))
    (when line-comment
      ;; Give the native command every line's full indentation.
      (setq begin (save-excursion (goto-char begin) (line-beginning-position)))
      ;; At CRLF's CR, newcomment otherwise inserts an extra LF.
      (setq end (save-excursion (goto-char end) (skip-chars-forward " \t\r") (point))))
    (list begin end line-comment)))

(defun scss2--uncomment-range (comment)
  "Return (BEGIN END LINE-COMMENT) for COMMENT's complete comment group."
  (let ((target (scss2--check-target
                 (scss2--with-font-lock-view
                   (scss2--comment-target comment)))))
    (list (scss2--target-beg target) (scss2--target-end target)
          (equal (treesit-node-type comment) "inline_comment"))))

;;;###autoload
(defun scss2-comment-uncomment ()
  "Comment code selected by `scss2-entity-node-types', or uncomment at point.
Uncomment a whole run of consecutive standalone // lines, or one block
or trailing comment.  Line comments use Emacs's `indent' comment style,
which aligns // markers at the region's minimum indentation."
  (interactive)
  (let ((comment (scss2--with-font-lock-view
                   (scss2--ancestor (scss2--touched-node) scss2--comment-types))))
    (pcase-let ((`(,begin ,end ,line-comment)
                 (if comment
                     (scss2--uncomment-range comment)
                   (scss2--comment-range))))
      (scss2--transaction
        (let ((comment-start (if line-comment "// " "/* "))
              (comment-end (if line-comment "" " */"))
              (comment-empty-lines t)
              (comment-style (if line-comment 'indent 'multi-line)))
          (if comment (uncomment-region begin end) (comment-region begin end)))))))

(defun scss2--navigation-target ()
  "Find the nearest complete multiline container around point.
Blocks include their headers; an else branch keeps its whole conditional.
Maps, lists and module configurations keep their delimiters.
Point after a container's closing delimiter belongs to its parent."
  (let ((node (scss2--containing-node)) target)
    (while (and node (= (point) (treesit-node-end node)))
      (setq node (treesit-node-parent node)))
    (while (and node (not target))
      (when (equal (treesit-node-type node) "else_clause")
        (setq node (treesit-node-parent node)))
      (when (and (or (scss2--block-bounds node)
                     (and (member (treesit-node-type node)
                                  '("map" "list" "configuration"))
                          (scss2--interior node)))
                 (save-excursion
                   (goto-char (treesit-node-start node))
                   (search-forward "\n" (treesit-node-end node) t)))
        (setq target (scss2--node-target node)))
      (setq node (treesit-node-parent node)))
    target))

;;;###autoload
(defun scss2-avy-word ()
  "Jump to a word in the nearest complete multiline container.
Containers include rule, at-rule and nested property blocks, maps, lists
and module configurations.  Single-line containers continue upward.
The invocation fixes the full range, including headers and delimiters;
other windows are not searched.  Requires the optional Avy package."
  (interactive)
  (unless (require 'avy nil t) (user-error "Install Avy to use scss2-avy-word"))
  (let ((target
         (scss2--check-target
          (scss2--with-font-lock-view
            (scss2--navigation-target))
          t))
        (avy-all-windows nil) (avy-all-windows-alt nil)
        (current-prefix-arg nil))
    (avy-goto-word-0 nil (scss2--target-beg target) (scss2--target-end target))))

(provide 'scss2-edit)
;;; scss2-edit.el ends here
