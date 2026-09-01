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

(ert-deftest epub-reader-publication-resolves-local-and-external-hrefs ()
  (epub-reader-publication-test--with "epub2.epub" publication
    (let ((target
           (epub-reader-publication-resolve-href
            publication "OEBPS/chapter1.xhtml"
            "chapter2.xhtml#second")))
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

(provide 'epub-reader-publication-test)
;;; epub-reader-publication-test.el ends here
