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

(defcustom epub-reader-store-lock-timeout 5.0
  "Seconds to wait for another sidecar transaction to finish."
  :type 'number
  :group 'epub-reader-store)

(defcustom epub-reader-store-ownerless-lock-grace 2.0
  "Seconds before an ownerless or malformed sidecar lock may be reclaimed.
Valid same-host locks whose recorded process has exited are reclaimed
immediately.  The grace period covers the small interval between creating a
lock directory and writing its owner record."
  :type 'number
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

(defun epub-reader-store--decode-data (data path)
  "Validate or explicitly reject versioned sidecar DATA from PATH."
  (let ((schema (and (listp data) (plist-get data :schema))))
    (cond
     ((not (integerp schema))
      (signal 'epub-reader-store-error
              (list (format "Invalid EPUB sidecar schema: %s" path))))
     ((= schema epub-reader-store--schema)
      (epub-reader-store--validate-data data path))
     ((< schema epub-reader-store--schema)
      (signal 'epub-reader-store-error
              (list (format
                     "Legacy EPUB sidecar schema %d has no migration: %s"
                     schema path))))
     (t
      (signal 'epub-reader-store-error
              (list (format "Newer EPUB sidecar schema %d is unsupported: %s"
                            schema path)))))))

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
            (epub-reader-store--decode-data data path)))
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
  (setf (epub-reader-store-pending store)
        (list :updated (float-time)
              :locator (epub-reader-locator-to-plist locator)))
  store)

(defconst epub-reader-store--lock-owner-file "owner.el")

(defun epub-reader-store--process-start-time (pid)
  "Return the operating-system start time for PID, or nil when unavailable."
  (let ((attributes (ignore-errors (process-attributes pid))))
    (or (alist-get 'start attributes)
        (and (= pid (emacs-pid))
             (boundp 'before-init-time)
             before-init-time))))

(defun epub-reader-store--new-lock-owner ()
  "Return a verifiable owner record for a new sidecar lock."
  (let ((pid (emacs-pid)))
    (list :pid pid
          :host (system-name)
          :start (epub-reader-store--process-start-time pid)
          :created (float-time)
          :nonce (secure-hash
                  'sha256
                  (format "%s:%s:%s:%s" pid (system-name) (float-time)
                          (random))))))

(defun epub-reader-store--lock-owner-path (lock)
  "Return the owner-record filename below LOCK."
  (expand-file-name epub-reader-store--lock-owner-file lock))

(defun epub-reader-store--valid-lock-owner-p (owner)
  "Return non-nil when OWNER has the fields needed for safe reclamation."
  (and (listp owner)
       (integerp (plist-get owner :pid))
       (> (plist-get owner :pid) 0)
       (stringp (plist-get owner :host))
       (plist-get owner :start)
       (numberp (plist-get owner :created))
       (stringp (plist-get owner :nonce))
       (not (string-empty-p (plist-get owner :nonce)))))

(defun epub-reader-store--read-lock-owner (lock)
  "Return LOCK's validated owner record, or nil if absent or malformed."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents (epub-reader-store--lock-owner-path lock))
        (let ((owner (read (current-buffer))))
          (and (epub-reader-store--valid-lock-owner-p owner) owner)))
    (error nil)))

