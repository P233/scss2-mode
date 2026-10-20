;;; scss2-flymake.el --- Tree-sitter parse diagnostics -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Flymake owns scheduling; this backend only reads Font Lock's tree view.

;;; Code:

(require 'flymake)
(require 'scss2-syntax)

(defconst scss2-flymake--diagnostic-limit 200
  "Maximum number of parse diagnostics reported by one check.")

(defun scss2-flymake (report-fn &rest _args)
  "Report Tree-sitter parse errors to Flymake through REPORT-FN.
Read Font Lock's tree view, including errors outside narrowing unless
`font-lock-dont-widen' is non-nil.  Report outermost ERROR nodes and
missing tokens, with at most `scss2-flymake--diagnostic-limit' diagnostics.
A buffer without a parser reports no diagnostics.  This function does
not enable `flymake-mode'."
  (let (diagnostics)
    (scss2--with-font-lock-view
      (let ((root (and (treesit-parser-list nil (scss2--language)) (scss2--root-node)))
            (count 0))
        (when (and root (treesit-node-check root 'has-error))
          (let ((stack (list (cons root 0))))
            (cl-labels
                ((report (beg end message)
                   (cl-incf count)
                   ;; Flymake discards empty ranges; at EOF, mark the preceding character.
                   (when (= beg end)
                     (setq beg (min beg (1- (point-max)))
                           end (1+ beg)))
                   (push (flymake-make-diagnostic
                          (current-buffer)
                          beg end
                          :error
                          (if (= count scss2-flymake--diagnostic-limit)
                              (format "%s (Diagnostic limit of %d reached; further errors may be omitted)"
                                      message scss2-flymake--diagnostic-limit)
                            message))
                         diagnostics)))
              (while (and stack (< count scss2-flymake--diagnostic-limit))
                (let* ((frame (pop stack))
                       (node (car frame))
                       (index (cdr frame)))
                  (cond
                   ((equal (treesit-node-type node) "ERROR")
                    (report (treesit-node-start node) (treesit-node-end node) "Parse error"))
                   ((treesit-node-check node 'missing)
                    (report (treesit-node-start node) (treesit-node-end node)
                            (format "Missing %s" (treesit-node-type node))))
                   (t
                    (let ((child (treesit-node-child node index)))
                      (while (and child (not (treesit-node-check child 'has-error)))
                        (setq index (1+ index)
                              child (treesit-node-child node index)))
                      (cond
                       (child
                        (push (cons node (1+ index)) stack)
                        (push (cons child 0) stack))
                       ;; Hidden MISSING tokens set has-error but have no child node.
                       ((zerop (cdr frame))
                        (let ((sexp (treesit-node-string node)) (start 0))
                          (while (and (< count scss2-flymake--diagnostic-limit)
                                      (string-match "(MISSING \\([^()]+\\))" sexp start))
                            (let ((type (match-string 1 sexp)))
                              (setq start (match-end 0))
                              (report (treesit-node-start node) (treesit-node-start node)
                                      (format "Missing %s" (string-trim-left type "_"))))))))))))))))))
    (funcall report-fn (nreverse diagnostics))))

(provide 'scss2-flymake)
;;; scss2-flymake.el ends here
