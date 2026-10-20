;;; scss2-context.el --- Completion roles at point -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Classify point into one completion role with its replacement bounds.
;; One ordered classifier reads node roles before falling back to the text
;; since the statement began for gaps and unfinished input.  Candidate
;; catalogs and module I/O belong to completion; nothing here is retained.

;;; Code:

(require 'cl-lib)
(require 'treesit)
(require 'scss2-syntax)
(require 'subr-x)

(defun scss2--declaration-body-p (owner)
  "Whether block OWNER permits declaration insertion in the current dialect.
Conditional blocks inherit their enclosing body's capability.  A Sass
function never emits declarations; a --named CSS function has a body."
  (let* ((function (scss2--ancestor owner '("function_definition")))
         (name (and function (treesit-node-child-by-field-name function "name")))
         (css-function (and name
                            (string-prefix-p "--" (scss2--decode-identifier
                                                   (treesit-node-text name t))))))
    (unless (and function (not css-function))
      (let (result done)
        (while (and owner (not done))
          (let ((type (or (car (cl-find-if
                               (lambda (scope)
                                 (member (car scope) '("mixin_definition" "function_definition"
                                                      "include_statement")))
                               (scss2--recovered-sass-scopes owner)))
                          (treesit-node-type owner)))
                (directive (scss2--directive owner)))
            (cond
             ((member type '("rule_set" "property_declaration" "mixin_definition"
                             "include_statement" "page_statement"))
              (setq result t done t))
             ((equal type "keyframes_statement") (setq done t))
             ((equal type "function_definition") (setq result css-function done t))
             ((member directive '("@font-face" "@property" "@font-palette-values"
                                  "@counter-style" "@view-transition" "@position-try"))
              (setq result t done t))
             ((and (member directive '("@styleset" "@stylistic" "@character-variant"
                                       "@swash" "@ornaments" "@annotation"))
                   (equal (scss2--directive
                           (scss2--ancestor (treesit-node-parent owner) '("css_statement")))
                          "@font-feature-values"))
              (setq result t done t))
             ;; An unclosed style rule can be recovered as a single ERROR node.
             ((and (equal type "ERROR")
                   (cl-find "selectors" (scss2--children owner t)
                            :key #'treesit-node-type :test #'equal))
              (setq result t done t))))
          (setq owner (treesit-node-parent owner)))
        result))))

(defun scss2-context--block-owner (node)
  "Find the innermost NODE ancestor whose block contains point."
  (while (and node (not (scss2--in-block-p node)))
    (setq node (treesit-node-parent node)))
  node)

(defun scss2-context--declaration-scope (owner)
  "Return (NAMES . DIRECTIVE) for declarations inside block OWNER.
NAMES are the Sass nested property names from OWNER outward, outermost
first, with nil for a dynamic name; they are nil outside nested property
blocks.  Sass control-flow and content blocks add no name, as in Sass, and
keep the surrounding descriptor domain, so DIRECTIVE is that of the nearest
rule or other directive."
  (let (names)
    (when (eq scss2-dialect 'scss)
      (while (member (treesit-node-type owner)
                     '("property_declaration" "if_statement" "else_clause" "each_statement"
                       "for_statement" "while_statement" "include_statement"))
        (when (equal (treesit-node-type owner) "property_declaration")
          (push (scss2--identifier-name (treesit-node-child-by-field-name owner "name")) names))
        (setq owner (scss2-context--block-owner (treesit-node-parent owner)))))
    (cons names (scss2--directive owner))))

(defun scss2-context--property-name (nested name)
  "Return property NAME inside NESTED property names, as Sass compiles it.
Return nil when any name is dynamic."
  (unless (memq nil (cons name nested))
    (mapconcat #'identity (append nested (list name)) "-")))

(defun scss2-context--context (role beginning ending &rest properties)
  "Build a ROLE context at BEGINNING and ENDING with PROPERTIES."
  (append (list :role role :beg beginning :end ending) properties))

(defun scss2-context--selector-context (beginning ending)
  "Describe a selector or pseudo prefix at BEGINNING and ENDING."
  (if (and (> beginning (point-min)) (eq (char-before beginning) ?:))
      (let ((colon (1- beginning)))
        (when (and (> colon (point-min)) (eq (char-before colon) ?:))
          (setq colon (1- colon)))
        (scss2-context--context 'pseudo colon ending))
    (scss2-context--context
     'selector (if (memq (char-before beginning) '(?. ?# ?%)) (1- beginning) beginning) ending)))

(defun scss2-context--containing (node types)
  "Return NODE or an ancestor in TYPES that actually contains point.
A direct real closing delimiter releases the endpoint.  A value token or
missing delimiter keeps it, so completion still works while typing."
  (let ((position (point)) found)
    (while (and node (not found))
      (when (and (member (treesit-node-type node) types)
                 (<= (treesit-node-start node) position)
                 (or (<= position (treesit-node-end node))
                     (and (member (treesit-node-type node) scss2--declaration-types)
                          (not (scss2--child node ";"))
                          (string-blank-p
                           (buffer-substring-no-properties (treesit-node-end node) position)))))
        (let ((closed (and (= position (treesit-node-end node))
                           (cl-some
                            (lambda (child)
                              (and (= (treesit-node-end child) position)
                                   (not (treesit-node-check child 'missing))
                                   (member (treesit-node-type child) '(";" ")" "]" "}"))))
                            (scss2--children node)))))
          (unless closed (setq found node))))
      (setq node (treesit-node-parent node)))
    found))

(defun scss2-context--explicit-selector-p (node limit)
  "Whether NODE contains explicit selector syntax starting before LIMIT.
Only descend through selector containers.  An ERROR or malformed attribute
can hold an abbreviation's raw value, including selector-like punctuation."
  (and (< (treesit-node-start node) limit)
       (let ((type (treesit-node-type node)))
         (if (member type '("selectors" "complex_selector" "compound_selector"))
             (cl-loop for child = (treesit-node-child node 0 t)
                      then (treesit-node-next-sibling child t)
                      while (and child (< (treesit-node-start child) limit))
                      thereis (scss2-context--explicit-selector-p child limit))
           (and (not (treesit-node-check node 'has-error))
                (or (member type '("class_selector" "attribute_selector" "namespace_selector"))
                    (and (equal type "combinator")
                         (member (treesit-node-text node t) '(">" "~")))))))))

(defun scss2-context--follows-declaration-p (selectors)
  "Whether SELECTORS starts a new declaration line after a terminated one.
Comments can separate the statements.  An explicit selector continuation
on the following line keeps the selector role."
  (let ((previous (treesit-node-prev-sibling (treesit-node-parent selectors) t)))
    (while (and previous (member (treesit-node-type previous) scss2--comment-types))
      (setq previous (treesit-node-prev-sibling previous t)))
    (and previous (member (treesit-node-type previous) scss2--declaration-types)
         (when-let* ((semicolon (scss2--child previous ";")))
           (not (treesit-node-check semicolon 'missing)))
         (save-excursion
           (goto-char (treesit-node-start selectors))
           (skip-chars-backward " \t")
           (bolp))
         (save-excursion
           (end-of-line)
           (forward-comment (point-max))
           (not (memq (char-after) '(?> ?+ ?~ ?| ?,)))))))

(defun scss2-context--abbreviation-p (text delimiters)
  "Whether TEXT is one declaration abbreviation on one line.
Outside bracket groups, the characters in the list DELIMITERS end it.
Bracket raw values may hold blanks, strings, calls and nested brackets, and
an unclosed final group is still being typed.  Attribute selectors put their
operator first, so `=' before any string, call or nested bracket in a group
keeps the selector role."
  (let (closers quote escaped raw)
    (and (string-match-p "\\`[[:alpha:]_-]" text)
         (cl-loop
          for char across text
          always (cond
                  ((eq char ?\n) nil)
                  (escaped (setq escaped nil) t)
                  (quote (cond ((eq char ?\\) (setq escaped t))
                               ((eq char quote) (setq quote nil)))
                         t)
                  ((and (null closers) (eq char ?\[)) (setq closers (list ?\]) raw nil) t)
                  ((null closers) (not (or (eq char ?\]) (memq char delimiters))))
                  ((eq char (car closers)) (pop closers) t)
                  ((memq char '(?\" ?')) (setq quote char raw t))
                  ((memq char '(?\( ?\[))
                   (push (if (eq char ?\() ?\) ?\]) closers)
                   (setq raw t))
                  (t (or raw (not (eq char ?=)))))))))

(defun scss2-context--declaration-shaped-p (selectors)
  "Whether SELECTORS absorbed an unfinished declaration at point.
A pseudo-class has no blank after its colon, so `name: ' inside a selector
with a parse error is a declaration typed above a nested rule.  In a
declaration body, an unqualified token is also a declaration insertion slot
when separated from the rest of SELECTORS by a blank line, or when it starts
a new line after a terminated declaration.  Explicit selector prefixes,
pseudo chains and selector continuations keep their selector role."
  (and (<= (treesit-node-start selectors) (point))
       (or (and (treesit-node-check selectors 'has-error)
                (string-match-p "\\`[[:alnum:]_-]+[ \t]*:[ \t\r\n]"
                                (buffer-substring-no-properties
                                 (treesit-node-start selectors) (point))))
           (and (< (line-end-position) (treesit-node-end selectors))
                (or (save-excursion
                      (end-of-line)
                      (looking-at "\r?\n[ \t]*\r?\n"))
                    (scss2-context--follows-declaration-p selectors))
                (scss2-context--abbreviation-p
                 (string-trim-right (buffer-substring-no-properties
                                     (treesit-node-start selectors) (line-end-position))
                                    "[ \t\r]+")
                 '(?\s ?\t ?\r ?: ?\; ?{ ?}))
                (not (scss2-context--explicit-selector-p selectors (line-end-position)))
                (scss2--declaration-body-p (scss2-context--block-owner selectors))))))

(defun scss2-context--selector-p (node)
  "Whether point at NODE is in an existing selector or its trailing gap."
  (or (when-let* ((selectors (scss2-context--containing node '("selectors"))))
        ;; Recovery can classify a declaration abbreviation such as m10+p20
        ;; as selectors without a rule.  Let the statement rules decide.
        (not (or (equal (treesit-node-type (treesit-node-parent selectors)) "ERROR")
                 (scss2-context--declaration-shaped-p selectors))))
      (scss2-context--trailing-child
       (scss2-context--containing node '("selector_query")) "selectors")
      (when-let* ((rule (scss2--ancestor node '("rule_set")))
                  (selectors (treesit-node-child-by-field-name rule "selectors"))
                  (opening (scss2--child rule "{")))
        (and (not (treesit-node-check opening 'missing))
             (<= (treesit-node-start selectors) (point) (treesit-node-start opening))
             (not (scss2-context--declaration-shaped-p selectors))))))

(defun scss2-context--module-before (beginning)
  "Return the decoded module qualifying the member name at BEGINNING.
Read the complete syntax token so escape terminator spaces stay in the name.
A call or variable has a module node.  A bare `module.member' is one dotted
token, and an unfinished reference leaves an identifier ending at the dot."
  (when (and (eq scss2-dialect 'scss)
             (> beginning (1+ (point-min))) (eq (char-before beginning) ?.))
    (let* ((dot (1- beginning))
           (leaf (treesit-node-at (1- dot) (scss2--language)))
           (node (scss2--ancestor
                  leaf '("module_name" "plain_value" "function_name" "dotted_value"))))
      (cond
       ((and node (equal (treesit-node-type node) "dotted_value"))
        (when (< (treesit-node-start node) dot (treesit-node-end node))
          (scss2--decode-identifier
           (buffer-substring-no-properties (treesit-node-start node) dot))))
       (node (and (= (treesit-node-end node) dot) (scss2--identifier-name node)))
       ;; Recovery can drop the identifier from the tree altogether.  Its
       ;; text is a module only when this buffer declares that namespace;
       ;; `m1.5' is an abbreviation and `div.a' a selector.
       ((< (1- dot) (treesit-node-start leaf))
        (let ((name (scss2--decode-identifier
                     (buffer-substring-no-properties
                      (save-excursion (goto-char dot)
                                      (skip-chars-backward "[:alnum:]_\\\\-")
                                      (point))
                      dot))))
          (and (assoc name (scss2--module-namespaces)) name)))))))

(defun scss2-context--custom-property-reference-p (node beginning)
  "Whether NODE at BEGINNING is the direct first argument of CSS var()."
  (scss2--custom-property-reference-p
   (scss2-context--containing node '("call_expression")) beginning))

(defun scss2-context--identifier-bounds (node)
  "Return complete identifier bounds at point, including an ending token.
Use NODE's identifier ancestor for CSS escapes; the fallback also accepts
non-ASCII names."
  (let* ((types '("property_name" "plain_value" "variable_name" "function_name"
                  "module_name" "class_selector" "id_selector" "tag_selector"
                  "placeholder_selector" "pseudo_name"))
         (identifier (scss2--ancestor node types)))
    (unless (and identifier
                 (<= (treesit-node-start identifier) (point) (treesit-node-end identifier)))
      (setq identifier
            (and (> (point) (point-min))
                 (scss2--ancestor
                  (treesit-node-at (1- (point)) (scss2--language)) types))))
    (if (and identifier
             (<= (treesit-node-start identifier) (point) (treesit-node-end identifier))
             (not (treesit-search-subtree identifier "interpolation")))
        (cons (treesit-node-start identifier) (treesit-node-end identifier))
      (cons (save-excursion (skip-chars-backward "[:alnum:]_$\200-\U0010ffff-") (point))
            (save-excursion (skip-chars-forward "[:alnum:]_\200-\U0010ffff-") (point))))))

(defun scss2-context--trailing-child (node type)
  "Return NODE's direct TYPE child followed only by trivia up to point."
  (cl-find-if
   (lambda (child)
     (and (equal (treesit-node-type child) type)
          (<= (treesit-node-end child) (point))
          (let ((end (point)))
            (save-excursion
              (goto-char (treesit-node-end child))
              (skip-chars-forward " \t\r\n\f" end)
              (while (and (< (point) end)
                          (let ((before (point)))
                            (condition-case nil
                                (progn (forward-comment 1) (> (point) before))
                              (scan-error nil))))
                (when (< (point) end) (skip-chars-forward " \t\r\n\f" end)))
              (= (point) end)))))
   (scss2--children node t)))

(defun scss2-context--declaration-context (node beginning ending &optional media nested)
  "Describe the name or value of declaration NODE at BEGINNING and ENDING.
MEDIA selects feature candidates instead of CSS property candidates.
NESTED lists the Sass nested property names that prefix NODE's name.
Read the colon after the name from the text: recovery can attach the next
statement's colon to an unfinished value."
  (let* ((name (treesit-node-child-by-field-name node "name"))
         (value (and name
                     (let ((position (point)))
                       (save-excursion
                         (goto-char (treesit-node-end name))
                         (forward-comment (point-max))
                         (and (eq (char-after) ?:) (< (point) position))))))
         (property (scss2-context--property-name nested (scss2--identifier-name name))))
    (scss2-context--context
     (if value (if media 'media-value 'property-value)
       (if media 'media-feature 'property))
     (if (and (not value) name) (treesit-node-start name) beginning)
     (if (and (not value) name) (treesit-node-end name) ending)
     :property property)))

(defun scss2-context--query-context (node beginning ending)
  "Describe NODE at point in a query prelude or a conditional branch's test.
BEGINNING and ENDING bound the identifier being completed."
  (let ((query (scss2-context--containing
                node '("query_statement" "conditional_branch"))))
    ;; A branch's value can still belong to an enclosing feature query.
    (while (and query
                (let ((boundary
                       (cl-find (if (equal (treesit-node-type query) "conditional_branch") ":" "{")
                                (scss2--children query) :key #'treesit-node-type :test #'equal)))
                  (and boundary (> (point) (treesit-node-start boundary)))))
      (setq query (scss2-context--containing
                   (treesit-node-parent query) '("query_statement" "conditional_branch"))))
    (when query
      (let* ((group (scss2-context--containing node '("query_group")))
             (arguments (scss2-context--containing node '("arguments")))
             (feature (or (scss2-context--containing node '("feature_query"))
                          (scss2-context--trailing-child (or arguments group) "feature_query")))
             (call (scss2--ancestor (or feature node) '("call_expression")))
             (call-name (and call (scss2--identifier-name
                                   (treesit-node-child-by-field-name call "name"))))
             (property (or (equal (scss2--directive query) "@supports")
                           (member (downcase (or call-name "")) '("style" "supports"))))
             ;; A conditional branch names its query language by its test.
             (language (or (scss2--directive query)
                           (and call-name (concat "@" (downcase call-name))))))
        (cond
         (feature (scss2-context--declaration-context feature beginning ending (not property)))
         (group
          (let* ((children (scss2--children group t))
                 (compound (cl-some
                            (lambda (child)
                              (or (member (treesit-node-type child) '("query_group" "selector_query"))
                                  (and (equal (treesit-node-type child) "operator")
                                       (member (downcase (scss2--decode-identifier
                                                          (treesit-node-text child t))) '("and" "or" "not")))
                                  (and (equal (treesit-node-type child) "call_expression")
                                       (member (downcase (or (scss2--identifier-name
                                                              (treesit-node-child-by-field-name child "name")) ""))
                                               '("style" "supports" "scroll-state")))))
                            children))
                 (range (cl-some (lambda (child)
                                   (member (treesit-node-text child t) '("<" ">" "<=" ">=" "=")))
                                 children))
                 ;; A complete group names its feature; an incomplete one's direct identifier
                 ;; is the slot.  Neither depends on the completion catalog knowing it.
                 (identifiers '("property_name" "plain_value"))
                 (name (or (cl-find "property_name" children :key #'treesit-node-type :test #'equal)
                           (cl-find "plain_value" children :key #'treesit-node-type :test #'equal)))
                 (current (cl-find-if
                           (lambda (child)
                             (<= (treesit-node-start child) (point) (treesit-node-end child)))
                           children))
                 (value (and range
                             (or (and current (not (member (treesit-node-type current) identifiers)))
                                 (and name (not (eq current name)))))))
            (scss2-context--context
             (cond (compound 'media-keyword)
                   (value 'media-value)
                   (property 'property)
                   (t 'media-feature))
             beginning ending
             :property (and name (scss2--identifier-name name))
             :query language)))
         ;; An unclosed group recovers as an ERROR prelude; the statement text decides.
         ((and (equal (treesit-node-type query) "query_statement")
               (when-let* ((opening (nth 1 (syntax-ppss))))
                 (and (eq (char-after opening) ?\() (> opening (treesit-node-start query)))))
          nil)
         (t (scss2-context--context 'media-keyword beginning ending
                                    :query language)))))))

(defun scss2-context--argument-slot-p (opening beginning)
  "Whether BEGINNING starts an argument of the list opened at OPENING.
Only there can a word name a parameter; elsewhere it is part of a value."
  (save-excursion
    (goto-char beginning)
    (forward-comment (- (point)))
    (pcase (char-before)
      (?\( (= (1- (point)) opening))
      (?, (eql (nth 1 (syntax-ppss (1- (point)))) opening)))))

(defun scss2-context--include-context (node beginning ending)
  "Describe NODE's include name or argument slot without crossing nested calls.
BEGINNING and ENDING bound the identifier being completed."
  (when-let* ((include (scss2-context--containing node '("include_statement"))))
    (let ((name (treesit-node-child-by-field-name include "name"))
          (module (treesit-node-child-by-field-name include "module"))
          (arguments (treesit-node-child-by-field-name include "arguments")))
      (cond
       ((and name (<= (treesit-node-start name) (point) (treesit-node-end name)))
        (scss2-context--context 'mixin beginning ending
                                :module (scss2--identifier-name module)))
       ((and arguments (< (treesit-node-start arguments) (point) (treesit-node-end arguments)))
        (let* ((named (or (scss2-context--containing node '("named_argument"))
                          (scss2-context--trailing-child arguments "named_argument")))
               (colon (and named (scss2--child named ":")))
               (nested (scss2-context--containing node '("arguments")))
               (incomplete-colon (scss2-context--trailing-child arguments "ERROR"))
               (value (or (and colon (<= (treesit-node-end colon) (point)))
                          ;; The empty RHS of `$name: ' recovers as a direct colon
                          ;; error until its first value is typed.
                          (and incomplete-colon
                               (equal (treesit-node-text incomplete-colon t) ":"))
                          (and nested (not (treesit-node-eq nested arguments)))
                          (not (scss2-context--argument-slot-p
                                (treesit-node-start arguments) beginning))))
               (mixin (scss2--identifier-name name)))
          ;; Named values come from this stylesheet; only parameter names come from the module.
          (if value
              (scss2-context--context 'property-value beginning ending :mixin mixin)
            (scss2-context--context 'argument beginning ending
                                    :mixin mixin :module (scss2--identifier-name module)))))))))

(defun scss2-context--classify (node state interpolation)
  "Classify NODE at point, using STATE and INTERPOLATION for lexical boundaries.
Tree roles precede statement-text recovery.  Keep this order explicit: a
recognized selector, literal or declaration owns its complete syntax."
  (let* ((raw (scss2--ancestor node '("raw_value")))
         (bounds (scss2-context--identifier-bounds node))
         (beginning (car bounds)) (ending (cdr bounds))
         (start (scss2--statement-start))
         (module (scss2-context--module-before beginning))
         (prefix (buffer-substring-no-properties start (point)))
         (owner (or (scss2-context--block-owner node)
                    (when-let* ((opening (nth 1 state))
                                (_ (eq (char-after opening) ?{)))
                      (scss2-context--block-owner
                       (treesit-node-at opening (scss2--language))))))
         (declaration (scss2-context--containing node scss2--declaration-types))
         (sass (eq scss2-dialect 'scss))
         (scope (scss2-context--declaration-scope owner))
         (nested (car scope))
         (directive (cdr scope))
         (include (and sass (scss2-context--include-context node beginning ending)))
         (selector (scss2-context--selector-p node))
         (case-fold-search (eq scss2-dialect 'css)))
    (cond
     ;; Raw braces/colons are value text; only Sass interpolation reopens it.
     ((and raw (scss2--contains-point-p raw) (not interpolation))
      (let* ((declaration (scss2--ancestor raw '("property_declaration" "feature_query")))
             (name (and declaration (treesit-node-child-by-field-name declaration "name"))))
        (scss2-context--context 'property-value beginning ending
                                :property (scss2-context--property-name
                                           nested (scss2--identifier-name name))
                                :at-rule directive)))
     ((and (> beginning (point-min)) (eq (char-before beginning) ?@))
      (when (string-match-p "\\`@[[:alnum:]_-]*\\'" prefix)
        (scss2-context--context 'at-rule (1- beginning) ending :owner owner)))
     ((and sass (memq (plist-get include :role) '(mixin argument))) include)
     ((and sass
           (string-match-p "\\`@include[ \t\n]+\\(?:[[:alnum:]_-]+\\.\\)?[[:alnum:]_-]*\\'" prefix))
      (scss2-context--context 'mixin beginning ending :module module))
     ((and sass (eq (char-after beginning) ?$)
           ;; A `$' glued to a name, as in p$a$b, continues an abbreviation.
           (not (string-match-p "[[:alnum:]]" (string (or (char-before beginning) ?\s)))))
      (scss2-context--context 'variable beginning ending :module module))
     ((and sass module)
      (scss2-context--context
       (if (and (scss2--ancestor node '("include_statement")) (not include))
           'mixin 'module-member)
       beginning ending :module module))
     ((and sass interpolation) (scss2-context--context 'property-value beginning ending))
     (include)
     (selector (scss2-context--selector-context beginning ending))
     ((scss2-context--query-context node beginning ending))
     ((and declaration (not sass)
           (equal (treesit-node-type declaration) "variable_declaration")) nil)
     ((and declaration
           (let ((opening (scss2--child declaration "{")))
             (or (not opening) (<= (point) (treesit-node-start opening)))))
      (plist-put (scss2-context--declaration-context
                  declaration beginning ending nil
                  (and (equal (treesit-node-type declaration) "property_declaration") nested))
                 :at-rule directive))
     ;; Gaps and unfinished input have no complete node to establish their role.
     ((and sass (string-match "\\`@include[ \t\n]+\\(?:\\([[:alnum:]_.-]+\\)\\.\\)?\\([[:alnum:]_-]+\\)([^)]*\\'"
                              prefix))
      (let ((module (match-string 1 prefix)) (mixin (match-string 2 prefix))
            (opening (+ start (match-end 2))))
        (if (or (string-match-p ":[^,]*\\'" prefix)
                (not (scss2-context--argument-slot-p opening beginning)))
            (scss2-context--context 'property-value beginning ending :mixin mixin)
          (scss2-context--context 'argument beginning ending :mixin mixin :module module))))
     ((string-match "\\`@\\(media\\|container\\|supports\\)\\_>" prefix)
      (let ((directive (downcase (match-string 1 prefix))))
        (cond
         ((string-match "([ \t\n]*\\([[:alnum:]_-]+\\)[ \t]*:[^()]*\\'" prefix)
          (scss2-context--context
           (if (equal directive "supports") 'property-value 'media-value)
           beginning ending :property (match-string 1 prefix)))
         ((string-match "([^():]*\\'" prefix)
          (scss2-context--context
           (if (equal directive "supports") 'property 'media-feature) beginning ending))
         (t (scss2-context--context 'media-keyword beginning ending
                                    :query (concat "@" directive))))))
     ((and sass
           (string-match-p
            "\\`@for[ \t\r\n]+\\$[^ \t\r\n]+[ \t\r\n]+from[ \t\r\n]+[^;{}]+[ \t\r\n]+[[:alnum:]_-]*\\'"
            prefix)
           (not (string-match-p "[ \t\r\n]\\(?:through\\|to\\)[ \t\r\n]" prefix))
           (not (and (nth 1 state) (memq (char-after (nth 1 state)) '(?\( ?\[))))
           (save-excursion
             (goto-char beginning)
             (skip-chars-backward " \t\r\n")
             (let ((previous (treesit-node-at (1- (point)) (scss2--language))))
               (not (or (scss2--ancestor previous '("operator"))
                        (member (treesit-node-type previous) '("," ":")))))))
      (scss2-context--context 'for-range beginning ending))
     ((or (and sass
               (string-match-p
                (concat "\\`@\\(?:"
                        "\\(?:return\\|debug\\|warn\\|error\\|if\\|while\\|else[ \t\n]+if\\)[ \t\n(]"
                        "\\|each[ \t\n][^{]*[ \t\n]in[ \t\n]"
                        "\\|for[ \t\n][^{]*[ \t\n]from[ \t\n]"
                        "\\)") prefix))
          (when-let* ((parameter (scss2-context--containing node '("parameter")))
                      (colon (scss2--child parameter ":")))
            (<= (treesit-node-end colon) (point)))
          (string-match-p
           (concat "\\`@" (if sass "\\(?:mixin\\|function\\)" "function")
                   "\\_>[^{;]*([^()]*:[^,()]*\\'") prefix))
      (scss2-context--context 'property-value beginning ending))
     ;; A Sass statement starting with `$' is a variable declaration, even at top level.
     ((and (or owner (and sass (string-prefix-p "$" prefix))) (not selector)
           (string-match "\\`\\([[:alnum:]_$-]+\\)[ \t]*:[ \t\n]*" prefix))
      (let ((property (match-string 1 prefix)))
        (unless (and (string-prefix-p "$" property) (not sass))
          (scss2-context--context 'property-value beginning ending
                                  :property (if (string-prefix-p "$" property) property
                                              (scss2-context--property-name nested property))
                                  :at-rule directive))))
     ((and (> beginning (point-min)) (eq (char-before beginning) ?:))
      (scss2-context--selector-context beginning ending))
     ((and (scss2--declaration-body-p owner)
           (not (string-match-p "\\`[.#&%>+~]" prefix))
           (or (string-match-p "\\`[[:alnum:]_-]*\\'" prefix)
               (scss2-context--abbreviation-p prefix '(?\s ?\t ?\; ?{ ?}))))
      ;; Expansions write whole names, which a nested property would prefix again.
      (scss2-context--context 'property beginning ending
                              :at-rule directive :start (unless nested start)))
     ((string-prefix-p "@" prefix) nil)
     (t (scss2-context--selector-context beginning ending)))))

(defun scss2-context--base-context ()
  "Describe the syntax role at point as a plist, or nil in opaque text.
The plist contains :role, :beg and :end.  Values additionally carry :property;
Sass member contexts may carry :module.  Incomplete input is expected."
  (when (and scss2-dialect (treesit-parser-list))
    (let* ((position (point))
           (node (scss2--node-at-point))
           (state (syntax-ppss))
           (comment (scss2--ancestor node scss2--comment-types))
           (interpolation-node (scss2--ancestor node '("interpolation")))
           (in-interpolation
            (and interpolation-node
                 (<= (treesit-node-start interpolation-node) position)
                 (< position (treesit-node-end interpolation-node))))
           (interpolation (and (eq scss2-dialect 'scss) in-interpolation)))
      (cond
       ;; Reject opaque text before scanning statement boundaries or names.
       ((or (nth 4 state)
            (and comment
                 ;; At the opener's start, point still precedes the comment;
                 ;; an adjacent value or variable prefix can be completed there.
                 (< (treesit-node-start comment) position)
                 (< position (treesit-node-end comment)))) nil)
       ((and (nth 3 state) (not interpolation))
        (let* ((quote (nth 8 state))
               (start (save-excursion
                        (goto-char quote)
                        (scss2--statement-start)))
               (before (buffer-substring-no-properties start quote))
               (case-fold-search (eq scss2-dialect 'css)))
          (when (string-match-p "\\`@\\(?:import\\|use\\|forward\\)[ \t\n]+\\'" before)
            (scss2-context--context 'path (1+ quote) position))))
       ((and (eq scss2-dialect 'css) in-interpolation) nil)
       (t (scss2-context--classify node state interpolation))))))

(defun scss2-context-at-point ()
  "Describe completion at point, refining value roles for CSS var() references.
Return nil in opaque text, otherwise a plist with :role, :beg and :end.
Values retain :property; Sass members may carry :module.  Incomplete input
is expected."
  (let ((minimum (point-min)) (maximum (point-max)))
    (scss2--with-font-lock-view
      (when-let* ((context (scss2-context--base-context))
                  (beginning (plist-get context :beg))
                  (_ (<= minimum beginning (point) (plist-get context :end) maximum)))
        (cond
         ((not (memq (plist-get context :role) '(property-value media-value)))
          context)
         ;; A hash or a bang starts a color or a flag, not a value name.
         ((memq (char-before beginning) '(?# ?!)) nil)
         ((scss2-context--custom-property-reference-p
           (scss2--node-at-point) beginning)
          (plist-put context :role 'custom-property))
         (t context))))))

(provide 'scss2-context)
;;; scss2-context.el ends here
