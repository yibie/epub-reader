;;; epub-reader-container-test.el --- Container tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'epub-reader-container)
(require 'epub-reader-test-helper)

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
                       (epub-reader-container-path
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
