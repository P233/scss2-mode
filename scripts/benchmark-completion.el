;;; benchmark-completion.el --- Completion input traces -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load both checkouts through -L. For comparable results, compile both to
;; bytecode in disposable copies first. SCSS2_BENCH_RUNS defaults to 100.
;; Reports edit + CAPF + matching + three display batches, with GC enabled.
;; This measures the frontend protocol, not popup drawing or input dispatch.

(require 'cl-lib)
(require 'json)
(require 'scss2-mode)
(require 'emmet2-capf)
(setq native-comp-enable-subr-trampolines nil
      gc-cons-threshold 800000 gc-cons-percentage 0.1)
(when-let* ((cache (getenv "SCSS2_BENCH_GRAMMAR")))
  (setq scss2-grammar-cache-directory cache))
(scss2-grammar-ensure 'scss)

(defvar scss2-bench--runs (string-to-number (or (getenv "SCSS2_BENCH_RUNS") "100")))

(defun scss2-bench--report (value)
  (princ (json-encode value)) (terpri))

(defun scss2-bench--request ()
  "Run the real completion table and repeated display callbacks."
  (when-let* ((data (scss2-completion-at-point)))
    (let* ((input (buffer-substring-no-properties (car data) (point)))
           (candidates (let ((all (completion-all-completions
                                   input (nth 2 data) nil (length input))))
                         (when (consp all) (setcdr (last all) nil))
                         all))
           (props (nthcdr 3 data))
           (affix (plist-get props :affixation-function))
           (annotation (plist-get props :annotation-function)))
      (dotimes (_ 3)
        (if affix (funcall affix candidates)
          (when annotation (mapc annotation candidates))))
      (length candidates))))

(defun scss2-bench--trace (name function)
  "Report comparable warmed traces of FUNCTION under NAME."
  (dotimes (_ 10) (funcall function))
  (garbage-collect)
  (let (samples count)
    (dotimes (_ scss2-bench--runs)
      (let ((start (current-time)) (gcs gcs-done) (gc-time gc-elapsed))
        (setq count (funcall function))
        (push (list (* 1000.0 (float-time (time-subtract (current-time) start)))
                    (- gcs-done gcs) (* 1000.0 (- gc-elapsed gc-time))) samples)))
    (let ((sorted (sort (mapcar #'car samples) #'<)) (creates 0)
          (create (symbol-function 'treesit-parser-create)))
      (cl-letf (((symbol-function 'treesit-parser-create)
                 (lambda (&rest args)
                   (let* ((before (treesit-parser-list)) (parser (apply create args)))
                     (unless (memq parser before) (cl-incf creates))
                     parser))))
        (funcall function))
      (scss2-bench--report
       (list :case name :runs scss2-bench--runs :candidates count :new_parsers creates
             :p50_ms (nth (/ scss2-bench--runs 2) sorted)
             :p95_ms (nth (1- (ceiling (* 0.95 scss2-bench--runs))) sorted)
             :samples (vconcat (nreverse samples)))))))

(scss2-bench--report
 (list :emacs emacs-version :gc_threshold gc-cons-threshold :gc_percentage gc-cons-percentage
       :host (locate-library "scss2-completion") :emmet (locate-library "emmet2-capf")
       :bytecode (and (byte-code-function-p (symbol-function 'scss2-completion-at-point))
                      (byte-code-function-p (symbol-function 'emmet2-capf)))))

(dolist (size '(0 1000))
  (dolist (input '("dis" "m10" "display: fl" "color: $to" "@me"))
    (with-temp-buffer
      (dotimes (i size) (insert (format "$token%d: red; .rule%d { color: red; }\n" i i)))
      (insert ".a { " input " }") (backward-char 2)
      (let ((position (point)) (css-fontify-colors nil)) (scss2-mode) (goto-char position))
      (scss2--root-node)
      (scss2-bench--trace
       (format "input-%d:%s" size input)
       (lambda ()
         ;; Retype the last character to include incremental parse invalidation.
         (let ((character (char-before))) (delete-char -1) (insert character))
         (scss2-bench--request))))))

(dolist (size '(100 1000 5000))
  (let* ((directory (make-temp-file "scss2-module-bench-" t))
         (path (expand-file-name "_tokens.scss" directory))
         (module (generate-new-buffer " *scss2 module benchmark*")))
    (unwind-protect
        (progn
          (with-temp-file path (insert "$saved: red;"))
          (with-current-buffer module
            (setq buffer-file-name path)
            (dotimes (i size) (insert (format "$token%d: red;\n" i)))
            (let ((css-fontify-colors nil)) (scss2-mode))
            (scss2--root-node))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "main.scss" directory))
            (insert "@use 'tokens'; .a { color: tokens.$to }") (backward-char 2)
            (let ((position (point)) (css-fontify-colors nil)) (scss2-mode) (goto-char position))
            (scss2-bench--trace
             (format "open-module-%d" size)
             (lambda () (delete-char -1) (insert "o") (scss2-bench--request)))))
      (kill-buffer module) (delete-directory directory t))))

;;; benchmark-completion.el ends here
