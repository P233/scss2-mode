;;; scss2-editing-test.el --- SCSS editor integration tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'imenu)
(require 'scss2-mode)

(defmacro scss2-editing-test--with-buffer (source &rest body)
  "Enter `scss2-mode' with SOURCE, then evaluate BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,source)
     (let ((scss2-fontify-colors nil)
           (scss2-fontify-details t)
           (treesit-font-lock-level 4)
           (scss2-indent-offset 2)
           (indent-tabs-mode nil))
       (scss2-mode)
       (font-lock-mode 1)
       (font-lock-ensure)
       ,@body)))

(defun scss2-editing-test--faces (text &optional offset)
  "Return the faces at OFFSET in the first occurrence of TEXT."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (let ((face (get-text-property (+ (match-beginning 0) (or offset 0)) 'face)))
      (if (listp face) face (list face)))))

(defconst scss2-editing-test--uncaptured-punctuation
  '(":" ";" "{" "}" "(" ")" "[" "]")
  "Tokens the shared query leaves unfontified outside pseudo-classes.")

(defun scss2-editing-test--assert-covered ()
  "Check actual fontification, including characters inside parent captures."
  (let (uncovered)
    (goto-char (point-min))
    (while (and (< (length uncovered) 12)
                (re-search-forward "[^ \t\r\n\f]" nil t))
      (unless (or (get-text-property (match-beginning 0) 'face)
                  (member (treesit-node-type (treesit-node-at (match-beginning 0)))
                          scss2-editing-test--uncaptured-punctuation))
        (push (list (line-number-at-pos) (match-string 0)) uncovered)))
    (should-not (nreverse uncovered))))

(ert-deftest scss2-editing-stress-fixture-has-faces-and-no-parse-errors ()
  (scss2-editing-test--with-buffer
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name "examples/highlight-stress.scss" scss2-grammar-directory))
        (buffer-string))
    (should-not (treesit-node-check (treesit-buffer-root-node (scss2-grammar-language 'scss)) 'has-error))
    (scss2-editing-test--assert-covered)))

(ert-deftest scss2-editing-retains-scss-editing-and-parser-lifecycle ()
  (scss2-editing-test--with-buffer ".card { color: red; }\n"
    ;; Built-in modes count as parents without being loaded or run.
    (should (derived-mode-p 'scss-mode 'css-mode 'css-base-mode))
    (should (eq indent-line-function #'scss2--indent-line))
    (should (equal editorconfig-indent-size-vars '(scss2-indent-offset)))
    (should (eq font-lock-fontify-region-function #'font-lock-default-fontify-region))
    (should (memq #'scss2-completion-at-point completion-at-point-functions))
    (should-not (memq 'css-completion-at-point completion-at-point-functions))
    (should (equal comment-start "// "))
    (should (equal comment-end ""))
    (should (= (length (treesit-parser-list)) 1))
    (scss2-mode)
    (should (= (length (treesit-parser-list)) 1))
    (fundamental-mode)
    (should-not (treesit-parser-list))))

(ert-deftest scss2-editing-respects-color-preview-preference ()
  (scss2-editing-test--with-buffer ".card { color: #ff0000; }\n"
    (should (memq 'font-lock-constant-face (scss2-editing-test--faces "#ff0000")))
    ;; The preference is read when the mode starts.
    (let ((scss2-fontify-colors t))
      (font-lock-flush)
      (font-lock-ensure)
      (should (memq 'font-lock-constant-face (scss2-editing-test--faces "#ff0000")))
      (scss2-mode)
      (font-lock-mode 1)
      (font-lock-ensure)
      (should (equal (plist-get (scss2-editing-test--faces "#ff0000") :background) "#ff0000")))))

(ert-deftest scss2-editing-reports-unavailable-grammar ()
  ;; Like an oversized buffer, the file keeps lexical editing and mode hooks.
  (pcase-dolist (`(,mode . ,comment) '((css2-mode . "/*") (scss2-mode . "// ")))
    (dolist (failure '((user-error "SCSS parser build failed")
                       (file-error "Creating directory" "Permission denied" "/cache")))
      (with-temp-buffer
        (insert ".a { color: red; }")
        (let ((hook (intern (format "%s-hook" mode)))
              warnings ran)
          (cl-letf (((symbol-function 'scss2-grammar-ensure)
                     (lambda (&rest _) (signal (car failure) (cdr failure))))
                    ((symbol-function 'display-warning)
                     (lambda (type message &rest _) (push (list type message) warnings)))
                    ((symbol-value hook) (list (lambda () (setq ran t)))))
            (funcall mode))
          (should (equal warnings
                         (list (list 'scss2 (error-message-string failure)))))
          (should ran)
          (should (eq major-mode mode))
          (should-not scss2-dialect)
          (should-not (treesit-parser-list))
          (should (equal font-lock-defaults '(nil)))
          (should (equal comment-start comment))
          (should (eq indent-line-function #'scss2--indent-line))
          (should-not (memq #'scss2-completion-at-point completion-at-point-functions))
          (goto-char (point-min)) (search-forward "{")
          (newline-and-indent)
          (should (= (current-indentation) scss2-indent-offset)))))))

(ert-deftest scss2-editing-interpolation-overrides-enclosing-faces ()
  (scss2-editing-test--with-buffer
      "$tone: red;\n$map: (key#{$tone}: red);\n.card-#{$tone}:lang(en#{$tone}) {\ncontent: \"value #{$tone}\";\n--raw: literal #{$tone};\n/* comment #{$tone} */\n// silent #{$tone}\n}\n@keyframes spin { from#{$tone} { opacity: 0; } }\n"
    (dolist (context '(".card-#{$tone}" "value #{$tone}" "literal #{$tone}"
                       "comment #{$tone}" "key#{$tone}" "en#{$tone}" "from#{$tone}"))
      (should (memq 'font-lock-variable-name-face
                    (scss2-editing-test--faces context (string-match "\\$tone" context)))))
    (should (memq 'font-lock-string-face (scss2-editing-test--faces "value ")))
    (should (memq 'font-lock-constant-face (scss2-editing-test--faces "literal ")))
    (should (memq 'font-lock-comment-face (scss2-editing-test--faces "comment ")))
    (should (memq 'font-lock-comment-face (scss2-editing-test--faces "silent #{$tone}" 9)))
    (scss2-editing-test--assert-covered)))

(ert-deftest scss2-editing-predicates-limit-pseudo-faces ()
  (scss2-editing-test--with-buffer
      "a:lang(en):not(button) { x: calc(pi); y: ordinary(pi); z: calc(custom); }"
    (should (equal (scss2-editing-test--faces "en)")
                   (scss2-editing-test--faces "custom")))
    (should-not (equal (scss2-editing-test--faces "en)")
                       (scss2-editing-test--faces "button")))
    (should (equal (scss2-editing-test--faces "calc(pi)" 5)
                   (scss2-editing-test--faces "ordinary(pi)" 9)))
    (should (equal (scss2-editing-test--faces "ordinary(pi)" 9)
                   (scss2-editing-test--faces "custom")))
    (scss2-editing-test--assert-covered)))

(ert-deftest scss2-editing-contextual-captures-override-basic-roles ()
  (scss2-editing-test--with-buffer
      "$palette: (tone: red);\n@keyframes spin { from { opacity: 0; } to { opacity: 1; } }\n"
    (should (memq 'scss2-property (scss2-editing-test--faces "tone")))
    (should (memq 'font-lock-keyword-face (scss2-editing-test--faces "from")))
    (should (memq 'font-lock-keyword-face (scss2-editing-test--faces "to {")))
    (scss2-editing-test--assert-covered)))

(ert-deftest scss2-editing-all-math-functions-fontify-constants-as-plain-values ()
  ;; CSS Values 4, sections 10.1-10.6.
  (dolist (function '("calc" "min" "max" "clamp" "round" "mod" "rem"
                      "sin" "cos" "tan" "asin" "acos" "atan" "atan2"
                      "pow" "sqrt" "hypot" "log" "exp" "abs" "sign"))
    (dolist (spelling (list function (upcase function)))
      (scss2-editing-test--with-buffer
          (format ".sample { width: %s(pi); }" spelling)
        (should (equal (scss2-editing-test--faces "pi)")
                       '(font-lock-constant-face)))))))

(ert-deftest scss2-editing-escaped-math-constants-have-plain-value-faces ()
  (dolist (example '(("calc(p\\69)" . "p\\69")
                     ("calc(\\000070i)" . "\\000070i")
                     ("sqrt(\\pi)" . "\\pi")
                     ("acos(\\65)" . "\\65")
                     ("calc(inf\\69 nity)" . "inf\\69 nity")
                     ("calc(N\\61 N)" . "N\\61 N")))
    (scss2-editing-test--with-buffer
        (format ".sample { width: %s; }" (car example))
      (should (equal (scss2-editing-test--faces (cdr example))
                     '(font-lock-constant-face))))))

(ert-deftest scss2-editing-math-constants-keep-plain-value-faces-when-nested ()
  (scss2-editing-test--with-buffer
      ".sample { a: calc(sqrt(pi) + min(e, max(infinity, 1))); b: calc((pi + e)); c: round(up, acos(pi / 4), 1); d: ordinary(pi); e: calc(ordinary(pi)); f: theme.calc(pi); g: calc(theme.calc(pi)); h: calc(var(--value, pi)); }"
    (dolist (context '("sqrt(pi" "min(e" "max(infinity" "calc((pi" "pi + e" "acos(pi"))
      (should (equal
               (scss2-editing-test--faces
                context (cond ((equal context "pi + e") 5)
                              ((equal context "calc((pi") 6)
                              (t (1+ (string-match "(" context)))))
               '(font-lock-constant-face))))
    (dolist (context '("d: ordinary(pi" "e: calc(ordinary(pi" "f: theme.calc(pi"
                       "g: calc(theme.calc(pi" "h: calc(var(--value, pi"))
      (should (equal (scss2-editing-test--faces context (- (length context) 2))
                     '(font-lock-constant-face)))))
  (dolist (call '("theme.c\\61 lc(pi)" "c\\61 lcx(pi)" "c\\61 lc(pi)" "\\sqrt(pi)"))
    (scss2-editing-test--with-buffer (format ".sample { width: %s; }" call)
      (should (equal (scss2-editing-test--faces "pi)")
                     '(font-lock-constant-face))))))

(ert-deftest scss2-editing-pseudo-argument-faces-respect-case-and-escapes ()
  (dolist (example '((":LANG" . "en") (":DiR" . "rtl") ("::PART" . "label")
                     ("::HIGHLIGHT" . "search") ("::VIEW-TRANSITION-OLD" . "root")
                     (":l\\61 ng" . "en") (":d\\69 r" . "rtl")
                     ("::p\\61 rt" . "label") ("::h\\69 ghlight" . "search")
                     ("::view-transit\\69 on-new" . "root")))
    (scss2-editing-test--with-buffer
        (format ".sample%s(%s) {}" (car example) (cdr example))
      (should (equal (scss2-editing-test--faces (concat "(" (cdr example)) 1)
                     (if (string-search "\\" (car example))
                         '(scss2-selector)
                       '(font-lock-constant-face))))))
  (dolist (pseudo '(":NOT" ":IS" ":WHERE" ":HAS" ":\\6e ot" ":\\69 s"))
    (scss2-editing-test--with-buffer (format ".sample%s(button) {}" pseudo)
      (should (equal (scss2-editing-test--faces "button") '(scss2-selector))))))

(ert-deftest scss2-editing-indents-nesting-and-raw-slashes ()
  (scss2-editing-test--with-buffer
      ".card {\n--image: https://example.test/icon;\ncolor: red;\n&:hover {\ncolor: blue;\n}\n}\n"
    (indent-region (point-min) (point-max))
    (should (equal (buffer-string)
                   ".card {\n  --image: https://example.test/icon;\n  color: red;\n  &:hover {\n    color: blue;\n  }\n}\n"))))

(ert-deftest scss2-editing-indents-continued-statements ()
  (scss2-editing-test--with-buffer
      (concat ".a,\n.b {\ntransition:\nopacity 1s,\ncolor 1s;\n}\n"
              ".x li[data-a]\n.y {\ncolor: red;\n}\n"
              "@if $a {\nb: c;\n}\n@else {\nb: d;\n}\n"
              "$m: (\nk: (\nv: 1\n),\n);\n"
              "/* one\n* two\n*/\n")
    (indent-region (point-min) (point-max))
    (should (equal (buffer-string)
                   (concat ".a,\n.b {\n  transition:\n    opacity 1s,\n    color 1s;\n}\n"
                           ".x li[data-a]\n  .y {\n  color: red;\n}\n"
                           "@if $a {\n  b: c;\n}\n@else {\n  b: d;\n}\n"
                           "$m: (\n  k: (\n    v: 1\n  ),\n);\n"
                           "/* one\n * two\n */\n")))))

(ert-deftest scss2-editing-indents-lines-being-typed ()
  ;; Before `}' is typed, the selector list itself is the statement being read.
  (dolist (case '((".p {\n  color: red;\n\n  &[a],\n&[b] {" . 2)
                  (".b,\n.c {" . 0)
                  (".a {\n  /* first line\n" . 2)
                  (".a {\n  /*\n   * first\n" . 3)))
    (scss2-editing-test--with-buffer (car case)
      (goto-char (point-max))
      (indent-according-to-mode)
      (ert-info ((car case))
        (should (= (current-indentation) (cdr case)))))))

(ert-deftest scss2-editing-new-lines-follow-the-block-indentation ()
  (scss2-editing-test--with-buffer ".a {\n    color: red;\n    transition:\n\topacity 1s,\n}\n"
    (goto-char (point-min))
    (search-forward "red;")
    (newline-and-indent)
    (should (= (current-indentation) 4))
    (search-forward "1s,")
    (newline-and-indent)
    (should (= (current-indentation) tab-width))))

(ert-deftest scss2-editing-fills-block-comments ()
  (scss2-editing-test--with-buffer "/* aaa bbb ccc ddd eee fff */\n.a {}\n"
    (let ((fill-column 12))
      (goto-char 4)
      (fill-paragraph))
    (should (equal (buffer-string) "/* aaa bbb\n   ccc ddd\n   eee fff\n   */\n.a {}\n")))
  (scss2-editing-test--with-buffer ".a {\n  color: red; background: blue; margin: 0;\n}\n"
    (let ((fill-column 14))
      (goto-char (point-min))
      (forward-line 1)
      (should (fill-paragraph)))
    (should (equal (buffer-string) ".a {\n  color: red; background: blue; margin: 0;\n}\n"))))

(ert-deftest scss2-editing-previews-literal-colors ()
  (with-temp-buffer
    (insert ".red { a: #ff000080; b: tomato; c: Red; d: rgb(0 0 255 / 50%);"
            " e: hsl(120deg 100% 50%); f: rgb($r, 0, 0); g: rgb(1 2); }\n")
    (let ((scss2-fontify-colors t))
      (scss2-mode)
      (font-lock-mode 1)
      (font-lock-ensure))
    (pcase-dolist (`(,text . ,color) '(("#ff0000" . "#ff0000") ("tomato" . "#ff6347") ("Red" . "#ff0000")
                                       ("rgb(0" . "#0000ff") ("hsl(" . "#00ff00")
                                       ("rgb($r" . nil) ("rgb(1" . nil)))
      (let ((background (let ((case-fold-search nil))
                          (plist-get (scss2-editing-test--faces text) :background))))
        (ert-info (text)
          (should (equal (and background (downcase background)) color)))))
    (should (equal (scss2-editing-test--faces ".red") '(scss2-selector)))))

(ert-deftest scss2-editing-raw-comment-boundaries-update-after-edit ()
  (scss2-editing-test--with-buffer
      ".café {\n--image: https://example.test/icon;\ncolor: red;\n}\n"
    (goto-char (point-min))
    (search-forward "example.test")
    (should-not (nth 4 (syntax-ppss)))
    (goto-char (point-min))
    (search-forward "--image: https:")
    (delete-region (match-beginning 0) (match-end 0))
    (font-lock-flush)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "example.test")
    (should (nth 4 (syntax-ppss)))
    (should (memq 'font-lock-comment-face (scss2-editing-test--faces "example.test")))
    (goto-char (point-min))
    (forward-line 1)
    (insert "--image: https:")
    (font-lock-flush)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "example.test")
    (should-not (nth 4 (syntax-ppss)))
    (should (memq 'font-lock-string-face (scss2-editing-test--faces "example.test")))
    (should-not (treesit-node-check (treesit-buffer-root-node (scss2-grammar-language 'scss)) 'has-error))))

(ert-deftest scss2-editing-imenu-includes-rules-mixins-and-functions ()
  (scss2-editing-test--with-buffer
      "@mixin paint($tone) { color: $tone; }\n@function twice($x) { @return $x * 2; }\n.card { @include paint(red); }\n"
    (let (names)
      (cl-labels ((collect (entry)
                    (when (consp entry)
                      (when (stringp (car entry)) (push (car entry) names))
                      (when (listp (cdr entry))
                        (mapc #'collect (cdr entry))))))
        (mapc #'collect (imenu--make-index-alist t)))
      (dolist (name '("paint" "twice" ".card"))
        (should (cl-some (lambda (entry) (string-match-p (regexp-quote name) entry)) names))))))

(provide 'scss2-editing-test)
;;; scss2-editing-test.el ends here
