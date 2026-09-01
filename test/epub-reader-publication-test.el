;;; epub-reader-publication-test.el --- Publication tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader-publication)
(require 'epub-reader-test-helper)

(defmacro epub-reader-publication-test--with (fixture binding &rest body)
  "Open FIXTURE as BINDING, evaluate BODY, then close it."
  (declare (indent 2) (debug (form symbolp body)))
  `(let ((,binding
          (epub-reader-publication-open
           (epub-reader-test-fixture ,fixture))))
     (unwind-protect
         (progn ,@body)
       (epub-reader-publication-close ,binding))))

(ert-deftest epub-reader-publication-parses-epub2-opf-spine-and-ncx ()
  (epub-reader-publication-test--with "epub2.epub" publication
    (should (equal (epub-reader-publication-version publication) "2.0"))
    (should (equal (epub-reader-publication-title publication)
                   "最小 EPUB 2"))
    (should (equal (epub-reader-publication-language publication) "zh-CN"))
    (should (equal (epub-reader-publication-identifier publication)
                   "urn:fixture:epub2"))
    (should (= (length (epub-reader-publication-spine publication)) 2))
    (should
     (equal
      (epub-reader-resource-path
       (epub-reader-publication-spine-resource publication 0))
      "OEBPS/chapter1.xhtml"))
    (let ((toc (epub-reader-publication-toc publication)))
      (should (= (length toc) 2))
      (should (equal (epub-reader-toc-entry-label (car toc)) "第一章"))
      (should (equal (epub-reader-toc-entry-path (car toc))
                     "OEBPS/chapter1.xhtml"))
      (should (equal (epub-reader-toc-entry-fragment (car toc)) "first")))))

(ert-deftest epub-reader-publication-lazily-materializes-spine-resources ()
  (epub-reader-publication-test--with "epub2.epub" publication
    (let* ((container (epub-reader-publication-container publication))
           (root (epub-reader-container-root container))
           (first
            (epub-reader-publication-spine-resource publication 0)))
      (should
       (equal (epub-reader-test-materialized-files container)
              '("META-INF/container.xml" "OEBPS/content.opf"
                "OEBPS/toc.ncx" "mimetype")))
      (should (= (epub-reader-resource-size first) 437))
      (should-not (file-exists-p
                   (expand-file-name "OEBPS/chapter1.xhtml" root)))
      (should-not (file-exists-p
                   (expand-file-name "OEBPS/chapter2.xhtml" root)))
      (let ((section
             (epub-reader-publication-load-section publication 0)))
        (should (epub-reader-section-p section))
        (should (file-readable-p
                 (expand-file-name "OEBPS/chapter1.xhtml" root)))
        (should-not (file-exists-p
                     (expand-file-name "OEBPS/chapter2.xhtml" root)))))))

(ert-deftest epub-reader-publication-parses-epub3-nav-and-linearity ()
  (epub-reader-publication-test--with "epub3.epub" publication
    (should (equal (epub-reader-publication-version publication) "3.0"))
    (should (equal (epub-reader-publication-title publication)
                   "Minimal EPUB 3"))
    (let ((spine (epub-reader-publication-spine publication)))
      (should (= (length spine) 2))
      (should (epub-reader-spine-item-linear-p (aref spine 0)))
      (should-not (epub-reader-spine-item-linear-p (aref spine 1))))
    (let ((toc (epub-reader-publication-toc publication)))
      (should (= (length toc) 2))
      (should (equal (mapcar #'epub-reader-toc-entry-label toc)
                     '("One" "Two")))
      (should (equal (epub-reader-toc-entry-path (car toc))
                     "EPUB/text/one.xhtml")))))

(ert-deftest epub-reader-publication-book-key-does-not-trust-identifier ()
  (let ((first
         (epub-reader-publication-open
          (epub-reader-test-fixture "shared-identifier-a.epub")))
        (second
         (epub-reader-publication-open
          (epub-reader-test-fixture "shared-identifier-b.epub")))
        reopened)
    (unwind-protect
        (progn
          (setq reopened
                (epub-reader-publication-open
                 (epub-reader-test-fixture "shared-identifier-a.epub")))
          (should (equal (epub-reader-publication-identifier first)
                         (epub-reader-publication-identifier second)))
          (should-not (equal (epub-reader-publication-book-key first)
                             (epub-reader-publication-identifier first)))
          (should-not (equal (epub-reader-publication-book-key first)
                             (epub-reader-publication-book-key second)))
          (should (equal (epub-reader-publication-book-key first)
                         (epub-reader-publication-book-key reopened))))
      (when reopened
        (epub-reader-publication-close reopened))
      (epub-reader-publication-close second)
      (epub-reader-publication-close first))))

(ert-deftest epub-reader-publication-cleanup-retries-and-preserves-open-error ()
  (let* ((publication
          (epub-reader-publication-open
           (epub-reader-test-fixture "epub2.epub")))
         (real-close (symbol-function 'epub-reader-container-close))
         failed-once)
    (cl-letf (((symbol-function 'epub-reader-container-close)
               (lambda (container)
                 (if failed-once
                     (funcall real-close container)
                   (setq failed-once t)
                   (error "injected cleanup failure")))))
      (should-error (epub-reader-publication-close publication))
      (should-not (epub-reader-publication-closed-p publication))
      (should-not (epub-reader-publication-close publication)))
    (should (epub-reader-publication-closed-p publication)))
  (let ((real-open (symbol-function 'epub-reader-container-open))
        captured-container
        primary-error)
    (unwind-protect
        (cl-letf (((symbol-function 'epub-reader-container-open)
                   (lambda (file)
                     (setq captured-container (funcall real-open file))))
                  ((symbol-function 'epub-reader-publication--from-container)
                   (lambda (_container) (error "primary publication error")))
                  ((symbol-function 'epub-reader-container-close)
                   (lambda (_container) (error "secondary cleanup error"))))
          (setq primary-error
                (should-error
                 (epub-reader-publication-open
                  (epub-reader-test-fixture "epub2.epub")))))
      (when captured-container
        (funcall (symbol-function 'epub-reader-container-close)
                 captured-container)))
    (should (string-match-p "primary publication error"
                            (error-message-string primary-error)))))

(ert-deftest epub-reader-publication-resolves-local-and-external-hrefs ()
  (epub-reader-publication-test--with "epub2.epub" publication
    (let* ((section
            (epub-reader-publication-load-section publication 0))
           (target
            (epub-reader-publication-resolve-resource
             publication section "chapter2.xhtml#second")))
      (should-not (epub-reader-link-target-external-p target))
      (should (equal (epub-reader-link-target-path target)
                     "OEBPS/chapter2.xhtml"))
      (should (equal (epub-reader-link-target-fragment target) "second"))
      (should (file-readable-p (epub-reader-link-target-file target))))
    (let ((target
           (epub-reader-publication-resolve-href
            publication "OEBPS/chapter1.xhtml" "https://example.com/")))
      (should (epub-reader-link-target-external-p target))
      (should (equal (epub-reader-link-target-uri target)
                     "https://example.com/")))
    (should-error
     (epub-reader-publication-resolve-href
      publication "OEBPS/chapter1.xhtml" "../../../escape.xhtml")
     :type 'epub-reader-publication-error)))

(ert-deftest epub-reader-publication-allows-only-safe-external-schemes ()
  (epub-reader-publication-test--with "epub2.epub" publication
    (dolist (href '("https://example.com/book"
                    "http://example.com/book"
                    "mailto:reader@example.com"))
      (should
       (epub-reader-link-target-external-p
        (epub-reader-publication-resolve-href
         publication "OEBPS/chapter1.xhtml" href))))
    (dolist (href '("file:///etc/passwd" "data:text/plain,bad"
                    "javascript:alert(1)" "custom-handler:payload"
                    "//example.com/ambiguous"))
      (should-error
       (epub-reader-publication-resolve-href
        publication "OEBPS/chapter1.xhtml" href)
       :type 'epub-reader-publication-error))))

(ert-deftest epub-reader-publication-url-resolver-preserves-segment-semantics ()
  (epub-reader-publication-test--with "epub3-edge.epub" publication
    (let ((resolve
           (lambda (href)
             (epub-reader-publication-resolve-href
              publication "EPUB/text/a b.xhtml" href))))
      (should
       (equal (epub-reader-link-target-path (funcall resolve "next%20part.xhtml"))
              "EPUB/text/next part.xhtml"))
      (should
       (equal (epub-reader-link-target-path (funcall resolve "part%23one.xhtml"))
              "EPUB/text/part#one.xhtml"))
      (should
       (equal (epub-reader-link-target-path (funcall resolve "a%2fb.xhtml"))
              "EPUB/text/a%2Fb.xhtml"))
      (should
       (equal (epub-reader-link-target-path (funcall resolve "a%5Cb.xhtml"))
              "EPUB/text/a%5Cb.xhtml"))
      (should
       (equal (epub-reader-link-target-path
               (funcall resolve "%2e%2e/nav.xhtml?ignored=yes"))
              "EPUB/nav.xhtml"))
      (let* ((base
              (epub-reader-publication-resolve-href
               publication "EPUB/text/a b.xhtml" "../assets/"))
             (target
              (epub-reader-publication-resolve-href
               publication (epub-reader-link-target-path base)
               "base-target.xhtml")))
        (should (equal (epub-reader-link-target-path base) "EPUB/assets/"))
        (should (equal (epub-reader-link-target-path target)
                       "EPUB/assets/base-target.xhtml")))
      (let ((target (funcall resolve "#%E7%AB%A0%E4%B8%80")))
        (should (equal (epub-reader-link-target-path target)
                       "EPUB/text/a b.xhtml"))
        (should (equal (epub-reader-link-target-fragment target) "章一")))
      (should-error (funcall resolve "%ZZ.xhtml")
                    :type 'epub-reader-publication-error)
      (should-error (funcall resolve "%FF.xhtml")
                    :type 'epub-reader-publication-error)
      (should-error (funcall resolve "../../../escape.xhtml")
                    :type 'epub-reader-publication-error)
      (should-error (funcall resolve "/EPUB/text/a%20b.xhtml")
                    :type 'epub-reader-publication-error))))

(ert-deftest epub-reader-publication-enforces-namespaces-and-required-fields ()
  (epub-reader-publication-test--with "epub3-edge.epub" publication
    (should (equal (epub-reader-publication-title publication)
                   "Namespace Edge Book"))
    (should (equal (epub-reader-publication-identifier publication)
                   "urn:fixture:edge")))
  (dolist (fixture '("epub3-missing-media.epub"
                     "epub3-duplicate-url.epub"))
    (should-error
     (epub-reader-publication-open (epub-reader-test-fixture fixture))
     :type 'epub-reader-publication-error)))

(ert-deftest epub-reader-publication-rejects-malformed-ocf-and-opf-values ()
  (dolist (fixture '("epub3-root-relative.epub"
                     "epub3-empty-required.epub"
                     "epub3-bad-version.epub"
                     "epub3-remote-fragment.epub"
                     "epub3-remote-duplicate.epub"
                     "epub3-remote-dot-duplicate.epub"
                     "epub3-remote-encoded-dot-duplicate.epub"))
    (should-error
     (epub-reader-publication-open (epub-reader-test-fixture fixture))
     :type 'epub-reader-publication-error)))

(ert-deftest epub-reader-publication-normalizes-remote-resource-keys ()
  (epub-reader-publication-test--with "epub3-edge.epub" publication
    (let ((upper
           (epub-reader-publication-resolve-href
            publication "EPUB/package.opf"
            "https://EXAMPLE.com:443/audio%2Emp3#track"))
          (lower
           (epub-reader-publication-resolve-href
            publication "EPUB/package.opf"
            "https://example.com/audio.mp3"))
          (literal-dot
           (epub-reader-publication-resolve-href
            publication "EPUB/package.opf"
            "https://example.com/a/../audio.mp3"))
          (encoded-dot
           (epub-reader-publication-resolve-href
            publication "EPUB/package.opf"
            "https://example.com/a/%2e%2E/audio.mp3")))
      (should (equal (epub-reader-link-target-resource-key upper)
                     (epub-reader-link-target-resource-key lower)))
      (should (equal (epub-reader-link-target-resource-key literal-dot)
                     (epub-reader-link-target-resource-key lower)))
      (should (equal (epub-reader-link-target-resource-key encoded-dot)
                     (epub-reader-link-target-resource-key lower)))
      (should (equal (epub-reader-link-target-fragment upper) "track"))
      (should (string-suffix-p "#track"
                               (epub-reader-link-target-uri upper))))))

(ert-deftest epub-reader-publication-records-remote-non-spine-resource ()
  (epub-reader-publication-test--with "epub3-edge.epub" publication
    (let ((remote (gethash "remote"
                           (epub-reader-publication-manifest publication))))
      (should (epub-reader-resource-remote-p remote))
      (should (equal (epub-reader-resource-uri remote)
                     "https://example.com/audio.mp3"))
      (should-not (epub-reader-resource-file remote))))
  (should-error
   (epub-reader-publication-open
    (epub-reader-test-fixture "epub3-remote-spine.epub"))
   :type 'epub-reader-publication-error))

(ert-deftest epub-reader-publication-preserves-span-navigation-groups ()
  (epub-reader-publication-test--with "epub3-edge.epub" publication
    (let* ((group (car (epub-reader-publication-toc publication)))
           (chapter (car (epub-reader-toc-entry-children group)))
           (appendix (car (epub-reader-toc-entry-children chapter))))
      (should (equal (epub-reader-toc-entry-label group) "第一部"))
      (should-not (epub-reader-toc-entry-path group))
      (should (equal (epub-reader-toc-entry-label chapter) "章一"))
      (should (equal (epub-reader-toc-entry-path chapter)
                     "EPUB/text/a b.xhtml"))
      (should (equal (epub-reader-toc-entry-fragment chapter) "章一"))
      (should (equal (epub-reader-toc-entry-label appendix) "附录")))))

(ert-deftest epub-reader-publication-loads-sections-behind-public-seam ()
  (epub-reader-publication-test--with "epub3-edge.epub" publication
    (let* ((section
            (epub-reader-publication-load-section publication 0))
           (target
            (epub-reader-publication-resolve-href
             publication (epub-reader-section-base-path section)
             "target.xhtml#base-target")))
      (should (epub-reader-section-p section))
      (should (equal (epub-reader-section-path section)
                     "EPUB/text/a b.xhtml"))
      (should (equal (epub-reader-section-base-path section)
                     "EPUB/assets/"))
      (should (consp (epub-reader-section-document section)))
      (should (equal (epub-reader-link-target-path target)
                     "EPUB/assets/target.xhtml"))
      (should (equal (epub-reader-link-target-fragment target)
                     "base-target")))))

(provide 'epub-reader-publication-test)
;;; epub-reader-publication-test.el ends here
