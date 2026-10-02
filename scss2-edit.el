;;; scss2-edit.el --- Structural CSS and SCSS editing -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Commands resolve semantic targets from the current tree.  A target lives
;; only for one command; no node or source position survives a buffer change.

;;; Code:

(require 'cl-lib)
(require 'scss2-syntax)
(require 'subr-x)
(declare-function yas-active-snippets "yasnippet" (&optional beg end))
(declare-function yas-next-field "yasnippet" (&optional arg))
(declare-function company-abort "company" ())

;; Structure: point must touch a token.  Every whole-target command then
;; selects a statement, a comment, or one item of a separated sequence.
;; Separators and flags are not targets; names and delimiters belong to their
;; owner.  Literals never become items by themselves; they only stop the
;; search for sequences inside them.  Content commands additionally accept
;; the interior of the literal at point.

(defconst scss2--list-types
  '("arguments" "parameters" "configuration" "map" "list")
  "Delimited containers whose direct children form a separated sequence.")

(defconst scss2--atom-types
  '("string" "raw_value" "url" "special_call" "block_comment" "inline_comment")
  "Literals that own everything nested inside them.")

(defconst scss2--required-sequences
  '(("selectors" . "Cannot remove the only selector; kill its statement instead")
    ("variable_declaration"
     . "Cannot remove a variable's only value; use scss2-empty-value")
    ("configuration"
     . "Cannot remove the only configured variable; remove its statement instead"))
  "Sequences that stay valid only with an item, and the advice when one is left.")

(cl-defstruct (scss2--target (:constructor scss2--make-target))
  "An edit selection that is valid only until the next buffer change.
OWNER establishes validation and sequence membership.  SUBJECT is the exact
selected node, or nil for a group of nodes.  BEG and END exclude separators;
BEFORE and AFTER identify adjacent separators for a sequence edit.  INDEX is
the selected group's position among COUNT groups."
  owner subject beg end before after count index separator)

(defun scss2--node-target (node &optional separator)
  "Make a target for NODE, with optional duplication SEPARATOR."
  (scss2--make-target :owner node :subject node :beg (treesit-node-start node)
                           :end (treesit-node-end node) :separator separator))

(defun scss2--check-target (target)
  "Return TARGET, or reject it when no reliable edit range exists.
A missing target, one outside the accessible buffer and one whose
boundaries depend on parser recovery are all rejected."
  (unless target (user-error "No stylesheet target here"))
  (unless (<= (point-min) (scss2--target-beg target)
              (scss2--target-end target) (point-max))
    (user-error "This target extends outside the accessible buffer"))
  (let ((node (scss2--target-owner target)))
    (when (or (treesit-node-check node 'has-error)
              (treesit-node-check node 'missing))
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
  (member (treesit-node-type node) '("block_comment" "inline_comment")))

(defun scss2--statement-p (node)
  "Whether NODE is a complete statement."
  (member (treesit-node-type node) scss2--statement-types))

(defun scss2--selector-owner (node)
  "Find the outer selector list before NODE's nearest containing statement.
Nested lists in :nth-child(... of ...) belong to the enclosing branch."
  (let (selectors)
    (while (and node (not (scss2--statement-p node)))
      (when (equal (treesit-node-type node) "selectors") (setq selectors node))
      (setq node (treesit-node-parent node)))
    selectors))

(defun scss2--sequence-p (node)
  "Whether NODE's direct children form a sequence of independent items."
  (let ((type (treesit-node-type node)))
    (or (member type scss2--list-types)
        (member type scss2--declaration-types)
        (and (equal type "selectors")
             (treesit-node-eq node (scss2--selector-owner node))))))

(defun scss2--sequence-members (sequence)
  "Return SEQUENCE's items and comma separators in source order.
A declaration's sequence is its value field, so its name, flags and block
are never items.  Delimiters and comments are not members either."
  (if (member (treesit-node-type sequence) scss2--declaration-types)
      (cl-remove-if-not
       (lambda (child) (equal (treesit-node-field-name child) "value"))
       (scss2--children sequence))
    (cl-remove-if
     (lambda (child)
       (or (scss2--comment-p child)
           (member (treesit-node-type child) '("(" ")" "[" "]" "with"))))
     (scss2--children sequence))))

(defun scss2--group-at-point (groups)
  "Return the entry of GROUPS whose nodes span point, or nil.
Point belongs to the group holding the character after it; a group that
merely ends at point is selected only when no other group begins there."
  (let (containing ending)
    (dolist (entry groups)
      (let ((begin (treesit-node-start (caar entry)))
            (end (treesit-node-end (car (last (car entry))))))
        (cond
         ((and (not containing) (<= begin (point)) (< (point) end))
          (setq containing entry))
         ((and (not ending) (= end (point)))
          (setq ending entry)))))
    (or containing ending)))

(defun scss2--sequence-target (sequence)
  "Select SEQUENCE's comma-delimited group at point, or nil between groups.
In a declaration value or a Sass list without any comma, independent atoms
are space-separated items.  Operators and spreads must stay with their
operands."
  (let ((space-items (not (member (treesit-node-type sequence)
                                  '("arguments" "parameters" "configuration"
                                    "map" "selectors"))))
        groups group before)
    (dolist (member (scss2--sequence-members sequence))
      (if (equal (treesit-node-type member) ",")
          (progn
            (when group (push (list (nreverse group) before member) groups))
            ;; Any comma, even a trailing one, makes commas the separator.
            (setq group nil before member space-items nil))
        (push member group)))
    (when group (push (list (nreverse group) before nil) groups))
    (setq groups (nreverse groups))
    (when (and space-items (scss2--group-at-point groups))
      (let ((items (caar groups)))
        (when (cl-some (lambda (node)
                         (member (treesit-node-type node)
                                 '("operator" "spread" "important")))
                       items)
          (user-error "Select the whole value; its operands are not independent items"))
        (setq groups (mapcar (lambda (node) (list (list node) nil nil)) items))))
    (when-let* ((selected (scss2--group-at-point groups))
                (items (car selected)))
      (scss2--make-target
       :owner sequence :subject (and (null (cdr items)) (car items))
       :beg (treesit-node-start (car items))
       :end (treesit-node-end (car (last items)))
       :before (nth 1 selected) :after (nth 2 selected)
       :count (length groups) :index (cl-position selected groups)
       :separator (if space-items 'space 'comma)))))

(defun scss2--covering-node (position)
  "Return the smallest node that includes the character at POSITION, or nil.
A blank character belongs to no token."
  (unless (memq (char-after position) '(nil ?\s ?\t ?\n ?\r ?\f))
    (let ((node (treesit-node-at position (scss2--language))))
      (while (and node (not (and (<= (treesit-node-start node) position)
                                 (< position (treesit-node-end node)))))
        (setq node (treesit-node-parent node)))
      node)))

(defun scss2--site ()
  "Return (NODE TOUCHED ATOM STATEMENT) describing point in the full syntax.
NODE is the smallest node containing point.  TOUCHED is the smallest node
holding the character point is on, else the character before it, and nil
in blank space.  ATOM is the outermost literal around point below
STATEMENT, its nearest enclosing statement."
  (let ((node (scss2--node-at-point)))
    (while (and node (not (scss2--contains-point-p node)))
      (setq node (treesit-node-parent node)))
    (unless node (user-error "Point is outside a stylesheet syntax target"))
    (let* ((touched (or (scss2--covering-node (point))
                        (and (> (point) (point-min))
                             (scss2--covering-node (1- (point))))))
           (statement (or touched node))
           atom)
      (while (and statement (not (scss2--statement-p statement)))
        (when (or (member (treesit-node-type statement) scss2--atom-types)
                  ;; Balanced var() payloads are one argument.  Raw groups
                  ;; in unknown statements retain their statement owner.
                  (and (equal (treesit-node-type statement) "raw_group")
                       (equal (treesit-node-type (treesit-node-parent statement))
                              "arguments")))
          (setq atom statement))
        (setq statement (treesit-node-parent statement)))
      (list node touched atom statement))))

(defun scss2--not-an-item-p (node sequence)
  "Whether NODE separates or qualifies SEQUENCE's items instead of being one."
  (or (equal (treesit-node-type node) ",")
      (and (member (treesit-node-type sequence) scss2--declaration-types)
           (equal (treesit-node-field-name node) "flags"))))

(defun scss2--owner (node)
  "Return the sequence or statement that NODE is part of."
  (let (owner)
    (while (and node (not owner))
      (let ((parent (treesit-node-parent node)))
        (cond
         ((and parent (scss2--sequence-p parent)) (setq owner parent))
         ((scss2--statement-p node) (setq owner node))
         (t (setq node parent)))))
    owner))

(defun scss2--item-target (site)
  "Return the sequence item, comment or statement that owns point at SITE.
Point must touch a token or lie inside a literal; blank space selects
nothing and never widens to an enclosing construct.  A query header belongs
to its statement, never to a partial list operand, and the outer literal
owns all of its nested expressions."
  (pcase-let* ((`(,_ ,touched ,atom ,statement) site)
               (start (cond
                       ((not (or touched atom))
                        (user-error "Point is not on a stylesheet target"))
                       ((and statement
                             (equal (treesit-node-type statement) "query_statement")
                             (let ((block (scss2--block-bounds statement)))
                               (or (not block) (< (point) (car block)))))
                        statement)
                       (atom)
                       (t touched)))
               (target nil))
    (while (and start (not target))
      (let ((parent (treesit-node-parent start)))
        (cond
         ;; Comments are trivia, not members of their parent's sequence.
         ((scss2--comment-p start)
          (setq target (scss2--node-target start)))
         ((and parent (scss2--sequence-p parent))
          (unless (setq target (scss2--sequence-target parent))
            ;; A name or delimiter belongs to the owner instead.
            (when (scss2--not-an-item-p start parent)
              (user-error "A separator or flag is not a stylesheet target"))))
         ((scss2--statement-p start)
          (setq target (scss2--node-target start 'statement))))
        (unless target (setq start parent))))
    target))

(defun scss2--resolve-target-1 (kind)
  "Derive KIND at point from the full buffer's syntax."
  (let* ((site (scss2--site))
         (node (car site)))
    (pcase kind
      ('block
       (while (and node (not (scss2--block-bounds node)))
         (setq node (treesit-node-parent node)))
       (when node (scss2--node-target node 'statement)))
      ('property
       (when-let* ((property (scss2--ancestor node scss2--declaration-types)))
         (scss2--node-target property 'statement)))
      ('selector
       (when-let* ((selectors (scss2--selector-owner node)))
         (scss2--sequence-target selectors)))
      ('value-item
       (let* ((target (scss2--item-target site))
              (owner (and target (scss2--target-owner target))))
         (when (and target
                    (or (eq (scss2--target-separator target) 'statement)
                        (equal (treesit-node-type owner) "selectors")
                        (not (scss2--ancestor owner (append scss2--list-types
                                                            scss2--declaration-types)))))
           (user-error "Point is not in a value item"))
         target))
      ('content
       ;; Inside a delimited literal, its interior is the content at point,
       ;; whatever surrounds it.  The sequence or statement it is part of
       ;; still establishes the validation boundary.
       (let ((atom (nth 2 site)))
         (if (and atom (not (scss2--comment-p atom)) (scss2--interior atom))
             (scss2--make-target :owner (scss2--owner atom) :subject atom
                                 :beg (treesit-node-start atom)
                                 :end (treesit-node-end atom))
           (scss2--item-target site))))
      (_ (scss2--item-target site)))))

(defun scss2--resolve-target (&optional kind)
  "Resolve KIND in the full syntax, then enforce the accessible edit range."
  (let ((target (save-restriction (widen) (scss2--resolve-target-1 kind))))
    (scss2--check-target target)))

(defun scss2--value-tab-target ()
  "Return the end of the declaration's semicolon when point is in its value.
Use the declaration's direct terminator, including inside strings, URLs,
comments and nested calls.  Incomplete or inaccessible declarations return nil."
  (when-let* ((target (condition-case nil (scss2--resolve-target 'property)
                       (user-error nil)))
              (owner (scss2--target-owner target))
              (colon (scss2--child owner ":"))
              (semicolon (scss2--child owner ";"))
              (_ (not (treesit-node-check semicolon 'missing)))
              (_ (<= (treesit-node-end colon) (point) (treesit-node-start semicolon))))
    (treesit-node-end semicolon)))

(defun scss2--tab-binding (command)
  "Use COMMAND only when point has a declaration terminator to navigate to.
Resolve this during key lookup so frontend pre-command hooks see their own
command when navigation does not apply."
  (and (scss2--value-tab-target) command))

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
                                    '(menu-item "Leave value" scss2-tab
                                                :filter scss2--tab-binding)))
                      (dolist (command '(yas-next-field yas-next-field-or-maybe-expand
                                         company-complete-common-or-cycle))
                        (define-key map (vector 'remap command)
                                    '(menu-item "Leave value" scss2-tab
                                                :filter scss2--tab-remapping)))
                      map)))
  "Value navigation takes precedence over completion and snippet TAB maps.
The existing buffer-local dialect enables it only in stylesheet buffers.")

;;;###autoload
(defun scss2-tab ()
  "Jump directly past the current declaration's semicolon from its value.
Dismiss an open completion menu without accepting a candidate.  Elsewhere
delegate to the existing TAB binding, including completion and snippet fields."
  (interactive)
  (if (scss2--value-tab-target)
      (progn
        (when completion-in-region-mode (completion-in-region-mode -1))
        (when (and (bound-and-true-p company-candidates) (fboundp 'company-abort))
          (company-abort))
        ;; A frontend can remove preview text while closing its menu.
        (when-let* ((end (scss2--value-tab-target)))
          (goto-char end)
          (deactivate-mark)))
    (if (and (fboundp 'yas-active-snippets) (yas-active-snippets))
        (yas-next-field)
      (call-interactively #'indent-for-tab-command))))

(defun scss2--interior (node)
  "Return NODE's delimited interior, or nil when delimiters are missing."
  (if (equal (treesit-node-type node) "inline_comment")
      (cons (+ (treesit-node-start node) 2) (treesit-node-end node))
    (let* ((children (scss2--children node))
           (opening (cl-find-if
                     (lambda (child)
                       (or (member (treesit-node-type child) '("(" "[" "{" "\"" "'" "/*"))
                           (and (equal (treesit-node-type node) "raw_group")
                                (equal (treesit-node-type child) "raw_text")
                                (equal (treesit-node-text child t) "#{"))))
                     children))
           (closing (car (last children))))
      (when (and opening closing
                 (not (treesit-node-check closing 'missing))
                 (member (treesit-node-type closing) '(")" "]" "}" "\"" "'" "*/")))
        (cons (treesit-node-end opening) (treesit-node-start closing))))))

(defun scss2--content-bounds (target)
  "Return TARGET's editable content while preserving its outer syntax.
SUBJECT is the exact selected node, when the selection is one node.  OWNER
continues to establish sequence membership and the validation boundary.
A statement's content is its block, or the arguments of a call without one.
Other statements and selector branches have no separate content."
  (let* ((subject (scss2--target-subject target))
         (type (and subject (treesit-node-type subject))))
    (or
     (when subject
       (or (scss2--block-bounds subject)
           (and (member type (append scss2--declaration-types
                                     '("named_argument" "map_entry" "parameter" "feature_query")))
                (scss2--value-bounds subject))
           (and (member type '("string" "raw_group" "list" "map" "url" "special_call"
                               "block_comment" "inline_comment"))
                (scss2--interior subject))
           (when-let* ((arguments (scss2--child subject "arguments")))
             (scss2--interior arguments))))
     (unless (or (and subject (scss2--statement-p subject))
                 (equal (treesit-node-type (scss2--target-owner target)) "selectors"))
       (cons (scss2--target-beg target) (scss2--target-end target))))))

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
           (save-current-buffer
             (let ((last-command nil)) ,@body)))
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
  "Return deletion ranges for TARGET, including one adjacent comma.
Separate ranges preserve comments between an item and its separator."
  (let* ((begin (scss2--target-beg target))
         (end (scss2--target-end target))
         (after (scss2--target-after target))
         (before (scss2--target-before target)))
    (when-let* ((_ (eql (scss2--target-index target) 0))
                (arguments (scss2--target-owner target))
                (_ (equal (treesit-node-type arguments) "arguments"))
                (call (treesit-node-parent arguments))
                (_ (equal (treesit-node-type call) "call_expression"))
                (_ (not (treesit-node-child-by-field-name call "module")))
                (name (scss2--identifier-name (treesit-node-child-by-field-name call "name")))
                (_ (equal (downcase name) "var")))
      (user-error "Cannot remove var()'s required first argument; remove the whole call instead"))
    (when-let* ((separator (or after before)))
      (unless (<= (point-min) (treesit-node-start separator)
                  (treesit-node-end separator) (point-max))
        (user-error "The adjacent separator is outside the accessible buffer")))
    (when-let* ((_ (eql (scss2--target-count target) 1))
                (advice (cdr (assoc (treesit-node-type (scss2--target-owner target))
                                    scss2--required-sequences))))
      (user-error "%s" advice))
    (cond
     (after
      (let ((comma-beg (treesit-node-start after)) (comma-end (treesit-node-end after)))
        (if (scss2--whitespace-p end comma-beg)
            (list (cons begin (save-excursion (goto-char comma-end)
                                             (skip-chars-forward " \t") (point))))
          (list (cons comma-beg comma-end) (cons begin end)))))
     (before
      (let ((comma-beg (treesit-node-start before)) (comma-end (treesit-node-end before)))
        (if (scss2--whitespace-p comma-end begin)
            (list (cons comma-beg end))
          (list (cons begin end) (cons comma-beg comma-end)))))
     ((and (eq (scss2--target-separator target) 'space)
           (> (scss2--target-count target) 1)
           (= (scss2--target-index target) (1- (scss2--target-count target))))
      ;; A final item takes the blanks after its predecessor, never indentation.
      (list (cons (save-excursion
                    (goto-char begin)
                    (skip-chars-backward " \t")
                    (if (bolp) begin (point)))
                  end)))
     ((eq (scss2--target-separator target) 'space)
      (list (cons begin (save-excursion (goto-char end) (skip-chars-forward " \t") (point)))))
     (t (list (cons begin end))))))

(defun scss2--whole-lines (range)
  "Return RANGE extended over its lines, or nil when other text shares them."
  (save-excursion
    (let ((begin (progn (goto-char (car range)) (skip-chars-backward " \t") (point)))
          (end (progn (goto-char (cdr range)) (skip-chars-forward " \t\r") (point))))
      (when (and (progn (goto-char begin) (bolp))
                 (progn (goto-char end) (eolp)))
        (cons begin (if (eobp) end (1+ end)))))))

(defun scss2--token-signature (position)
  "Return the syntax token's type and spelling at POSITION, or nil in blanks."
  (when (<= (point-min) position (1- (point-max)))
    (when-let* ((node (scss2--covering-node position)))
      (cons (treesit-node-type node) (treesit-node-text node t)))))

(defun scss2--kill-target (target)
  "Kill TARGET, retaining surrounding comments and unrelated whitespace.
A target that occupies whole lines takes those lines with it."
  (let* ((ranges (sort (scss2--deletion-ranges target)
                       (lambda (a b) (> (car a) (car b)))))
         (lines (and (null (cdr ranges)) (scss2--whole-lines (car ranges))))
         (ranges (if lines (list lines) ranges))
         (begin (caar (last ranges)))
         ;; Preserve the neighboring tokens, not comment bytes.  Comparing the
         ;; current tree avoids treating selector punctuation as whitespace.
         (tokens (and (not lines)
                      (scss2--target-subject target)
                      (scss2--comment-p (scss2--target-subject target))
                      (let ((left (scss2--token-signature (1- begin)))
                            (right (scss2--token-signature (cdar ranges))))
                        (and left right (list left right)))))
         (text (mapconcat (lambda (range)
                            (buffer-substring-no-properties (car range) (cdr range)))
                          (reverse ranges) "")))
    (scss2--transaction
      (dolist (range ranges) (delete-region (car range) (cdr range)))
      (goto-char begin)
      (when (and tokens
                 (not (equal tokens (list (scss2--token-signature (1- begin))
                                          (scss2--token-signature begin)))))
        (insert " ")
        (backward-char))
      ;; Land on the following statement so the command can be repeated.
      (when lines (back-to-indentation))
      (unless (string-empty-p text) (kill-new text)))))

(defun scss2--empty-target (target &optional replacement)
  "Kill TARGET's content and insert optional REPLACEMENT verbatim."
  (let ((bounds (or (scss2--content-bounds target)
                    (user-error "This target has no editable content"))))
    (scss2--replace-content bounds replacement)))

(defun scss2--replace-content (bounds &optional replacement)
  "Kill exact BOUNDS and insert REPLACEMENT without changing its whitespace.
Only REPLACEMENT's characters are inserted, never its text properties."
  (scss2--transaction
    (let ((text (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (delete-region (car bounds) (cdr bounds))
      (goto-char (car bounds))
      (when replacement (insert (substring-no-properties replacement)))
      (unless (string-empty-p text) (kill-new text)))))

;;;###autoload
(defun scss2-kill ()
  "Kill the semantic target at point: statement, selector or value item."
  (interactive)
  (scss2--kill-target (scss2--resolve-target)))

;;;###autoload
(defun scss2-empty ()
  "Kill the target's contents, retaining its delimiters or declaration."
  (interactive)
  (scss2--empty-target (scss2--resolve-target 'content)))

;;;###autoload
(defun scss2-substitute ()
  "Replace the target's contents with the current kill, preserving its bytes."
  (interactive)
  (scss2--transaction
    (let* ((tick (buffer-chars-modified-tick))
           (position (point))
           (replacement (save-current-buffer (current-kill 0 t))))
      ;; Clipboard retrieval can run user callbacks before a range is resolved.
      (unless (and (= tick (buffer-chars-modified-tick)) (= position (point)))
        (user-error "The source or point changed while reading the clipboard"))
      (scss2--empty-target (scss2--resolve-target 'content) replacement))))

;;;###autoload
(defun scss2-copy ()
  "Copy the semantic target at point without moving point or mark."
  (interactive)
  (let ((target (scss2--resolve-target)))
    (scss2--transaction
      (kill-new (buffer-substring-no-properties
                 (scss2--target-beg target) (scss2--target-end target))))))

;;;###autoload
(defun scss2-duplicate ()
  "Duplicate the target, preserving internal whitespace and the kill ring."
  (interactive)
  (let* ((target (scss2--resolve-target))
         (text (buffer-substring-no-properties
                (scss2--target-beg target) (scss2--target-end target)))
         (separator (scss2--target-separator target))
         (type (treesit-node-type (scss2--target-owner target))))
    (unless separator (user-error "This target cannot be duplicated in its context"))
    (when (equal type "else_clause")
      (user-error "Duplicate the entire conditional instead of an else clause"))
    (scss2--transaction
      (goto-char (scss2--target-end target))
      (insert
       (pcase separator
         ('comma ", ")
         ('space " ")
         ('statement
          (concat
           (when (and (not (string-suffix-p ";" text))
                      (not (scss2--block-bounds (scss2--target-owner target))))
             ";")
           (save-excursion
             (end-of-line)
             (when (eobp) (search-backward "\n" nil t))
             (if (eq (char-before) ?\r) "\r\n" "\n"))
           (save-excursion
             (goto-char (scss2--target-beg target))
             (buffer-substring-no-properties
              (line-beginning-position)
              (progn (back-to-indentation) (point))))))))
      (insert text))))

;;;###autoload
(defun scss2-mark ()
  "Select the semantic target at point; repeated calls keep the same target."
  (interactive)
  ;; A target can begin with another target, such as a rule and its selector.
  (unless (and (eq last-command 'scss2-mark) (region-active-p))
    (let ((target (scss2--resolve-target)))
      (goto-char (scss2--target-beg target))
      (push-mark (scss2--target-end target) t)
      (activate-mark))))

;;;###autoload
(defun scss2-zap ()
  "Delete from point to the target content's end without changing the kill ring."
  (interactive)
  (let* ((target (scss2--resolve-target 'content))
         (bounds (scss2--content-bounds target)))
    (unless (and bounds (<= (car bounds) (point) (cdr bounds)))
      (user-error "Point is outside this target's editable content"))
    (scss2--transaction (delete-region (point) (cdr bounds)))))

;;;###autoload
(defun scss2-kill-block ()
  "Kill the nearest complete block, including its header and any else chain."
  (interactive)
  (let* ((target (scss2--resolve-target 'block))
         (node (scss2--target-owner target)))
    (scss2--kill-target
     (if (equal (treesit-node-type node) "else_clause")
         (scss2--check-target
          (scss2--node-target (treesit-node-parent node) 'statement))
       target))))

;;;###autoload
(defun scss2-empty-block ()
  "Kill the nearest block's interior, retaining its header and braces."
  (interactive)
  (scss2--empty-target (scss2--resolve-target 'block)))

;;;###autoload
(defun scss2-kill-selector ()
  "Kill the whole selector branch at point, retaining other comma branches."
  (interactive)
  (scss2--kill-target (scss2--resolve-target 'selector)))

;;;###autoload
(defun scss2-kill-property ()
  "Kill the nearest complete property or variable declaration."
  (interactive)
  (scss2--kill-target (scss2--resolve-target 'property)))

;;;###autoload
(defun scss2-empty-value ()
  "Kill a declaration's entire value and flags, retaining its name and terminator."
  (interactive)
  (let* ((target (scss2--resolve-target 'property))
         (bounds (or (scss2--value-bounds (scss2--target-owner target))
                     (user-error "No declaration value here"))))
    (scss2--replace-content bounds)))

;;;###autoload
(defun scss2-kill-value-item ()
  "Kill one value, argument, parameter or map entry with its adjacent separator."
  (interactive)
  (scss2--kill-target (scss2--resolve-target 'value-item)))

(provide 'scss2-edit)
;;; scss2-edit.el ends here