(defun epub-reader-store--write-lock-owner (lock owner)
  "Write OWNER into newly acquired LOCK."
  (with-temp-file (epub-reader-store--lock-owner-path lock)
    (let ((print-length nil)
          (print-level nil))
      (prin1 owner (current-buffer))
      (insert "\n")))
  (set-file-modes (epub-reader-store--lock-owner-path lock) #o600))

(defun epub-reader-store--same-process-start-p (first second)
  "Return non-nil when FIRST and SECOND denote the same process start time."
  (condition-case nil
      (time-equal-p first second)
    (error (equal first second))))

(defun epub-reader-store--lock-owner-alive-p (owner)
  "Return non-nil unless same-host OWNER can be proven dead or reused."
  (if (not (equal (plist-get owner :host) (system-name)))
      ;; A local process cannot safely judge a PID from another host.
      t
    (let* ((pid (plist-get owner :pid))
           (attributes (ignore-errors (process-attributes pid)))
           (live-start
            (or (alist-get 'start attributes)
                (and (= pid (emacs-pid))
                     (epub-reader-store--process-start-time pid)))))
      (cond
       ((and (= pid (emacs-pid)) live-start)
        (epub-reader-store--same-process-start-p
         (plist-get owner :start) live-start))
       ((null attributes) nil)
       ;; A live PID without a comparable OS start time cannot be reclaimed
       ;; safely; wait for a later probe rather than guessing it is stale.
       ((null live-start) t)
       (t
        (epub-reader-store--same-process-start-p
         (plist-get owner :start) live-start))))))

(defun epub-reader-store--lock-age (lock)
  "Return LOCK's age in seconds, or zero when its attributes are unavailable."
  (let ((attributes (ignore-errors (file-attributes lock))))
    (if attributes
        (max 0.0
             (float-time
              (time-subtract nil (file-attribute-modification-time attributes))))
      0.0)))

(defun epub-reader-store--stale-lock-p (lock)
  "Return non-nil when LOCK can be safely reclaimed."
  (let ((owner (epub-reader-store--read-lock-owner lock)))
    (if owner
        (not (epub-reader-store--lock-owner-alive-p owner))
      (> (epub-reader-store--lock-age lock)
         epub-reader-store-ownerless-lock-grace))))

(defun epub-reader-store--reclaim-stale-lock (lock)
  "Atomically quarantine and remove stale LOCK, returning non-nil on success."
  (when (epub-reader-store--stale-lock-p lock)
    (let ((quarantine
           (format "%s.stale-%s" lock
                   (substring
                    (secure-hash 'sha256
                                 (format "%s:%s:%s" lock (emacs-pid)
                                         (float-time)))
                    0 16))))
      (condition-case nil
          (progn
            ;; Rename is the ownership claim: only the contender whose rename
            ;; succeeds may delete this exact stale directory.
            (rename-file lock quarantine)
            (delete-directory quarantine t)
            t)
        (file-error nil)))))

(defun epub-reader-store--acquire-lock (path)
  "Acquire and return an ownership token for PATH's transaction lock."
  (let* ((lock (concat path ".lock"))
         (deadline (+ (float-time) epub-reader-store-lock-timeout))
         (owner (epub-reader-store--new-lock-owner))
         acquired)
    (make-directory (file-name-directory path) t)
    (while (not acquired)
      (condition-case error-data
          (progn
            ;; Directory creation is the portable cross-process exclusive
            ;; operation; only its owner may enter read/merge/write.
            (make-directory lock)
            (condition-case owner-error
                (epub-reader-store--write-lock-owner lock owner)
              (error
               (ignore-errors (delete-directory lock t))
               (signal (car owner-error) (cdr owner-error))))
            (setq acquired t))
        (file-already-exists
         (unless (epub-reader-store--reclaim-stale-lock lock)
           (when (>= (float-time) deadline)
             (signal 'epub-reader-store-error
                     (list (format
                            "Timed out waiting for EPUB sidecar lock: %s"
                            lock))))
           (sleep-for 0.01)))
        (error (signal (car error-data) (cdr error-data)))))
    (list :path lock :nonce (plist-get owner :nonce))))

(defun epub-reader-store--release-lock (token)
  "Release the transaction lock identified by ownership TOKEN."
  (let* ((lock (plist-get token :path))
         (owner (epub-reader-store--read-lock-owner lock)))
    (unless (and owner
                 (equal (plist-get owner :nonce) (plist-get token :nonce)))
      (signal 'epub-reader-store-error
              (list (format "EPUB sidecar lock ownership changed: %s" lock))))
    (delete-directory lock t)))

(defun epub-reader-store--call-with-lock (path function)
  "Call FUNCTION while holding PATH's read/merge/write transaction lock."
  (let ((token (epub-reader-store--acquire-lock path))
        result primary-error cleanup-error)
    (unwind-protect
        (condition-case error-data
            (setq result (funcall function))
          (error (setq primary-error error-data)))
      (condition-case error-data
          (epub-reader-store--release-lock token)
        (error (setq cleanup-error error-data))))
    (cond
     (primary-error (signal (car primary-error) (cdr primary-error)))
     (cleanup-error (signal (car cleanup-error) (cdr cleanup-error)))
     (t result))))

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
      (let ((path (epub-reader-store-path store))
            (book-key (epub-reader-store-book-key store)))
        (epub-reader-store--call-with-lock
         path
         (lambda ()
           (let* ((data (epub-reader-store--read path))
                  (books (copy-tree (plist-get data :books)))
                  (existing (assoc book-key books))
                  (existing-record (and existing (cdr existing)))
                  (existing-updated
                   (and existing-record
                        (plist-get existing-record :updated)))
                  (pending-record
                   (list :updated (plist-get pending :updated)
                         :locator (plist-get pending :locator))))
             ;; The disk value is reread under the lock.  Position capture
             ;; time, rather than close order, determines the per-book winner;
             ;; a newer disk record is never replaced by an older snapshot.
             (unless (and existing-updated
                          (>= existing-updated
                              (plist-get pending :updated)))
               (if existing
                   (setcdr existing pending-record)
                 (push (cons book-key pending-record) books))
               (setq data (plist-put data :books books))
               (epub-reader-store--write-atomic path data)))))
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
