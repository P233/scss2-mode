;;; scss2-narrowing-test.el --- Narrowed buffers keep one full parse -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'imenu)
(require 'outline)
(require 'scss2-mode)

(defvar scss2-narrowing-test--parses nil
  "For each reparse, newest first, whether the parser's buffer was narrowed.")

(defun scss2-narrowing-test--record (_ranges parser)
  "Record whether PARSER's buffer was narrowed during this reparse."
  (push (with-current-buffer (treesit-parser-buffer parser) (buffer-narrowed-p))
        scss2-narrowing-test--parses))

(defmacro scss2-narrowing-test--with-buffer (mode &rest body)
  "Evaluate BODY in a fontified MODE buffer of rules, recording reparses."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (rename-buffer "scss2-narrowing-test" t)
     (dotimes (index 300)
       (insert (format ".card-%d {\n  background: url(http://example.test/%d.png);\n  margin: 2px/* note */3px;\n}\n"
                       index index)))
     (let ((css-fontify-colors nil)) (funcall ,mode))
     (let ((noninteractive nil)) (font-lock-mode 1))
     (jit-lock-fontify-now)
     (syntax-propertize (point-max))
     (let ((scss2-narrowing-test--parses nil))
       (treesit-parser-add-notifier (car (treesit-parser-list))
                                    #'scss2-narrowing-test--record)
       ,@body)))

(defun scss2-narrowing-test--redisplay ()
  "Run the redisplay hooks and fontify the lines around point."
  (run-hook-with-args 'pre-redisplay-functions (selected-window))
  (jit-lock-fontify-now (line-beginning-position -1) (line-beginning-position 3)))

(defun scss2-narrowing-test--parses-during (function &optional syntax-first)
  "Return the reparses caused by FUNCTION and the redisplay that follows it.
Each element tells whether the buffer was narrowed during that reparse.
With SYNTAX-FIRST, a lexical syntax reader runs before the redisplay hooks."
  (let ((scss2-narrowing-test--parses nil))
    (funcall function)
    (when syntax-first (syntax-ppss))
    (scss2-narrowing-test--redisplay)
    (unless syntax-first (syntax-ppss))
    (nreverse scss2-narrowing-test--parses)))

(defun scss2-narrowing-test--runs (property)
  "Return the runs of PROPERTY in the accessible buffer."
  (let ((position (point-min)) runs)
    (while (< position (point-max))
      (let ((next (next-single-property-change position property nil (point-max))))
        (push (list position next (get-text-property position property)) runs)
        (setq position next)))
    (nreverse runs)))

(defun scss2-narrowing-test--properties ()
  "Complete fontification and lexical syntax, then return their runs."
  (save-restriction
    (widen)
    (jit-lock-fontify-now)
    (syntax-propertize (point-max))
    (list (scss2-narrowing-test--runs 'face)
          (scss2-narrowing-test--runs 'syntax-table))))

(defun scss2-narrowing-test--fresh-properties ()
  "Return the properties of a new buffer with this buffer's mode and text."
  (let ((text (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))
        (mode major-mode))
    (with-temp-buffer
      (rename-buffer "scss2-narrowing-fresh" t)
      (insert text)
      (let ((css-fontify-colors nil)) (funcall mode))
      (let ((noninteractive nil)) (font-lock-mode 1))
      (scss2-narrowing-test--properties))))

(defun scss2-narrowing-test--narrow-around (text)
  "Move to the middle occurrence of TEXT and narrow to the lines around it."
  (goto-char (/ (point-max) 2))
  (search-forward text)
  (narrow-to-region (line-beginning-position -20) (line-beginning-position 20)))

(defun scss2-narrowing-test--typing-parses ()
  "Type and delete a silent comment, returning the reparses of each key."
  (cl-loop for event in '(?x ?/ ?/ ?y delete delete delete delete)
           for index from 0
           collect (scss2-narrowing-test--parses-during
                    (lambda ()
                      (if (eq event 'delete) (delete-char -1) (insert-char event)))
                    (cl-evenp index))))

(ert-deftest scss2-narrowing-typing-parses-once-per-key ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-narrowing-test--with-buffer mode
      (scss2-narrowing-test--narrow-around "margin")
      (let ((parses (scss2-narrowing-test--typing-parses)))
        ;; One incremental parse of the full buffer per key, never of the restriction.
        (ert-info ((format "%s parses per key %S" mode parses))
          (should (equal parses (make-list 8 '(nil))))))
      (let ((before scss2-narrowing-test--parses))
        (should (= (treesit-node-end (save-restriction (widen) (scss2--root-node)))
                   (1+ (buffer-size))))
        (should (eq scss2-narrowing-test--parses before)))
      (insert "color: red;")
      (scss2-narrowing-test--redisplay)
      (should (equal (scss2-narrowing-test--properties)
                     (scss2-narrowing-test--fresh-properties))))))

(ert-deftest scss2-narrowing-font-lock-dont-widen-reads-the-restriction ()
  ;; Polymode and markdown-ts-mode code blocks fontify only the restriction.
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-narrowing-test--with-buffer mode
      (setq-local font-lock-dont-widen t)
      (scss2-narrowing-test--narrow-around "margin")
      (let ((parses (scss2-narrowing-test--typing-parses)))
        (ert-info ((format "%s parses per key %S" mode parses))
          (should (equal parses (make-list 8 '(t)))))))
    ;; Host text before the restriction is never read as stylesheet code.
    (dolist (host '("<p>see a/*b</p>" "<p>Don't panic</p>" "<template><p>Plain text</p></template>"))
      (with-temp-buffer
        (insert host "\n<style lang=\"scss\">\n")
        (let ((start (point)))
          (insert ".a { color: red; --y: a//b; }\n")
          (funcall mode)
          (narrow-to-region start (point-max))
          (goto-char start))
        (let ((scss2-narrowing-test--parses nil))
          (treesit-parser-add-notifier (car (treesit-parser-list))
                                       #'scss2-narrowing-test--record)
          (ert-info ((format "%s code block after %S" mode host))
            (let ((font-lock-dont-widen t))
              (font-lock-ensure)
              (search-forward "a//")
              (should (equal (get-text-property (- (point) 2) 'syntax-table)
                             (string-to-syntax ".")))
              (should-not (nth 4 (syntax-ppss)))
              (should (equal scss2-narrowing-test--parses '(t)))
              (goto-char (point-min)) (search-forward "color: r")
              (let ((context (scss2-context-at-point)))
                (should (eq (plist-get context :role) 'property-value))
                (should (equal (plist-get context :property) "color")))
              (search-backward "lor")
              (scss2-mark)
              (should (equal (buffer-substring-no-properties (point) (mark)) "color: red;"))
              (deactivate-mark)
              (scss2-kill)
              (should (equal (buffer-string) ".a {  --y: a//b; }\n"))
              (search-forward "--y")
              (scss2-mark)
              (should (equal (buffer-substring-no-properties (point) (mark)) "--y: a//b;")))
            ;; Reading and editing reparse only the restriction.
            (should (equal scss2-narrowing-test--parses '(t t)))))))))

(ert-deftest scss2-narrowing-comment-commands-never-parse-the-restriction ()
  ;; Comment commands narrow internally even in a widened buffer.
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (narrowed '(nil t))
      (scss2-narrowing-test--with-buffer mode
        (scss2-narrowing-test--narrow-around "margin")
        (unless narrowed (widen))
        (dolist (command '(comment-region uncomment-region))
          (let ((parses (scss2-narrowing-test--parses-during
                         (lambda ()
                           (funcall command (line-beginning-position) (line-end-position)))
                         t)))
            ;; A block comment's two edits may each be parsed, but only incrementally.
            (ert-info ((format "%s %s narrowed: %s parses %S" mode command narrowed parses))
              (should parses)
              (should-not (memq t parses)))))
        (comment-region (line-beginning-position) (line-end-position))
        (scss2-narrowing-test--redisplay)
        (should (equal (scss2-narrowing-test--properties)
                       (scss2-narrowing-test--fresh-properties)))))))

(ert-deftest scss2-narrowing-features-read-the-full-tree ()
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-narrowing-test--with-buffer mode
      (scss2-narrowing-test--narrow-around "note")
      (let ((note (point)))
        (pcase-dolist (`(,name . ,function)
                       `((context . ,(lambda () (search-backward ": ") (forward-char 2)
                                       (should (scss2-context-at-point))))
                         (completion . ,(lambda ()
                                          (should (all-completions
                                                   "" (nth 2 (scss2-completion-at-point))))))
                         (mark . ,(lambda () (scss2-mark) (deactivate-mark)))
                         (kill-declaration . ,(lambda ()
                                                (goto-char note) (search-backward "margin")
                                                (scss2-kill)
                                                (should-not (looking-at-p "margin"))))
                         (imenu . ,(lambda ()
                                     (setq imenu--index-alist nil)
                                     (should (imenu--make-index-alist t))))))
          (let ((parses (scss2-narrowing-test--parses-during function t)))
            (ert-info ((format "%s %s parses %S" mode name parses))
              (should (buffer-narrowed-p))
              (should-not (memq t parses)))))))))

(ert-deftest scss2-narrowing-incomplete-comment-ranges-reject-uncomment ()
  (dolist (mode '(css2-mode scss2-mode))
    (dolist (edge '(start end))
      (with-temp-buffer
        (insert ".a { /* retained */ color: red; }")
        (funcall mode)
        (goto-char (point-min)) (search-forward "/*")
        (let ((start (- (point) 2)))
          (search-forward "*/")
          (let ((end (point)))
            (narrow-to-region (if (eq edge 'start) (1+ start) (point-min))
                              (if (eq edge 'end) (1- end) (point-max)))
            (goto-char (+ start 3))
            (let ((original (buffer-string)) (position (point)))
              (should-error (scss2-comment-uncomment) :type 'user-error)
              (should (equal (buffer-string) original))
              (should (= (point) position)))))))))

(ert-deftest scss2-narrowing-syntax-extension-stays-accessible ()
  ;; Each edit changes the full tree from before the restriction.
  (pcase-dolist (`(,text ,start ,end ,insertion)
                 '(("/* open\n.a { background: url(http://example.test/a.png); }\n.b { margin: 0; }\n"
                    1 nil "*/")
                   (".a {\n  color: red;\n  .b {\n    margin: 0;\n  }\n}\n" 2 3 "{")))
    (dolist (mode '(css2-mode scss2-mode))
      ;; The reparse comes from `syntax-ppss', or earlier from redisplay.
      (dolist (redisplay '(nil t))
        (with-temp-buffer
          (insert text)
          (funcall mode)
          (syntax-propertize (point-max))
          (goto-char (point-min)) (forward-line start)
          (narrow-to-region (point) (if end (line-beginning-position (- end start -1)) (point-max)))
          (back-to-indentation)
          (insert insertion)
          (when redisplay
            (run-hook-with-args 'pre-redisplay-functions nil))
          ;; `syntax-propertize' complains when asked to start before the restriction.
          (let ((message-log-max t)
                (logged (with-current-buffer (messages-buffer) (buffer-size))))
            (syntax-ppss (point-max))
            (ert-info ((format "%s %S redisplay %s" mode insertion redisplay))
              (should (= logged (with-current-buffer (messages-buffer) (buffer-size))))))
          (widen)
          (should-not (nth 4 (syntax-ppss (point-max)))))))))

(ert-deftest scss2-narrowing-outline-search-finds-only-accessible-headings ()
  (with-temp-buffer
    (insert (scss2-narrowing-test--nested-text))
    (scss2-mode)
    (goto-char (point-min)) (search-forward ".card-2 {")
    (let ((rule (line-beginning-position)))
      (search-forward ".title")
      (narrow-to-region (line-beginning-position) (line-beginning-position 3))
      (forward-line 1)
      ;; The enclosing heading line begins inside the restriction.
      (outline-back-to-heading)
      (should (= (point) (point-min)))
      (should (funcall outline-search-function nil nil nil t))
      ;; Its parent's heading line does not.
      (should-not (funcall outline-search-function nil nil t))
      (should (= (point) (point-min)))
      (widen)
      (goto-char rule) (forward-line 1)
      (narrow-to-region (point) (line-beginning-position 2))
      (should-error (outline-back-to-heading) :type 'outline-before-first-heading)
      (should-not (funcall outline-search-function nil t))
      (should (= (point) (point-max)))
      ;; A heading line cut by the restriction is no heading when looking at it either.
      (widen)
      (narrow-to-region (+ rule 3) (progn (goto-char rule) (line-beginning-position 3)))
      (goto-char (point-min))
      (should-not (funcall outline-search-function nil nil nil t))
      (should-not (outline-on-heading-p))
      (forward-line 1)
      (should-error (outline-back-to-heading) :type 'outline-before-first-heading))))

(ert-deftest scss2-narrowing-wrappers-replace-only-present-treesit-hooks ()
  (with-temp-buffer
    (insert ".a { color: red; }")
    (dolist (mode '(css2-mode scss2-mode))
      (funcall mode)
      (should (memq #'scss2--pre-redisplay pre-redisplay-functions))
      (should (memq #'scss2--pre-syntax-ppss syntax-propertize-extend-region-functions))
      (should-not (memq #'treesit--pre-redisplay pre-redisplay-functions))
      (should-not (memq #'treesit--pre-syntax-ppss syntax-propertize-extend-region-functions))
      ;; Hooks without the stock functions, as after a treesit.el change, stay as they are.
      (let ((hooks (list pre-redisplay-functions syntax-propertize-extend-region-functions)))
        (scss2--widen-tree-hooks)
        (should (equal hooks (list pre-redisplay-functions
                                   syntax-propertize-extend-region-functions)))))
    ;; Renamed or removed private functions keep the stock hooks in place.
    (cl-letf (((symbol-function 'treesit--pre-redisplay) nil)
              ((symbol-function 'treesit--pre-syntax-ppss) nil))
      (scss2-mode))
    (should (memq 'treesit--pre-redisplay pre-redisplay-functions))
    (should (memq 'treesit--pre-syntax-ppss syntax-propertize-extend-region-functions))
    (should-not (memq #'scss2--pre-redisplay pre-redisplay-functions))
    (should-not (memq #'scss2--pre-syntax-ppss syntax-propertize-extend-region-functions))))

(defvar scss2-narrowing-test--is-stock nil
  "Non-nil to run the treesit.el command functions instead of the wrappers.")

(defconst scss2-narrowing-test--commands
  `((C-M-a . ,(lambda ()
                (call-interactively (if scss2-narrowing-test--is-stock #'treesit-beginning-of-defun
                                      (key-binding (kbd "C-M-a"))))))
    (C-M-e . ,(lambda ()
                (call-interactively (if scss2-narrowing-test--is-stock #'treesit-end-of-defun
                                      (key-binding (kbd "C-M-e"))))))
    (beginning-of-defun . ,#'beginning-of-defun)
    (M-q . ,(lambda () (call-interactively #'prog-fill-reindent-defun) nil))
    (C-M-t . ,(lambda () (call-interactively #'transpose-sexps) nil))
    (add-log-current-defun . ,#'add-log-current-defun)
    (outline-next-heading . ,(lambda () (outline-next-heading) nil))
    (outline-previous-heading . ,(lambda () (outline-previous-heading) nil)))
  "Emacs commands that read the tree, as (NAME . FUNCTION).")

(defun scss2-narrowing-test--nested-text ()
  "Return indented SCSS with nested rules, mixins and comments."
  (mapconcat
   (lambda (index)
     (format "// Group %d\n@media (min-width: %dpx) {\n  .card-%d {\n    color: red;\n    .title {\n      margin: 0 2px;\n    }\n  }\n}\n@mixin m-%d($a) {\n  width: $a;\n}\n.row-%d { a: b; c: d; }\n"
             index index index index index))
   (number-sequence 0 5) ""))

(defun scss2-narrowing-test--unindent (start end)
  "Remove the indentation of the lines that lie entirely within START..END.
START and END are markers, so they follow the removed text."
  (save-excursion
    (goto-char start)
    (unless (bolp) (forward-line 1))
    (while (and (< (point) end) (<= (line-end-position) end))
      (delete-horizontal-space)
      (forward-line 1))))

(defun scss2-narrowing-test--run (function position &optional restriction)
  "Run FUNCTION at POSITION, narrowed to RESTRICTION (BEG . END) when non-nil.
Return (POINT VALUE TEXT); VALUE is (error MESSAGE) when FUNCTION signals.
Use the buffer's installed command variables, or with
`scss2-narrowing-test--is-stock' bind them to the treesit.el originals."
  (goto-char position)
  ;; Reinserted text must not be propertized only from inside the restriction.
  (syntax-propertize (point-max))
  (when restriction (narrow-to-region (car restriction) (cdr restriction)))
  (unwind-protect
      (let ((value (condition-case err
                       (if scss2-narrowing-test--is-stock
                           (cl-progv (mapcar #'car scss2--widened-tree-functions)
                               (mapcar #'cadr scss2--widened-tree-functions)
                             (funcall function))
                         (funcall function))
                     (error (list 'error (error-message-string err))))))
        (list (point) value
              (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max)))))
    (widen)))

(defun scss2-narrowing-test--changed-span (old new)
  "Return (FIRST . LAST) positions of OLD that differ in NEW, or nil."
  (let ((size (min (length old) (length new))) (first 0) (last 0))
    (while (and (< first size) (eq (aref old first) (aref new first)))
      (setq first (1+ first)))
    (while (and (< last (- size first))
                (eq (aref old (- (length old) last 1)) (aref new (- (length new) last 1))))
      (setq last (1+ last)))
    (unless (and (= first (length old)) (= (length old) (length new)))
      (cons (1+ first) (1+ (- (length old) last))))))

(ert-deftest scss2-narrowing-tree-commands-match-the-widened-buffer ()
  ;; Targets in the restriction are found as in the widened buffer; others stop at its edge.
  (with-temp-buffer
    (insert (scss2-narrowing-test--nested-text))
    (let ((css-fontify-colors nil) (css-indent-offset 2) (original (buffer-string))
          (lines (count-lines (point-min) (point-max))) outcomes)
      (scss2-mode)
      (pcase-dolist (`(,name . ,function) scss2-narrowing-test--commands)
        (dotimes (line lines)
          ;; Line edges, and edges inside a line's indentation or text.
          (pcase-dolist (`(,start-offset . ,end-offset) '((0 . 0) (1 . 3)))
            (erase-buffer) (insert original)
            (goto-char (point-min)) (forward-line line) (back-to-indentation)
            (let ((markers (list (point-marker)
                                 (copy-marker (+ (line-beginning-position -3) start-offset))
                                 (copy-marker (+ (line-beginning-position 5) end-offset)))))
              ;; Misindented accessible lines give M-q work that needs no outside text.
              (when (eq name 'M-q)
                (scss2-narrowing-test--unindent (nth 1 markers) (nth 2 markers)))
              (let ((position (marker-position (nth 0 markers)))
                    (restriction (cons (marker-position (nth 1 markers))
                                       (marker-position (nth 2 markers))))
                    (before (buffer-string)))
                (mapc (lambda (marker) (set-marker marker nil)) markers)
                (when (<= (car restriction) position (cdr restriction))
                  (let* ((widened (scss2-narrowing-test--run function position))
                         (stock (progn (erase-buffer) (insert before)
                                       (let ((scss2-narrowing-test--is-stock t))
                                         (scss2-narrowing-test--run function position))))
                         (narrowed (progn (erase-buffer) (insert before)
                                          (scss2-narrowing-test--run function position restriction)))
                         (span (scss2-narrowing-test--changed-span before (nth 2 widened)))
                         (inside (or (memq name '(M-q add-log-current-defun))
                                     (and (not (eq (car-safe (nth 1 widened)) 'error))
                                          (<= (car restriction) (car widened) (cdr restriction))
                                          (or (null span)
                                              (and (<= (car restriction) (car span))
                                                   (<= (cdr span) (cdr restriction))))))))
                    (ert-info ((format "%s at %d in %S: widened %S narrowed %S"
                                       name position restriction (butlast widened) (butlast narrowed)))
                      ;; Unnarrowed behavior is unchanged.
                      (should (equal widened stock))
                      (push (cons name (if inside 'inside 'edge)) outcomes)
                      (cond
                       (inside (should (equal narrowed widened)))
                       ((eq name 'C-M-t)
                        (should (equal (nth 2 narrowed) before))
                        (should (member (nth 1 narrowed)
                                        (list (nth 1 widened)
                                              '(error "Sexps to transpose extend outside the narrowed region")))))
                       (t
                        (should (equal (nth 2 narrowed) before))
                        (should (memq (car narrowed) (list (car restriction) (cdr restriction))))
                        ;; `beginning-of-defun' returns t after moving to the line's beginning.
                        (unless (eq name 'beginning-of-defun)
                          (should-not (nth 1 narrowed)))))))))))))
      ;; Every command met targets of both kinds.
      (pcase-dolist (`(,name . ,_) scss2-narrowing-test--commands)
        (should (member (cons name 'inside) outcomes))
        (unless (memq name '(M-q add-log-current-defun))
          (should (member (cons name 'edge) outcomes)))))))

(ert-deftest scss2-narrowing-tree-commands-parse-once ()
  ;; Stock commands parse the restriction and leave a full reparse to redisplay.
  (dolist (mode '(css2-mode scss2-mode))
    (scss2-narrowing-test--with-buffer mode
      (scss2-narrowing-test--narrow-around "margin")
      (let ((origin (point)))
        (pcase-dolist (`(,name . ,function) scss2-narrowing-test--commands)
          (goto-char origin)
          (insert "x") (delete-char -1)
          (let* ((tick (buffer-chars-modified-tick))
                 (parses (scss2-narrowing-test--parses-during
                          (lambda () (ignore-errors (funcall function))) t)))
            (ert-info ((format "%s %s parses %S" mode name parses))
              (should (buffer-narrowed-p))
              (should (equal parses (if (= tick (buffer-chars-modified-tick))
                                        '(nil) '(nil nil)))))))))))

(ert-deftest scss2-narrowing-fill-reindent-defun-in-a-cut-block ()
  ;; Alone, a restriction inside the block parses without a defun.
  (let ((css-indent-offset 2)
        (head '(":root {" "  color-scheme: light;" "  // Layer 1"))
        (tail '("   --base: #b67ea9;" "      --n-100: oklch(0.965 0.003 265);"
                "  @include accent-tokens;" "    }")))
    (with-temp-buffer
      (pcase-dolist (`(,restriction . ,expected)
                     '(;; Lines 2-5 and two columns of the indentation of line 6.
                       (((2 . 0) . (6 . 2)) "  --base: #b67ea9;" "  --n-100: oklch(0.965 0.003 265);"
                        "  @include accent-tokens;" "    }")
                       ;; From inside the indentation of line 3, whose column the
                       ;; following lines then share as in the widened buffer.
                       (((3 . 1) . (7 . 0)) "   --base: #b67ea9;" "   --n-100: oklch(0.965 0.003 265);"
                        "   @include accent-tokens;" "}")
                       (nil "  --base: #b67ea9;" "  --n-100: oklch(0.965 0.003 265);"
                            "  @include accent-tokens;" "}")))
        (erase-buffer)
        (insert (string-join (append head tail) "\n") "\n")
        (scss2-mode)
        (when restriction
          (let ((position (pcase-lambda (`(,line . ,column))
                            (save-excursion
                              (goto-char (point-min)) (forward-line line) (+ (point) column)))))
            (narrow-to-region (funcall position (car restriction))
                              (funcall position (cdr restriction)))))
        (goto-char (point-min)) (search-forward "--n-100")
        (prog-fill-reindent-defun)
        (widen)
        (ert-info ((format "restriction %S" restriction))
          (should (equal (buffer-string)
                         (concat (string-join (append head expected) "\n") "\n"))))))))

(ert-deftest scss2-narrowing-fill-reindent-defun-decides-in-the-full-buffer ()
  ;; A restriction that starts inside a comment hides the comment's opener.
  (let ((css-indent-offset 2))
    (with-temp-buffer
      ;; Inside the restriction, the apostrophe opens a string over the rule.
      (insert "// it's a note\n.a {\n      color: red;\n  margin: 0;\n}\n")
      (scss2-mode)
      (narrow-to-region 2 (point-max))
      (goto-char (point-min)) (search-forward "color")
      (prog-fill-reindent-defun)
      (widen)
      (should (equal (buffer-string) "// it's a note\n.a {\n  color: red;\n  margin: 0;\n}\n"))
      (erase-buffer)
      (insert "/* one\n   two three */\n.a { color: red; }\n")
      (goto-char (point-min)) (search-forward "one")
      (narrow-to-region (point) (point-max))
      (search-forward "two")
      (should-error (prog-fill-reindent-defun) :type 'user-error)
      (widen)
      (should (equal (buffer-string) "/* one\n   two three */\n.a { color: red; }\n"))
      ;; A comment that begins in the restriction is filled there.
      (goto-char (point-min))
      (narrow-to-region (point-min) (search-forward "*/"))
      (search-backward "two")
      (let ((fill-column 12))
        (prog-fill-reindent-defun))
      (widen)
      (should (equal (buffer-string) "/* one two\n   three */\n.a { color: red; }\n")))))

(ert-deftest scss2-narrowing-outline-level-reads-the-full-tree ()
  (with-temp-buffer
    (insert (scss2-narrowing-test--nested-text))
    (scss2-mode)
    (goto-char (point-min)) (search-forward ".title")
    (let ((level (funcall outline-level)))
      (should (> level 1))
      (narrow-to-region (line-beginning-position) (line-beginning-position 3))
      (should (= (funcall outline-level) level)))))

(ert-deftest scss2-narrowing-tree-command-wrappers-replace-only-treesit-originals ()
  (with-temp-buffer
    (insert ".a { color: red; }")
    (scss2-mode)
    (pcase-dolist (`(,variable ,_ ,wrapper) scss2--widened-tree-functions)
      (should (eq (symbol-value variable) wrapper)))
    (pcase-dolist (`(,command ,_ ,wrapper) scss2--widened-tree-remaps)
      (should (eq (key-binding (vector 'remap command)) wrapper)))
    ;; A function another package installed after setup stays in place.
    (setq-local add-log-current-defun-function #'ignore)
    (scss2--widen-tree-commands)
    (should (eq add-log-current-defun-function #'ignore))))

(provide 'scss2-narrowing-test)
;;; scss2-narrowing-test.el ends here
