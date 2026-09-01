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
immediately.  The grace period covers abandoned directories from older
versions or external interference; current locks are fully initialized before
their canonical pathname becomes visible."
  :type 'number
  :group 'epub-reader-store)

(define-error 'epub-reader-store-error
  "Could not read or write EPUB progress" 'error)

(cl-defstruct (epub-reader-store
               (:constructor epub-reader-store--create))
  "One book identity's handle to a versioned sidecar."
  path book-key pending pending-bookmarks pending-annotations warning closed-p)

(defconst epub-reader-store--schema 2)

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

(defun epub-reader-store--valid-item-record-p (entry)
  "Return non-nil when ENTRY is a valid persisted collection item."
  (let ((record (and (consp entry) (cdr entry))))
    (and (stringp (car-safe entry))
         (not (string-empty-p (car entry)))
         (listp record)
         (numberp (plist-get record :updated))
         (or (eq (plist-get record :deleted) t)
             (and (null (plist-get record :deleted))
                  (listp (plist-get record :value))
                  (equal (plist-get (plist-get record :value) :id)
                         (car entry)))))))

(defun epub-reader-store--valid-book-record-p (record)
  "Return non-nil when current-schema book RECORD is valid."
  (and (listp record)
       (let ((has-updated (plist-member record :updated))
             (has-locator (plist-member record :locator)))
         (and (eq (and has-updated t) (and has-locator t))
              (or (not has-updated)
                  (and (numberp (plist-get record :updated))
                       (listp (plist-get record :locator))))))
       (listp (plist-get record :bookmarks))
       (cl-every #'epub-reader-store--valid-item-record-p
                 (plist-get record :bookmarks))
       (listp (plist-get record :annotations))
       (cl-every #'epub-reader-store--valid-item-record-p
                 (plist-get record :annotations))))

(defun epub-reader-store--validate-data (data path)
  "Return DATA when it is a valid sidecar value for PATH."
  (unless (and (listp data)
               (= (or (plist-get data :schema) -1)
                  epub-reader-store--schema)
               (listp (plist-get data :books))
               (cl-every
               (lambda (entry)
                  (and (consp entry) (stringp (car entry))
                       (epub-reader-store--valid-book-record-p (cdr entry))))
                (plist-get data :books)))
    (signal 'epub-reader-store-error
            (list (format "Invalid or unsupported EPUB sidecar: %s" path))))
  data)

(defun epub-reader-store--migrate-v1 (data path)
  "Return schema 1 DATA from PATH migrated to the current schema."
  (unless
      (and (listp (plist-get data :books))
           (cl-every
            (lambda (entry)
              (and (consp entry) (stringp (car entry))
                   (listp (cdr entry))
                   (numberp (plist-get (cdr entry) :updated))
                   (listp (plist-get (cdr entry) :locator))))
            (plist-get data :books)))
    (signal 'epub-reader-store-error
            (list (format "Invalid legacy EPUB sidecar: %s" path))))
  (list
   :schema epub-reader-store--schema
   :books
   (mapcar
    (lambda (entry)
      (cons (car entry)
            (list :updated (plist-get (cdr entry) :updated)
                  :locator (plist-get (cdr entry) :locator)
                  :bookmarks nil :annotations nil)))
    (plist-get data :books))))

(defun epub-reader-store--decode-data (data path)
  "Validate or explicitly reject versioned sidecar DATA from PATH."
  (let ((schema (and (listp data) (plist-get data :schema))))
    (cond
     ((not (integerp schema))
      (signal 'epub-reader-store-error
              (list (format "Invalid EPUB sidecar schema: %s" path))))
     ((= schema epub-reader-store--schema)
      (epub-reader-store--validate-data data path))
     ((= schema 1)
      (epub-reader-store--validate-data
       (epub-reader-store--migrate-v1 data path) path))
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

(defun epub-reader-store--load-items (store key)
  "Return STORE's active persisted item values under collection KEY."
  (unless (or (epub-reader-store-closed-p store)
              (epub-reader-store-warning store))
    (let* ((data (epub-reader-store--read (epub-reader-store-path store)))
           (entry (assoc (epub-reader-store-book-key store)
                         (plist-get data :books))))
      (cl-loop for item in (and entry (plist-get (cdr entry) key))
               unless (plist-get (cdr item) :deleted)
               collect (copy-tree (plist-get (cdr item) :value))))))

(defun epub-reader-store-load-bookmarks (store)
  "Return STORE's active bookmark values as plain plists."
  (epub-reader-store--load-items store :bookmarks))

(defun epub-reader-store-load-annotations (store)
  "Return STORE's active annotation values as plain plists."
  (epub-reader-store--load-items store :annotations))

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

(defun epub-reader-store--stage-item (store slot id value deleted)
  "Stage one STORE collection item in SLOT.
ID identifies the item.  VALUE is its plain plist, or nil when DELETED."
  (when (epub-reader-store-closed-p store)
    (signal 'epub-reader-store-error '("EPUB store is closed")))
  (unless (and (stringp id) (not (string-empty-p id))
               (or deleted
                   (and (listp value) (equal (plist-get value :id) id))))
    (signal 'epub-reader-store-error '("Invalid EPUB sidecar item")))
  (let* ((pending
          (copy-tree
           (pcase slot
             ('bookmarks (epub-reader-store-pending-bookmarks store))
             ('annotations (epub-reader-store-pending-annotations store)))))
         (existing (assoc id pending))
         (record (list :updated (float-time) :deleted (and deleted t)
                       :value (and (not deleted) value))))
    (if existing
        (setcdr existing record)
      (push (cons id record) pending))
    (pcase slot
      ('bookmarks
       (setf (epub-reader-store-pending-bookmarks store) pending))
      ('annotations
       (setf (epub-reader-store-pending-annotations store) pending))))
  store)

(defun epub-reader-store-stage-bookmark (store value)
  "Stage plain bookmark VALUE for STORE."
  (epub-reader-store--stage-item
   store 'bookmarks
   (plist-get value :id) value nil))

(defun epub-reader-store-delete-bookmark (store id)
  "Stage deletion of bookmark ID for STORE."
  (epub-reader-store--stage-item
   store 'bookmarks id nil t))

(defun epub-reader-store-stage-annotation (store value)
  "Stage plain annotation VALUE for STORE."
  (epub-reader-store--stage-item
   store 'annotations
   (plist-get value :id) value nil))

(defun epub-reader-store-delete-annotation (store id)
  "Stage deletion of annotation ID for STORE."
  (epub-reader-store--stage-item
   store 'annotations id nil t))

(defconst epub-reader-store--lock-owner-file "owner.el")

(cl-defstruct (epub-reader-store-lock-snapshot
               (:constructor epub-reader-store--lock-snapshot-create))
  "Identity and liveness inputs captured for one lock directory instance."
  owner file-identifier modified)

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

(defun epub-reader-store--lock-snapshot (lock)
  "Return a stable identity snapshot for LOCK, or nil during replacement."
  (let* ((before (ignore-errors (file-attributes lock 'integer)))
         (before-id (and before (file-attribute-file-identifier before)))
         (owner (and before (epub-reader-store--read-lock-owner lock)))
         (after (and before
                     (ignore-errors (file-attributes lock 'integer))))
         (after-id (and after (file-attribute-file-identifier after))))
    (when (and before-id (equal before-id after-id))
      (epub-reader-store--lock-snapshot-create
       :owner owner :file-identifier before-id
       :modified (file-attribute-modification-time after)))))

(defun epub-reader-store--lock-snapshot-age (snapshot)
  "Return SNAPSHOT's age in seconds."
  (max 0.0
       (float-time
        (time-subtract
         nil (epub-reader-store-lock-snapshot-modified snapshot)))))

(defun epub-reader-store--same-lock-instance-p (first second)
  "Return non-nil when FIRST and SECOND identify the same lock instance."
  (and first second
       (equal (epub-reader-store-lock-snapshot-file-identifier first)
              (epub-reader-store-lock-snapshot-file-identifier second))
       (let ((first-owner (epub-reader-store-lock-snapshot-owner first))
             (second-owner (epub-reader-store-lock-snapshot-owner second)))
         (if first-owner
             (and second-owner
                  (equal (plist-get first-owner :nonce)
                         (plist-get second-owner :nonce)))
           (and (null second-owner)
                ;; An ownerless replacement can briefly exist before its
                ;; owner record is written; inode reuse alone must not make it
                ;; indistinguishable from the older orphan.
                (time-equal-p
                 (epub-reader-store-lock-snapshot-modified first)
                 (epub-reader-store-lock-snapshot-modified second)))))))

(defun epub-reader-store--stale-lock-snapshot-p (snapshot)
  "Return non-nil when captured lock SNAPSHOT is safely stale."
  (let ((owner (epub-reader-store-lock-snapshot-owner snapshot)))
    (if owner
        (not (epub-reader-store--lock-owner-alive-p owner))
      (> (epub-reader-store--lock-snapshot-age snapshot)
         epub-reader-store-ownerless-lock-grace))))

(defun epub-reader-store--stale-lock-p (lock)
  "Return non-nil when LOCK can be safely reclaimed."
  (let ((snapshot (epub-reader-store--lock-snapshot lock)))
    (and snapshot (epub-reader-store--stale-lock-snapshot-p snapshot))))

(defun epub-reader-store--takeover-intent-prefix (lock)
  "Return the unique-intent filename prefix for LOCK takeover attempts."
  (concat lock ".takeover-"))

(defun epub-reader-store--takeover-intent-paths (lock)
  "Return takeover intent directories associated with LOCK."
  (let* ((directory (file-name-directory lock))
         (prefix (file-name-nondirectory
                  (epub-reader-store--takeover-intent-prefix lock))))
    (and (file-directory-p directory)
         (directory-files
          directory t (concat "\\`" (regexp-quote prefix) ".+\\'")))))

(defun epub-reader-store--active-takeover-intent-p (lock &optional except)
  "Return non-nil when a live takeover intent other than EXCEPT blocks LOCK."
  (cl-some
   (lambda (path)
     (and (not (equal path except))
          (let ((snapshot (epub-reader-store--lock-snapshot path)))
            ;; A directory being replaced is conservatively active.
            (or (null snapshot)
                (not (epub-reader-store--stale-lock-snapshot-p snapshot))))))
   (epub-reader-store--takeover-intent-paths lock)))

(defun epub-reader-store--prepare-owned-directory (path tag &optional owner)
  "Build a private complete owner directory for PATH, named with TAG.
When OWNER is non-nil, record that owner instead of creating a new one."
  (let* ((owner (or owner (epub-reader-store--new-lock-owner)))
         (private
          (make-temp-file
           (expand-file-name
            (format ".%s.%s-" (file-name-nondirectory path) tag)
            (file-name-directory path))
           t)))
    (condition-case error-data
        (epub-reader-store--write-lock-owner private owner)
      (error
       (ignore-errors (delete-directory private t))
       (signal (car error-data) (cdr error-data))))
    (list :path path :private-path private
          :nonce (plist-get owner :nonce))))

(defun epub-reader-store--publish-owned-directory (candidate)
  "Atomically publish complete private CANDIDATE and return its owner token."
  (rename-file (plist-get candidate :private-path)
               (plist-get candidate :path))
  (list :path (plist-get candidate :path)
        :nonce (plist-get candidate :nonce)))

(defun epub-reader-store--discard-owned-directory (candidate)
  "Remove CANDIDATE's unpublished private directory, if it remains."
  (let ((private (and candidate (plist-get candidate :private-path))))
    (when (and private (file-exists-p private))
      (delete-directory private t))))

(defun epub-reader-store--create-takeover-intent (lock)
  "Create and return this contender's unique takeover intent for LOCK."
  (let* ((owner (epub-reader-store--new-lock-owner))
         (path (concat (epub-reader-store--takeover-intent-prefix lock)
                       (plist-get owner :nonce)))
         (candidate
          (epub-reader-store--prepare-owned-directory
           path "takeover-prep" owner))
         token)
    (unwind-protect
        (setq token (epub-reader-store--publish-owned-directory candidate))
      (epub-reader-store--discard-owned-directory candidate))
    token))

(defun epub-reader-store--release-lock-if-owned (token)
  "Release TOKEN's lock only if its nonce still owns the canonical pathname."
  (let* ((path (plist-get token :path))
         (owner (epub-reader-store--read-lock-owner path)))
    (when (and owner
               (equal (plist-get owner :nonce) (plist-get token :nonce)))
      (delete-directory path t)
      t)))

(defun epub-reader-store--reclaim-under-intent (lock)
  "Reclaim stale LOCK while this process's unique intent remains visible."
  (let ((expected (epub-reader-store--lock-snapshot lock)))
    (when (and expected
               (epub-reader-store--stale-lock-snapshot-p expected))
      (let ((quarantine
             (format "%s.stale-%s" lock
                     (substring
                      (secure-hash 'sha256
                                   (format "%s:%s:%s:%s" lock (emacs-pid)
                                           (float-time) (random)))
                      0 16)))
            renamed)
        (setq renamed
              (condition-case nil
                  (progn (rename-file lock quarantine) t)
                (file-error nil)))
        (when renamed
          (let ((claimed (epub-reader-store--lock-snapshot quarantine)))
            ;; All compliant acquirers observe an active unique intent before
            ;; entering a transaction.  Therefore a mismatching replacement
            ;; moved here during the race has not become an owner and can be
            ;; discarded without a restore window.
            (delete-directory quarantine t)
            (epub-reader-store--same-lock-instance-p expected claimed)))))))

(defun epub-reader-store--call-with-takeover-intent (lock function)
  "Call FUNCTION with a unique visible takeover intent for LOCK.
FUNCTION receives the intent token.  Preserve its error if releasing the
intent also fails."
  (let ((intent (epub-reader-store--create-takeover-intent lock))
        result primary-error cleanup-error)
    (unwind-protect
        (condition-case error-data
            (setq result (funcall function intent))
          (error (setq primary-error error-data)))
      (condition-case error-data
          (epub-reader-store--release-lock intent)
        (error (setq cleanup-error error-data))))
    (cond
     (primary-error (signal (car primary-error) (cdr primary-error)))
     (cleanup-error (signal (car cleanup-error) (cdr cleanup-error)))
     (t result))))

(defun epub-reader-store--reclaim-stale-lock (lock)
  "Reclaim stale LOCK under a visible unique intent, returning success status."
  (epub-reader-store--call-with-takeover-intent
   lock (lambda (_intent)
          (epub-reader-store--reclaim-under-intent lock))))

(defun epub-reader-store--wait-for-lock (lock deadline)
  "Wait briefly for LOCK, or signal after DEADLINE."
  (when (>= (float-time) deadline)
    (signal 'epub-reader-store-error
            (list (format "Timed out waiting for EPUB sidecar lock: %s"
                          lock))))
  (sleep-for 0.01))

(defun epub-reader-store--reclaim-and-publish (lock candidate deadline)
  "Replace stale LOCK by atomically publishing complete CANDIDATE.
DEADLINE bounds waiting for contenders that had already observed the stale
instance.  Return an ownership token on success, or nil when another caller
won the canonical pathname."
  (let (published)
    (condition-case error-data
        (epub-reader-store--call-with-takeover-intent
         lock
         (lambda (intent)
           (when (epub-reader-store--reclaim-under-intent lock)
             ;; A lagging reclaimer may already have snapshotted the old lock.
             ;; Keep canonical empty until it has failed its rename and
             ;; withdrawn its intent, so it cannot quarantine our new owner.
             (while (epub-reader-store--active-takeover-intent-p
                     lock (plist-get intent :path))
               (epub-reader-store--wait-for-lock lock deadline))
             (setq published
                   (condition-case nil
                       (epub-reader-store--publish-owned-directory candidate)
                     (file-already-exists nil))))))
      (error
       (when published
         (epub-reader-store--release-lock-if-owned published))
       (signal (car error-data) (cdr error-data))))
    published))

(defun epub-reader-store--acquire-lock (path)
  "Acquire and return an ownership token for PATH's transaction lock."
  (let* ((lock (concat path ".lock"))
         (deadline (+ (float-time) epub-reader-store-lock-timeout))
         candidate acquired)
    (make-directory (file-name-directory path) t)
    (unwind-protect
        (progn
          (while (not acquired)
            (unless candidate
              (setq candidate
                    (epub-reader-store--prepare-owned-directory
                     lock "publish")))
            (if (epub-reader-store--active-takeover-intent-p lock)
                (epub-reader-store--wait-for-lock lock deadline)
              (condition-case error-data
                  (let ((token
                         (epub-reader-store--publish-owned-directory
                          candidate)))
                    (setq candidate nil)
                    ;; Close the race where a takeover intent appears after
                    ;; the precheck but before atomic publication.
                    (if (epub-reader-store--active-takeover-intent-p lock)
                        (progn
                          (epub-reader-store--release-lock-if-owned token)
                          (epub-reader-store--wait-for-lock lock deadline))
                      (setq acquired token)))
                (file-already-exists
                 (let ((token
                        (and (epub-reader-store--stale-lock-p lock)
                             (epub-reader-store--reclaim-and-publish
                              lock candidate deadline))))
                   (if token
                       (setq candidate nil
                             acquired token)
                     (epub-reader-store--wait-for-lock lock deadline))))
                (error (signal (car error-data) (cdr error-data))))))
          acquired)
      (epub-reader-store--discard-owned-directory candidate))))

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

(defun epub-reader-store--merge-item-records (disk pending)
  "Merge PENDING item records into DISK by item-level update timestamp."
  (let ((result (copy-tree disk)))
    (dolist (item pending)
      (let* ((id (car item))
             (incoming (cdr item))
             (existing (assoc id result)))
        (unless (and existing
                     (>= (plist-get (cdr existing) :updated)
                         (plist-get incoming :updated)))
          (if existing
              (setcdr existing (copy-tree incoming))
            (push (copy-tree item) result)))))
    result))

(defun epub-reader-store--merge-book-record
    (disk progress bookmarks annotations)
  "Merge pending PROGRESS, BOOKMARKS, and ANNOTATIONS into DISK record."
  (let ((record (copy-tree (or disk '(:bookmarks nil :annotations nil)))))
    (unless (plist-member record :bookmarks)
      (setq record (plist-put record :bookmarks nil)))
    (unless (plist-member record :annotations)
      (setq record (plist-put record :annotations nil)))
    (when progress
      (let ((disk-updated (and (plist-member record :updated)
                               (plist-get record :updated))))
        (unless (and disk-updated
                     (>= disk-updated (plist-get progress :updated)))
          (setq record
                (plist-put record :updated (plist-get progress :updated)))
          (setq record
                (plist-put record :locator (plist-get progress :locator))))))
    (when bookmarks
      (setq record
            (plist-put
             record :bookmarks
             (epub-reader-store--merge-item-records
              (plist-get record :bookmarks) bookmarks))))
    (when annotations
      (setq record
            (plist-put
             record :annotations
             (epub-reader-store--merge-item-records
              (plist-get record :annotations) annotations))))
    record))

(defun epub-reader-store-flush (store)
  "Merge and atomically flush STORE's staged progress and reader marks."
  (when (epub-reader-store-closed-p store)
    (signal 'epub-reader-store-error '("EPUB store is closed")))
  (let ((pending (epub-reader-store-pending store))
        (pending-bookmarks (epub-reader-store-pending-bookmarks store))
        (pending-annotations (epub-reader-store-pending-annotations store)))
    (when (or pending pending-bookmarks pending-annotations)
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
                  (merged
                   (epub-reader-store--merge-book-record
                    (and existing (cdr existing)) pending
                    pending-bookmarks pending-annotations)))
             ;; Disk is reread under the lock.  Progress and every bookmark or
             ;; annotation then choose their own newest captured version, so
             ;; independent readers cannot erase each other's additions.
             (if existing
                 (setcdr existing merged)
               (push (cons book-key merged) books))
             (setq data (plist-put data :books books))
             (epub-reader-store--write-atomic path data))))
        (setf (epub-reader-store-pending store) nil
              (epub-reader-store-pending-bookmarks store) nil
              (epub-reader-store-pending-annotations store) nil))))
  store)

(defun epub-reader-store-close (store)
  "Flush and close STORE; failed flushes remain retryable."
  (unless (epub-reader-store-closed-p store)
    (epub-reader-store-flush store)
    (setf (epub-reader-store-closed-p store) t))
  nil)

(provide 'epub-reader-store)
;;; epub-reader-store.el ends here
