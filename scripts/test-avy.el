;;; test-avy.el --- Optional real Avy integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run with this checkout and the installed Avy directory on load-path.
;; Real candidates, key reading and cleanup; label drawing needs GUI checks.

(require 'ert)
(require 'cl-lib)
(require 'avy)
(require 'scss2-edit)
(load (expand-file-name "../test/scss2-test-support.el"
                        (file-name-directory load-file-name)) nil t)
(setq native-comp-enable-subr-trampolines nil)
(defvar scss2-avy-test--temporary (make-temp-file "scss2-avy-" t))
(setq scss2-grammar-cache-directory scss2-avy-test--temporary)

(defmacro scss2-avy-test--buffer (source &rest body)
  "Display SOURCE in a temporary stylesheet buffer and evaluate BODY."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (scss2-test-with-buffer 'scss2-mode ,source
       (switch-to-buffer (current-buffer))
       (delete-other-windows)
       ,@body)))

(ert-deftest scss2-avy-test-real-selection-and-cleanup ()
  (scss2-avy-test--buffer ".outside {}\n.a │{\n color: red;\n}\n.after {}"
    (let ((avy-keys '(?a ?s ?d ?f)) (avy-style 'at-full)
          (avy-all-windows t) (avy-all-windows-alt 'all-frames)
          (unread-command-events '(?d)) (kill-ring '("previous")))
      (call-interactively #'scss2-avy-word)
      (should (looking-at-p "red"))
      (should (equal kill-ring '("previous")))
      (should (eq avy-all-windows t))
      (should (eq avy-all-windows-alt 'all-frames))
      (should-not (cl-find-if (lambda (overlay) (eq (overlay-get overlay 'category) 'avy))
                             (overlays-in (point-min) (point-max)))))))

(ert-deftest scss2-avy-test-after-child-block-includes-parent-candidates ()
  (scss2-avy-test--buffer ".outer {\n .inner { x: 1; }│ .after { y: 2; }\n} .outside {}"
    (let (candidates)
      (cl-letf (((symbol-function 'avy-process)
                 (lambda (found &rest _) (setq candidates found))))
        (scss2-avy-word))
      (let ((positions (mapcar #'avy-candidate-beg candidates)))
        (goto-char (point-min)) (search-forward "outer")
        (should (memq (- (point) 5) positions))
        (search-forward "after")
        (should (memq (- (point) 5) positions))
        (search-forward "outside")
        (should-not (memq (- (point) 7) positions))))))

(ert-deftest scss2-avy-test-cancellation-cleans-up ()
  (scss2-avy-test--buffer ".a │{\n color: red;\n}"
    (let ((avy-keys '(?a ?s ?d ?f)) (avy-style 'at-full)
          (unread-command-events '(?\C-g))
          (original (buffer-string)) (position (point)))
      (condition-case nil (scss2-avy-word) (quit nil))
      (should (= (point) position))
      (should (equal (buffer-string) original))
      (should-not (cl-find-if (lambda (overlay) (eq (overlay-get overlay 'category) 'avy))
                             (overlays-in (point-min) (point-max)))))))

(ert-deftest scss2-avy-test-map-candidates-stay-inside-multiline-container ()
  (scss2-avy-test--buffer
      "$before: outside;\n$palette: (\n primary: (shade: re│d),\n secondary: blue,\n);\n$after: outside;"
    (let (candidates)
      (cl-letf (((symbol-function 'avy-process)
                 (lambda (found &rest _) (setq candidates found))))
        (scss2-avy-word))
      (let ((words (mapcar (lambda (candidate)
                            (save-excursion
                              (goto-char (avy-candidate-beg candidate))
                              (thing-at-point 'word t)))
                          candidates)))
        (dolist (word '("primary" "shade" "red" "secondary" "blue"))
          (should (member word words)))
        (dolist (word '("before" "palette" "after" "outside"))
          (should-not (member word words)))))))

(ert-deftest scss2-avy-test-full-range-ignores-viewport-and-other-buffers ()
  (dolist (setting '(nil t all-frames))
    (scss2-avy-test--buffer
        (concat ".outside {}\n@media screen {\n"
                (mapconcat (lambda (index) (format "  .item%d { color: red; }" index))
                           (number-sequence 1 80) "\n")
                "\n  │\n}\n.after {}")
      (let* ((origin (selected-window)) (other (split-window-below))
             (avy-all-windows setting) (avy-all-windows-alt 'all-frames)
             (current-prefix-arg '(4))
             (bounds (save-excursion
                       (goto-char (point-min)) (search-forward "@media")
                       (cons (- (point) 6)
                             (progn (goto-char (point-max)) (search-backward "\n.after") (point)))))
             candidates)
        (set-window-start origin (save-excursion (forward-line -5) (point)) t)
        (with-temp-buffer
          (insert ".foreign { destination: elsewhere; }")
          (set-window-buffer other (current-buffer))
          (with-selected-window origin
            ;; Avy's actual search receives the entire syntactic range.
            (cl-letf (((symbol-function 'avy-process)
                       (lambda (found &rest _) (setq candidates found))))
              (scss2-avy-word))
            (should candidates)
            (should (cl-some (lambda (candidate)
                               (< (avy-candidate-beg candidate) (window-start origin)))
                             candidates))
            (dolist (candidate candidates)
              (should (eq (avy-candidate-wnd candidate) origin))
              (should (<= (car bounds) (avy-candidate-beg candidate)))
              (should (< (avy-candidate-beg candidate) (cdr bounds))))
            (should (eq avy-all-windows setting))
            (should (eq avy-all-windows-alt 'all-frames))
            (should (equal current-prefix-arg '(4)))
            (should (eq (selected-window) origin))))))))

(unwind-protect
    (let ((result (ert-run-tests-batch "scss2-avy-test")))
      (delete-directory scss2-avy-test--temporary t)
      (kill-emacs (if (zerop (ert-stats-completed-unexpected result)) 0 1)))
  (when (file-directory-p scss2-avy-test--temporary)
    (delete-directory scss2-avy-test--temporary t)))
;;; test-avy.el ends here
