;;; epub-reader-annotation.el --- EPUB bookmarks and annotations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Plain domain values for bookmarks and highlighted text.  Serialization is
;; deliberately independent of the TextUI layout and of the sidecar store.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'epub-reader-locator)

(cl-defstruct (epub-reader-bookmark
               (:constructor epub-reader-bookmark--create))
  "One named reading position."
  id name preview locator created)

(cl-defstruct (epub-reader-annotation
               (:constructor epub-reader-annotation--create))
  "One highlighted source range and its optional NOTE."
  id range note created quality)

(defun epub-reader-annotation-new-id (book-key kind)
  "Return a unique identifier scoped by BOOK-KEY and KIND."
  (secure-hash
   'sha256
   (format "%s:%s:%s:%s:%s" book-key kind (float-time)
           (emacs-pid) (random))))

(defun epub-reader-bookmark-create (book-key name preview locator)
  "Create a bookmark for BOOK-KEY with NAME, PREVIEW, and LOCATOR."
  (epub-reader-bookmark--create
   :id (epub-reader-annotation-new-id book-key 'bookmark)
   :name name :preview preview :locator locator :created (float-time)))

(defun epub-reader-annotation-create (book-key range &optional note)
  "Create a highlight for BOOK-KEY over RANGE with optional NOTE."
  (epub-reader-annotation--create
   :id (epub-reader-annotation-new-id book-key 'annotation)
   :range range :note (or note "") :created (float-time)))

(defun epub-reader-bookmark-to-plist (bookmark)
  "Return plain persisted data for BOOKMARK."
  (list :id (epub-reader-bookmark-id bookmark)
        :name (epub-reader-bookmark-name bookmark)
        :preview (epub-reader-bookmark-preview bookmark)
        :locator (epub-reader-locator-to-plist
                  (epub-reader-bookmark-locator bookmark))
        :created (epub-reader-bookmark-created bookmark)))

(defun epub-reader-bookmark-from-plist (data)
  "Decode and validate BOOKMARK from plain DATA."
  (unless (and (listp data)
               (stringp (plist-get data :id))
               (not (string-empty-p (plist-get data :id)))
               (stringp (plist-get data :name))
               (stringp (plist-get data :preview))
               (listp (plist-get data :locator))
               (numberp (plist-get data :created)))
    (error "Invalid persisted EPUB bookmark: %S" data))
  (epub-reader-bookmark--create
   :id (plist-get data :id) :name (plist-get data :name)
   :preview (plist-get data :preview)
   :locator (epub-reader-locator-from-plist (plist-get data :locator))
   :created (plist-get data :created)))

(defun epub-reader-annotation-to-plist (annotation)
  "Return plain persisted data for ANNOTATION."
  (list :id (epub-reader-annotation-id annotation)
        :range (epub-reader-locator-range-to-plist
                (epub-reader-annotation-range annotation))
        :note (epub-reader-annotation-note annotation)
        :created (epub-reader-annotation-created annotation)))

(defun epub-reader-annotation-from-plist (data)
  "Decode and validate ANNOTATION from plain DATA."
  (unless (and (listp data)
               (stringp (plist-get data :id))
               (not (string-empty-p (plist-get data :id)))
               (listp (plist-get data :range))
               (stringp (plist-get data :note))
               (numberp (plist-get data :created)))
    (error "Invalid persisted EPUB annotation: %S" data))
  (epub-reader-annotation--create
   :id (plist-get data :id)
   :range (epub-reader-locator-range-from-plist (plist-get data :range))
   :note (plist-get data :note) :created (plist-get data :created)))

(provide 'epub-reader-annotation)
;;; epub-reader-annotation.el ends here
