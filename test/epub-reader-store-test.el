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

(ert-deftest epub-reader-ui-store-saves-on-idle-chapter-and-kill ()
  (let ((directory (make-temp-file "epub-reader-ui-lifecycle-store-" t))
        (source (make-temp-file "epub-reader-ui-lifecycle-book-" nil ".epub"))
        (epub-reader-enable-progress t)
        (epub-reader-save-idle-delay 0.01))
    (copy-file (epub-reader-test-fixture "epub2.epub") source t)
    (unwind-protect
        (let ((epub-reader-store-directory directory)
              reader book-key store idle-callback)
          (cl-letf (((symbol-function 'run-with-idle-timer)
                     (lambda (_seconds _repeat function &rest arguments)
                       (setq idle-callback
                             (lambda () (apply function arguments)))
                       nil)))
            (setq reader (epub-reader-open source)))
          (with-current-buffer reader
            (setq store (epub-reader-session-store epub-reader-ui--session)
                  book-key (epub-reader-store-book-key store)))
          (should idle-callback)
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

(provide 'epub-reader-store-test)
;;; epub-reader-store-test.el ends here
