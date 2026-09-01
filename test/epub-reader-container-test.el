;;; epub-reader-container-test.el --- Container tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
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

(provide 'epub-reader-container-test)
;;; epub-reader-container-test.el ends here
