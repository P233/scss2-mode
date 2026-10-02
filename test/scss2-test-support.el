;;; scss2-test-support.el --- Real stylesheet buffer fixtures -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'scss2-syntax)

(defun scss2-test-setup-buffer (mode)
  "Set up MODE's real syntax without loading host composition or frontends."
  (let ((dialect (if (eq mode 'scss2-mode) 'scss 'css)))
    (funcall (if (eq dialect 'scss) #'scss-mode #'css-mode))
    (scss2-syntax-setup dialect)))

(defmacro scss2-test-with-buffer (mode source &rest body)
  "Evaluate BODY with MODE's syntax and SOURCE, using │ to indicate point.
MODE names css2-mode or scss2-mode; no host mode or frontend is loaded."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (insert ,source)
     (goto-char (point-min))
     (search-forward "│")
     (delete-char -1)
     (let ((position (point)) (css-fontify-colors nil))
       (scss2-test-setup-buffer ,mode)
       (goto-char position)
       ,@body)))

(provide 'scss2-test-support)
;;; scss2-test-support.el ends here
