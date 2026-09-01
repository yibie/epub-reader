;;; epub-reader-container-test.el --- Container tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'epub-reader-container)
(require 'epub-reader-test-helper)

(ert-deftest epub-reader-container-open-materializes-only-bootstrap-members ()
  (let ((container
         (epub-reader-container-open
          (epub-reader-test-fixture "epub2.epub"))))
    (unwind-protect
        (progn
          (should
           (equal (epub-reader-test-materialized-files container)
                  '("META-INF/container.xml" "mimetype")))
          (should (= (epub-reader-container-member-size
                      container "OEBPS/chapter1.xhtml")
                     437))
          (should-not
           (file-exists-p
            (epub-reader-container-path container "OEBPS/chapter1.xhtml"))))
      (epub-reader-container-close container))))

(ert-deftest epub-reader-container-materialize-member-is-cached ()
  (let ((container
         (epub-reader-container-open
          (epub-reader-test-fixture "epub2.epub")))
        (real-stream (symbol-function 'epub-reader-container--stream-member))
        (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'epub-reader-container--stream-member)
                   (lambda (&rest arguments)
                     (setq calls (1+ calls))
                     (apply real-stream arguments))))
          (let ((first
                 (epub-reader-container-materialize-member
                  container "OEBPS/chapter1.xhtml"))
                (second
                 (epub-reader-container-materialize-member
                  container "OEBPS/chapter1.xhtml")))
            (should (equal first second))
            (should (file-readable-p first))
            (should (= calls 1))))
      (epub-reader-container-close container))))

(ert-deftest epub-reader-container-rejects-source-replacement-after-preflight ()
  (let* ((directory (make-temp-file "epub-reader-replacement-" t))
         (source (expand-file-name "book.epub" directory))
         (replacement (expand-file-name "replacement.epub" directory))
         container original-size original-mtime)
    (unwind-protect
        (progn
          (copy-file
           (epub-reader-test-fixture "shared-identifier-a.epub") source)
          (setq original-size (file-attribute-size (file-attributes source))
                original-mtime
                (file-attribute-modification-time (file-attributes source))
                container (epub-reader-container-open source))
          (copy-file
           (epub-reader-test-fixture "shared-identifier-b.epub") replacement)
          (set-file-times replacement original-mtime)
          (should (= (file-attribute-size (file-attributes replacement))
                     original-size))
          (rename-file replacement source t)
          (let ((error-data
                 (should-error
                  (epub-reader-container-materialize-member
                   container "OEBPS/content.opf")
                  :type 'epub-reader-archive-changed)))
            (should (string-match-p
                     "changed after preflight"
                     (error-message-string error-data))))
          (should-not
           (file-exists-p
            (epub-reader-container-path container "OEBPS/content.opf"))))
      (when container
        (epub-reader-container-close container))
      (delete-directory directory t))))

(ert-deftest epub-reader-container-reentrant-members-commit-cumulative-bytes ()
  (let* ((container
          (epub-reader-container-open
           (epub-reader-test-fixture "epub2.epub")))
         (real-stream (symbol-function 'epub-reader-container--stream-member))
         nested)
    (unwind-protect
        (cl-letf (((symbol-function 'epub-reader-container--stream-member)
                   (lambda (adapter archive entry target total-counter
                            &optional budget-callback)
                     (when (and (not nested)
                                (equal
                                 (epub-reader-container-entry-name entry)
                                 "OEBPS/chapter1.xhtml"))
                       (setq nested t)
                       (epub-reader-container-materialize-member
                        container "OEBPS/chapter2.xhtml"))
                     (if budget-callback
                         (funcall real-stream adapter archive entry target
                                  total-counter budget-callback)
                       (funcall real-stream adapter archive entry target
                                total-counter)))))
          (epub-reader-container-materialize-member
           container "OEBPS/chapter1.xhtml")
          (let ((actual
                 (cl-loop for file being the hash-values of
                          (epub-reader-container-materialized container)
                          sum (file-attribute-size
                               (file-attributes file 'string)))))
            (should (= (epub-reader-container-materialized-bytes container)
                       actual))))
      (epub-reader-container-close container))))

(ert-deftest epub-reader-container-reentrant-budget-reservation-is-atomic ()
  (let* ((container
          (epub-reader-container-open
           (epub-reader-test-fixture "epub2.epub")))
         (baseline (epub-reader-container-materialized-bytes container))
         (epub-reader-container-max-total-bytes (+ baseline 544))
         (real-stream (symbol-function 'epub-reader-container--stream-member))
         nested-error nested)
    (unwind-protect
        (cl-letf (((symbol-function 'epub-reader-container--stream-member)
                   (lambda (adapter archive entry target total-counter
                            &optional budget-callback)
                     (when (and (not nested)
                                (equal
                                 (epub-reader-container-entry-name entry)
                                 "OEBPS/chapter1.xhtml"))
                       (setq nested t
                             nested-error
                             (should-error
                              (epub-reader-container-materialize-member
                               container "OEBPS/chapter2.xhtml")
                              :type 'epub-reader-archive-limit)))
                     (if budget-callback
                         (funcall real-stream adapter archive entry target
                                  total-counter budget-callback)
                       (funcall real-stream adapter archive entry target
                                total-counter)))))
          (epub-reader-container-materialize-member
           container "OEBPS/chapter1.xhtml")
          (should nested-error)
          (should-not
           (file-exists-p
            (epub-reader-container-path container "OEBPS/chapter2.xhtml")))
          (should (= (epub-reader-container-materialized-bytes container)
                     (+ baseline 437))))
      (epub-reader-container-close container))))

(ert-deftest epub-reader-container-reentrant-same-member-retries-winner-cache ()
  (let* ((container
          (epub-reader-container-open
           (epub-reader-test-fixture "epub2.epub")))
         (real-stream (symbol-function 'epub-reader-container--stream-member))
         nested-error nested first)
    (unwind-protect
        (cl-letf (((symbol-function 'epub-reader-container--stream-member)
                   (lambda (adapter archive entry target total-counter
                            &optional budget-callback)
                     (when (and (not nested)
                                (equal
                                 (epub-reader-container-entry-name entry)
                                 "OEBPS/chapter1.xhtml"))
                       (setq nested t
                             nested-error
                             (should-error
                              (epub-reader-container-materialize-member
                               container "OEBPS/chapter1.xhtml")
                              :type 'epub-reader-materialization-busy)))
                     (if budget-callback
                         (funcall real-stream adapter archive entry target
                                  total-counter budget-callback)
                       (funcall real-stream adapter archive entry target
                                total-counter)))))
          (setq first
                (epub-reader-container-materialize-member
                 container "OEBPS/chapter1.xhtml"))
          (should nested-error)
          (should
           (equal first
                  (epub-reader-container-materialize-member
                   container "OEBPS/chapter1.xhtml"))))
      (epub-reader-container-close container))))

(ert-deftest epub-reader-container-verifies-published-final-truename ()
  (let* ((container
          (epub-reader-container-open
           (epub-reader-test-fixture "epub2.epub")))
         (real-verify
          (symbol-function 'epub-reader-container--verify-materialized-target))
         (final
          (epub-reader-container-path container "OEBPS/chapter1.xhtml"))
         verified)
    (unwind-protect
        (cl-letf
            (((symbol-function 'epub-reader-container--verify-materialized-target)
              (lambda (root target)
                (when (and (equal target final) (file-regular-p target))
                  (setq verified t))
                (funcall real-verify root target))))
          (epub-reader-container-materialize-member
           container "OEBPS/chapter1.xhtml")
          (should verified))
      (epub-reader-container-close container))))

(ert-deftest epub-reader-container-opens-and-cleans-up ()
  (let* ((container
          (epub-reader-container-open
           (epub-reader-test-fixture "epub2.epub")))
         (root (epub-reader-container-root container)))
    (unwind-protect
        (progn
          (should (file-directory-p root))
          (should (file-regular-p
                   (epub-reader-container-path
                    container "META-INF/container.xml")))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally
             (epub-reader-container-path container "mimetype"))
            (should (equal (buffer-string) "application/epub+zip"))))
      (epub-reader-container-close container))
    (should-not (file-exists-p root))
    (should-not (epub-reader-container-close container))))

(ert-deftest epub-reader-container-cleanup-can-be-retried ()
  (let* ((container
          (epub-reader-container-open
           (epub-reader-test-fixture "epub2.epub")))
         (root (epub-reader-container-root container))
         (real-delete (symbol-function 'delete-directory))
         (failed-once nil))
    (cl-letf (((symbol-function 'delete-directory)
               (lambda (directory &optional recursive trash)
                 (if failed-once
                     (funcall real-delete directory recursive trash)
                   (setq failed-once t)
                   (error "injected cleanup failure")))))
      (should-error (epub-reader-container-close container))
      (should-not (epub-reader-container-closed-p container))
      (should (file-directory-p root))
      (should-not (epub-reader-container-close container)))
    (should (epub-reader-container-closed-p container))
    (should-not (file-exists-p root))))

(ert-deftest epub-reader-container-each-adapter-can-open-fixture ()
  (dolist (adapter '(unzip bsdtar))
    (when (epub-reader-container--program adapter)
      (let ((epub-reader-container-adapters (list adapter))
            container)
        (unwind-protect
            (progn
              (setq container
                    (epub-reader-container-open
                     (epub-reader-test-fixture "epub3.epub")))
              (should (eq (epub-reader-container-adapter container) adapter))
              (should (file-exists-p
                       (epub-reader-container-materialize-member
                        container "EPUB/package.opf"))))
          (when container
            (epub-reader-container-close container)))))))

(ert-deftest epub-reader-container-rejects-traversal-and-cleans-temp-root ()
  (let ((temporary-file-directory (make-temp-file "epub-reader-test-" t)))
    (unwind-protect
        (progn
          (should-error
           (epub-reader-container-open
            (epub-reader-test-fixture "malicious-path.epub"))
           :type 'epub-reader-unsafe-archive)
          (should-not
           (directory-files temporary-file-directory nil
                            directory-files-no-dot-files-regexp)))
      (delete-directory temporary-file-directory t))))

(ert-deftest epub-reader-container-enforces-file-count-limit ()
  (let ((epub-reader-container-max-files 1))
    (should-error
     (epub-reader-container-open
     (epub-reader-test-fixture "epub2.epub"))
     :type 'epub-reader-unsafe-archive)))

(defmacro epub-reader-container-test--for-each-adapter (binding &rest body)
  "Evaluate BODY for each available archive adapter bound to BINDING."
  (declare (indent 1) (debug (symbolp body)))
  `(dolist (,binding '(unzip bsdtar))
     (when (epub-reader-container--program ,binding)
       (let ((epub-reader-container-adapters (list ,binding)))
         ,@body))))

(ert-deftest epub-reader-container-rejects-glob-members-for-each-adapter ()
  (epub-reader-container-test--for-each-adapter _adapter
    (should-error
     (epub-reader-container-open
      (epub-reader-test-fixture "glob-member.epub"))
     :type 'epub-reader-unsafe-archive)))

(ert-deftest epub-reader-container-rejects-casefold-path-collision ()
  (epub-reader-container-test--for-each-adapter _adapter
    (should-error
     (epub-reader-container-open
      (epub-reader-test-fixture "case-collision.epub"))
     :type 'epub-reader-unsafe-archive))
  (should
   (equal (epub-reader-container--canonical-path "书/e\u0301.xhtml")
          (epub-reader-container--canonical-path "书/É.XHTML")))
  (dolist (pair '(("ſ.xhtml" "s.xhtml")
                  ("ς.xhtml" "σ.xhtml")
                  ("ẞ.xhtml" "ss.xhtml")))
    (should
     (equal (epub-reader-container--canonical-path (car pair))
            (epub-reader-container--canonical-path (cadr pair))))))

(ert-deftest epub-reader-container-rejects-full-fold-collision-fixture ()
  (epub-reader-container-test--for-each-adapter _adapter
    (should-error
     (epub-reader-container-open
      (epub-reader-test-fixture "full-fold-collision.epub"))
     :type 'epub-reader-unsafe-archive)))

(ert-deftest epub-reader-container-rejects-all-ocf-forbidden-ranges ()
  (epub-reader-container-test--for-each-adapter _adapter
    (should-error
     (epub-reader-container-open
      (epub-reader-test-fixture "ocf-forbidden.epub"))
     :type 'epub-reader-unsafe-archive))
  (dolist (character '(#xe000 #xf8ff #xf0000 #xffffd #x100000 #x10fffd
                       #xfdd0 #xfdef #xfff0 #xfff9 #xffff #x1fffe #x10ffff))
    (should-error
     (epub-reader-container--validate-entry
      (format "bad%c.xhtml" character))
     :type 'epub-reader-unsafe-archive)))

(ert-deftest epub-reader-container-counts-directory-members ()
  (epub-reader-container-test--for-each-adapter _adapter
    (let ((epub-reader-container-max-directories 1))
      (should-error
       (epub-reader-container-open
        (epub-reader-test-fixture "directory-entries.epub"))
       :type 'epub-reader-archive-limit))))

(ert-deftest epub-reader-container-bounds-central-directory-before-reading-it ()
  (let ((epub-reader-container-max-central-directory-bytes 40))
    (should-error
     (epub-reader-container-open
      (epub-reader-test-fixture "epub2.epub"))
     :type 'epub-reader-archive-limit)))

(ert-deftest epub-reader-container-preflights-size-and-compression-ratio ()
  (epub-reader-container-test--for-each-adapter _adapter
    (let ((epub-reader-container-max-compression-ratio 2))
      (should-error
       (epub-reader-container-open
        (epub-reader-test-fixture "high-ratio.epub"))
       :type 'epub-reader-archive-limit))
    (let ((epub-reader-container-max-entry-bytes 100))
      (should-error
       (epub-reader-container-open
        (epub-reader-test-fixture "high-ratio.epub"))
       :type 'epub-reader-archive-limit))))

(ert-deftest epub-reader-container-actual-stream-cap-catches-false-metadata ()
  (epub-reader-container-test--for-each-adapter adapter
    (let* ((archive (epub-reader-test-fixture "high-ratio.epub"))
           (entries (epub-reader-container--preflight archive))
           (payload
            (cl-find "payload.txt" entries
                     :key #'epub-reader-container-entry-name
                     :test #'equal))
           (temporary-file-directory
            (make-temp-file "epub-reader-stream-test-" t))
           (epub-reader-container-max-entry-bytes 64))
      (setf (epub-reader-container-entry-size payload) 1
            (epub-reader-container-entry-compressed-size payload) 1)
      (unwind-protect
          (progn
            (should-error
             (epub-reader-container--extract
              adapter archive temporary-file-directory (list payload))
             :type 'epub-reader-archive-limit)
            (should-not
             (file-exists-p
              (expand-file-name "payload.txt" temporary-file-directory))))
        (delete-directory temporary-file-directory t)))))

(provide 'epub-reader-container-test)
;;; epub-reader-container-test.el ends here
