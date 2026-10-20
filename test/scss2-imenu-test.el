;;; scss2-imenu-test.el --- On-demand navigation categories -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'imenu)
(require 'outline)
(require 'scss2-mode)

(defun scss2-imenu-test--index ()
  "Return a fresh Imenu index with marker positions as integers."
  (let ((imenu-auto-rescan t)
        (imenu--index-alist nil))
    (mapcar (lambda (category)
              (cons (car category)
                    (mapcar (lambda (entry)
                              (cons (car entry) (marker-position (cdr entry))))
                            (cdr category))))
            (imenu--make-index-alist t))))

(ert-deftest scss2-imenu-variables-are-module-declarations ()
  (with-temp-buffer
    (insert "@use \"theme\" with ($configured: red);\n"
            "$plain: 1;\n$default: 2 !default;\nmodule.$assigned: 3;\n"
            ".rule { $rule: 4; }\n"
            "@mixin mix($parameter: 5) { $mixin: 6; }\n"
            "@function fn($argument: 7) { $function: 8; @return $function; }\n"
            "@if true { $conditional: 9; }\n"
            "@for $i from 1 through 2 { $loop: 10; }\n"
            "@each $item in a, b { $each: 11; }\n"
            "@while false { $while: 12; }\n"
            "@media screen { $media: 13; }\n")
    (scss2-mode)
    (let ((index (scss2-imenu-test--index)))
      (should (equal (mapcar #'car (cdr (assoc "Variables" index)))
                     '("$plain" "$default")))
      (dolist (entry (cdr (assoc "Variables" index)))
        (goto-char (cdr entry))
        (should (looking-at-p (regexp-quote (concat (car entry) ":")))))
      (should (equal (mapcar #'car (cdr (assoc "Mixins" index))) '("mix")))
      (should (equal (mapcar #'car (cdr (assoc "Functions" index))) '("fn"))))))

(ert-deftest scss2-imenu-placeholders-use-the-whole-selector ()
  (with-temp-buffer
    (insert "%base { color: red; }\n%other { color: blue; }\n"
            "%commented /* note */ { color: red; }\n"
            "%compound.active { color: red; }\n"
            "%complex .child { color: red; }\n"
            ".parent > %descendant { color: red; }\n"
            "%one, %two { color: red; }\n"
            "@media screen { %nested { color: red; } }\n")
    (scss2-mode)
    (let ((index (scss2-imenu-test--index)))
      (should (equal (mapcar #'car (cdr (assoc "Placeholders" index)))
                     '("%base" "%other" "%commented" "%nested")))
      (dolist (entry (cdr (assoc "Placeholders" index)))
        (goto-char (cdr entry))
        (should (looking-at-p (regexp-quote (car entry)))))
      (should (member "%compound.active" (mapcar #'car (cdr (assoc "Rules" index)))))
      (should (member "%complex .child" (mapcar #'car (cdr (assoc "Rules" index))))))))

(ert-deftest scss2-imenu-keyframes-in-both-dialects ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (insert "@keyframes fade { from { opacity: 0; } to { opacity: 1; } }\n"
              "@keyframes slide { to { left: 0; } }\n")
      (funcall mode)
      (let ((entries (cdr (assoc "Keyframes" (scss2-imenu-test--index)))))
        (should (equal (mapcar #'car entries) '("fade" "slide")))
        (dolist (entry entries)
          (goto-char (cdr entry))
          (should (looking-at-p (regexp-quote (concat "@keyframes " (car entry))))))))))

(ert-deftest scss2-imenu-plain-css-has-no-empty-categories ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (insert ".card { color: red; }\n")
      (funcall mode)
      (should (equal (scss2-imenu-test--index) '(("Rules" (".card" . 1))))))))

(ert-deftest scss2-imenu-keyframes-ignore-header-comments ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (insert "@keyframes /* note */ fade { to { opacity: 1; } }\n")
      (funcall mode)
      (should (equal (assoc "Keyframes" (scss2-imenu-test--index))
                     '("Keyframes" ("fade" . 1)))))))

(ert-deftest scss2-imenu-shares-settings-between-dialects ()
  (let (settings)
    (dolist (mode '(scss2-mode css2-mode))
      (with-temp-buffer
        (insert ".card {}")
        (funcall mode)
        (push treesit-simple-imenu-settings settings)))
    (should (equal (car settings) (cadr settings)))))

(ert-deftest scss2-imenu-preserves-index-under-narrowing ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (when (eq mode 'scss2-mode)
        (insert "$top: 1 !default;\n%base { color: red; }\n"))
      (insert "@keyframes fade { to { opacity: 1; } }\n"
              ".card {\n  color: red;\n}\n"
              "@keyframes slide { to { left: 0; } }\n")
      (funcall mode)
      (let ((full-index (scss2-imenu-test--index)))
        (goto-char (point-min)) (search-forward "  color: red;")
        (narrow-to-region (line-beginning-position) (line-end-position))
        (let ((minimum (point-min)) (maximum (point-max)) (origin (point)))
          (should (equal (scss2-imenu-test--index) full-index))
          (should (= (point-min) minimum))
          (should (= (point-max) maximum))
          (should (= (point) origin)))))))

(ert-deftest scss2-imenu-damaged-buffers-keep-complete-definitions ()
  (dolist (mode '(scss2-mode css2-mode))
    (with-temp-buffer
      (when (eq mode 'scss2-mode)
        (insert "$before: 1;\n%base { color: red; }\n"))
      (insert "}\n@keyframes fade { to { opacity: 1; } }\n"
              ".broken { color: ; }\n"
              "@keyframes slide { to { left: 0; } }\n")
      (funcall mode)
      (let ((index (scss2-imenu-test--index)))
        (should (equal (mapcar #'car (cdr (assoc "Keyframes" index))) '("fade" "slide")))
        (when (eq mode 'scss2-mode)
          (should (equal (mapcar #'car (cdr (assoc "Variables" index))) '("$before")))
          (should (equal (mapcar #'car (cdr (assoc "Placeholders" index))) '("%base"))))))))

(ert-deftest scss2-imenu-builds-only-when-requested ()
  (dolist (mode '(scss2-mode css2-mode))
    (let ((create-index (symbol-function 'treesit-simple-imenu)) (calls 0))
      (cl-letf (((symbol-function 'treesit-simple-imenu)
                 (lambda () (cl-incf calls) (funcall create-index))))
        (with-temp-buffer
          (insert ".card { color: red; }\n")
          (funcall mode)
          (goto-char (point-max))
          (insert "@keyframes fade { to { opacity: 1; } }\n")
          (run-hooks 'post-command-hook)
          (run-hook-with-args 'pre-redisplay-functions nil)
          (font-lock-ensure)
          (should (= calls 0))
          (should-not imenu--index-alist)
          (should (assoc "Keyframes" (scss2-imenu-test--index)))
          (should (= calls 1)))))))

(ert-deftest scss2-imenu-categories-leave-outline-headings-on-definitions ()
  (with-temp-buffer
    (insert "$color: red;\n@mixin mix() { a: b; }\n"
            "@keyframes fade {\n  from { opacity: 0; }\n}\n"
            ".rule { color: $color; }\n")
    (scss2-mode)
    (outline-minor-mode 1)
    (let (headings)
      (goto-char (point-min))
      (while (not (eobp))
        (when (outline-on-heading-p t)
          (push (buffer-substring-no-properties (point) (line-end-position)) headings))
        (forward-line 1))
      (should (equal (nreverse headings)
                     '("@mixin mix() { a: b; }" "  from { opacity: 0; }"
                       ".rule { color: $color; }"))))))

(provide 'scss2-imenu-test)
;;; scss2-imenu-test.el ends here
