;;; epub-reader-store.el --- Versioned EPUB reading progress -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Persist plain locator data in a versioned sidecar.  Each flush rereads and
;; merges the on-disk book map, then replaces it atomically from the same
;; directory so independent identities are not lost.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'epub-reader-locator)

(defgroup epub-reader-store nil
  "Persistent EPUB reading progress."
  :group 'epub-reader)

(defcustom epub-reader-store-directory nil
  "Directory for EPUB progress sidecars.
When nil, write FILE.epub-reader beside each EPUB.  When non-nil, use one
hashed sidecar filename below this directory."
  :type '(choice (const :tag "Beside EPUB" nil) directory)
  :group 'epub-reader-store)

(define-error 'epub-reader-store-error
  "Could not read or write EPUB progress" 'error)

(cl-defstruct (epub-reader-store
               (:constructor epub-reader-store--create))
  "One book identity's handle to a versioned sidecar."
  path book-key pending warning closed-p)

(defconst epub-reader-store--schema 1)

(defun epub-reader-store--path (file)
  "Return sidecar path for EPUB FILE under current policy."
  (let ((source (file-truename file)))
    (if epub-reader-store-directory
        (expand-file-name
         (concat (secure-hash 'sha256 source) ".el")
         (file-name-as-directory
          (expand-file-name epub-reader-store-directory)))
      (concat source ".epub-reader"))))

(defun epub-reader-store--empty-data ()
  "Return an empty current-schema sidecar value."
  (list :schema epub-reader-store--schema :books nil))

(defun epub-reader-store--validate-data (data path)
  "Return DATA when it is a valid sidecar value for PATH."
  (unless (and (listp data)
               (= (or (plist-get data :schema) -1)
                  epub-reader-store--schema)
               (listp (plist-get data :books))
               (cl-every
                (lambda (entry)
                  (and (consp entry) (stringp (car entry))
                       (listp (cdr entry))
                       (numberp (plist-get (cdr entry) :updated))
                       (listp (plist-get (cdr entry) :locator))))
                (plist-get data :books)))
    (signal 'epub-reader-store-error
            (list (format "Invalid or unsupported EPUB sidecar: %s" path))))
  data)

(defun epub-reader-store--read (path)
  "Read and validate sidecar PATH, or return an empty value when absent."
  (if (not (file-exists-p path))
      (epub-reader-store--empty-data)
    (condition-case error-data
        (with-temp-buffer
          (insert-file-contents path)
          (let ((data (read (current-buffer))))
            (skip-chars-forward " \t\r\n")
            (unless (eobp)
              (error "Trailing sidecar data"))
            (epub-reader-store--validate-data data path)))
      (epub-reader-store-error (signal (car error-data) (cdr error-data)))
      (error
       (signal 'epub-reader-store-error
               (list (format "Cannot read EPUB sidecar %s: %s"
                             path (error-message-string error-data))))))))

(defun epub-reader-store-open (file book-key)
  "Open FILE's sidecar for BOOK-KEY and return a store handle.
A corrupt or newer sidecar is retained untouched and reported through the
handle's warning; reading may continue without saved progress."
  (let ((path (epub-reader-store--path file))
        warning)
    (condition-case error-data
        (epub-reader-store--read path)
      (epub-reader-store-error
       (setq warning (error-message-string error-data))))
    (epub-reader-store--create
     :path path :book-key book-key :warning warning :closed-p nil)))

(defun epub-reader-store-load-locator (store)
  "Return STORE's saved locator, or nil when absent or unreadable."
  (unless (or (epub-reader-store-closed-p store)
              (epub-reader-store-warning store))
    (let* ((data (epub-reader-store--read (epub-reader-store-path store)))
           (entry (assoc (epub-reader-store-book-key store)
                         (plist-get data :books))))
      (when entry
        (condition-case error-data
            (epub-reader-locator-from-plist
             (plist-get (cdr entry) :locator))
          (error
           (setf (epub-reader-store-warning store)
                 (format "Invalid saved EPUB locator: %s"
                         (error-message-string error-data)))
           nil))))))

(defun epub-reader-store-stage (store locator)
  "Stage LOCATOR as STORE's next durable reading position."
  (when (epub-reader-store-closed-p store)
    (signal 'epub-reader-store-error '("EPUB store is closed")))
  (unless (equal (epub-reader-locator-book-key locator)
                 (epub-reader-store-book-key store))
    (signal 'epub-reader-store-error
            '("Locator belongs to another EPUB identity")))
  (setf (epub-reader-store-pending store) locator)
  store)

(defun epub-reader-store--write-atomic (path data)
  "Atomically replace PATH with printable sidecar DATA."
  (let* ((directory (file-name-directory path))
         (prefix (expand-file-name
                  (concat "." (file-name-nondirectory path) ".tmp-")
                  directory))
         temporary)
    (make-directory directory t)
    (setq temporary (make-temp-file prefix))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (let ((print-length nil)
                  (print-level nil))
              (prin1 data (current-buffer))
              (insert "\n")))
          (set-file-modes temporary #o600)
          (rename-file temporary path t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun epub-reader-store-flush (store)
  "Merge and atomically flush STORE's staged locator."
  (when (epub-reader-store-closed-p store)
    (signal 'epub-reader-store-error '("EPUB store is closed")))
  (let ((pending (epub-reader-store-pending store)))
    (when pending
      (when (epub-reader-store-warning store)
        (signal 'epub-reader-store-error
                (list (epub-reader-store-warning store))))
      (let* ((path (epub-reader-store-path store))
             (data (epub-reader-store--read path))
             (book-key (epub-reader-store-book-key store))
             (books (copy-tree (plist-get data :books)))
             (record
              (list :updated (float-time)
                    :locator (epub-reader-locator-to-plist pending)))
             (existing (assoc book-key books)))
        (if existing
            (setcdr existing record)
          (push (cons book-key record) books))
        (setq data (plist-put data :books books))
        (epub-reader-store--write-atomic path data)
        (setf (epub-reader-store-pending store) nil))))
  store)

(defun epub-reader-store-close (store)
  "Flush and close STORE; failed flushes remain retryable."
  (unless (epub-reader-store-closed-p store)
    (epub-reader-store-flush store)
    (setf (epub-reader-store-closed-p store) t))
  nil)

(provide 'epub-reader-store)
;;; epub-reader-store.el ends here
