;;; epub-reader-locator.el --- Stable positions in rendered EPUB text -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chenyibin
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: chenyibin
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Rendered source characters carry [document-path block-key source-offset].
;; Capture compares nearby source characters around synthetic layout space.
;; Resolution reports whether it was exact or degraded through quote and spine
;; fallbacks instead of hiding that distinction from callers.  Schema 3 uses
;; book-key plus source document path (the normalized spine href) as durable
;; identity; the numeric spine index is only a navigation hint.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defcustom epub-reader-locator-max-synthetic-distance 64
  "Maximum character distance for attaching synthetic layout space."
  :type 'integer
  :group 'epub-reader)

(defcustom epub-reader-locator-max-synthetic-rows 2
  "Maximum visual row distance for attaching synthetic layout space."
  :type 'integer
  :group 'epub-reader)

(cl-defstruct (epub-reader-locator
               (:constructor epub-reader-locator--create))
  "A layout-independent reading position.
PATH is the durable normalized spine href; SPINE-INDEX is a session hint."
  schema book-key spine-index path block offset prefix suffix context)

(cl-defstruct (epub-reader-locator-resolution
               (:constructor epub-reader-locator-resolution--create))
  "Resolved buffer position and its degradation QUALITY."
  position quality)

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

(defun epub-reader-locator-attach-source
    (string path block &optional book-key spine-index)
  "Attach source identity and offsets to STRING.
PATH and BLOCK identify the semantic block; BOOK-KEY and SPINE-INDEX prevent
resolution in a different publication or spine item."
  (let ((result (copy-sequence string)))
    (dotimes (offset (length result))
      (add-text-properties
       offset (1+ offset)
       (list 'epub-reader-source
             (epub-reader-locator-source path block offset)
             'epub-reader-book-key book-key
             'epub-reader-spine-index spine-index)
       result))
    result))

(defun epub-reader-locator--at (position)
  "Return (POSITION . SOURCE) when POSITION carries valid source data."
  (when (and (>= position (point-min)) (< position (point-max)))
    (let ((source (get-text-property position 'epub-reader-source)))
      (and (epub-reader-locator-source-p source)
           (cons position source)))))

(defun epub-reader-locator--previous-source (position)
  "Return closest source character strictly before POSITION."
  (let ((candidate (1- (min position (point-max))))
        found)
    (while (and (>= candidate (point-min)) (not found))
      (setq found (epub-reader-locator--at candidate))
      (unless found
        (let ((change (previous-single-property-change
                       (1+ candidate) 'epub-reader-source nil (point-min))))
          (setq candidate (if change (1- change) (1- (point-min)))))))
    found))

(defun epub-reader-locator--next-source (position)
  "Return closest source character at or after POSITION."
  (let ((candidate (max position (point-min)))
        found)
    (while (and (< candidate (point-max)) (not found))
      (setq found (epub-reader-locator--at candidate))
      (unless found
        (setq candidate
              (or (next-single-property-change
                   candidate 'epub-reader-source nil (point-max))
                  (point-max)))))
    found))

(defun epub-reader-locator--candidate-distance (origin candidate)
  "Return comparable (ROW-DISTANCE CHAR-DISTANCE SIDE) for CANDIDATE."
  (when candidate
    (let* ((position (car candidate))
           (character-distance (abs (- position origin)))
           (row-distance
            (abs (- (line-number-at-pos position)
                    (line-number-at-pos
                     (max (point-min) (min origin (point-max))))))))
      (when (and (<= character-distance
                     epub-reader-locator-max-synthetic-distance)
                 (<= row-distance epub-reader-locator-max-synthetic-rows))
        (list row-distance character-distance
              (if (< position origin) 0 1))))))

(defun epub-reader-locator--source-at-or-near (position)
  "Return nearest (BUFFER-POSITION . SOURCE) around POSITION.
Direct source wins.  Synthetic ties prefer the preceding source.  Frame chrome
never attaches to chapter content."
  (let ((bounded (max (point-min) (min position (point-max)))))
    (cond
     ((and (< bounded (point-max))
           (get-text-property bounded 'epub-reader-chrome)) nil)
     ((epub-reader-locator--at bounded))
     (t
      (let* ((previous (epub-reader-locator--previous-source bounded))
             (next (epub-reader-locator--next-source bounded))
             (previous-distance
              (epub-reader-locator--candidate-distance bounded previous))
             (next-distance
              (epub-reader-locator--candidate-distance bounded next)))
        (cond
         ((and previous-distance next-distance)
          (if (or (< (car previous-distance) (car next-distance))
                  (and (= (car previous-distance) (car next-distance))
                       (<= (cadr previous-distance) (cadr next-distance))))
              previous next))
         (previous-distance previous)
         (next-distance next)))))))

(defun epub-reader-locator--source-blocks ()
  "Return source blocks as (PATH BLOCK TEXT POSITIONS BOOK-KEY SPINE-INDEX)."
  (let ((position (point-min))
        (table (make-hash-table :test #'equal))
        order)
    (while (< position (point-max))
      (let ((source (get-text-property position 'epub-reader-source)))
        (if (not (epub-reader-locator-source-p source))
            (setq position
                  (or (next-single-property-change
                       position 'epub-reader-source nil (point-max))
                      (point-max)))
          (let* ((book-key
                  (get-text-property position 'epub-reader-book-key))
                 (spine-index
                  (get-text-property position 'epub-reader-spine-index))
                 (path (aref source 0))
                 (block (aref source 1))
                 (offset (aref source 2))
                 (key (list book-key spine-index path block))
                 (record (gethash key table)))
            (unless record
              (setq record
                    (list path block (make-hash-table :test #'eql)
                          book-key spine-index))
              (puthash key record table)
              (push key order))
            (unless (gethash offset (nth 2 record))
              (puthash offset (cons (char-after position) position)
                       (nth 2 record)))
            (setq position (1+ position))))))
    (mapcar
     (lambda (key)
       (let* ((record (gethash key table))
              (offset-table (nth 2 record))
              offsets)
         (maphash (lambda (offset _value) (push offset offsets)) offset-table)
         (setq offsets (sort offsets #'<))
         (list
          (nth 0 record) (nth 1 record)
          (apply #'string
                 (mapcar (lambda (offset)
                           (car (gethash offset offset-table)))
                         offsets))
          (vconcat
           (mapcar (lambda (offset)
                     (cdr (gethash offset offset-table)))
                   offsets))
          (nth 3 record) (nth 4 record))))
     (nreverse order))))

(defun epub-reader-locator--capture-quotes (source book-key)
  "Return (PREFIX SUFFIX) around SOURCE offset from current buffer."
  (let* ((path (aref source 0))
         (block (aref source 1))
         (offset (aref source 2))
         (record
          (cl-find-if
           (lambda (candidate)
             (and (equal (nth 0 candidate) path)
                  (equal (nth 1 candidate) block)
                  (equal (nth 4 candidate) book-key)))
           (epub-reader-locator--source-blocks)))
         (text (and record (nth 2 record))))
    (if (not text)
        '("" "")
      (list (substring text (max 0 (- offset 12)) (min offset (length text)))
            (substring text (min offset (length text))
                       (min (length text) (+ offset 20)))))))

(defun epub-reader-locator-at-point
    (spine-index &optional position buffer)
  "Return locator at POSITION in BUFFER for zero-based SPINE-INDEX."
  (with-current-buffer (or buffer (current-buffer))
    (let ((found (epub-reader-locator--source-at-or-near
                  (or position (point)))))
      (when found
        (let* ((source-position (car found))
               (source (cdr found))
               (book-key
                (get-text-property source-position 'epub-reader-book-key))
               (source-spine-index
                (get-text-property source-position
                                   'epub-reader-spine-index))
               (effective-spine-index
                (if (natnump source-spine-index)
                    source-spine-index
                  spine-index))
               (quotes
                (epub-reader-locator--capture-quotes
                 source book-key)))
          (epub-reader-locator--create
           :schema 3 :book-key book-key :spine-index effective-spine-index
           :path (aref source 0) :block (aref source 1)
           :offset (aref source 2)
           :prefix (car quotes) :suffix (cadr quotes)
           :context (concat (car quotes) (cadr quotes))))))))

(defun epub-reader-locator--quote-position (record locator)
  "Return source position in RECORD matching LOCATOR's quote."
  (let* ((text (nth 2 record))
         (positions (nth 3 record))
         (prefix (or (epub-reader-locator-prefix locator) ""))
         (suffix (or (epub-reader-locator-suffix locator) ""))
         (quote (concat prefix suffix)))
    (when (and (not (string-empty-p quote))
               (string-match-p (regexp-quote quote) text))
      (let* ((start (string-match (regexp-quote quote) text))
             (offset (+ start (length prefix))))
        (when (< offset (length positions))
          (aref positions offset))))))

(defun epub-reader-locator--quote-matches-offset-p (record locator offset)
  "Return non-nil when LOCATOR's quote still surrounds OFFSET in RECORD."
  (let* ((text (nth 2 record))
         (prefix (or (epub-reader-locator-prefix locator) ""))
         (suffix (or (epub-reader-locator-suffix locator) ""))
         (start (- offset (length prefix)))
         (end (+ offset (length suffix))))
    (and (not (string-empty-p (concat prefix suffix)))
         (>= start 0)
         (<= end (length text))
         (equal (substring text start offset) prefix)
         (equal (substring text offset end) suffix))))

(defun epub-reader-locator--record-identity-matches-p (record locator)
  "Return non-nil when RECORD belongs to LOCATOR's book and spine."
  (and (equal (nth 4 record) (epub-reader-locator-book-key locator))
       (equal (nth 0 record) (epub-reader-locator-path locator))))

(defun epub-reader-locator-resolve (locator &optional buffer)
  "Resolve LOCATOR in BUFFER and return position plus degradation quality."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((all-records (epub-reader-locator--source-blocks))
           (records
            (cl-remove-if-not
             (lambda (record)
               (epub-reader-locator--record-identity-matches-p
                record locator))
             all-records))
           (path (epub-reader-locator-path locator))
           (block (epub-reader-locator-block locator))
           (offset (epub-reader-locator-offset locator))
           (same-block
            (cl-find-if (lambda (record)
                          (and (equal (nth 0 record) path)
                               (equal (nth 1 record) block)))
                        records))
           (same-path (cl-remove-if-not
                       (lambda (record) (equal (nth 0 record) path))
                       records)))
      (cond
       ((= (or (epub-reader-locator-schema locator) 0) 2)
        (epub-reader-locator-resolution--create
         :position nil :quality 'legacy-identity))
       ((not (= (or (epub-reader-locator-schema locator) 0) 3))
        (epub-reader-locator-resolution--create
         :position nil :quality 'unsupported-schema))
       ((and all-records (null records))
        (epub-reader-locator-resolution--create
         :position nil :quality 'identity-mismatch))
       ((and same-block (< offset (length (nth 3 same-block)))
             (epub-reader-locator--quote-matches-offset-p
              same-block locator offset))
        (epub-reader-locator-resolution--create
         :position (aref (nth 3 same-block) offset) :quality 'exact))
       ((and same-block
             (epub-reader-locator--quote-position same-block locator))
        (epub-reader-locator-resolution--create
         :position (epub-reader-locator--quote-position same-block locator)
         :quality 'quote-near-block))
       ((cl-loop for record in same-path
                 for position = (epub-reader-locator--quote-position
                                 record locator)
                 when position return position)
        (epub-reader-locator-resolution--create
         :position
         (cl-loop for record in same-path
                  for position = (epub-reader-locator--quote-position
                                  record locator)
                  when position return position)
         :quality 'quote-in-spine))
       (same-path
        (epub-reader-locator-resolution--create
         :position (aref (nth 3 (car same-path)) 0) :quality 'spine-start))
       (t
        (epub-reader-locator-resolution--create
         :position nil :quality 'none))))))

(defun epub-reader-locator-point (locator &optional buffer)
  "Return best buffer position corresponding to LOCATOR in BUFFER."
  (epub-reader-locator-resolution-position
   (epub-reader-locator-resolve locator buffer)))

(defun epub-reader-locator-goto (locator &optional buffer)
  "Move point to LOCATOR in BUFFER and return its resolution."
  (let ((resolution (epub-reader-locator-resolve locator buffer)))
    (when (epub-reader-locator-resolution-position resolution)
      (with-current-buffer (or buffer (current-buffer))
        (goto-char (epub-reader-locator-resolution-position resolution))))
    resolution))

(defun epub-reader-locator-tag-image-runs (&optional buffer)
  "Attach explicit source mapping to every fixed image row in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (let ((position (point-min))
            (inhibit-read-only t))
        (while (< position (point-max))
          (let ((anchor
                 (get-text-property position 'epub-reader-image-anchor)))
            (if (not anchor)
                (setq position
                      (or (next-single-property-change
                           position 'epub-reader-image-anchor nil (point-max))
                          (point-max)))
              (let ((source (nth 0 anchor))
                    (rows (nth 1 anchor))
                    (book-key (nth 2 anchor))
                    (spine-index (nth 3 anchor)))
                (goto-char position)
                (beginning-of-line)
                (dotimes (_ rows)
                  (let ((start (line-beginning-position))
                        (end (line-end-position)))
                    (when (< start end)
                      (add-text-properties
                       start end
                       (list 'epub-reader-source source
                             'epub-reader-book-key book-key
                             'epub-reader-spine-index spine-index
                             'epub-reader-image-slice t))))
                  (forward-line 1))
                (setq position (point))))))))
  nil))

(provide 'epub-reader-locator)
;;; epub-reader-locator.el ends here
