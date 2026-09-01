;;; epub-reader-store-test.el --- Progress store tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader)
(require 'epub-reader-store)
(require 'epub-reader-test-helper)

(defun epub-reader-store-test--locator (book-key path block offset)
  "Return a captured locator for BOOK-KEY, PATH, BLOCK, and OFFSET."
  (with-temp-buffer
    (insert (epub-reader-locator-attach-source
             "Alpha target Omega" path block book-key 0))
    (epub-reader-locator-at-point 0 offset)))

(ert-deftest epub-reader-store-round-trips-and-merges-book-identities ()
  (let ((directory (make-temp-file "epub-reader-store-test-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (first (epub-reader-store-open source "book-a"))
               (second (epub-reader-store-open source "book-b"))
               (locator-a
                (epub-reader-store-test--locator
                 "book-a" "a.xhtml" "id:a" 6))
               (locator-b
                (epub-reader-store-test--locator
                 "book-b" "b.xhtml" "id:b" 7)))
          (epub-reader-store-stage first locator-a)
          (epub-reader-store-flush first)
          (epub-reader-store-stage second locator-b)
          (epub-reader-store-flush second)
          (should
           (equal (epub-reader-locator-to-plist
                   (epub-reader-store-load-locator first))
                  (epub-reader-locator-to-plist locator-a)))
          (should
           (equal (epub-reader-locator-to-plist
                   (epub-reader-store-load-locator second))
                  (epub-reader-locator-to-plist locator-b)))
          (should-not
           (directory-files directory nil "\\.tmp-"))
          (epub-reader-store-close second)
          (epub-reader-store-close first))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-newer-staged-position-wins-across-handles ()
  (let ((directory (make-temp-file "epub-reader-store-order-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (older (epub-reader-store-open source "book"))
               (newer (epub-reader-store-open source "book"))
               (old-locator
                (epub-reader-store-test--locator
                 "book" "a.xhtml" "id:a" 1))
               (new-locator
                (epub-reader-store-test--locator
                 "book" "a.xhtml" "id:a" 14)))
          (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 10.0)))
            (epub-reader-store-stage older old-locator))
          (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 20.0)))
            (epub-reader-store-stage newer new-locator))
          (epub-reader-store-flush newer)
          (epub-reader-store-flush older)
          (should
           (= (epub-reader-locator-offset
               (epub-reader-store-load-locator newer))
              (epub-reader-locator-offset new-locator))))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-old-reader-close-does-not-overwrite-new-progress ()
  (let ((directory (make-temp-file "epub-reader-ui-two-readers-" t))
        (source (make-temp-file "epub-reader-ui-book-" nil ".epub"))
        (epub-reader-enable-progress t)
        first second reopened)
    (copy-file (epub-reader-test-fixture "epub2.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq first (epub-reader-open source)
                second (epub-reader-open source))
          (with-current-buffer second
            (epub-reader-next-chapter))
          (kill-buffer second)
          (setq second nil)
          ;; FIRST has never moved.  Closing it later must not give its stale
          ;; chapter-one locator a new timestamp.
          (kill-buffer first)
          (setq first nil)
          (setq reopened (epub-reader-open source))
          (with-current-buffer reopened
            (should (= (plist-get textui-state :spine-index) 1))))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second))
      (when (buffer-live-p reopened) (kill-buffer reopened))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-dirty-old-reader-does-not-overwrite-new-progress ()
  (let ((directory (make-temp-file "epub-reader-ui-two-dirty-readers-" t))
        (source (make-temp-file "epub-reader-ui-book-" nil ".epub"))
        (epub-reader-enable-progress t)
        first second reopened)
    (copy-file (epub-reader-test-fixture "epub2.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (setq first (epub-reader-open source)
                second (epub-reader-open source))
          ;; FIRST moves first, but its debounced save has not fired.
          (with-current-buffer first
            (forward-char 1)
            (epub-reader-ui--progress-post-command)
            (should (epub-reader-session-progress-dirty-p
                     epub-reader-ui--session)))
          ;; SECOND moves later and durably closes first.
          (with-current-buffer second
            (epub-reader-next-chapter))
          (kill-buffer second)
          (setq second nil)
          ;; Closing FIRST later must flush its older movement version without
          ;; allowing close order to turn it into the newer record.
          (kill-buffer first)
          (setq first nil)
          (setq reopened (epub-reader-open source))
          (with-current-buffer reopened
            (should (= (plist-get textui-state :spine-index) 1))))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second))
      (when (buffer-live-p reopened) (kill-buffer reopened))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-explicitly-rejects-unmigratable-schema ()
  (let ((directory (make-temp-file "epub-reader-store-schema-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (initial (epub-reader-store-open source "book"))
               (path (epub-reader-store-path initial)))
          (make-directory (file-name-directory path) t)
          (with-temp-file path (insert "(:schema 0 :books nil)\n"))
          (let ((store (epub-reader-store-open source "book")))
            (should (string-match-p "has no migration"
                                    (epub-reader-store-warning store)))
            (should-not (epub-reader-store-load-locator store))))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-lock-covers-read-merge-write-transaction ()
  (let ((directory (make-temp-file "epub-reader-store-lock-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (store (epub-reader-store-open source "book"))
               (path (epub-reader-store-path store))
               (real-read (symbol-function 'epub-reader-store--read))
               (real-write
                (symbol-function 'epub-reader-store--write-atomic))
               read-locked write-locked)
          (epub-reader-store-stage
           store (epub-reader-store-test--locator
                  "book" "a.xhtml" "id:a" 4))
          (cl-letf (((symbol-function 'epub-reader-store--read)
                     (lambda (candidate)
                       (setq read-locked
                             (file-directory-p (concat candidate ".lock")))
                       (funcall real-read candidate)))
                    ((symbol-function 'epub-reader-store--write-atomic)
                     (lambda (candidate data)
                       (setq write-locked
                             (file-directory-p (concat candidate ".lock")))
                       (funcall real-write candidate data))))
            (epub-reader-store-flush store))
          (should read-locked)
          (should write-locked)
          (should-not (file-exists-p (concat path ".lock"))))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-takes-over-lock-from-dead-owner ()
  (let ((directory (make-temp-file "epub-reader-store-orphan-lock-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (epub-reader-store-lock-timeout 0.05)
               (store (epub-reader-store-open source "book"))
               (lock (concat (epub-reader-store-path store) ".lock")))
          (make-directory lock t)
          (with-temp-file (expand-file-name "owner.el" lock)
            (prin1 (list :pid 99999999 :host (system-name)
                         :start '(0 0 0 0) :created (float-time)
                         :nonce "dead-owner")
                   (current-buffer)))
          (epub-reader-store-stage
           store (epub-reader-store-test--locator
                  "book" "a.xhtml" "id:a" 9))
          (epub-reader-store-flush store)
          (should-not (file-exists-p lock))
          (should (= (epub-reader-locator-offset
                      (epub-reader-store-load-locator store))
                     8)))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-takes-over-expired-ownerless-lock ()
  (let ((directory (make-temp-file "epub-reader-store-ownerless-lock-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (epub-reader-store-lock-timeout 0.05)
               (epub-reader-store-ownerless-lock-grace 0.01)
               (store (epub-reader-store-open source "book"))
               (lock (concat (epub-reader-store-path store) ".lock")))
          ;; Simulate a crash after mkdir but before the owner record reached
          ;; disk.  A fresh ownerless lock still receives the grace period.
          (make-directory lock t)
          (set-file-times lock (seconds-to-time (- (float-time) 1.0)))
          (epub-reader-store-stage
           store (epub-reader-store-test--locator
                  "book" "a.xhtml" "id:a" 6))
          (epub-reader-store-flush store)
          (should-not (file-exists-p lock))
          (should (epub-reader-store-load-locator store)))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-does-not-take-over-live-owner-lock ()
  (let ((directory (make-temp-file "epub-reader-store-live-lock-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (epub-reader-store-lock-timeout 0.02)
               (store (epub-reader-store-open source "book"))
               (lock (concat (epub-reader-store-path store) ".lock"))
               (start (alist-get 'start (process-attributes (emacs-pid)))))
          (should start)
          (make-directory lock t)
          (with-temp-file (expand-file-name "owner.el" lock)
            (prin1 (list :pid (emacs-pid) :host (system-name)
                         :start start :created 0.0 :nonce "live-owner")
                   (current-buffer)))
          (epub-reader-store-stage
           store (epub-reader-store-test--locator
                  "book" "a.xhtml" "id:a" 9))
          (should-error (epub-reader-store-flush store)
                        :type 'epub-reader-store-error)
          (should (file-directory-p lock))
          (should (epub-reader-store-pending store)))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-takeover-intent-serializes-two-contender-aba ()
  (let ((directory (make-temp-file "epub-reader-store-lock-aba-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (store (epub-reader-store-open source "book"))
               (path (epub-reader-store-path store))
               (lock (concat (epub-reader-store-path store) ".lock"))
               (real-rename (symbol-function 'rename-file))
               competitor-result outer-result replacement-error injected)
          (make-directory lock t)
          (epub-reader-store--write-lock-owner
           lock (list :pid 99999999 :host (system-name)
                      :start '(0 0 0 0) :created (float-time)
                      :nonce "old-dead-owner"))
          (cl-letf (((symbol-function 'rename-file)
                     (lambda (old new &optional ok-if-already)
                       (when (and (not injected) (equal old lock))
                         (setq injected t)
                         ;; A nested call deterministically represents the
                         ;; other process: it wins the stale reclaim, then a
                         ;; normal acquisition attempts to enter before the
                         ;; outer contender reaches rename (the ABA).
                         (setq competitor-result
                               (epub-reader-store--reclaim-stale-lock lock))
                         (let ((epub-reader-store-lock-timeout 0.0))
                           (condition-case error-data
                               (epub-reader-store--acquire-lock path)
                             (epub-reader-store-error
                              (setq replacement-error error-data)))))
                       (funcall real-rename old new ok-if-already))))
            (setq outer-result
                  (epub-reader-store--reclaim-stale-lock lock)))
          (should injected)
          (should competitor-result)
          (should-not outer-result)
          (should replacement-error)
          (should-not (file-exists-p lock))
          (should-not (epub-reader-store--takeover-intent-paths lock)))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-stale-reclaim-has-no-three-contender-window ()
  (let ((directory (make-temp-file "epub-reader-store-lock-three-way-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (store (epub-reader-store-open source "book"))
               (path (epub-reader-store-path store))
               (lock (concat (epub-reader-store-path store) ".lock"))
               (parent (file-name-directory lock))
               (basename (file-name-nondirectory lock))
               (real-rename (symbol-function 'rename-file))
               (replacement-owner (epub-reader-store--new-lock-owner))
               competitor-result outer-result third-token third-error
               outer-error replacement-injected)
          (setq replacement-owner
                (plist-put replacement-owner :nonce "replacement-live"))
          (make-directory lock t)
          (epub-reader-store--write-lock-owner
           lock (list :pid 99999999 :host (system-name)
                      :start '(0 0 0 0) :created (float-time)
                      :nonce "old-dead-owner"))
          (cl-letf
              (((symbol-function 'rename-file)
                (lambda (old new &optional ok-if-already)
                  (let ((outer-move-p
                         (and (not replacement-injected) (equal old lock))))
                    (when outer-move-p
                      (setq replacement-injected t
                            competitor-result
                            (epub-reader-store--reclaim-stale-lock lock))
                      (when competitor-result
                        (make-directory lock)
                        (epub-reader-store--write-lock-owner
                         lock replacement-owner)))
                    (let ((result
                           (funcall real-rename old new ok-if-already)))
                      (when outer-move-p
                        ;; The outer contender has just made canonical empty.
                        ;; A compliant third contender must observe the intent
                        ;; both before and after mkdir and must not enter.
                        (let ((epub-reader-store-lock-timeout 0.0))
                          (condition-case error-data
                              (setq third-token
                                    (epub-reader-store--acquire-lock path))
                            (epub-reader-store-error
                             (setq third-error error-data)))))
                      result)))))
            (condition-case error-data
                (setq outer-result
                      (epub-reader-store--reclaim-stale-lock lock))
              (error (setq outer-error error-data))))
          (let ((live-nonces
                 (cl-loop
                  for candidate in (directory-files
                                    parent t
                                    (concat "\\`" (regexp-quote basename)
                                            "\\(?:\\.stale-.*\\)?\\'"))
                  for owner = (and (file-directory-p candidate)
                                   (epub-reader-store--read-lock-owner
                                    candidate))
                  when (and owner
                            (epub-reader-store--lock-owner-alive-p owner))
                  collect (plist-get owner :nonce))))
            (should-not outer-error)
            (should third-error)
            (should-not third-token)
            (should (<= (length live-nonces) 1))
            (should (= (length (delq nil
                                     (list competitor-result outer-result
                                           third-token)))
                       1))))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-dead-takeover-intent-does-not-block-acquire ()
  (let ((directory (make-temp-file "epub-reader-store-dead-intent-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (store (epub-reader-store-open source "book"))
               (path (epub-reader-store-path store))
               (lock (concat path ".lock"))
               (intent (concat lock ".takeover-dead-process"))
               token)
          (make-directory intent t)
          (epub-reader-store--write-lock-owner
           intent (list :pid 99999999 :host (system-name)
                        :start '(0 0 0 0) :created (float-time)
                        :nonce "dead-intent"))
          (setq token (epub-reader-store--acquire-lock path))
          (should (file-directory-p lock))
          (epub-reader-store--release-lock token)
          (should-not (file-exists-p lock)))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-publishes-canonical-owner-atomically ()
  (let ((directory (make-temp-file "epub-reader-store-owner-publish-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (epub-reader-store-lock-timeout 0.1)
               (epub-reader-store-ownerless-lock-grace 0.01)
               (store (epub-reader-store-open source "book"))
               (path (epub-reader-store-path store))
               (lock (concat path ".lock"))
               (real-write
                (symbol-function 'epub-reader-store--write-lock-owner))
               (real-rename (symbol-function 'rename-file))
               outer-token nested-token outer-error nested-error injected)
          (cl-letf
              (((symbol-function 'epub-reader-store--write-lock-owner)
                (lambda (target owner)
                  (when (and (not injected) (equal target lock))
                    (setq injected t)
                    ;; A has published an ownerless canonical directory.  It
                    ;; pauses beyond grace, so B reclaims and acquires before
                    ;; A resumes writing through the old pathname.
                    (set-file-times
                     lock (seconds-to-time (- (float-time) 1.0)))
                    (condition-case error-data
                        (setq nested-token
                              (epub-reader-store--acquire-lock path))
                      (error (setq nested-error error-data))))
                  (funcall real-write target owner)))
               ((symbol-function 'rename-file)
                (lambda (old new &optional ok-if-already)
                  ;; With the fixed protocol, pause A immediately before its
                  ;; single publication rename.  B publishes first; A's same
                  ;; rename must then lose without ever exposing an ownerless
                  ;; canonical lock.
                  (when (and (not injected) (equal new lock))
                    (setq injected t)
                    (condition-case error-data
                        (setq nested-token
                              (epub-reader-store--acquire-lock path))
                      (error (setq nested-error error-data))))
                  (funcall real-rename old new ok-if-already))))
            (condition-case error-data
                (setq outer-token (epub-reader-store--acquire-lock path))
              (error (setq outer-error error-data))))
          (should injected)
          (should-not (and outer-token nested-token))
          (should (= (length (delq nil (list outer-token nested-token))) 1))
          (let ((canonical-owner
                 (epub-reader-store--read-lock-owner lock)))
            (should canonical-owner)
            (should
             (equal (plist-get canonical-owner :nonce)
                    (plist-get (or outer-token nested-token) :nonce))))
          (should-not (and outer-error nested-error)))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-retains-corrupt-sidecar ()
  (let ((directory (make-temp-file "epub-reader-store-corrupt-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (initial (epub-reader-store-open source "book"))
               (path (epub-reader-store-path initial)))
          (make-directory (file-name-directory path) t)
          (with-temp-file path (insert "(:schema 999 :books nil)\n"))
          (let ((store (epub-reader-store-open source "book")))
            (should (stringp (epub-reader-store-warning store)))
            (epub-reader-store-stage
             store (epub-reader-store-test--locator
                    "book" "a.xhtml" "id:a" 3))
            (should-error (epub-reader-store-flush store)
                          :type 'epub-reader-store-error)
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p ":schema 999" (buffer-string))))))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-store-restores-exact-and-degraded-progress ()
  (let ((directory (make-temp-file "epub-reader-ui-store-" t))
        (source (make-temp-file "epub-reader-ui-book-" nil ".epub"))
        (epub-reader-enable-progress t)
        exact-message degraded-message)
    (copy-file (epub-reader-test-fixture "epub2.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory))
          (let ((reader (epub-reader-open source)))
            (with-current-buffer reader
              (epub-reader-next-chapter)
              (epub-reader-ui--save-progress t))
            (kill-buffer reader))
          (let (reader)
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest arguments)
                         (setq exact-message
                               (apply #'format format-string arguments)))))
              (setq reader (epub-reader-open source)))
            (with-current-buffer reader
              (should (= (plist-get textui-state :spine-index) 1))
              (should (eq (plist-get textui-state :restore-quality) 'exact)))
            (kill-buffer reader))
          (should (string-match-p "restored exactly" exact-message))
          (let* ((publication (epub-reader-publication-open source))
                 (book-key (epub-reader-publication-book-key publication))
                 (store (epub-reader-store-open source book-key))
                 (locator (epub-reader-store-load-locator store)))
            (setf (epub-reader-locator-block locator) "missing-block")
            (epub-reader-store-stage store locator)
            (epub-reader-store-close store)
            (epub-reader-publication-close publication))
          (let (reader)
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest arguments)
                         (setq degraded-message
                               (apply #'format format-string arguments)))))
              (setq reader (epub-reader-open source)))
            (with-current-buffer reader
              (should (memq (plist-get textui-state :restore-quality)
                            '(quote-near-block quote-in-spine spine-start))))
            ;; Avoid replacing the deliberately degraded record on cleanup.
            (with-current-buffer reader
              (setf (epub-reader-session-store epub-reader-ui--session) nil))
            (kill-buffer reader))
          (should (string-match-p "degraded match" degraded-message)))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-restores-frozen-v0.1.0-sidecar ()
  (let ((directory (make-temp-file "epub-reader-v010-store-" t))
        (source (make-temp-file "epub-reader-v010-book-" nil ".epub"))
        (epub-reader-enable-progress t)
        publication probe reader)
    (copy-file (epub-reader-test-fixture "epub2.epub") source t)
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (_publication
                (setq publication (epub-reader-publication-open source)))
               (book-key (epub-reader-publication-book-key publication))
               (_probe (setq probe (epub-reader-store-open source book-key)))
               (sidecar (epub-reader-store-path probe)))
          (epub-reader-store-close probe)
          (setq probe nil)
          (epub-reader-publication-close publication)
          (setq publication nil)
          (make-directory (file-name-directory sidecar) t)
          ;; This file is checked in as literal 0.1.0 output.  Substitute only
          ;; the path-dependent fingerprint; do not encode it through current
          ;; store or locator writers.
          (with-temp-buffer
            (insert-file-contents
             (epub-reader-test-fixture "v0.1.0-sidecar.el"))
            (goto-char (point-min))
            (while (search-forward "__BOOK_KEY__" nil t)
              (replace-match book-key t t))
            (write-region (point-min) (point-max) sidecar nil 'silent))
          (setq reader (epub-reader-open source))
          (with-current-buffer reader
            (should (= (plist-get textui-state :spine-index) 1))
            (should (eq (plist-get textui-state :restore-quality) 'exact))
            (let ((locator (epub-reader-ui--current-locator)))
              (should (equal (epub-reader-locator-path locator)
                             "OEBPS/chapter2.xhtml"))
              (should (equal (epub-reader-locator-block locator) "id:second"))
              (should (= (epub-reader-locator-offset locator) 0)))
            (should (string-match-p "44\\.5%" (epub-reader-ui--header-line)))))
      (when (buffer-live-p reader) (kill-buffer reader))
      (when probe (epub-reader-store-close probe))
      (when publication (epub-reader-publication-close publication))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-ui-store-saves-on-idle-chapter-and-kill ()
  (let ((directory (make-temp-file "epub-reader-ui-lifecycle-store-" t))
        (source (make-temp-file "epub-reader-ui-lifecycle-book-" nil ".epub"))
        (epub-reader-enable-progress t)
        (epub-reader-save-idle-delay 0.01))
    (copy-file (epub-reader-test-fixture "epub2.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory)
              reader book-key store idle-callback idle-repeat)
          (cl-letf (((symbol-function 'run-with-idle-timer)
                     (lambda (seconds repeat function &rest arguments)
                       (when (= seconds epub-reader-save-idle-delay)
                         (setq idle-repeat repeat)
                         (setq idle-callback
                               (lambda () (apply function arguments))))
                       nil)))
            (setq reader (epub-reader-open source))
            (should-not idle-callback)
            (with-current-buffer reader
              (setq store (epub-reader-session-store epub-reader-ui--session)
                    book-key (epub-reader-store-book-key store))
              (forward-char 1)
              (epub-reader-ui--progress-post-command)))
          (should idle-callback)
          (should-not idle-repeat)
          (funcall idle-callback)
          (with-current-buffer reader
            (should (file-exists-p (epub-reader-store-path store)))
            (epub-reader-next-chapter)
            (should
             (equal (epub-reader-locator-path
                     (epub-reader-store-load-locator store))
                    "OEBPS/chapter1.xhtml")))
          (kill-buffer reader)
          (let* ((reopened (epub-reader-store-open source book-key))
                 (locator (epub-reader-store-load-locator reopened)))
            (should (equal (epub-reader-locator-path locator)
                           "OEBPS/chapter2.xhtml"))
            (epub-reader-store-close reopened)))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-migrates-v1-when-reader-marks-are-written ()
  (let ((directory (make-temp-file "epub-reader-store-v1-migration-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (probe (epub-reader-store-open source "book"))
               (path (epub-reader-store-path probe))
               (locator (epub-reader-store-test--locator
                         "book" "a.xhtml" "id:a" 6)))
          (epub-reader-store-close probe)
          (with-temp-file path
            (prin1
             (list :schema 1 :books
                   (list (cons "book"
                               (list :updated 10.0
                                     :locator
                                     (epub-reader-locator-to-plist locator)))))
             (current-buffer)))
          (let ((store (epub-reader-store-open source "book")))
            (should (epub-reader-store-load-locator store))
            (should-not (epub-reader-store-load-bookmarks store))
            (epub-reader-store-stage-bookmark
             store '(:id "bookmark-1" :name "Start"))
            (epub-reader-store-close store))
          (with-temp-buffer
            (insert-file-contents path)
            (let ((data (read (current-buffer))))
              (should (= (plist-get data :schema) 2))
              (should (= (length (plist-get
                                  (cdr (assoc "book"
                                              (plist-get data :books)))
                                  :bookmarks))
                         1)))))
      (delete-directory directory t)
      (delete-file source))))

(ert-deftest epub-reader-store-merges-concurrent-annotations-per-item ()
  (let ((directory (make-temp-file "epub-reader-store-annotations-" t))
        (source (make-temp-file "epub-reader-store-source-" nil ".epub")))
    (unwind-protect
        (let* ((epub-reader-store-directory directory)
               (first-buffer-store (epub-reader-store-open source "book"))
               (second-buffer-store (epub-reader-store-open source "book")))
          (epub-reader-store-stage-annotation
           first-buffer-store '(:id "annotation-a" :quote "Alpha"))
          (epub-reader-store-stage-annotation
           second-buffer-store '(:id "annotation-b" :quote "Beta"))
          (epub-reader-store-flush second-buffer-store)
          (epub-reader-store-flush first-buffer-store)
          (let* ((reopened (epub-reader-store-open source "book"))
                 (values (epub-reader-store-load-annotations reopened)))
            (should (equal (sort (mapcar (lambda (value)
                                          (plist-get value :id))
                                        values)
                                 #'string<)
                           '("annotation-a" "annotation-b")))
            (epub-reader-store-delete-annotation reopened "annotation-a")
            (epub-reader-store-flush reopened)
            (should (equal (mapcar (lambda (value) (plist-get value :id))
                                   (epub-reader-store-load-annotations reopened))
                           '("annotation-b")))
            (epub-reader-store-close reopened))
          (epub-reader-store-close second-buffer-store)
          (epub-reader-store-close first-buffer-store))
      (delete-directory directory t)
      (delete-file source))))

(provide 'epub-reader-store-test)
;;; epub-reader-store-test.el ends here
