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

(defun scss2-context--declaration-shaped-p (selectors)
  "Whether recovered SELECTORS reads as a declaration up to point.
A pseudo-class has no blank after its colon, so `name: ' inside a selector
with a parse error is a declaration typed above a nested rule."
  (and (treesit-node-check selectors 'has-error)
       (<= (treesit-node-start selectors) (point))
       (string-match-p "\\`[[:alnum:]_-]+[ \t]*:[ \t\r\n]"
                       (buffer-substring-no-properties
                        (treesit-node-start selectors) (point)))))

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
  "Whether NODE at BEGINNING is the direct first argument of CSS var().
Use the call's static name and argument boundaries.  Raw values and parser
recovery lack call nodes, so retain their simple unqualified var() spelling."
  (when (string-prefix-p "--" (scss2--decode-identifier
                               (buffer-substring-no-properties beginning (point))))
    (let* ((arguments (scss2-context--containing node '("arguments")))
           (call (and arguments (treesit-node-parent arguments))))
      (if arguments
          (let ((first (cl-find-if
                        (lambda (child)
                          (not (member (treesit-node-type child) '("(" "block_comment" "inline_comment"))))
                        (scss2--children arguments))))
            (and (equal (treesit-node-type call) "call_expression")
                 (treesit-node-eq arguments (treesit-node-child-by-field-name call "arguments"))
                 (equal (downcase (or (scss2--identifier-name
                                      (treesit-node-child-by-field-name call "name")) "")) "var")
                 (not (treesit-node-child-by-field-name call "module"))
                 first (equal (treesit-node-type first) "plain_value")
                 (= (treesit-node-start first) beginning)
                 (<= (point) (treesit-node-end first))))
        (when (scss2--ancestor node '("raw_value" "ERROR"))
          (save-excursion
            (when-let* ((opening (nth 1 (syntax-ppss beginning)))
                        (_ (eq (char-after opening) ?\()))
              (goto-char opening)
              (skip-chars-backward "[:alnum:]_-")
              (when (and (equal (downcase (buffer-substring-no-properties (point) opening)) "var")
                         (not (memq (char-before) '(?. ?$ ?\\))))
                (goto-char (1+ opening))
                (condition-case nil
                    (progn (forward-comment (point-max)) (= (point) beginning))
                  (scan-error nil))))))))))

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
        (cons (scss2--identifier-start identifier) (treesit-node-end identifier))
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

(defun scss2-context--declaration-context (node beginning ending &optional media)
  "Describe the name or value of declaration NODE at BEGINNING and ENDING.
MEDIA selects feature candidates instead of CSS property candidates."
  (let* ((name (treesit-node-child-by-field-name node "name"))
         (colon (scss2--child node ":"))
         (value (and colon (<= (treesit-node-end colon) (point))))
         (property (scss2--identifier-name name)))
    (scss2-context--context
     (if value (if media 'media-value 'property-value)
       (if media 'media-feature 'property))
     (if (and (not value) name) (scss2--identifier-start name) beginning)
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
                 ;; A direct identifier is the feature slot in a range.  Its
                 ;; identity cannot depend on the completion catalog knowing it.
                 (name (cl-find "plain_value" children :key #'treesit-node-type :test #'equal))
                 (current (cl-find-if
                           (lambda (child)
                             (<= (treesit-node-start child) (point) (treesit-node-end child)))
                           children))
                 (value (and range
                             (or (and current (not (equal (treesit-node-type current) "plain_value")))
                                 (and name (not (eq current name)))))))
            (scss2-context--context
             (cond (compound 'media-keyword)
                   (value 'media-value)
                   (property 'property)
                   (t 'media-feature))
             beginning ending
             :property (and name (scss2--identifier-name name))
             :query language)))
         (t (scss2-context--context 'media-keyword beginning ending
                                    :query language)))))))

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
                          (and nested (not (treesit-node-eq nested arguments))))))
          (scss2-context--context
           (if value 'property-value 'argument) beginning ending
           :mixin (let ((name (scss2--identifier-name name)))
                    (if module (concat (scss2--identifier-name module) "." name) name)))))))))

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
         (include (and sass (scss2-context--include-context node beginning ending)))
         (selector (scss2-context--selector-p node))
         (case-fold-search (eq scss2-dialect 'css)))
    (cond
     ;; Raw braces/colons are value text; only Sass interpolation reopens it.
     ((and raw (scss2--contains-point-p raw) (not interpolation))
      (let* ((declaration (scss2--ancestor raw '("property_declaration" "feature_query")))
             (name (and declaration (treesit-node-child-by-field-name declaration "name"))))
        (scss2-context--context 'property-value beginning ending
                                :property (scss2--identifier-name name))))
     ((and (> beginning (point-min)) (eq (char-before beginning) ?@))
      (when (string-match-p "\\`@[[:alnum:]_-]*\\'" prefix)
        (scss2-context--context 'at-rule (1- beginning) ending :owner owner)))
     ((and sass (memq (plist-get include :role) '(mixin argument))) include)
     ((and sass
           (string-match-p "\\`@include[ \t\n]+\\(?:[[:alnum:]_-]+\\.\\)?[[:alnum:]_-]*\\'" prefix))
      (scss2-context--context 'mixin beginning ending :module module))
     ((and sass (eq (char-after beginning) ?$))
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
      (plist-put (scss2-context--declaration-context declaration beginning ending)
                 :at-rule (scss2--directive owner)))
     ;; Gaps and unfinished input have no complete node to establish their role.
     ((and sass (string-match "\\`@include[ \t\n]+\\([[:alnum:]_.-]+\\)([^)]*\\'" prefix))
      (let ((mixin (match-string 1 prefix)))
        (scss2-context--context
         (if (string-match-p ":[^,]*\\'" prefix) 'property-value 'argument)
         beginning ending :mixin mixin)))
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
     ((and owner (not selector)
           (string-match "\\`\\([[:alnum:]_$-]+\\)[ \t]*:[ \t\n]*" prefix))
      (let ((property (match-string 1 prefix)))
        (unless (and (string-prefix-p "$" property) (not sass))
          (scss2-context--context 'property-value beginning ending :property property))))
     ((and (> beginning (point-min)) (eq (char-before beginning) ?:))
      (scss2-context--selector-context beginning ending))
     ((and (scss2--declaration-body-p owner)
           (not (string-match-p "\\`[.#&%>+~]" prefix))
           (or (string-match-p "\\`[[:alnum:]_-]*\\'" prefix)
               (string-match-p "\\`[[:alpha:]_-][^ \t\n;{}]*\\'" prefix)))
      (scss2-context--context 'property beginning ending
                              :at-rule (scss2--directive owner) :start start))
     ((string-prefix-p "@" prefix) nil)
     (t (scss2-context--selector-context beginning ending)))))

(defun scss2-context--base-context ()
  "Describe the syntax role at point as a plist, or nil in opaque text.
The plist contains :role, :beg and :end.  Values additionally carry :property;
Sass member contexts may carry :module.  Incomplete input is intentional."
  (when (and scss2-dialect (treesit-parser-list))
    (let* ((position (point))
           (node (scss2--node-at-point))
           (state (syntax-ppss))
           (comment (scss2--ancestor node '("block_comment" "inline_comment")))
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
is intentional."
  (let ((minimum (point-min)) (maximum (point-max)))
    (save-restriction
      (widen)
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
