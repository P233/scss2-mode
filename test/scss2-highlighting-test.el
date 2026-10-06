;;; scss2-highlighting-test.el --- Selector and numeric highlighting -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'scss2-mode)

(defmacro scss2-highlighting-test--with-buffer (mode text &rest body)
  "Run BODY with MODE and real JIT fontification of TEXT."
  (declare (indent 2))
  `(with-temp-buffer
     (rename-buffer "scss2-highlighting-test" t)
     (insert ,text)
     (let ((scss2-fontify-colors nil))
       (funcall ,mode)
       (let ((noninteractive nil)) (font-lock-mode 1))
       (font-lock-ensure)
       ,@body)))

(defun scss2-highlighting-test--face (text face &optional offset)
  "Assert that TEXT, or its character at OFFSET, has FACE."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (let* ((start (+ (match-beginning 0) (or offset 0)))
           (end (if offset (1+ start) (match-end 0))))
      (cl-loop for position from start below end
               do (ert-info ((format "%S at %d" text position))
                    (should (eq (get-text-property position 'face) face)))))))

(defun scss2-highlighting-test--faces ()
  "Return every accessible character's face."
  (cl-loop for position from (point-min) below (point-max)
           collect (get-text-property position 'face)))

(ert-deftest scss2-highlighting-selector-prefixes-share-the-name-face ()
  (dolist (mode '(scss2-mode css2-mode))
    (scss2-highlighting-test--with-buffer mode
        ".class#id::before, a:hover, :not(.muted):is(#x), [data-x=\"word\"] { color: red; }"
      (dolist (text '(".class#id::before" "a:hover" ":not" ".muted" ":is" "#x" "data-x"))
        (scss2-highlighting-test--face text 'scss2-selector))
      (scss2-highlighting-test--face "\"word\"" 'font-lock-string-face)
      (scss2-highlighting-test--face "[" nil)
      (scss2-highlighting-test--face "=" 'font-lock-operator-face))))

(ert-deftest scss2-highlighting-selector-interpolation-keeps-its-faces ()
  (scss2-highlighting-test--with-buffer 'scss2-mode
      "%base, .card-#{$size}::before, #main-#{$name}, :nth-child(2n + 1 of .active) { color: red; }"
    (dolist (text '("%base" ".card-" "::before" "#main-" ":nth-child" ".active"))
      (scss2-highlighting-test--face text 'scss2-selector))
    (scss2-highlighting-test--face "#{" 'font-lock-escape-face)
    (scss2-highlighting-test--face "$size" 'font-lock-variable-name-face)
    (scss2-highlighting-test--face "$name" 'font-lock-variable-name-face)
    (scss2-highlighting-test--face "2n + 1" 'font-lock-number-face)))

(ert-deftest scss2-highlighting-numbers-and-units-keep-distinct-faces ()
  (dolist (mode '(scss2-mode css2-mode))
    (scss2-highlighting-test--with-buffer mode
        ".a { x: 0; margin: 12px 1rem 50%; width: calc(100% - 2px); x: -1.5e2s 3deg; }"
      (dolist (entry '(("0" . 1) ("12px" . 2) ("1rem" . 1) ("50%" . 2)
                       ("100%" . 3) ("2px" . 1) ("-1.5e2s" . 6) ("3deg" . 1)))
        (cl-loop for offset from 0 below (length (car entry))
                 do (scss2-highlighting-test--face
                     (car entry)
                     (if (< offset (cdr entry)) 'font-lock-number-face
                       'font-lock-type-face)
                     offset)))
      (scss2-highlighting-test--face " - " 'font-lock-constant-face 1)
      (scss2-highlighting-test--face "calc" 'font-lock-function-name-face)
      (scss2-highlighting-test--face ":" nil))))

(ert-deftest scss2-highlighting-numbers-preserve-other-semantic-roles ()
  (dolist (mode '(scss2-mode css2-mode))
    (scss2-highlighting-test--with-buffer mode
        "@media (width >= 800px) { .col-12 { opacity: .5; color: #123abc; unicode-range: U+00A0-00FF; content: \"123\"; /* 456 */ } } @keyframes fade { 50% { opacity: 0; } }"
      (dolist (text '("800" ".5" "50"))
        (scss2-highlighting-test--face text 'font-lock-number-face))
      (scss2-highlighting-test--face "px" 'font-lock-type-face)
      (scss2-highlighting-test--face "%" 'font-lock-type-face)
      (scss2-highlighting-test--face ">=" 'font-lock-operator-face)
      (scss2-highlighting-test--face ".col-12" 'scss2-selector)
      (scss2-highlighting-test--face "#123abc" 'font-lock-constant-face)
      (scss2-highlighting-test--face "U+00A0-00FF" 'font-lock-constant-face)
      (scss2-highlighting-test--face "\"123\"" 'font-lock-string-face)
      (scss2-highlighting-test--face "/* 456 */" 'font-lock-comment-face))))

(ert-deftest scss2-highlighting-expression-operators-keep-nested-roles ()
  (scss2-highlighting-test--with-buffer 'scss2-mode
      "$x: 1px; .a { width: calc(100% - $x); x: 1+2; y: 1 + 2 * 3 / 4 % 5 == 0; color: red !important; content: \"12px + 3\"; /* 12px - 3 */ }"
    (dolist (text '("+" "* 3" "/ 4" "% 5" "=="))
      (scss2-highlighting-test--face text 'font-lock-constant-face 0))
    (scss2-highlighting-test--face "$x" 'font-lock-variable-name-face)
    (scss2-highlighting-test--face "1+2" 'font-lock-number-face 0)
    (scss2-highlighting-test--face "1+2" 'font-lock-constant-face 1)
    (scss2-highlighting-test--face "1+2" 'font-lock-number-face 2)
    (scss2-highlighting-test--face "red" 'font-lock-constant-face)
    (scss2-highlighting-test--face "!important" 'font-lock-keyword-face)
    (scss2-highlighting-test--face "\"12px + 3\"" 'font-lock-string-face)
    (scss2-highlighting-test--face "/* 12px - 3 */" 'font-lock-comment-face)))

(ert-deftest scss2-highlighting-structural-operators-and-dots-keep-their-faces ()
  (dolist (mode '(scss2-mode css2-mode))
    (scss2-highlighting-test--with-buffer mode
        "@media not screen and (width > 10px) { .a > .b + #c { width: 1px; } } @function --f(--n <length>+) returns <length> { result: 2px; }"
      (dolist (text '("not" "and"))
        (scss2-highlighting-test--face text 'font-lock-operator-face))
      (scss2-highlighting-test--face "width >" 'font-lock-operator-face 6)
      (scss2-highlighting-test--face ".a >" 'font-lock-operator-face 3)
      (scss2-highlighting-test--face ".b +" 'font-lock-operator-face 3)
      (scss2-highlighting-test--face "length>+" 'font-lock-operator-face 7)
      (scss2-highlighting-test--face "length" 'font-lock-type-face)))
  (scss2-highlighting-test--with-buffer 'scss2-mode
      "theme.$gap: 1px; .a:lang(en.*) { @include theme.card; width: theme.$gap; height: math.max(1px, 2px); x: foo.bar; }"
    (dolist (entry '(("theme.$gap" . 5) ("en.*" . 2) ("theme.card" . 5)
                     ("math.max" . 4) ("foo.bar" . 3)))
      (scss2-highlighting-test--face (car entry) 'font-lock-delimiter-face (cdr entry)))))

(ert-deftest scss2-highlighting-typing-through-incomplete-syntax-equals-fresh ()
  (dolist (mode '(scss2-mode css2-mode))
    (dolist (entry '(("" " { color: red; }\n.tail { margin: 1px; }" ".card#main::before")
                     (".a { width: " "; }\n.tail { margin: 1px; }" "calc(100% - 2rem)")))
      (scss2-highlighting-test--with-buffer mode (concat (nth 0 entry) (nth 1 entry))
        (goto-char (1+ (length (nth 0 entry))))
        (dolist (event (append (string-to-list (nth 2 entry))
                               (make-list (length (nth 2 entry)) 'delete)))
          (if (eq event 'delete) (delete-char -1) (insert-char event))
          (run-hook-with-args 'pre-redisplay-functions nil)
          (font-lock-ensure (line-beginning-position) (line-end-position))
          (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                 (incremental (scss2-highlighting-test--faces))
                 (fresh (scss2-highlighting-test--with-buffer mode text
                          (scss2-highlighting-test--faces))))
            (ert-info ((format "%s %S" mode text))
              (should (equal incremental fresh)))))))))

(defvar scss2-highlighting-test--parses 0
  "Number of reparses since the counter was last reset.")

(defun scss2-highlighting-test--count (&rest _)
  "Count one reparse."
  (setq scss2-highlighting-test--parses (1+ scss2-highlighting-test--parses)))

(ert-deftest scss2-highlighting-early-tree-reads-keep-other-lines-current ()
  ;; Emacs 31 hands a reparse's changed ranges only to the reader that caused it.
  (dolist (entry '((".x { color: red; }\n@mixin m($a) {\n  width: $" "width: $" "a")
                   ("/* open\n.a { color: red; }\nend *\n.c { color: blue; }\n" "end *" "/")))
    (scss2-highlighting-test--with-buffer 'scss2-mode (car entry)
      (let ((scss2-highlighting-test--parses 0))
        (treesit-parser-add-notifier (car (treesit-parser-list))
                                     #'scss2-highlighting-test--count)
        (goto-char (point-min)) (search-forward (nth 1 entry))
        (insert (nth 2 entry))
        (treesit-node-at (point))
        (run-hook-with-args 'pre-redisplay-functions nil)
        (jit-lock-fontify-now)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (ert-info ((format "%S" text))
            (should (= scss2-highlighting-test--parses 1))
            (should (equal (scss2-highlighting-test--faces)
                           (scss2-highlighting-test--with-buffer 'scss2-mode text
                             (scss2-highlighting-test--faces))))))))))

(ert-deftest scss2-highlighting-early-tree-reads-extend-syntax-propertization ()
  (scss2-highlighting-test--with-buffer 'scss2-mode ".x { color: red; }\n@mixin m($a) {\n  width: $"
    (syntax-ppss (point-max))
    (let ((propertize syntax-propertize-function) starts)
      (setq-local syntax-propertize-function
                  (lambda (start end) (push start starts) (funcall propertize start end)))
      (goto-char (point-max)) (insert "a")
      (treesit-node-at (point))
      (syntax-ppss (point-max))
      ;; The reparse changed the mixin's header, before the edited line.
      (goto-char (point-min)) (search-forward "@mixin")
      (should (<= (apply #'min starts) (match-beginning 0))))))

(ert-deftest scss2-highlighting-repaired-interpolation-restores-following-selector ()
  (dolist (mode '(scss2-mode css2-mode))
    (scss2-highlighting-test--with-buffer mode ".a{--x:#{m.#{x};x;} a.a{}"
      ;; Damaged-input colors are unspecified; repaired text must match a fresh buffer.
      (goto-char (point-min))
      (search-forward "#{m.#{x};x;")
      (replace-match "#{1 + 2};" t t)
      (should-not (treesit-node-check (scss2--root-node) 'has-error))
      (run-hook-with-args 'pre-redisplay-functions nil)
      (jit-lock-fontify-now)
      (scss2-highlighting-test--face "a.a" 'scss2-selector)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (equal (scss2-highlighting-test--faces)
                       (scss2-highlighting-test--with-buffer mode text
                         (scss2-highlighting-test--faces))))))))

(provide 'scss2-highlighting-test)
;;; scss2-highlighting-test.el ends here
