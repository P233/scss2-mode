;;; scss2-grammar.el --- Load the bundled CSS/SCSS grammar -*- lexical-binding: t; -*-

;; Copyright (C) 2026 P233
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The package owns its grammar source and language identities.  Native output
;; belongs to a content-addressed user cache, never to the package directory.
;; Compilation is local and synchronous; no grammar is fetched at runtime.

;;; Code:

(require 'json)
(require 'treesit)
(require 'subr-x)

(defgroup scss2 nil
  "CSS and SCSS editing with a bundled grammar."
  :group 'languages)

(defconst scss2-grammar-directory
  (expand-file-name "vendor/tree-sitter-scss/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing the package's grammar source and highlight query.")

(defconst scss2-grammar--content-id
  (let ((identity
         (with-temp-buffer
           (insert-file-contents
            (expand-file-name "manifest.json" scss2-grammar-directory))
           (alist-get 'contentId (json-parse-buffer :object-type 'alist)))))
    (unless (and (stringp identity)
                 (string-match-p "\\`[0-9a-f]\\{64\\}\\'" identity))
      (error "Invalid bundled scss2-mode grammar manifest"))
    identity)
  "Content identity of the bundled grammar and query snapshot.")

(defcustom scss2-grammar-cache-directory
  (expand-file-name "tree-sitter/scss2-mode/" user-emacs-directory)
  "Root directory for native libraries built from the bundled grammar.
Each source identity and platform has its own subdirectory.  The package
directory can be read-only.  Compilation uses the CC environment variable
as one executable name, or cc when CC is unset."
  :type 'directory
  :group 'scss2)

(defun scss2-grammar--library-base ()
  "Return the private library base name for the bundled source."
  (concat "libtree-sitter-scss2-" (substring scss2-grammar--content-id 0 16)))

(defun scss2-grammar-language (dialect)
  "Return the private Tree-sitter language for DIALECT, css or scss.
Register its C entry point without loading or building a native library.
The source identity avoids sharing Emacs's language cache with other
SCSS grammars or a different version of this package."
  (unless (memq dialect '(css scss))
    (error "Unknown stylesheet dialect: %S" dialect))
  (let ((language
         (intern (format "scss2-%s-%s" dialect
                         (substring scss2-grammar--content-id 0 16)))))
    ;; Emacs consults the path again when creating a parser, so the mapping
    ;; retains the absolute base path rather than a temporary search path.
    (setf (alist-get language treesit-load-name-override-list)
          (list (expand-file-name (scss2-grammar--library-base)
                                  (scss2-grammar--cache-path))
                (if (eq dialect 'css)
                    "tree_sitter_stylesheet_css"
                  "tree_sitter_scss")))
    language))

(defun scss2-grammar--cache-path ()
  "Return the native output directory for this source and platform."
  (expand-file-name
   (concat scss2-grammar--content-id "/" system-configuration "/")
   scss2-grammar-cache-directory))

(defun scss2-grammar--library-file ()
  "Return the cached native library file name."
  (expand-file-name
   (concat (scss2-grammar--library-base)
           (pcase system-type
             ('darwin ".dylib")
             ('windows-nt ".dll")
             (_ ".so")))
   (scss2-grammar--cache-path)))

(defun scss2-grammar--library-present-p (library)
  "Whether LIBRARY is a nonempty regular file."
  (let ((attributes (file-attributes library)))
    (and attributes (null (file-attribute-type attributes))
         (> (file-attribute-size attributes) 0))))

(defun scss2-grammar--compile (library)
  "Build bundled sources and atomically publish LIBRARY on success."
  (let* ((compiler-name (or (getenv "CC") "cc"))
         (compiler (executable-find compiler-name))
         (source (expand-file-name "src/" scss2-grammar-directory)))
    (unless compiler
      (user-error "scss2-mode needs a C compiler; install cc or set CC to its executable"))
    (make-directory (file-name-directory library) t)
    (let ((temporary (make-temp-file
                      (expand-file-name ".compile-" (file-name-directory library))
                      nil (file-name-extension library t)))
          (progress "Compiling the bundled scss2-mode grammar..."))
      (message "%s" progress)
      (unwind-protect
          (with-temp-buffer
            (let ((status
                   (condition-case failure
                       (call-process compiler nil t nil
                                     "-std=c11" "-O2" "-fPIC"
                                     (if (eq system-type 'darwin) "-dynamiclib" "-shared")
                                     "-I" source
                                     (expand-file-name "parser.c" source)
                                     (expand-file-name "scanner.c" source)
                                     "-o" temporary)
                     (file-error
                      (user-error "Could not run the scss2-mode compiler: %s"
                                  (error-message-string failure))))))
              (unless (eq status 0)
                (user-error "Could not compile the bundled scss2-mode grammar (%s):\n%s"
                            status (string-trim (buffer-string))))
              (unless (scss2-grammar--library-present-p temporary)
                (user-error "The scss2-mode compiler succeeded but produced no native library:\n%s"
                            (string-trim (buffer-string))))
              (rename-file temporary library t)
              (message "%sdone" progress)))
        (when (file-exists-p temporary)
          (delete-file temporary))))))

(defun scss2-grammar-ensure (dialect)
  "Build and load the bundled grammar for DIALECT, then return its language.
Existing native output is reused.  A failed build leaves no published
library; a library that cannot load reports the runtime's diagnostic."
  (unless (treesit-available-p)
    (user-error "scss2-mode requires Emacs built with Tree-sitter support"))
  (let* ((language (scss2-grammar-language dialect))
         (library (scss2-grammar--library-file)))
    (unless (scss2-grammar--library-present-p library)
      (scss2-grammar--compile library))
    (let ((availability (treesit-language-available-p language t)))
      (unless (car availability)
        (user-error "Cannot load the bundled scss2-mode grammar from %s: %S"
                    library (cdr availability))))
    language))

(provide 'scss2-grammar)
;;; scss2-grammar.el ends here
