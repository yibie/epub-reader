;;; epub-reader-annotation-index-test.el --- Annotation index tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'epub-reader-annotation-index)

(defun epub-reader-annotation-index-test--range
    (chapter path block start end exact)
  "Return a locator range for CHAPTER, PATH, and BLOCK."
  (let ((make-locator
         (lambda (offset)
           (epub-reader-locator--create
            :schema 3 :book-key "book" :spine-index chapter
            :path path :block block :offset offset
            :prefix "" :suffix "" :context ""))))
    (epub-reader-locator-range--create
     :schema 1
     :start (funcall make-locator start)
     :end (funcall make-locator end)
     :exact exact :prefix "" :suffix "")))

(defun epub-reader-annotation-index-test--annotation
    (id chapter created &optional note block)
  "Return annotation ID in CHAPTER with CREATED time."
  (epub-reader-annotation--create
   :id id
   :range (epub-reader-annotation-index-test--range
           chapter (format "chapter-%d.xhtml" chapter)
           (or block (format "block-%s" id)) 1 3 id)
   :note (or note "") :created created))

(defmacro epub-reader-annotation-index-test--count-resolutions
    (counter &rest body)
  "Run BODY while incrementing COUNTER for every range resolution."
  (declare (indent 1) (debug (symbolp body)))
  `(cl-letf (((symbol-function 'epub-reader-locator-range-resolve)
              (lambda (range _source)
                (setq ,counter (1+ ,counter))
                (epub-reader-locator-range-resolution--create
                 :spans
                 (list
                  (list
                   (epub-reader-locator-block
                    (epub-reader-locator-range-start range))
                   (epub-reader-locator-offset
                    (epub-reader-locator-range-start range))
                   (1+ (epub-reader-locator-offset
                        (epub-reader-locator-range-end range)))))
                 :quality 'exact))))
     ,@body))

(ert-deftest epub-reader-annotation-index-repeated-reads-reuse-resolution ()
  (let* ((first (epub-reader-annotation-index-test--annotation "a" 0 2))
         (second (epub-reader-annotation-index-test--annotation "b" 0 1))
         (other (epub-reader-annotation-index-test--annotation "c" 1 3))
         (index (epub-reader-annotation-index-create
                 (list first second other)))
         (calls 0))
    (epub-reader-annotation-index-test--count-resolutions calls
      ;; List display is lazy and does not validate entries merely to open.
      (should (= (length (epub-reader-annotation-index-list-items index)) 3))
      (should (= calls 0))
      (let ((spans (epub-reader-annotation-index-chapter-spans
                    index 0 'source-1 'chapter-source)))
        (should (= (hash-table-count spans) 2)))
      (should (= calls 2))
      ;; Reopening either view at the same generation reuses both resolutions.
      (epub-reader-annotation-index-chapter-spans
       index 0 'source-1 'chapter-source)
      (epub-reader-annotation-index-list-items index)
      (should (= calls 2))
      ;; On-demand validation is cached too; a new source generation is not.
      (epub-reader-annotation-index-validate
       index "a" 'source-1 'chapter-source)
      (should (= calls 2))
      (epub-reader-annotation-index-validate
       index "a" 'source-2 'chapter-source)
      (should (= calls 3)))))

(ert-deftest epub-reader-annotation-index-list-validation-is-lazy-per-entry ()
  (let* ((annotations
          (list
           (epub-reader-annotation-index-test--annotation "late" 1 9)
           (epub-reader-annotation-index-test--annotation "second" 0 2)
           (epub-reader-annotation-index-test--annotation "first" 0 1)))
         (index (epub-reader-annotation-index-create annotations))
         (calls 0))
    (epub-reader-annotation-index-test--count-resolutions calls
      (let ((items (epub-reader-annotation-index-list-items index)))
        (should (equal (mapcar #'epub-reader-annotation-index-item-id items)
                       '("first" "second" "late")))
        (should-not (cl-some
                     #'epub-reader-annotation-index-item-validated-p items)))
      (should (= calls 0))
      (epub-reader-annotation-index-validate
       index "second" 'generation 'source)
      (should (= calls 1))
      (let ((items (epub-reader-annotation-index-list-items index)))
        (should
         (equal
          (mapcar
           (lambda (item)
             (cons (epub-reader-annotation-index-item-id item)
                   (epub-reader-annotation-index-item-validated-p item)))
           items)
          '(("first") ("second" . t) ("late")))))
      (should (= calls 1)))))

(ert-deftest epub-reader-annotation-index-invalidates-only-affected-state ()
  (let* ((annotation
          (epub-reader-annotation-index-test--annotation "a" 0 1 "old"))
         (index (epub-reader-annotation-index-create (list annotation)))
         (calls 0))
    (epub-reader-annotation-index-test--count-resolutions calls
      (epub-reader-annotation-index-validate index "a" 'source-1 'source)
      (should (= calls 1))

      ;; Note changes refresh display metadata but retain locator resolution.
      (setf (epub-reader-annotation-note annotation) "new")
      (epub-reader-annotation-index-put index annotation)
      (should
       (equal (epub-reader-annotation-index-item-note
               (car (epub-reader-annotation-index-list-items index)))
              "new"))
      (epub-reader-annotation-index-validate index "a" 'source-1 'source)
      (should (= calls 1))

      ;; Locator and source changes each invalidate the cached resolution.
      (setf (epub-reader-annotation-range annotation)
            (epub-reader-annotation-index-test--range
             0 "chapter-0.xhtml" "replacement" 2 4 "replacement"))
      (epub-reader-annotation-index-put index annotation)
      (epub-reader-annotation-index-validate index "a" 'source-1 'source)
      (should (= calls 2))
      (epub-reader-annotation-index-invalidate-source index 0)
      (epub-reader-annotation-index-validate index "a" 'source-1 'source)
      (should (= calls 3))

      (should (epub-reader-annotation-index-remove index "a"))
      (should-not (epub-reader-annotation-index-validate
                   index "a" 'source-1 'source))
      (should-not (epub-reader-annotation-index-list-items index))
      (let ((replacement
             (epub-reader-annotation-index-test--annotation "b" 1 2)))
        (epub-reader-annotation-index-put index replacement)
        (epub-reader-annotation-index-validate
         index "b" 'source-1 'source)
        (should (= calls 4))))))

(provide 'epub-reader-annotation-index-test)
;;; epub-reader-annotation-index-test.el ends here
