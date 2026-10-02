;;; scss2-test-runner.el --- Shared source and installed ERT suite -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)

(defun scss2-test-run (directory &optional suites)
  "Load tests from DIRECTORY and return non-nil when all selected tests pass.
SCSS2_TEST_SELECTOR optionally limits the suite; selecting no test fails.
Callers own runtime loading, temporary resources and process exit.
SUITES optionally lists test file names relative to DIRECTORY.
Only test helpers from DIRECTORY are added to load-path while loading tests."
  (let ((load-path (cons directory load-path)))
    (dolist (file (or suites (directory-files directory nil "\\`[^.].*-test\\.el\\'")))
      (load (expand-file-name file directory) nil t)))
  (let ((results (ert-run-tests-batch (or (getenv "SCSS2_TEST_SELECTOR") t))))
    (when (zerop (ert-stats-total results))
      (message "No test matched SCSS2_TEST_SELECTOR=%s" (getenv "SCSS2_TEST_SELECTOR")))
    (and (> (ert-stats-total results) 0)
         (zerop (ert-stats-completed-unexpected results)))))

(provide 'scss2-test-runner)
;;; scss2-test-runner.el ends here
