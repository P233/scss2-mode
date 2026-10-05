;;; scss2-emmet.el --- Emmet expansion for stylesheets -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Peiwen Lu
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The stylesheet dispatcher decides where abbreviations are meaningful.
;; Emmet2 owns live choices, previews and atomic insertion, which adds no
;; snippet fields to CSS.  This host owns value navigation.

;;; Code:

(require 'cl-lib)
(require 'scss2-context)
(require 'emmet2-mode)
(defvar css-indent-offset)

(defvar scss2-emmet--context nil
  "Context supplied by the dispatcher during one synchronous CAPF call.
Completion tables never retain this binding; later revisions analyze afresh.")

(defcustom scss2-enable-emmet t
  "Offer declaration abbreviations through the required Emmet2 dependency.
Set nil to retain semantic completion without abbreviation candidates."
  :type 'boolean :group 'scss2)

(defun scss2-emmet-setup ()
  "Install this buffer's context provider without enabling Emmet's minor mode."
  ;; Source load-path installations can bypass the package dependency check.
  ;; Never fall back to another host classifier when this API is missing.
  (unless (and (boundp 'emmet2-context-provider)
               (fboundp 'emmet2-expand-analysis))
    (error "scss2-mode requires the current Emmet2 host API; update the Emmet2 checkout"))
  (setq-local emmet2-context-provider
              (list :analyze #'scss2-emmet--analysis :revision #'scss2-emmet--revision)))

(defun scss2-emmet--revision ()
  "Return immutable non-text inputs to the host's abbreviation policy."
  (list scss2-enable-emmet scss2-dialect scss2--parser-language css-indent-offset))

(defun scss2-emmet--provider-p ()
  "Whether Emmet is using this stylesheet's context provider."
  (eq (plist-get emmet2-context-provider :analyze) #'scss2-emmet--analysis))

(defun scss2-emmet--analysis (_automatic)
  "Confirm an abbreviation's bounds and syntax, or return nil.
Emmet owns confidence checks for automatic and explicit requests alike;
the host only confirms a declaration insertion position."
  (when-let* ((_ scss2-enable-emmet)
              (context (or scss2-emmet--context (scss2-context-at-point)))
              (_ (and (eq (plist-get context :role) 'property)
                      (plist-get context :start))))
    (when-let* ((abbr (scss2--with-font-lock-view
                        ;; Include a suffix that narrowing hides, within Font Lock's view.
                        ;; Emmet rejects bounds outside the visible area.
                        (emmet2-extract (plist-get context :start) (point-max) 'css)))
                (text (plist-get abbr :abbr)))
      (when (and (string-match-p "\\`[a-zA-Z-]" text)
                 (or (eq scss2-dialect 'scss)
                     (not (string-match-p "[$]\\|#{" text))))
        (append abbr (list :lang 'css :syntax scss2-dialect
                           :position 'declaration-start
                           :indent-width css-indent-offset
                           :at-rule (plist-get context :at-rule)))))))

;;;###autoload
(defun scss2-expand ()
  "Expand a declaration abbreviation using Emmet2.
Only declaration insertion positions are accepted.  Values, selectors and
directives are completed by the semantic stylesheet completion provider."
  (interactive)
  (unless scss2-enable-emmet
    (user-error "Emmet expansion is disabled; enable scss2-enable-emmet"))
  (let ((analysis (and (scss2-emmet--provider-p) (emmet2-context-analyze))))
    (unless analysis (user-error "No declaration abbreviation at point"))
    (let* ((snapshot (emmet2-insert-snapshot analysis))
           (result (emmet2-expand-analysis analysis)))
      (emmet2-insert snapshot result))))

(defun scss2-emmet-completion-at-point (&optional context)
  "Offer Emmet's live choices, reusing the dispatcher's current CONTEXT."
  (let ((scss2-emmet--context context))
    (and scss2-enable-emmet (scss2-emmet--provider-p) (emmet2-capf))))

(provide 'scss2-emmet)
;;; scss2-emmet.el ends here
