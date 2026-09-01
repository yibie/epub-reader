;;; epub-reader-container.el --- Safe EPUB archive access -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; This module extracts an EPUB with either unzip or bsdtar.  Archive members
;; are listed and validated first, then copied one by one through stdout.  The
;; external program never chooses a destination path.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup epub-reader nil
  "Read EPUB publications in Emacs."
  :group 'applications)

(defcustom epub-reader-container-adapters '(unzip bsdtar)
  "Archive adapters tried by `epub-reader-container-open'."
  :type '(repeat (choice (const unzip) (const bsdtar)))
  :group 'epub-reader)

(defcustom epub-reader-container-max-files 10000
  "Maximum number of regular archive members accepted from one EPUB."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-entry-bytes (* 64 1024 1024)
  "Maximum uncompressed bytes accepted from one archive member."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-container-max-total-bytes (* 512 1024 1024)
  "Maximum uncompressed bytes accepted from one EPUB."
  :type 'integer
  :group 'epub-reader)

(define-error 'epub-reader-error "EPUB reader error")
(define-error 'epub-reader-container-error
  "Could not open EPUB container" 'epub-reader-error)
(define-error 'epub-reader-unsafe-archive
  "Unsafe EPUB archive" 'epub-reader-container-error)

(cl-defstruct (epub-reader-container
               (:constructor epub-reader-container--create))
  "An extracted EPUB archive owned by the caller."
  source root adapter closed-p)

(defun epub-reader-container--program (adapter)
  "Return executable name for ADAPTER, or nil when unavailable."
  (pcase adapter
    ('unzip (executable-find "unzip"))
    ('bsdtar (executable-find "bsdtar"))
    (_ nil)))

(defun epub-reader-container--choose-adapter ()
  "Return the first configured, available archive adapter."
  (or (cl-find-if #'epub-reader-container--program
                  epub-reader-container-adapters)
      (signal 'epub-reader-container-error
              '("Neither unzip nor bsdtar is available"))))

(defun epub-reader-container--run (adapter coding &rest arguments)
  "Run ADAPTER with ARGUMENTS and return stdout decoded with CODING."
  (let ((program (epub-reader-container--program adapter)))
    (unless program
      (signal 'epub-reader-container-error
              (list (format "Archive adapter is unavailable: %s" adapter))))
    (with-temp-buffer
      (set-buffer-multibyte (not (eq coding 'no-conversion)))
      (let* ((coding-system-for-read coding)
             (coding-system-for-write 'utf-8-unix)
             (status (apply #'process-file program nil t nil arguments)))
        (unless (and (integerp status) (zerop status))
          (signal 'epub-reader-container-error
                  (list (format "%s failed (status %s): %s"
                                adapter status
                                (string-trim (buffer-string))))))
        (buffer-string)))))

(defun epub-reader-container--entries (adapter archive)
  "Return member names from ARCHIVE using ADAPTER."
  (let ((output
         (pcase adapter
           ('unzip
            (epub-reader-container--run
             adapter 'utf-8-unix "-Z1" archive))
           ('bsdtar
            (epub-reader-container--run
             adapter 'utf-8-unix "-tf" archive)))))
    (split-string output "\r?\n" t)))

(defun epub-reader-container--directory-entry-p (entry)
  "Return non-nil when ENTRY names an archive directory."
  (string-suffix-p "/" entry))

(defun epub-reader-container--validate-entry (entry)
  "Signal `epub-reader-unsafe-archive' unless ENTRY is a safe path."
  (let* ((trimmed (string-remove-suffix "/" entry))
         (components (split-string trimmed "/" nil)))
    (when (or (string-empty-p trimmed)
              (file-name-absolute-p entry)
              (string-prefix-p "~" entry)
              (string-prefix-p "-" entry)
              (string-match-p "\\`[[:alpha:]]:" entry)
              (string-match-p "[\\\\\0\r\n]" entry)
              (cl-some (lambda (component)
                         (member component '("" "." "..")))
                       components))
      (signal 'epub-reader-unsafe-archive
              (list (format "Unsafe archive member: %S" entry)))))
  entry)

(defun epub-reader-container--validated-entries (adapter archive)
  "Return validated, unique members of ARCHIVE listed by ADAPTER."
  (let ((entries (epub-reader-container--entries adapter archive))
        (seen (make-hash-table :test #'equal))
        (file-count 0))
    (dolist (entry entries)
      (epub-reader-container--validate-entry entry)
      (when (gethash entry seen)
        (signal 'epub-reader-unsafe-archive
                (list (format "Duplicate archive member: %S" entry))))
      (puthash entry t seen)
      (unless (epub-reader-container--directory-entry-p entry)
        (cl-incf file-count)
        (when (> file-count epub-reader-container-max-files)
          (signal 'epub-reader-unsafe-archive
                  (list "Archive contains too many files")))))
    entries))

(defun epub-reader-container--member-bytes (adapter archive entry)
  "Return raw bytes for ENTRY in ARCHIVE using ADAPTER."
  (pcase adapter
    ('unzip
     (epub-reader-container--run
      adapter 'no-conversion "-p" archive entry))
    ('bsdtar
     (epub-reader-container--run
      adapter 'no-conversion "-xOf" archive entry))))

(defun epub-reader-container--target (root entry)
  "Return safe extraction path below ROOT for validated ENTRY."
  (let ((target (expand-file-name entry root)))
    (unless (file-in-directory-p target root)
      (signal 'epub-reader-unsafe-archive
              (list (format "Archive member escaped extraction root: %S"
                            entry))))
    target))

(defun epub-reader-container--extract (adapter archive root entries)
  "Extract validated ENTRIES from ARCHIVE below ROOT using ADAPTER."
  (let ((total-bytes 0))
    (dolist (entry entries)
      (let ((target (epub-reader-container--target root entry)))
        (if (epub-reader-container--directory-entry-p entry)
            (make-directory target t)
          (make-directory (file-name-directory target) t)
          (let* ((bytes (epub-reader-container--member-bytes
                         adapter archive entry))
                 (size (length bytes)))
            (when (> size epub-reader-container-max-entry-bytes)
              (signal 'epub-reader-unsafe-archive
                      (list (format "Archive member is too large: %S" entry))))
            (cl-incf total-bytes size)
            (when (> total-bytes epub-reader-container-max-total-bytes)
              (signal 'epub-reader-unsafe-archive
                      (list "Archive expands beyond the configured limit")))
            (let ((coding-system-for-write 'no-conversion))
              (with-temp-file target
                (set-buffer-multibyte nil)
                (insert bytes))))))))
  root)

;;;###autoload
(defun epub-reader-container-open (file)
  "Safely extract EPUB FILE and return an `epub-reader-container'.
The caller must eventually call `epub-reader-container-close'."
  (let ((archive (expand-file-name file)))
    (unless (file-readable-p archive)
      (signal 'file-missing (list "EPUB file is not readable" archive)))
    (let ((root (make-temp-file "epub-reader-" t))
          (adapter (epub-reader-container--choose-adapter))
          succeeded)
      (unwind-protect
          (let ((entries
                 (epub-reader-container--validated-entries adapter archive)))
            (epub-reader-container--extract adapter archive root entries)
            (setq succeeded t)
            (epub-reader-container--create
             :source archive :root root :adapter adapter :closed-p nil))
        (unless succeeded
          (when (file-directory-p root)
            (delete-directory root t)))))))

(defun epub-reader-container-path (container relative-path)
  "Return extracted path for RELATIVE-PATH inside live CONTAINER."
  (when (epub-reader-container-closed-p container)
    (signal 'epub-reader-container-error '("EPUB container is closed")))
  (epub-reader-container--validate-entry relative-path)
  (epub-reader-container--target
   (epub-reader-container-root container) relative-path))

(defun epub-reader-container-close (container)
  "Release extracted files owned by CONTAINER; this is idempotent."
  (unless (epub-reader-container-closed-p container)
    (let ((root (epub-reader-container-root container)))
      (setf (epub-reader-container-closed-p container) t)
      (when (file-directory-p root)
        (delete-directory root t))))
  nil)

(provide 'epub-reader-container)
;;; epub-reader-container.el ends here
