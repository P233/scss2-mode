;;; benchmark-emacs.el --- Measure parser and font-lock phases -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Run: emacs -Q --batch -L /path/to/emmet2-mode -l scripts/benchmark-emacs.el
;; Optional environment variables:
;; SCSS2_BENCH_ROOT: checkout containing the Lisp and highlight query.
;; SCSS2_BENCH_FIXTURES: checkout containing the fixed input samples.
;; SCSS2_BENCH_RUNS: measured repetitions (default 7, after 2 warmups).
;; SCSS2_BENCH_PROFILE: also report one separately instrumented run.
;;
;; Compare separate Emacs processes using the same fixture root and compiler.
;; Each workload runs with scss2-fontify-details both nil and t.  JSON Lines
;; record that option, all samples, medians, and a hash of every final face span.
;; Medians follow warmups and do not establish cold query-compilation cost.
;; Mode setup includes reading/compiling queries and syntax initialization.
;; Parsing is forced before full fontification.  Incremental measurements edit
;; one number and one plain map key, then parse and fontify the edited line via
;; real JIT hooks.  Text insertion and GC are outside timed phases.
;; Incremental update timings include pre-redisplay changed-region invalidation.
;; CSS color previews are disabled; this does not measure redisplay or GUI latency.

(require 'treesit)
(require 'json)
(require 'cl-lib)
(require 'elp)

(defvar scss2-benchmark--root
  (or (getenv "SCSS2_BENCH_ROOT")
      (file-name-directory
       (directory-file-name (file-name-directory load-file-name)))))
(defvar scss2-benchmark--fixtures
  (or (getenv "SCSS2_BENCH_FIXTURES")
      (expand-file-name "vendor/tree-sitter-scss" scss2-benchmark--root)))
(defvar scss2-benchmark--runs
  (string-to-number (or (getenv "SCSS2_BENCH_RUNS") "7")))
(defvar scss2-benchmark--warmups 2)
(setq native-comp-enable-subr-trampolines nil)
(add-to-list 'load-path scss2-benchmark--root)
(require 'scss2-mode)
;; Created after loading, so a failed load leaves no directory behind.
(defvar scss2-benchmark--temporary (make-temp-file "scss2-benchmark-" t))
(setq scss2-grammar-cache-directory scss2-benchmark--temporary)

(defun scss2-benchmark--median (values)
  (let* ((ordered (sort (copy-sequence values) #'<)) (n (length ordered)))
    (if (cl-oddp n) (nth (/ n 2) ordered)
      (/ (+ (nth (/ n 2) ordered) (nth (1- (/ n 2)) ordered)) 2.0))))

(defun scss2-benchmark--ms (function)
  (let ((start (current-time)))
    (funcall function)
    (* 1000.0 (float-time (time-subtract (current-time) start)))))

(defun scss2-benchmark--faces ()
  (let ((position (point-min)) result)
    (while (< position (point-max))
      (let ((next (next-single-property-change position 'face nil (point-max))))
        (push (list position next (get-text-property position 'face)) result)
        (setq position next)))
    (secure-hash 'sha256 (prin1-to-string (nreverse result)))))

(defun scss2-benchmark--edit (position replacement)
  (goto-char position)
  (delete-char 1)
  (insert replacement)
  (let ((update (scss2-benchmark--ms
                 (lambda ()
                   (scss2--root-node)
                   (run-hook-with-args 'pre-redisplay-functions nil))))
        (fontify (scss2-benchmark--ms
                  (lambda ()
                    (font-lock-ensure (line-beginning-position)
                                      (line-end-position))))))
    (list update fontify)))

(defun scss2-benchmark--run (name source details)
  (let ((scss2-fontify-details details)
        parse setup full incremental-update incremental-fontify
        key-update key-fontify digest stats)
    (dotimes (run (+ scss2-benchmark--warmups scss2-benchmark--runs))
      (garbage-collect)
      (let ((gc-cons-threshold most-positive-fixnum)
            (gc-cons-percentage 1.0)
            (scss2-fontify-colors nil)
            (buffer (generate-new-buffer "scss2-benchmark")))
        (unwind-protect
            (with-current-buffer buffer
              (insert source)
              (let* ((parser (treesit-parser-create (scss2-grammar-language 'scss)))
                     (elapsed (scss2-benchmark--ms
                               (lambda () (treesit-parser-root-node parser)))))
                (when (>= run scss2-benchmark--warmups) (push elapsed parse))
                (treesit-parser-delete parser))
              (let ((elapsed (scss2-benchmark--ms #'scss2-mode)))
                (when (>= run scss2-benchmark--warmups) (push elapsed setup)))
              (when (treesit-node-check (scss2--root-node) 'has-error)
                (error "Invalid benchmark input: %s" name))
              (let ((noninteractive nil)) (font-lock-mode 1))
              (unless (and font-lock-mode
                           (eq font-lock-ensure-function #'jit-lock-fontify-now))
                (error "JIT font-lock did not activate"))
              (let ((elapsed (scss2-benchmark--ms #'font-lock-ensure)))
                (when (>= run scss2-benchmark--warmups) (push elapsed full)))
              (setq digest (scss2-benchmark--faces))
              (let* ((numbers (treesit-query-capture
                               (scss2--root-node) '((number) @number) nil nil t))
                     (target (nth (/ (length numbers) 2) numbers))
                     (position (treesit-node-start target)))
                (goto-char position)
                (skip-chars-forward "+-")
                (setq position (point))
                (unless (looking-at "[0-9]") (error "No numeric edit position"))
                (let ((elapsed (scss2-benchmark--edit
                                position (if (eq (char-after) ?1) "2" "1"))))
                  (when (>= run scss2-benchmark--warmups)
                    (push (car elapsed) incremental-update)
                    (push (cadr elapsed) incremental-fontify)))
                (let ((expected (and details 'font-lock-number-face)))
                  (unless (eq (get-text-property position 'face) expected)
                    (error "Edited number face: expected %S, got %S"
                           expected (get-text-property position 'face)))))
              (when-let* ((keys (treesit-query-capture
                                 (scss2--root-node)
                                 '((map_entry key: (plain_value) @key)) nil nil t))
                          (key (cl-find-if (lambda (node)
                                             (zerop (treesit-node-child-count node)))
                                           keys)))
                (let* ((position (treesit-node-start key))
                       (replacement (if (eq (char-after position) ?a) "b" "a"))
                       (elapsed (scss2-benchmark--edit position replacement)))
                  (when (>= run scss2-benchmark--warmups)
                    (push (car elapsed) key-update)
                    (push (cadr elapsed) key-fontify))
                  (unless (eq (get-text-property position 'face) 'scss2-property)
                    (error "Edited map key lost its face"))))
              (unless (equal digest (scss2-benchmark--faces))
                (error "Incremental edits changed face spans: %s" name)))
          (kill-buffer buffer))))
    (when (getenv "SCSS2_BENCH_PROFILE")
      (let ((buffer (generate-new-buffer "scss2-profile"))
            (scss2-fontify-colors nil)
            (gc-cons-threshold most-positive-fixnum)
            (functions '(scss2--fontify-context
                         treesit-query-capture
                         treesit-fontify-with-override
                         scss2--syntax-propertize)))
        (unwind-protect
            (with-current-buffer buffer
              (insert source) (scss2-mode) (scss2--root-node)
              (let ((noninteractive nil)) (font-lock-mode 1))
              (elp-instrument-list functions)
              (font-lock-ensure)
              (dolist (symbol functions)
                (let ((info (get symbol 'elp-info)))
                  (push (list :function (symbol-name symbol) :calls (aref info 0)
                              :total_ms (* 1000 (aref info 1))) stats))))
          (elp-restore-all) (kill-buffer buffer))))
    (princ (json-encode
            (list :sample name :bytes (string-bytes source)
                  :fontify_details (if details t :json-false)
                  :input_sha256 (secure-hash 'sha256 source) :face_sha256 digest
                  :parse_ms (scss2-benchmark--median parse)
                  :mode_setup_ms (scss2-benchmark--median setup)
                  :full_fontify_ms (scss2-benchmark--median full)
                  :incremental_update_ms (scss2-benchmark--median incremental-update)
                  :incremental_fontify_ms (scss2-benchmark--median incremental-fontify)
                  :key_update_ms (and key-update (scss2-benchmark--median key-update))
                  :key_fontify_ms (and key-fontify (scss2-benchmark--median key-fontify))
                  :raw (list :parse parse :setup setup :full full
                             :incremental_update incremental-update
                             :incremental_fontify incremental-fontify
                             :key_update key-update :key_fontify key-fontify)
                  :profile (vconcat stats))))
    (terpri)))

(defun scss2-benchmark--sample (name source)
  "Measure NAME's SOURCE in both compact and detailed highlighting modes."
  (dolist (details '(nil t))
    (scss2-benchmark--run name source details)))

(unwind-protect
    (progn
      (unless (> scss2-benchmark--runs 0)
        (error "SCSS2_BENCH_RUNS must be positive"))
      (scss2-grammar-ensure 'scss)
      (princ (json-encode
              (list :emacs emacs-version
                    :grammar scss2-grammar-directory
                    :source scss2-benchmark--root
                    :fixture_root scss2-benchmark--fixtures
                    :compiler (or (getenv "CC") "cc")
                    :runs scss2-benchmark--runs
                    :warmups scss2-benchmark--warmups
                    :gc "before each run, disabled during phases"
                    :native_trampolines :json-false :css_color_previews :json-false
                    :fontify_details [:json-false t]
                    :scss2_compilation
                    (if (byte-code-function-p (symbol-function 'scss2--root-node))
                        "bytecode" "source"))))
      (terpri)
      (dolist (sample '(("stress" "examples/highlight-stress.scss" 1)
                        ("large" "examples/highlight-stress.scss" 10)))
        (let ((source (with-temp-buffer
                        (insert-file-contents
                         (expand-file-name (cadr sample) scss2-benchmark--fixtures))
                        (buffer-string))))
          (scss2-benchmark--sample
           (car sample) (mapconcat #'identity (make-list (nth 2 sample) source) "\n"))))
      (scss2-benchmark--sample
       "deep-query"
       (concat "@media " (make-string 512 ?\() "width > 1px"
               (make-string 512 ?\)) " { .a { color: red; } }\n"))
      (scss2-benchmark--sample
       "wide-query"
       (concat "@media (width " (apply #'concat (make-list 4096 "/**/ "))
               "> 1px) { .a { color: red; } }\n"))
      (scss2-benchmark--sample
       "numbers-heavy"
       (concat
        (mapconcat
         #'identity
         (make-list 1000
                    ".n { z-index: 1; width: 10px; opacity: .5; margin: -2.5em 0 20% 1e2vw; animation-duration: .2s; padding: +3rem; column-count: 2; }")
         "\n")
        "\n.math { width: calc(100% - #{math.max(2px, 1px)}); height: min(20px, calc(2 * 3px)); }\n")))
  (delete-directory scss2-benchmark--temporary t))

;;; benchmark-emacs.el ends here
