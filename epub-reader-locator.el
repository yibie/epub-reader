;;; epub-reader-locator.el --- Stable positions in rendered EPUB text -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Rendered source characters carry an `epub-reader-source' property whose
;; value is [document-path block-key source-offset].  TextUI preserves this
;; property while wrapping.  Locators translate between that property and a
;; persistent, layout-independent position.

;;; Code:

(require 'cl-lib)

(cl-defstruct (epub-reader-locator
               (:constructor epub-reader-locator--create))
  "A layout-independent reading position."
  spine-index path block offset context)

(defun epub-reader-locator-source (path block offset)
  "Create a source-property value for PATH, BLOCK, and character OFFSET."
  (vector path block offset))

(defun epub-reader-locator-source-p (value)
  "Return non-nil when VALUE is a valid source-property vector."
  (and (vectorp value)
       (= (length value) 3)
       (stringp (aref value 0))
       (stringp (aref value 1))
       (natnump (aref value 2))))

(defun epub-reader-locator-attach-source (string path block)
  "Attach PATH, BLOCK, and per-character offsets to STRING."
  (let ((result (copy-sequence string)))
    (dotimes (offset (length result))
      (put-text-property
       offset (1+ offset) 'epub-reader-source
       (epub-reader-locator-source path block offset) result))
    result))

(defun epub-reader-locator--source-at-or-near (position)
  "Return (BUFFER-POSITION . SOURCE) at or near POSITION."
  (let ((minimum (point-min))
        (maximum (point-max)))
    (cl-labels
        ((at (candidate)
           (when (and (>= candidate minimum) (< candidate maximum))
             (let ((source
                    (get-text-property candidate 'epub-reader-source)))
               (and (epub-reader-locator-source-p source)
                    (cons candidate source))))))
      (or (at position)
          (at (1- position))
          (let ((next (next-single-property-change
                       (max minimum (min position maximum))
                       'epub-reader-source nil maximum)))
            (and next (< next maximum) (at next)))
          (let ((previous (previous-single-property-change
                           (max minimum (min position maximum))
                           'epub-reader-source nil minimum)))
            (and previous (> previous minimum) (at (1- previous))))))))

(defun epub-reader-locator--context (position)
  "Return a short display context around POSITION."
  (string-trim
   (buffer-substring-no-properties
    (max (point-min) (- position 16))
    (min (point-max) (+ position 17)))))

(defun epub-reader-locator-at-point
    (spine-index &optional position buffer)
  "Return locator at POSITION in BUFFER for zero-based SPINE-INDEX.
Synthetic layout characters are mapped to the nearest source character."
  (with-current-buffer (or buffer (current-buffer))
    (let ((found (epub-reader-locator--source-at-or-near
                  (or position (point)))))
      (when found
        (let ((source (cdr found)))
          (epub-reader-locator--create
           :spine-index spine-index
           :path (aref source 0)
           :block (aref source 1)
           :offset (aref source 2)
           :context (epub-reader-locator--context (car found))))))))

(defun epub-reader-locator-point (locator &optional buffer)
  "Return best buffer position corresponding to LOCATOR in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (let ((position (point-min))
          exact best best-distance first-in-document)
      (while (and (< position (point-max)) (not exact))
        (let ((source (get-text-property position 'epub-reader-source)))
          (if (not (epub-reader-locator-source-p source))
              (setq position
                    (or (next-single-property-change
                         position 'epub-reader-source nil (point-max))
                        (point-max)))
            (let ((path (aref source 0))
                  (block (aref source 1))
                  (offset (aref source 2)))
              (when (equal path (epub-reader-locator-path locator))
                (unless first-in-document
                  (setq first-in-document position))
                (when (equal block (epub-reader-locator-block locator))
                  (let ((distance
                         (abs (- offset
                                 (epub-reader-locator-offset locator)))))
                    (when (or (null best-distance)
                              (< distance best-distance))
                      (setq best position
                            best-distance distance))
                    (when (zerop distance)
                      (setq exact position)))))
              (setq position (1+ position))))))
      (or exact best first-in-document))))

(defun epub-reader-locator-goto (locator &optional buffer)
  "Move point to LOCATOR in BUFFER and return the resulting position."
  (let ((position (epub-reader-locator-point locator buffer)))
    (when position
      (with-current-buffer (or buffer (current-buffer))
        (goto-char position)))
    position))

(provide 'epub-reader-locator)
;;; epub-reader-locator.el ends here
