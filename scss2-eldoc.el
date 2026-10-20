;;; scss2-eldoc.el --- Signatures for resolved Sass calls -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Argument context and presentation only; scss2-completion owns lookup.

;;; Code:

(require 'eldoc)
(require 'scss2-completion)

(defun scss2-eldoc--argument-context ()
  "Return (NAME INDEX KEYWORD) for the innermost call's arguments at point.
NAME is the callee name node, INDEX is zero-based and KEYWORD is the
source spelling of a named argument, or nil.  Content parameters and
unparsed argument lists are ignored."
  (let* ((position (point))
         (node (treesit-node-at (max (point-min) (1- position)) (scss2--language)))
         arguments)
    (while (and node (not arguments))
      (when (and (equal (treesit-node-type node) "arguments")
                 (< (treesit-node-start node) position (treesit-node-end node)))
        (setq arguments node))
      (setq node (treesit-node-parent node)))
    (when (and arguments
               (member (treesit-node-type (treesit-node-parent arguments))
                       '("include_statement" "call_expression"))
               (eq (char-before (treesit-node-end arguments)) ?\)))
      (let ((index 0) keyword)
        (dolist (child (scss2--children arguments))
          (cond
           ((and (equal (treesit-node-type child) ",")
                 (< (treesit-node-start child) position))
            (cl-incf index)
            (setq keyword nil))
           ((and (member (treesit-node-type child) '("named_argument" "variable_name"))
                 (<= (treesit-node-start child) position))
            (let ((name (if (equal (treesit-node-type child) "named_argument")
                            (treesit-node-child-by-field-name child "name") child)))
              ;; With an empty value, the parser leaves the colon in an ERROR.
              (when (save-excursion
                      (goto-char (treesit-node-end name))
                      (forward-comment (point-max))
                      (eq (char-after) ?:))
                (setq keyword (treesit-node-text name t)))))))
        (list (treesit-node-child-by-field-name (treesit-node-parent arguments) "name")
              index keyword)))))

(defun scss2-eldoc--parameter-text (parameter)
  "Return PARAMETER's text on one line, without comments or properties."
  (let ((text (treesit-node-text parameter t))
        (start (treesit-node-start parameter))
        (pending (scss2--children parameter t)) comments)
    (while pending
      (let ((node (pop pending)))
        (if (member (treesit-node-type node) scss2--comment-types)
            (push node comments)
          (setq pending (append (scss2--children node t) pending)))))
    (dolist (comment comments)
      (setq text (concat (substring text 0 (- (treesit-node-start comment) start))
                         " " (substring text (- (treesit-node-end comment) start)))))
    (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text))))

(defun scss2-eldoc--signature (name index keyword)
  "Read NAME's definition in its live tree, highlighting INDEX or KEYWORD."
  (when-let* ((definition (scss2--ancestor name '("mixin_definition" "function_definition"))))
    (let* ((parameters (treesit-node-child-by-field-name definition "parameters"))
           (items (cl-remove-if-not
                   (lambda (child) (equal (treesit-node-type child) "parameter"))
                   (scss2--children parameters t)))
           (rest (cl-find-if (lambda (parameter) (scss2--child parameter "spread")) items))
           (current (if keyword
                        (or (cl-find (scss2-completion-sass-name keyword) items
                                     :key (lambda (parameter)
                                            (scss2-completion-sass-name
                                             (treesit-node-text
                                              (treesit-node-child-by-field-name parameter "name") t)))
                                     :test #'equal)
                            rest)
                      (or (nth index items) rest))))
      (concat "("
              (mapconcat (lambda (parameter)
                           (let ((text (scss2-eldoc--parameter-text parameter)))
                             (if (eq parameter current)
                                 (propertize text 'face 'eldoc-highlight-function-argument)
                               text)))
                         items ", ")
              ")"))))

(defun scss2-eldoc--documentation ()
  "Return (SIGNATURE . THING) for the resolved Sass call around point."
  (when (and (eq scss2-dialect 'scss)
             (treesit-parser-list nil (scss2--language)))
    (scss2--with-font-lock-view
     (save-excursion
       (when-let* ((context (scss2-eldoc--argument-context))
                   (name (car context)))
         (goto-char (treesit-node-start name))
         (when-let* ((reference (scss2-completion-reference-at-point))
                     (definition (car (scss2-completion-definitions
                                       reference
                                       (lambda (target)
                                         (scss2-eldoc--signature target (nth 1 context) (nth 2 context))))))
                     (signature (plist-get definition :value)))
           (cons signature (concat (and (nth 1 reference) (concat (nth 1 reference) "."))
                                   (nth 2 reference)))))))))

(defun scss2-eldoc-function (callback &rest _ignored)
  "Document the resolved Sass call around point through CALLBACK.
Return nil without documentation elsewhere so other providers can run."
  (when-let* ((documentation (scss2-eldoc--documentation)))
    (funcall callback (car documentation)
             :thing (cdr documentation) :face 'font-lock-function-name-face)))

(provide 'scss2-eldoc)
;;; scss2-eldoc.el ends here
