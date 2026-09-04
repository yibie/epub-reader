;;; epub-reader-annotation-index.el --- Cached annotation resolution index -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: epub-reader contributors
;; Keywords: multimedia, hypermedia

;;; Commentary:

;; This module indexes annotations independently of their presentation.  It
;; caches range resolutions against a caller-supplied source generation, so a
;; chapter view and an annotation list can share resolved data without coupling
;; the cache to either UI.

;;; Code:

(require 'cl-lib)
(require 'epub-reader-annotation)
(require 'epub-reader-locator)

(cl-defstruct (epub-reader-annotation-index-item
               (:constructor epub-reader-annotation-index-item--create))
  "Display metadata for one indexed annotation.

RESOLUTION-dependent fields are meaningful only when VALIDATED-P is non-nil."
  annotation
  id
  chapter-index
  path
  created
  exact
  note
  quality
  validated-p)

(cl-defstruct (epub-reader-annotation-index--entry
               (:constructor epub-reader-annotation-index--entry-create))
  annotation
  id
  chapter-index
  range-key
  note
  created
  resolution-generation
  resolution)

(cl-defstruct (epub-reader-annotation-index
               (:constructor epub-reader-annotation-index--create))
  entries
  by-chapter
  list-cache
  list-dirty-p)

(defun epub-reader-annotation-index--range-key (annotation)
  "Return a stable value describing ANNOTATION's range."
  (epub-reader-locator-range-to-plist
   (epub-reader-annotation-range annotation)))

(defun epub-reader-annotation-index--chapter-index (annotation)
  "Return ANNOTATION's spine index."
  (epub-reader-locator-spine-index
   (epub-reader-locator-range-start
    (epub-reader-annotation-range annotation))))

(defun epub-reader-annotation-index--bucket-add (index entry)
  "Add ENTRY to its chapter bucket in INDEX."
  (let* ((chapter (epub-reader-annotation-index--entry-chapter-index entry))
         (buckets (epub-reader-annotation-index-by-chapter index)))
    (puthash chapter (cons entry (gethash chapter buckets)) buckets)))

(defun epub-reader-annotation-index--bucket-remove (index entry chapter)
  "Remove ENTRY from CHAPTER's bucket in INDEX."
  (let* ((buckets (epub-reader-annotation-index-by-chapter index))
         (remaining (delq entry (gethash chapter buckets))))
    (if remaining
        (puthash chapter remaining buckets)
      (remhash chapter buckets))))

(defun epub-reader-annotation-index--clear-resolution (entry)
  "Discard ENTRY's cached range resolution."
  (setf (epub-reader-annotation-index--entry-resolution-generation entry) nil
        (epub-reader-annotation-index--entry-resolution entry) nil)
  (setf (epub-reader-annotation-quality
         (epub-reader-annotation-index--entry-annotation entry))
        nil))

;;;###autoload
(defun epub-reader-annotation-index-create (&optional annotations)
  "Create an annotation index containing ANNOTATIONS.

The index does not resolve any annotation until chapter spans or explicit
validation are requested."
  (let ((index
         (epub-reader-annotation-index--create
          :entries (make-hash-table :test #'equal)
          :by-chapter (make-hash-table :test #'eql)
          :list-dirty-p t)))
    (dolist (annotation annotations)
      (epub-reader-annotation-index-put index annotation))
    index))

(defun epub-reader-annotation-index-put (index annotation)
  "Add or replace ANNOTATION in INDEX.

Annotations are identified by `epub-reader-annotation-id'.  A note-only or
creation-time change preserves a cached resolution.  A range change invalidates
it, and a chapter change also moves the entry to the appropriate chapter
bucket.  Return ANNOTATION."
  (unless (epub-reader-annotation-p annotation)
    (signal 'wrong-type-argument
            (list 'epub-reader-annotation-p annotation)))
  (let* ((id (epub-reader-annotation-id annotation))
         (entries (epub-reader-annotation-index-entries index))
         (entry (gethash id entries))
         (chapter (epub-reader-annotation-index--chapter-index annotation))
         (range-key (epub-reader-annotation-index--range-key annotation)))
    (if entry
        (let ((old-chapter
               (epub-reader-annotation-index--entry-chapter-index entry))
              (range-changed
               (not (equal range-key
                           (epub-reader-annotation-index--entry-range-key
                            entry)))))
          (unless (eql old-chapter chapter)
            (epub-reader-annotation-index--bucket-remove
             index entry old-chapter))
          (setf (epub-reader-annotation-index--entry-annotation entry)
                annotation
                (epub-reader-annotation-index--entry-chapter-index entry)
                chapter
                (epub-reader-annotation-index--entry-range-key entry)
                range-key
                (epub-reader-annotation-index--entry-note entry)
                (epub-reader-annotation-note annotation)
                (epub-reader-annotation-index--entry-created entry)
                (epub-reader-annotation-created annotation))
          (when range-changed
            (epub-reader-annotation-index--clear-resolution entry))
          (unless (eql old-chapter chapter)
            (epub-reader-annotation-index--bucket-add index entry))
          (when (epub-reader-annotation-index--entry-resolution entry)
            (setf (epub-reader-annotation-quality annotation)
                  (epub-reader-locator-range-resolution-quality
                   (epub-reader-annotation-index--entry-resolution entry)))))
      (setq entry
            (epub-reader-annotation-index--entry-create
             :annotation annotation
             :id id
             :chapter-index chapter
             :range-key range-key
             :note (epub-reader-annotation-note annotation)
             :created (epub-reader-annotation-created annotation)))
      (puthash id entry entries)
      (epub-reader-annotation-index--bucket-add index entry))
    (setf (epub-reader-annotation-index-list-dirty-p index) t)
    annotation))

(defun epub-reader-annotation-index-remove (index annotation-id)
  "Remove ANNOTATION-ID from INDEX.

Return the removed annotation, or nil when it was not indexed."
  (let* ((entries (epub-reader-annotation-index-entries index))
         (entry (gethash annotation-id entries)))
    (when entry
      (remhash annotation-id entries)
      (epub-reader-annotation-index--bucket-remove
       index entry
       (epub-reader-annotation-index--entry-chapter-index entry))
      (setf (epub-reader-annotation-index-list-dirty-p index) t)
      (epub-reader-annotation-index--entry-annotation entry))))

(defun epub-reader-annotation-index-invalidate-source (index chapter-index)
  "Invalidate cached resolutions for CHAPTER-INDEX in INDEX.

Use this when a chapter source changes in place without changing the generation
value supplied to read operations.  Return the number of invalidated entries."
  (let ((count 0))
    (dolist (entry (gethash chapter-index
                            (epub-reader-annotation-index-by-chapter index)))
      (when (epub-reader-annotation-index--entry-resolution entry)
        (epub-reader-annotation-index--clear-resolution entry)
        (cl-incf count)))
    (when (> count 0)
      (setf (epub-reader-annotation-index-list-dirty-p index) t))
    count))

(defun epub-reader-annotation-index-validate
    (index annotation-id source-generation source)
  "Resolve ANNOTATION-ID in INDEX against SOURCE when necessary.

SOURCE-GENERATION is an opaque caller-owned value.  A cached resolution is
reused while it compares equal; changing it invalidates that annotation's
cached result lazily.  Return the range resolution, or nil for an unknown ID."
  (let ((entry (gethash annotation-id
                        (epub-reader-annotation-index-entries index))))
    (when entry
      (unless (and (epub-reader-annotation-index--entry-resolution entry)
                   (equal source-generation
                          (epub-reader-annotation-index--entry-resolution-generation
                           entry)))
        (let ((resolution
               (epub-reader-locator-range-resolve
                (epub-reader-annotation-range
                 (epub-reader-annotation-index--entry-annotation entry))
                source)))
          (setf (epub-reader-annotation-index--entry-resolution entry)
                resolution
                (epub-reader-annotation-index--entry-resolution-generation entry)
                source-generation
                (epub-reader-annotation-quality
                 (epub-reader-annotation-index--entry-annotation entry))
                (epub-reader-locator-range-resolution-quality resolution)
                (epub-reader-annotation-index-list-dirty-p index)
                t)))
      (epub-reader-annotation-index--entry-resolution entry))))

(defun epub-reader-annotation-index--entry-less-p (left right)
  "Return non-nil when LEFT should sort before RIGHT."
  (let ((left-chapter
         (epub-reader-annotation-index--entry-chapter-index left))
        (right-chapter
         (epub-reader-annotation-index--entry-chapter-index right))
        (left-created
         (or (epub-reader-annotation-index--entry-created left) 0))
        (right-created
         (or (epub-reader-annotation-index--entry-created right) 0)))
    (or (< left-chapter right-chapter)
        (and (= left-chapter right-chapter)
             (or (< left-created right-created)
                 (and (= left-created right-created)
                      (string<
                       (epub-reader-annotation-index--entry-id left)
                       (epub-reader-annotation-index--entry-id right))))))))

(defun epub-reader-annotation-index--sorted-entries (index &optional chapter)
  "Return INDEX entries sorted for display, optionally restricted to CHAPTER."
  (let (entries)
    (if chapter
        (dolist (entry (gethash chapter
                                (epub-reader-annotation-index-by-chapter index)))
          (push entry entries))
      (maphash (lambda (_id entry) (push entry entries))
               (epub-reader-annotation-index-entries index)))
    (sort entries #'epub-reader-annotation-index--entry-less-p)))

(defun epub-reader-annotation-index-chapter-spans
    (index chapter-index source-generation source)
  "Return resolved annotation spans for CHAPTER-INDEX as a block hash table.

Each hash value is a list of plists with :start, :end, :id, :quality, and
:note keys.  Resolving uses the same per-entry cache as explicit list
validation."
  (let ((spans-by-block (make-hash-table :test #'equal)))
    (dolist (entry
             (epub-reader-annotation-index--sorted-entries index chapter-index))
      (let* ((resolution
              (epub-reader-annotation-index-validate
               index
               (epub-reader-annotation-index--entry-id entry)
               source-generation
               source))
             (quality
              (epub-reader-locator-range-resolution-quality resolution)))
        (dolist (span
                 (epub-reader-locator-range-resolution-spans resolution))
          (let ((block (nth 0 span)))
            (puthash
             block
             (cons (list :start (nth 1 span)
                         :end (nth 2 span)
                         :id (epub-reader-annotation-index--entry-id entry)
                         :quality quality
                         :note (epub-reader-annotation-index--entry-note entry))
                   (gethash block spans-by-block))
             spans-by-block)))))
    (maphash (lambda (block spans)
               (puthash block (nreverse spans) spans-by-block))
             spans-by-block)
    spans-by-block))

(defun epub-reader-annotation-index-list-items (index)
  "Return sorted display metadata for all annotations in INDEX.

This operation never resolves annotations.  Items without a cached resolution
have VALIDATED-P nil; call `epub-reader-annotation-index-validate' only when a
consumer needs current resolution-dependent metadata."
  (when (epub-reader-annotation-index-list-dirty-p index)
    (let (items)
      (dolist (entry (epub-reader-annotation-index--sorted-entries index))
        (let* ((annotation
                (epub-reader-annotation-index--entry-annotation entry))
               (range (epub-reader-annotation-range annotation))
               (start (epub-reader-locator-range-start range))
               (resolution
                (epub-reader-annotation-index--entry-resolution entry)))
          (push
           (epub-reader-annotation-index-item--create
            :annotation annotation
            :id (epub-reader-annotation-index--entry-id entry)
            :chapter-index
            (epub-reader-annotation-index--entry-chapter-index entry)
            :path (epub-reader-locator-path start)
            :created (epub-reader-annotation-index--entry-created entry)
            :exact (epub-reader-locator-range-exact range)
            :note (epub-reader-annotation-index--entry-note entry)
            :quality (and resolution
                          (epub-reader-locator-range-resolution-quality
                           resolution))
            :validated-p (and resolution t))
           items)))
      (setf (epub-reader-annotation-index-list-cache index) (nreverse items)
            (epub-reader-annotation-index-list-dirty-p index) nil)))
  (copy-sequence (epub-reader-annotation-index-list-cache index)))

(provide 'epub-reader-annotation-index)
;;; epub-reader-annotation-index.el ends here
