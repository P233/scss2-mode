;;; scss2-edit.el --- Structural CSS and SCSS editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Entity commands select declarations, selector branches or complete blocks.
;; Empty resolves content independently.  Targets live for one command only.

;;; Code:

(require 'cl-lib)
(require 'newcomment)
(require 'scss2-syntax)
(require 'subr-x)
(declare-function yas-active-snippets "yasnippet" (&optional beg end))
(declare-function yas-next-field "yasnippet" (&optional arg))
(declare-function company-abort "company" ())
(declare-function avy-goto-word-0 "avy" (arg &optional beg end))
(defvar avy-all-windows)
(defvar avy-all-windows-alt)

(cl-defstruct (scss2--target (:constructor scss2--make-target))
  "A transient selection, validated by OWNER, spanning BEG to END.
Selector branches also carry BEFORE and AFTER commas and their COUNT.
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
  (member (treesit-node-type node) '("block_comment" "inline_comment")))

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

(defun scss2--selector-target (selectors)
  "Select one complete comma-separated branch of SELECTORS at point."
  (let (groups group before selected ending)
    (dolist (child (scss2--children selectors))
      (cond
       ((scss2--comment-p child))
       ((equal (treesit-node-type child) ",")
        (when group (push (list (nreverse group) before child) groups))
        (setq group nil before child))
       (t (push child group))))
    (when group (push (list (nreverse group) before nil) groups))
    (setq groups (nreverse groups))
    (dolist (entry groups)
      (let ((beg (treesit-node-start (caar entry)))
            (end (treesit-node-end (car (last (car entry))))))
        (cond ((and (<= beg (point)) (< (point) end)) (setq selected entry))
              ((= end (point)) (setq ending entry)))))
    (when-let* ((entry (or selected ending)))
      (scss2--make-target
       :owner selectors :beg (treesit-node-start (caar entry))
       :end (treesit-node-end (car (last (car entry))))
       :before (nth 1 entry) :after (nth 2 entry)
       :count (length groups) :separator 'comma))))

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
                    ;; A blank line in a multi-line value or list belongs to no entity.
                    (and (save-excursion (beginning-of-line) (looking-at-p "[ \t]*\r?$"))
                         (not (scss2--ancestor node '("string" "block_comment" "inline_comment")))))
          node))))

(defun scss2--containing-node ()
  "Return the nearest node whose source bounds contain point."
  (let ((node (scss2--node-at-point)))
    (while (and node (not (scss2--contains-point-p node)))
      (setq node (treesit-node-parent node)))
    node))

(defun scss2--block-node (node &optional branch)
  "Find the nearest structural block around NODE.
Unless BRANCH is non-nil, an else branch selects its entire conditional."
  (while (and node (not (scss2--block-bounds node)))
    (setq node (treesit-node-parent node)))
  (if (and node (not branch) (equal (treesit-node-type node) "else_clause"))
      (treesit-node-parent node)
    node))

(defun scss2--resolve-target-1 (kind)
  "Resolve entity KIND in the current tree view.
Only explicit block selection may cross a leaf statement boundary."
  (let ((node (scss2--containing-node)))
    (pcase kind
      ('block (when-let* ((block (scss2--block-node node)))
                (scss2--node-target block 'statement)))
      ('property (when-let* ((declaration (scss2--ancestor node scss2--declaration-types)))
                   (scss2--node-target declaration 'statement)))
      (_
       (setq node (or (scss2--touched-node)
                      (user-error "Point is not on a stylesheet target")))
       (when (scss2--ancestor node '("block_comment" "inline_comment"))
         (user-error "Comments can be uncommented with scss2-comment-uncomment"))
       (if-let* ((selectors (scss2--selector-owner node)))
           (scss2--selector-target selectors)
         (when-let* ((statement (scss2--ancestor node scss2--statement-types)))
           (cond
            ((member (treesit-node-type statement) scss2--declaration-types)
             (scss2--node-target statement 'statement))
            ((scss2--block-bounds statement)
             (scss2--node-target (scss2--block-node statement) 'statement)))))))))

(defun scss2--resolve-target (&optional kind)
  "Resolve KIND in Font Lock's view and enforce accessible edit bounds."
  (scss2--check-target
   (scss2--with-font-lock-view (scss2--resolve-target-1 kind))))

(defun scss2--interior (node)
  "Return NODE's bracketed or quoted interior, using a call's argument container."
  (let* ((children (scss2--children node))
         (opening (cl-find-if
                   (lambda (child)
                     (or (member (treesit-node-type child) '("(" "[" "{" "#{" "\"" "'"))
                         (and (equal (treesit-node-type node) "raw_group")
                              (equal (treesit-node-text child t) "#{"))))
                   children))
         (closing (car (last children))))
    (if opening
        (when (and closing
                   ;; A lone quote in an ERROR node is both its first and last child.
                   (not (treesit-node-eq opening closing))
                   (not (treesit-node-check opening 'missing))
                   (not (treesit-node-check closing 'missing))
                   (equal (treesit-node-type closing)
                          (pcase (treesit-node-text opening t)
                            ("(" ")") ("[" "]") ((and (or "\"" "'") quotation) quotation)
                            (_ "}"))))
          (cons (treesit-node-end opening) (treesit-node-start closing)))
      (when-let* ((arguments (scss2--child node "arguments")))
        (scss2--interior arguments)))))

(defun scss2--condition-bounds (node)
  "Return NODE's complete condition field, including all value siblings."
  (let ((conditions
         (cl-loop for index below (treesit-node-child-count node)
                  when (equal (treesit-node-field-name-for-child node index) "condition")
                  collect (treesit-node-child node index))))
    (when conditions
      (cons (treesit-node-start (car conditions))
            (treesit-node-end (car (last conditions)))))))

(defun scss2--map-entry-value (node)
  "Return the value bounds of map entry NODE, as for a declaration.
For map NODE, use its entry that ends at point, before a comma or `)'."
  (when-let* ((entry (if (equal (treesit-node-type node) "map")
                         (cl-find (point) (scss2--children node t) :key #'treesit-node-end)
                       node))
              (_ (equal (treesit-node-type entry) "map_entry")))
    (scss2--value-bounds entry)))

(defun scss2--content-target (block)
  "Resolve content at point, or the nearest structural body with BLOCK."
  (scss2--check-target
   (scss2--with-font-lock-view
     (let* ((node (scss2--containing-node))
            (statement (scss2--ancestor node scss2--statement-types))
            bounds owner)
       (if block
           (setq owner (scss2--block-node node t)
                 bounds (and owner (scss2--block-bounds owner)))
         (while (and node (not bounds))
           (cond
            ((scss2--statement-p node)
             (setq owner node
                   bounds
                   (or (when-let* ((body (scss2--block-bounds node))
                                   ;; The opening brace belongs to the body.
                                   (_ (< (point) (1- (car body)))))
                         (or (scss2--condition-bounds node)
                             (and (member (treesit-node-type node) scss2--declaration-types)
                                  (scss2--value-bounds node))))
                       (scss2--block-bounds node)
                       (and (member (treesit-node-type node)
                                    (cons "value_statement" scss2--declaration-types))
                            (scss2--value-bounds node))))
             ;; Unsupported leaf statements never empty their parent block.
             (setq node nil))
            ((scss2--comment-p node) (setq node nil))
            ;; Inside interpolation, a call's name selects the interpolation.
            ((and (equal (treesit-node-type (treesit-node-parent node)) "interpolation")
                  (when-let* ((interior (scss2--interior node)))
                    (and (eq (char-before (car interior)) ?\()
                         (< (point) (1- (car interior))))))
             (setq node (treesit-node-parent node)))
            ((setq bounds (or (scss2--map-entry-value node) (scss2--interior node)))
             ;; Errors in a block's body leave its header's content reliable.
             (setq owner (if (and statement (not (scss2--block-bounds statement)))
                             statement
                           node)))
            (t (setq node (treesit-node-parent node))))))
       (if bounds
           (scss2--make-target :owner owner :beg (car bounds) :end (cdr bounds))
         (user-error "Nothing to empty here"))))))

(defun scss2--declaration-tab-target ()
  "Return where TAB moves within the declaration at point, or nil.
From the name, move to the start of the value, past any comment; from the
value, move past the declaration's direct semicolon, including inside
strings, URLs, comments and nested calls.  Return nil for an inaccessible
declaration, one without a direct colon or value, and a value without `;'."
  (when-let* ((target (condition-case nil (scss2--resolve-target 'property)
                       (user-error nil)))
              (owner (scss2--target-owner target))
              (colon (scss2--child owner ":")))
    (if (<= (point) (treesit-node-start colon))
        (when-let* ((value (treesit-node-child-by-field-name owner "value")))
          (treesit-node-start value))
      (when-let* ((semicolon (scss2--child owner ";"))
                  (_ (not (treesit-node-check semicolon 'missing)))
                  (_ (<= (point) (treesit-node-start semicolon))))
        (treesit-node-end semicolon)))))

(defun scss2--tab-binding (command)
  "Use COMMAND only when point has a declaration position to navigate to.
Resolve this during key lookup so frontend pre-command hooks see their own
command when navigation does not apply."
  (and (scss2--declaration-tab-target) command))

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
                                    '(menu-item "Move through declaration" scss2-tab
                                                :filter scss2--tab-binding)))
                      (dolist (command '(yas-next-field yas-next-field-or-maybe-expand
                                         company-complete-common-or-cycle))
                        (define-key map (vector 'remap command)
                                    '(menu-item "Move through declaration" scss2-tab
                                                :filter scss2--tab-remapping)))
                      map)))
  "Declaration navigation takes precedence over completion and snippet TAB maps.
The existing buffer-local dialect enables it only in stylesheet buffers.")

;;;###autoload
(defun scss2-tab ()
  "Move from a declaration's name to its value, or from its value past `;'.
Dismiss an open completion menu without accepting a candidate.  Elsewhere
delegate to the existing TAB binding, including completion and snippet fields."
  (interactive)
  (if (scss2--declaration-tab-target)
      (progn
        (when completion-in-region-mode (completion-in-region-mode -1))
        (when (and (bound-and-true-p company-candidates) (fboundp 'company-abort))
          (company-abort))
        ;; A frontend can remove preview text while closing its menu.
        (when-let* ((destination (scss2--declaration-tab-target)))
          (goto-char destination)
          (deactivate-mark)))
    (if (and (fboundp 'yas-active-snippets) (yas-active-snippets))
        (yas-next-field)
      (call-interactively #'indent-for-tab-command))))

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
  "Return TARGET's deletion ranges, preserving comments around its comma."
  (let ((begin (scss2--target-beg target)) (end (scss2--target-end target))
        (after (scss2--target-after target)) (before (scss2--target-before target)))
    (when (eql (scss2--target-count target) 1)
      (user-error "Cannot remove the only selector; use C-u to select its block"))
    (when-let* ((comma (or after before)))
      (unless (<= (point-min) (treesit-node-start comma)
                  (treesit-node-end comma) (point-max))
        (user-error "The adjacent comma is outside the accessible buffer")))
    (cond
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
(defun scss2-kill (&optional block)
  "Kill a selector branch, declaration or complete at-rule block.
With prefix BLOCK, kill the nearest complete structural block instead."
  (interactive "P")
  (scss2--kill-target (scss2--resolve-target (and block 'block))))

;;;###autoload
(defun scss2-empty (&optional block)
  "Kill the nearest delimited interior, declaration value or if condition.
Brackets, interpolation and string quotes delimit interiors.  A map entry
empties its value as a declaration does, and @return, @debug, @warn and
@error empty the value that follows them.
With prefix BLOCK, clear the nearest structural block's body."
  (interactive "P")
  (let ((target (scss2--content-target block)))
    (scss2--transaction
      (let ((text (buffer-substring-no-properties
                   (scss2--target-beg target) (scss2--target-end target))))
        (delete-region (scss2--target-beg target) (scss2--target-end target))
        (goto-char (scss2--target-beg target))
        (unless (string-empty-p text) (kill-new text))))))

;;;###autoload
(defun scss2-copy (&optional block)
  "Copy the same entity as `scss2-kill', preserving point and mark.
With prefix BLOCK, copy the nearest complete structural block."
  (interactive "P")
  (let ((target (scss2--resolve-target (and block 'block))))
    (scss2--transaction
      (kill-new (buffer-substring-no-properties
                 (scss2--target-beg target) (scss2--target-end target))))))

(defun scss2--end-of-trailing-comment (position)
  "Return the end of a comment that follows POSITION on its line, or POSITION."
  (save-excursion
    (goto-char position)
    (skip-chars-forward " \t")
    (if-let* ((comment (scss2--ancestor (scss2--covering-node (point))
                                       '("block_comment" "inline_comment"))))
        (treesit-node-end comment)
      position)))

(defun scss2--comma-separator (target)
  "Return the comma and following whitespace that join TARGET's branches."
  (if-let* ((comma (or (scss2--target-before target) (scss2--target-after target))))
      (save-excursion
        (scss2--with-font-lock-view
          (goto-char (treesit-node-end comma))
          (concat "," (buffer-substring-no-properties
                       (point) (progn (skip-chars-forward " \t\r\n") (point))))))
    ", "))

;;;###autoload
(defun scss2-duplicate (&optional block)
  "Duplicate the entity, preserving its body text and the kill ring.
With prefix BLOCK, duplicate the nearest complete structural block."
  (interactive "P")
  (let* ((target (scss2--resolve-target (and block 'block)))
         (text (buffer-substring-no-properties
                (scss2--target-beg target) (scss2--target-end target))))
    (scss2--transaction
      (goto-char (scss2--target-end target))
      (insert
       (if (eq (scss2--target-separator target) 'comma)
           (scss2--comma-separator target)
         (concat
          (when (and (not (string-suffix-p ";" text))
                     (not (scss2--block-bounds (scss2--target-owner target)))) ";")
          (if (scss2--whole-lines (cons (scss2--target-beg target)
                                        (scss2--end-of-trailing-comment
                                         (scss2--target-end target))))
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
      (insert text))))

;;;###autoload
(defun scss2-mark (&optional block)
  "Select the entity; repeated calls keep the same selection.
With prefix BLOCK, select the nearest complete structural block."
  (interactive "P")
  (unless (and (not block) (eq last-command 'scss2-mark) (region-active-p))
    (let ((target (scss2--resolve-target (and block 'block))))
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

;;;###autoload
(defun scss2-comment-uncomment (&optional block)
  "Comment the same entity as `scss2-kill', or uncomment an existing comment.
With prefix BLOCK, comment the nearest complete structural block."
  (interactive "P")
  (let* ((comment (unless block
                    (scss2--with-font-lock-view
                      (scss2--ancestor (scss2--touched-node)
                                       '("block_comment" "inline_comment")))))
         (target (if comment
                     (scss2--check-target
                      (scss2--with-font-lock-view (scss2--comment-target comment)))
                   (scss2--resolve-target (and block 'block))))
         (ranges (unless comment (scss2--deletion-ranges target)))
         (begin (if comment (scss2--target-beg target) (apply #'min (mapcar #'car ranges))))
         (end (if comment (scss2--target-end target)
                ;; Keep separator whitespace outside the wrapper: uncommenting
                ;; removes padding at its edge along with the comment markers.
                (max (scss2--target-end target)
                     (if-let* ((comma (scss2--target-after target)))
                         (treesit-node-end comma) 0))))
         ;; Inline // would also hide the following selector or declaration.
         (line-comment (if comment (equal (treesit-node-type comment) "inline_comment")
                         (and (eq scss2-dialect 'scss)
                              (not (eq (scss2--target-separator target) 'comma))
                              (scss2--whole-lines (cons begin end))))))
    (when (and line-comment (not comment))
      ;; At CRLF's CR, newcomment otherwise inserts an extra LF.
      (setq end (save-excursion (goto-char end) (skip-chars-forward " \t\r") (point)))
      ;; Plain style puts later lines' markers in column 0, so put the first's there too.
      (save-excursion
        (goto-char begin)
        (when (< (line-end-position) end) (setq begin (line-beginning-position)))))
    (scss2--transaction
      (let ((comment-start (if line-comment "// " "/* "))
            (comment-end (if line-comment "" " */"))
            ;; Keep one block's // comments contiguous for a single uncomment.
            (comment-empty-lines t)
            ;; Indented line comments pad blank lines to the block's column.
            (comment-style (if line-comment 'plain 'multi-line)))
        (if comment (uncomment-region begin end) (comment-region begin end))))))

;;;###autoload
(defun scss2-avy-word ()
  "Jump to a word in the nearest complete rule or at-rule, including its header.
The invocation's block fixes the range; other windows are not searched.
Requires the optional Avy package."
  (interactive)
  (unless (require 'avy nil t) (user-error "Install Avy to use scss2-avy-word"))
  (let ((target
         (scss2--check-target
          (scss2--with-font-lock-view
            (let ((node (scss2--block-node (scss2--containing-node))))
              (while (and node (member (treesit-node-type node) scss2--declaration-types))
                (setq node (scss2--block-node (treesit-node-parent node))))
              (when node (scss2--node-target node))))
          t))
        (avy-all-windows nil) (avy-all-windows-alt nil)
        (current-prefix-arg nil))
    (avy-goto-word-0 nil (scss2--target-beg target) (scss2--target-end target))))

(provide 'scss2-edit)
;;; scss2-edit.el ends here
