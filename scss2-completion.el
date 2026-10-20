;;; scss2-completion.el --- Contextual CSS and SCSS completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Semantic tables consume an explicit context.  CSS metadata comes from
;; emmet2-mode's bundled data; scopes and local module members are derived on
;; demand.
;; Tables follow the completion-table protocol and return plain prefix
;; matches.  The `scss2' completion style owns CSS and Sass name matching.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'scss2-syntax)
(require 'emmet2-completion)

;; Loading the CSS data parses Emmet's documentation JSON; defer it to first use.
(autoload 'emmet2-css-data-query "emmet2-css-data")

(defconst scss2-completion--media
  '(("width") ("height") ("aspect-ratio") ("resolution")
    ("min-width") ("max-width") ("min-height") ("max-height")
    ("orientation" "portrait" "landscape")
    ("prefers-color-scheme" "light" "dark")
    ("prefers-reduced-motion" "reduce" "no-preference")
    ("prefers-contrast" "more" "less" "custom" "no-preference")
    ("hover" "none" "hover") ("any-hover" "none" "hover")
    ("pointer" "none" "coarse" "fine") ("any-pointer" "none" "coarse" "fine")
    ("color") ("color-gamut" "srgb" "p3" "rec2020")
    ("display-mode" "browser" "fullscreen" "standalone" "minimal-ui")
    ("forced-colors" "none" "active")
    ("overflow-block" "none" "scroll" "paged")
    ("overflow-inline" "none" "scroll")
    ("scripting" "none" "initial-only" "enabled")
    ("update" "none" "slow" "fast")))

(defun scss2-completion--custom-property-spelling (name)
  "Spell decoded custom-property NAME as a valid CSS identifier."
  (replace-regexp-in-string
   "[^[:alnum:]_-]"
   (lambda (text)
     (let ((character (string-to-char text)))
       (if (< character 128) (format "\\%x " character) text)))
   name t t))

(defun scss2-completion--text (node)
  "Return NODE's text without properties."
  (when node (treesit-node-text node t)))

(defun scss2-completion--sass-name (text)
  "Return the Sass identity of TEXT, retaining its case."
  (string-replace "_" "-" (scss2--decode-identifier text)))

(defun scss2-completion--visible-p (node position)
  "Whether NODE's containing block is visible at POSITION."
  (let ((parent (treesit-node-parent node)) scope)
    (while (and parent (not scope))
      (setq scope (scss2--block-bounds parent)
            parent (treesit-node-parent parent)))
    (or (not scope) (<= (car scope) position (cdr scope)))))

(defun scss2-completion--definitions (types)
  "Return visible definition nodes in TYPES from the current syntax tree."
  (let ((position (point)))
    (cl-remove-if-not
     (lambda (node) (scss2-completion--visible-p node position))
     (mapcar #'cdr
             (treesit-query-capture
              (scss2--root-node)
              (scss2--query
               (mapconcat (lambda (type) (format "(%s) @definition" type)) types "\n")))))))

(defun scss2-completion--bound-p (node position)
  "Whether variable declaration NODE is complete before POSITION.
One followed only by blanks up to POSITION is still being written, unless
its terminator is already there."
  (let ((end (treesit-node-end node)))
    (and (<= end position)
         (or (eq (char-before end) ?\;)
             (not (string-blank-p (buffer-substring-no-properties end position)))))))

(defun scss2-completion--parameters (parameters position)
  "Return the variable nodes of PARAMETERS bound at POSITION.
A parameter is bound once the comma or parenthesis that ends it precedes
POSITION, so a default value sees only the parameters before its own."
  (let (bound pending)
    (dolist (child (scss2--children parameters))
      (pcase (treesit-node-type child)
        ("parameter"
         (when-let* ((name (treesit-node-child-by-field-name child "name"))
                     (_ (equal (treesit-node-type name) "variable_name")))
           (push name pending)))
        ((or "," ")")
         (when (< (treesit-node-start child) position)
           (setq bound (nconc pending bound) pending nil)))))
    (nreverse bound)))

(defun scss2-completion--scope (node position)
  "Return statement NODE as a scope (TYPE IN-BLOCK . BINDERS) at POSITION.
IN-BLOCK is non-nil when point is inside NODE's block.  BINDERS are the
variable nodes bound there: a callable binds its parameters for its
signature and body; a loop and an include's content block bind theirs only
inside the block."
  (let* ((type (treesit-node-type node))
         (in-block (and (scss2--in-block-p node) t)))
    (cl-list*
     type in-block
     (cond
      ((member type '("mixin_definition" "function_definition"))
       (scss2-completion--parameters
        (treesit-node-child-by-field-name node "parameters") position))
      ((not in-block) nil)
      ((equal type "include_statement")
       (scss2-completion--parameters
        (treesit-node-child-by-field-name node "parameters") position))
      ((member type '("each_statement" "for_statement"))
       ;; Variables before the keyword are bound; those after it are read.
       (cl-loop for child in (scss2--children node)
                until (member (treesit-node-type child) '("in" "from"))
                when (equal (treesit-node-type child) "variable_name")
                collect child))))))

(defun scss2-completion--scopes ()
  "Return the scopes around point, innermost first.
Each is (TYPE IN-BLOCK . BINDERS), as `scss2-completion--scope' describes.
TYPE is recovered from surviving tokens where the parser lost it; only
blocks that still enclose point are recovered."
  (let ((node (scss2--node-at-point)) (position (point)) scopes)
    (while node
      (if (equal (treesit-node-type node) "ERROR")
          (dolist (scope (scss2--recovered-sass-scopes node))
            (push (cl-list* (car scope) t
                            (append (scss2-completion--parameters (cadr scope) position)
                                    (cddr scope)))
                  scopes))
        (when (member (treesit-node-type node) scss2--statement-types)
          (push (scss2-completion--scope node position) scopes)))
      (setq node (treesit-node-parent node)))
    (nreverse scopes)))

