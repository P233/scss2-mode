;;; scss2-flymake-test.el --- Parse diagnostic contracts -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'scss2-mode)
(require 'css2-mode)

(defmacro scss2-flymake-test--with (dialect source &rest body)
  "Run BODY in DIALECT's SOURCE."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (insert ,source)
     (let ((scss2-fontify-colors nil))
       (funcall (if (eq ,dialect 'css) #'css2-mode #'scss2-mode))
       ,@body)))

(defun scss2-flymake-test--report ()
  "Collect exactly one synchronous report from the registered backend."
  (should (memq #'scss2-flymake flymake-diagnostic-functions))
  (let ((calls 0) diagnostics)
    (scss2-flymake (lambda (report &rest _)
                     (cl-incf calls)
                     (setq diagnostics report)))
    (should (= calls 1))
    (dolist (diagnostic diagnostics)
      (should (eq (flymake-diagnostic-buffer diagnostic) (current-buffer)))
      (should (eq (flymake-diagnostic-type diagnostic) :error)))
    diagnostics))

(defun scss2-flymake-test--expect (beg end message)
  "Expect one diagnostic over BEG to END with MESSAGE."
  (let ((diagnostics (scss2-flymake-test--report)))
    (should (= (length diagnostics) 1))
    (should (= (flymake-diagnostic-beg (car diagnostics)) beg))
    (should (= (flymake-diagnostic-end (car diagnostics)) end))
    (should (equal (flymake-diagnostic-text (car diagnostics)) message))))

(ert-deftest scss2-flymake-valid-input-skips-traversal ()
  (dolist (dialect '(scss css))
    (dolist (source '("" ".a { color: red; }" "@media (width > 1px) { .a { x: fn(1, 2); } }"))
      (scss2-flymake-test--with dialect source
        (cl-letf (((symbol-function 'treesit-node-child) (lambda (&rest _) (ert-fail "Child traversal")))
                  ((symbol-function 'treesit-node-string) (lambda (&rest _) (ert-fail "S-expression scan"))))
          (should-not (scss2-flymake-test--report))))))
  (scss2-flymake-test--with 'scss "$x: 1; @mixin paint($a) { color: $a; } .a { @include paint($x); }"
    (should-not (scss2-flymake-test--report))))

(ert-deftest scss2-flymake-errors-and-missing-tokens ()
  (dolist (dialect '(scss css))
    (dolist (case '(("}" 1 2 "Parse error")
                    (".a {" 1 5 "Parse error")
                    (".a { color: red\nwidth: 1px; }" 6 16 "Parse error")
                    ("@keyframes;" 1 11 "Parse error")
                    (".a { x: fn(, }" 13 14 "Missing )")
                    ("@keyframes {}" 11 12 "Missing identifier")))
      (scss2-flymake-test--with dialect (car case)
        (apply #'scss2-flymake-test--expect (cdr case))))))

(ert-deftest scss2-flymake-nested-errors-report-outermost ()
  (dolist (dialect '(scss css))
    (scss2-flymake-test--with dialect "@mixin foo($a { ) ] ; }"
      (scss2-flymake-test--expect 1 (point-max) "Parse error"))))

(ert-deftest scss2-flymake-cap-stops-and-marks-last-diagnostic ()
  (dolist (dialect '(scss css))
    (scss2-flymake-test--with dialect (apply #'concat (make-list 205 ".a { x: fn(, }\n"))
      (let ((diagnostics (scss2-flymake-test--report)))
        (should (= (length diagnostics) 200))
        (should (equal (flymake-diagnostic-text (car diagnostics)) "Missing )"))
        (should (= (flymake-diagnostic-beg (car (last diagnostics))) (+ (* 199 15) 13)))
        (should (equal (flymake-diagnostic-text (car (last diagnostics)))
                       "Missing ) (Diagnostic limit of 200 reached; further errors may be omitted)"))))))

(ert-deftest scss2-flymake-registration-is-local-and-opt-in ()
  (let ((global (default-value 'flymake-diagnostic-functions)))
    (dolist (dialect '(scss css))
      (scss2-flymake-test--with dialect ".a {}"
        (should (local-variable-p 'flymake-diagnostic-functions))
        (should (memq #'scss2-flymake flymake-diagnostic-functions))
        (should-not (bound-and-true-p flymake-mode))))
    (should (equal global (default-value 'flymake-diagnostic-functions)))))

(ert-deftest scss2-flymake-user-hook-enables-real-flymake ()
  (let ((scss2-mode-hook '(flymake-mode))
        (css2-mode-hook '(flymake-mode))
        (flymake-diagnostic-functions nil))
    (dolist (dialect '(scss css))
      (dolist (source '("}" ".a { x: fn(, }" "@keyframes {}"))
        (scss2-flymake-test--with dialect source
          (should flymake-mode)
          (flymake-start)
          (should (= (length (flymake-diagnostics)) 1))
          (erase-buffer)
          (insert ".a {}")
          (flymake-start)
          (should-not (flymake-diagnostics)))))))

(ert-deftest scss2-flymake-indirect-clone-keeps-the-backend ()
  (let ((scss2-mode-hook '(flymake-mode))
        (css2-mode-hook '(flymake-mode))
        (flymake-diagnostic-functions nil))
    (dolist (dialect '(scss css))
      (scss2-flymake-test--with dialect "}\n.a {}\n"
        (flymake-start)
        (should (= (length (flymake-diagnostics)) 1))
        (let ((clone (clone-indirect-buffer " *scss2 flymake clone*" nil)))
          (unwind-protect
              (with-current-buffer clone
                (should-not (treesit-parser-list))
                (should-not (scss2-flymake-test--report))
                (flymake-start)
                (should-not (flymake-disabled-backends)))
            (kill-buffer clone)))
        (should-not (flymake-disabled-backends))
        (flymake-start)
        (should (= (length (flymake-diagnostics)) 1))))))

(ert-deftest scss2-flymake-narrowing-reads-font-lock-view ()
  (dolist (dialect '(scss css))
    (scss2-flymake-test--with dialect "}\n.a {}\n@keyframes {}"
      (let ((whole (mapcar (lambda (diagnostic)
                             (list (flymake-diagnostic-beg diagnostic)
                                   (flymake-diagnostic-end diagnostic)
                                   (flymake-diagnostic-text diagnostic)))
                           (scss2-flymake-test--report))))
        (should (= (length whole) 2))
        (narrow-to-region 3 8)
        (goto-char 5)
        (should (equal whole
                       (mapcar (lambda (diagnostic)
                                 (list (flymake-diagnostic-beg diagnostic)
                                       (flymake-diagnostic-end diagnostic)
                                       (flymake-diagnostic-text diagnostic)))
                               (scss2-flymake-test--report))))
        (should (= (point-min) 3))
        (should (= (point-max) 8))
        (should (= (point) 5))
        (let ((font-lock-dont-widen t))
          (should-not (scss2-flymake-test--report)))
        (let ((flymake-diagnostic-functions '(scss2-flymake)))
          (flymake-mode 1)
          (flymake-start)
          (should (= (save-restriction (widen) (length (flymake-diagnostics))) 2)))
        (should (= (point-min) 3))
        (should (= (point-max) 8))
        (should (= (point) 5))))))

(ert-deftest scss2-flymake-reports-known-parser-limits ()
  (dolist (dialect '(scss css))
    (dolist (source '(".a { x: attr(data-width type(<length> | <percentage>), 10px); }"
                      ".a { x: url(/* note */ \"a.png\"); }"))
      (scss2-flymake-test--with dialect source
        (should (scss2-flymake-test--report))))))

(provide 'scss2-flymake-test)
;;; scss2-flymake-test.el ends here