(defun scss2-completion--enclosing-types ()
  "Return the types of the statements whose block contains point."
  (cl-loop for (type in-block) in (scss2-completion--scopes)
           when in-block collect type))

(cl-defun scss2-completion--bindings
    (types &optional variable (definitions (scss2-completion--definitions types)) transform)
  "Return name nodes of visible TYPES; VARIABLE includes lexical bindings.
DEFINITIONS can reuse visible nodes already collected for this request.
TRANSFORM optionally projects each name node while collecting it."
  (let ((position (point)) bindings)
    (dolist (node definitions)
      (when (and (member (treesit-node-type node) types)
                 (or (not variable) (scss2-completion--bound-p node position)))
        (when-let* ((name (treesit-node-child-by-field-name node "name")))
          (push (if transform (funcall transform name) name) bindings))))
    (when variable
      (dolist (scope (scss2-completion--scopes))
        (dolist (binder (cddr scope))
          (push (if transform (funcall transform binder) binder) bindings))))
    bindings))

(cl-defun scss2-completion--names
    (types &optional variable (definitions (scss2-completion--definitions types)))
  "Return names of visible TYPES; VARIABLE also includes lexical bindings.
DEFINITIONS can reuse visible nodes already collected for this request."
  (delete-dups (scss2-completion--bindings types variable definitions
                                           #'scss2-completion--text)))

(defun scss2-completion--custom-properties ()
  "Return (NODE . NAME) for static custom properties in source order."
  (cl-loop for capture in (treesit-query-capture (scss2--root-node)
                                                (scss2--query '((property_declaration name: (property_name) @property))))
           for node = (cdr capture)
           for name = (scss2--identifier-name node)
           when (and name (string-prefix-p "--" name)) collect (cons node name)))

(defun scss2-completion--module-path (module)
  "Resolve MODULE from a literal local @use in this buffer, or return nil.
Only direct local files are read; load paths and packages are left to other
completion functions, such as a language server.  No project index is kept."
  (when-let* ((path (cdr (assoc module (scss2--module-namespaces))))
              (_ (not (string-match-p "[:#]" path))))
    (let* ((base (expand-file-name path (if buffer-file-name
                                           (file-name-directory buffer-file-name) default-directory)))
           (directory (file-name-directory base))
           (name (file-name-nondirectory base))
           (extension (file-name-extension base))
           (candidates
            (if (member extension '("scss" "css"))
                ;; An explicit extension must never select another dialect.
                (list base (expand-file-name (concat "_" name) directory))
              (list (concat base ".scss")
                    (expand-file-name (concat "_" name ".scss") directory)
                    (concat base ".css")
                    (expand-file-name (concat "_" name ".css") directory)
                    (expand-file-name "_index.scss" base)
                    (expand-file-name "index.scss" base)
                    (expand-file-name "_index.css" base)
                    (expand-file-name "index.css" base)
                    base))))
      (cl-find-if (lambda (file) (and (file-regular-p file) (file-readable-p file)))
                  candidates))))

(defun scss2-completion--public-definitions (root types)
  "Return (NODE . SPELLING) for ROOT's public top-level definitions of TYPES.
The last definition comes first."
  (let (definitions)
    ;; Stop at direct children and materialize only matching definitions.
    (dolist (entry (cdr (treesit-induce-sparse-tree
                        root (concat "\\`" (regexp-opt types t) "\\'") nil 1)))
      (when-let* ((text (scss2--identifier-text
                         (treesit-node-child-by-field-name (car entry) "name")))
                  (_ (not (string-match-p "\\`\\$?[-_]" (scss2--decode-identifier text)))))
        (push (cons (car entry) text) definitions)))
    definitions))

(defun scss2-completion--exports (root types)
  "Return public top-level names in ROOT matching TYPES."
  (mapcar #'cdr (scss2-completion--public-definitions root types)))

(defun scss2-completion--module-names (module types)
  "Return public top-level Sass names in local MODULE matching TYPES."
  (scss2-completion--in-module
   module (lambda (root) (scss2-completion--exports root types))))

(defun scss2-completion--read-module (path existing function)
  "Call FUNCTION on the Sass root of PATH, using EXISTING when open."
  (let* (;; The host already loaded this generation, even after a package reload.
         (language (scss2--language))
         (parser (and existing
                      (with-current-buffer existing
                        (cl-find language (treesit-parser-list) :key #'treesit-parser-language)))))
    (if parser
        (with-current-buffer existing
          (save-excursion
            (save-restriction
              (widen)
              (funcall function (treesit-parser-root-node parser)))))
      (with-temp-buffer
        ;; Unsaved source is authoritative when the module is already open.
        (when (condition-case nil
                  (progn
                    (if existing
                        (let ((target (current-buffer)))
                          (with-current-buffer existing
                            (save-restriction
                              (widen)
                              (with-current-buffer target
                                (insert-buffer-substring-no-properties existing)))))
                      (insert-file-contents path))
                    t)
                (file-error nil))
          (let ((parser (treesit-parser-create language)))
            (unwind-protect
                (funcall function (treesit-parser-root-node parser))
              ;; Deleting a parser leaves its native tree allocated until GC.
              ;; Replace this temporary tree with an empty one before exit.
              (treesit-parser-set-included-ranges parser '((1 . 1)))
              (treesit-parser-root-node parser))))))))

(defun scss2-completion--in-module (module function)
  "Call FUNCTION on local MODULE's Sass root in its source buffer.
Nodes are valid only during the call. CSS modules have no Sass exports."
  (when-let* ((path (scss2-completion--module-path module))
              (_ (not (equal (file-name-extension path) "css"))))
    (scss2-completion--read-module path (find-buffer-visiting path) function)))

(defun scss2-completion--reference-node ()
  "Return the static name node at point, including a module qualifier."
  (let ((position (point)))
    (cl-loop for p in (list position (max (point-min) (1- position)))
             for leaf = (treesit-node-at p (scss2--language))
             for name = (scss2--ancestor leaf '("variable_name" "function_name" "module_name"
                                                "placeholder_selector" "plain_value"))
             when (and name (scss2--identifier-text name)
                       (<= (treesit-node-start name) position (treesit-node-end name)))
             return (if (equal (treesit-node-type name) "module_name")
                        (treesit-node-child-by-field-name (treesit-node-parent name) "name")
                      name))))

(defun scss2-completion-reference-at-point ()
  "Return (KIND MODULE NAME) for the static name at point, or nil.
MODULE and NAME retain source spelling; MODULE is nil for local names.
KIND is variable, mixin, function, placeholder or custom-property."
  (scss2--with-font-lock-view
   (let* ((node (scss2-completion--reference-node))
          (type (treesit-node-type node))
          (parent (treesit-node-parent node))
          (text (scss2--identifier-text node))
          (kind
           (cond
            ((and (eq scss2-dialect 'scss) (equal type "variable_name")) 'variable)
            ((and (eq scss2-dialect 'scss) (equal type "placeholder_selector")) 'placeholder)
            ((and (eq scss2-dialect 'scss) (equal type "function_name"))
             (pcase (treesit-node-type parent)
               ((or "include_statement" "mixin_definition") 'mixin)
               ((or "call_expression" "function_definition") 'function)))
            ((and text
                  (save-excursion
                    (goto-char (treesit-node-end node))
                    (scss2--custom-property-reference-p
                     (scss2--ancestor node '("call_expression")) (treesit-node-start node))))
             'custom-property))))
     (when (and kind text)
       (list kind (scss2--identifier-text (treesit-node-child-by-field-name parent "module")) text)))))

(defun scss2-completion--binding-owner (node)
  "Return the lexical block owning name NODE, or nil for the module scope."
  (let ((parent (treesit-node-parent node)) owner)
    (while (and parent (not owner))
      (when (and (not (equal (treesit-node-type parent) "variable_declaration"))
                 (or (scss2--block-bounds parent)
                     (and (member (treesit-node-type parent) '("mixin_definition" "function_definition"
                                                               "each_statement" "for_statement" "include_statement"))
                          (scss2--in-block-p parent))))
        (setq owner parent))
      (setq parent (treesit-node-parent parent)))
    owner))

(defun scss2-completion--global-p (name)
  "Whether variable name NAME is declared with !global."
  (let ((declaration (treesit-node-parent name)))
    (and (equal (treesit-node-type declaration) "variable_declaration")
         (cl-some (lambda (child)
                    (and (equal (treesit-node-type child) "flag")
                         (equal (scss2-completion--text child) "!global")))
                  (scss2--children declaration)))))

(defun scss2-completion--in-parameter-default-p ()
  "Whether point is in the default value of a mixin or function parameter."
  (when-let* ((node (scss2-completion--reference-node))
              (parameter (scss2--ancestor node '("parameter")))
              (value (treesit-node-child-by-field-name parameter "value")))
    (and (<= (treesit-node-start value) (point) (treesit-node-end value))
         (member (treesit-node-type (treesit-node-parent (treesit-node-parent parameter)))
                 '("mixin_definition" "function_definition")))))

(defun scss2-completion--local-definition (kind name)
  "Return the nearest static binding for KIND and Sass NAME at point."
  (let* ((types (pcase kind
                  ('variable '("variable_declaration"))
                  ('mixin '("mixin_definition"))
                  ('function '("function_definition"))))
         (all (mapcar #'cdr (treesit-query-capture
                             (scss2--root-node)
                             (scss2--query (format "(%s) @definition" (car types))))))
         (visible (cl-remove-if-not (lambda (node) (scss2-completion--visible-p node (point))) all))
         (bindings (scss2-completion--bindings types (eq kind 'variable) visible))
         best (best-depth -1) (best-position -1))
    (when (eq kind 'variable)
      (dolist (node all)
        (let ((binding (treesit-node-child-by-field-name node "name")))
          (when (and (scss2-completion--global-p binding)
                     (scss2-completion--bound-p node (point)))
            (push binding bindings)))))
    (dolist (binding bindings)
      (when (and (< (treesit-node-start binding) (point))
                 (not (treesit-node-child-by-field-name (treesit-node-parent binding) "module"))
                 (equal (scss2-completion--sass-name (or (scss2--identifier-text binding) "")) name))
        (let ((owner (unless (scss2-completion--global-p binding)
                       (scss2-completion--binding-owner binding)))
              (depth 0) (position (treesit-node-start binding)))
          (while owner
            (cl-incf depth)
            (setq owner (scss2-completion--binding-owner owner)))
          (when (or (> depth best-depth)
                    (and (= depth best-depth) (> position best-position)))
            (setq best binding best-depth depth best-position position)))))
    (or best
        (when (or (cl-some (lambda (scope)
                             (and (cadr scope) (member (car scope) '("mixin_definition" "function_definition"))))
                           (scss2-completion--scopes))
                  (scss2-completion--in-parameter-default-p))
          (cl-loop for declaration in all
                   for binding = (treesit-node-child-by-field-name declaration "name")
                   when (and (> (treesit-node-start binding) (point))
                             (not (scss2-completion--binding-owner declaration))
                             (not (treesit-node-child-by-field-name declaration "module"))
                             (equal (scss2-completion--sass-name (or (scss2--identifier-text binding) "")) name))
                   return binding)))))

(defun scss2-completion--definition-location (node kind name &optional file buffer)
  "Copy NODE into a durable location for KIND and NAME, with FILE or BUFFER."
  (let ((position (treesit-node-start node)))
    (save-excursion
      (goto-char position)
      (let ((line (line-number-at-pos position t))
            (column (- position (line-beginning-position))))
        (beginning-of-line)
        (skip-chars-forward " \t" (line-end-position))
        (list :kind kind :name name :buffer (if file buffer (or buffer (current-buffer)))
              :file (or file buffer-file-name) :position position :line line :column column
              :summary (string-trim (buffer-substring-no-properties
                                     (point) (min (line-end-position) (+ (point) 160)))))))))

(defun scss2-completion--parameter (definition name)
  "Return DEFINITION's parameter matching canonical Sass NAME."
  (cl-find name (scss2-completion--parameters
                 (treesit-node-child-by-field-name definition "parameters") most-positive-fixnum)
           :key (lambda (node) (scss2-completion--sass-name (scss2-completion--text node)))
           :test #'equal))

(defun scss2-completion--sass-definition (reference &optional parameter)
  "Resolve Sass REFERENCE, optionally selecting its named PARAMETER."
  (pcase-let ((`(,kind ,module ,name) reference))
    (let ((project (lambda (node file buffer)
                     (when-let* ((target (if parameter (scss2-completion--parameter node parameter) node)))
                       (list (scss2-completion--definition-location
                              target (if parameter 'variable kind) (or parameter name) file buffer))))))
      (if module
          (when-let* ((file (scss2-completion--module-path module))
                      (_ (not (equal (file-name-extension file) "css"))))
            (let ((existing (find-buffer-visiting file))
                  (types (pcase kind ('variable '("variable_declaration"))
                                ('mixin '("mixin_definition")) ('function '("function_definition")))))
              (scss2-completion--read-module
               file existing
               (lambda (root)
                 (when-let* ((entry (cl-find name (scss2-completion--public-definitions root types)
                                             :key (lambda (entry) (scss2-completion--sass-name (cdr entry)))
                                             :test #'equal)))
                   (funcall project (if parameter (car entry)
                                      (treesit-node-child-by-field-name (car entry) "name")) file existing))))))
        (when-let* ((node (scss2-completion--local-definition kind name)))
          (funcall project (if parameter (treesit-node-parent node) node) nil (current-buffer)))))))

(defun scss2-completion-definitions (reference)
  "Return location plists for (KIND MODULE NAME) REFERENCE at point.
Results contain :kind, :name, :buffer, :file, :position, :line, :column and
:summary; :buffer is nil for a module file that is not open. Positions are
absolute. Read Font Lock's tree view and preserve point and narrowing. Local
@use reads include unsaved buffers. Return nil for unresolved names; see
docs/architecture.md for lookup rules and limits."
  (scss2--with-font-lock-view
   (pcase-let ((`(,kind ,module ,spelling) reference))
     (when (and (memq kind '(variable mixin function placeholder custom-property))
                (stringp spelling) (or (null module) (stringp module)))
       (let* ((name (if (eq kind 'custom-property) (scss2--decode-identifier spelling)
                      (scss2-completion--sass-name spelling)))
              (module (and module (scss2--decode-identifier module)))
              (node (and (eq kind 'variable) (scss2-completion--reference-node)))
              (argument (and node (equal (treesit-node-type (treesit-node-parent node)) "named_argument")
                             (treesit-node-eq node (treesit-node-child-by-field-name
                                                    (treesit-node-parent node) "name"))
                             (equal name (scss2-completion--sass-name (scss2-completion--text node)))
                             (treesit-node-parent node))))
         (cond
          (argument
           (let* ((call (scss2--ancestor argument '("include_statement" "call_expression")))
                  (callee (scss2--identifier-name (treesit-node-child-by-field-name call "name")))
                  (namespace (scss2--identifier-name (treesit-node-child-by-field-name call "module"))))
             (when callee
               (scss2-completion--sass-definition
                (list (if (equal (treesit-node-type call) "include_statement") 'mixin 'function)
                      namespace (scss2-completion--sass-name callee)) name))))
          ((eq kind 'custom-property)
           (cl-loop for (node . property) in (scss2-completion--custom-properties)
                    when (equal property name)
                    collect (scss2-completion--definition-location node kind name)))
          ((and (eq scss2-dialect 'scss) (eq kind 'placeholder) (not module))
           (cl-loop for capture in (treesit-query-capture (scss2--root-node)
                                                          (scss2--query '((placeholder_selector) @name)))
                    for node = (cdr capture)
                    when (and (equal (treesit-node-type (scss2--ancestor node '("rule_set" "extend_statement"))) "rule_set")
                              (equal (scss2-completion--sass-name (or (scss2--identifier-text node) "")) name))
                    collect (scss2-completion--definition-location node kind name)))
          ((and (eq scss2-dialect 'scss) (memq kind '(variable mixin function)))
           (scss2-completion--sass-definition (list kind module name)))))))))

(defun scss2-completion--values (property &optional at-rule)
  "Return shared CSS values for PROPERTY in AT-RULE plus visible Sass names."
  (let ((values (emmet2-css-data-query 'value :property property :at-rule at-rule :vendor t))
        (names
         (when (eq scss2-dialect 'scss)
           (let ((definitions (scss2-completion--definitions
                               '("variable_declaration" "function_definition"))))
             (append (scss2-completion--names '("variable_declaration") t definitions)
                     (mapcar (lambda (name) (concat name "()"))
                             (scss2-completion--names
                              '("function_definition") nil definitions)))))))
    (append values (mapcar (lambda (name) (cons name nil)) names))))

(defun scss2-completion--continues-conditional-p (position)
  "Whether a directive at POSITION directly follows an @if or @else if block.
The block's own statement text decides, so an unclosed outer block or a
recovered tree gives the same answer."
  (save-excursion
    (goto-char position)
    (forward-comment (- (point)))
    (when (eq (char-before) ?})
      (condition-case nil
          (progn
            (backward-sexp)
            (goto-char (scss2--statement-start))
            (let ((case-fold-search nil))
              (looking-at-p "@\\(?:if\\|else[ \t\n]+if\\)\\_>")))
        (scan-error nil)))))

(defun scss2-completion--at-rules (context)
  "Return directives legal for the language and enclosing CONTEXT."
  (let* ((owner (plist-get context :owner))
         (rules (emmet2-css-data-query 'at-rule :vendor t))
         (scss (eq scss2-dialect 'scss)))
    (when owner
      (setq rules (cl-remove-if (lambda (entry) (member (car entry) '("@charset" "@import" "@namespace"))) rules)))
    (when scss
      (let* ((scopes (scss2-completion--enclosing-types))
             ;; The innermost callable decides what its body may contain.
             (callable (cl-find-if (lambda (type)
                                     (member type '("mixin_definition" "function_definition")))
                                   scopes)))
        (setq rules
              (append
               (mapcar (lambda (name) (cons name "Sass directive"))
                       (append (when (scss2-completion--continues-conditional-p
                                      (plist-get context :beg))
                                 '("@else"))
                               '("@mixin" "@include" "@function" "@if" "@each" "@for" "@while"
                                 "@debug" "@warn" "@error" "@at-root")
                               (unless owner '("@use" "@forward"))
                               (when (member "rule_set" scopes) '("@extend"))
                               (when (equal callable "mixin_definition") '("@content"))
                               (when (equal callable "function_definition") '("@return"))))
               rules))))
    rules))

(defun scss2-completion--paths (prefix)
  "Return local file candidates for the import path PREFIX.
Sass loads `_name.scss' and `name.scss' as `name', so offer that name too."
  (let* ((directory (file-name-directory prefix))
         (base (if buffer-file-name (file-name-directory buffer-file-name) default-directory))
         (files (condition-case nil
                    (file-name-all-completions "" (expand-file-name (or directory "") base))
                  (file-error nil)))
         names)
    (dolist (file files)
      (when (and (eq scss2-dialect 'scss)
                 (string-match "\\`_?\\(.+\\)\\.scss\\'" file))
        (push (concat directory (match-string 1 file)) names))
      (push (concat directory file) names))
    (delete-dups (nreverse names))))

(defun scss2-completion--named-arguments (definition)
  "Return named-argument candidates for the parameters of mixin DEFINITION."
  (when-let* ((parameters (treesit-node-child-by-field-name definition "parameters")))
    (mapcar (lambda (name) (cons (concat (scss2-completion--text name) ": ") "Mixin argument"))
            (scss2-completion--parameters parameters most-positive-fixnum))))

(defun scss2-completion--candidates (context)
  "Return (NAME . DOCUMENTATION) pairs for CONTEXT."
  (let ((role (plist-get context :role)) (module (plist-get context :module)))
    (pcase role
      ('at-rule (scss2-completion--at-rules context))
      ('for-range '(("through" . "Inclusive loop bound") ("to" . "Exclusive loop bound")))
      ('property-value (scss2-completion--values (plist-get context :property) (plist-get context :at-rule)))
      ('pseudo (emmet2-css-data-query 'pseudo :vendor t))
      ('media-feature (mapcar (lambda (entry) (cons (car entry) "Media feature")) scss2-completion--media))
      ('media-value (mapcar (lambda (name) (cons name nil))
                           (cdr (assoc (downcase (or (plist-get context :property) "")) scss2-completion--media))))
      ('media-keyword
       (mapcar (lambda (name) (cons name nil))
               ;; Media types belong to media queries and import conditions.
               (if (member (plist-get context :query) '("@media" "@import"))
                   '("screen" "print" "all" "and" "or" "not" "only")
                 '("and" "or" "not"))))
      ((or 'variable 'mixin 'module-member)
       (let* ((types (pcase role
                       ('variable '("variable_declaration"))
                       ('mixin '("mixin_definition"))
                       ;; A value reads functions and variables, never mixins.
                       (_ '("function_definition" "variable_declaration"))))
              (names (if module (scss2-completion--module-names module types)
                       (scss2-completion--names types (eq role 'variable))))
              (documentation (if module (concat "From " module) "Current scope")))
         (mapcar (lambda (name) (cons name documentation)) names)))
      ('argument
       (let* ((name (scss2-completion--sass-name (or (plist-get context :mixin) "")))
              (named-p (lambda (text) (and text (equal name (scss2-completion--sass-name text)))))
              (arguments
               (if module
                   (scss2-completion--in-module
                    module (lambda (root)
                             (when-let* ((definition (cl-find-if named-p (scss2-completion--public-definitions
                                                                           root '("mixin_definition"))
                                                                 :key #'cdr)))
                               (scss2-completion--named-arguments (car definition)))))
                 ;; Visible definitions arrive in source order.  The last one
                 ;; before point is the innermost, latest static binding.
                 (when-let* ((definition
                              (cl-find-if (lambda (node)
                                            (and (< (treesit-node-start node) (point))
                                                 (funcall named-p (scss2--identifier-text
                                                                   (treesit-node-child-by-field-name node "name")))))
                                          (reverse (scss2-completion--definitions '("mixin_definition"))))))
                   (scss2-completion--named-arguments definition)))))
         (append arguments (scss2-completion--values nil))))
      ('custom-property
       (mapcar (lambda (entry)
                 (cons (scss2-completion--custom-property-spelling (cdr entry)) "Custom property"))
               (scss2-completion--custom-properties))))))

(add-to-list 'completion-styles-alist
             (cons 'scss2 (cdr (assq 'emmet2-name completion-styles-alist))))

(add-to-list 'completion-category-defaults '(scss2 (styles scss2)))

(defun scss2-completion-for-context (context)
  "Return a semantic completion table for CONTEXT in the current buffer.
CONTEXT supplies the role and replacement bounds.  This function neither
classifies point nor invokes abbreviation completion; composition owns both.
Return nil for a module without a local file or a path without a local
listing, so that later completion functions can offer them."
  (when context
    (pcase (plist-get context :role)
      ((or 'property 'selector) nil)
      ('path
       (let* ((begin (plist-get context :beg))
              (end (plist-get context :end))
              (prefix (buffer-substring-no-properties begin end))
              ;; Built-in modules and package URLs have no local listing.
              (paths (and (not (string-match-p "[:#]" prefix))
                          (scss2-completion--paths prefix))))
         (when paths
           (list begin end paths :exclusive t :company-kind (lambda (_) 'file)))))
      (_ (let* ((role (plist-get context :role))
                (module (plist-get context :module))
                (sass (memq role '(variable mixin argument module-member for-range))))
           ;; Decline built-in, package and load-path modules, which have no local file.
           ;; Collect members lazily: frontends call this again on every key.
           (unless (and module (not (scss2--with-font-lock-view
                                      (scss2-completion--module-path module))))
             (emmet2-completion-capf
              (plist-get context :beg) (plist-get context :end)
              (lambda () (scss2--with-font-lock-view (scss2-completion--candidates context)))
              :category 'scss2
              :identity (if sass #'scss2-completion--sass-name #'scss2--decode-identifier)
              :fuzzy (not (or sass (eq role 'custom-property)))
              :annotation (concat "  " (or (plist-get context :property) (symbol-name role)))
              :prefix (and (memq role '(at-rule variable pseudo custom-property)) t))))))))

(provide 'scss2-completion)
;;; scss2-completion.el ends here
